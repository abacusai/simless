// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// Hot reload. Edited view files are compiled, together with the fixtures
/// file, into a small dylib (its own module, `@testable import`ing the app).
/// The patch's copies of the edited types shadow the app's, so its
/// `simlessFixtures` builds every fixture from the new code. Everything else
/// resolves against the app's debug dylib at load time.
enum Patch {
    enum Mode: String { case live, warm }

    struct Result {
        let mode: Mode
        let files: [String]
        let extra: [String]     // unedited files patched because they embed an edited view
        let stale: [String]     // fixtures that reach the edit but still render the last build
        let compile: Double
        let apply: Double
    }

    /// Patches `files` so that `fixtures` (all of them when nil) render them.
    static func apply(ws: Workspace, slot: inout SlotRecord, files: [String], fixtures: [String]? = nil) throws -> Result {
        let settings = try ws.settings()
        let t0 = now()
        let scope = try scope(ws: ws, slot: slot, files: files, fixtures: fixtures)
        let dylib: String
        if scope.previews.isEmpty {
            dylib = try compile(ws: ws, slot: slot, settings: settings, files: scope.all, texts: scope.texts)
        } else {
            // Previews the reload renders compile into it, from their files.
            let p = Previews.patchCode(ws: ws, names: scope.previews, kept: scope.kept, texts: scope.texts)
            dylib = try compile(ws: ws, slot: slot, settings: settings, files: scope.all, texts: p.texts, prelude: p.prelude, entry: p.entry)
        }
        Cleanup.prunePatches(ws: ws)
        let tCompile = now() - t0

        let t1 = now()
        var mode = Mode.warm
        do {
            if try live(dylib: dylib, slot: slot) == nil { mode = .live }
        } catch {
            Log.info("  live reload failed (\(error)); falling back to warm reload")
        }
        if mode == .warm, Native.isNative(slot) {
            // No warm mode natively: start the host again and load the patch into it.
            Slots.stop(slot)
            try Slots.launch(slot, idleMinutes: ws.idleMinutes)
            if let why = try live(dylib: dylib, slot: slot) { throw SimlessError("could not load the patch: \(why)") }
            mode = .live
        }
        if mode == .warm { try warm(dylib: dylib, slot: slot, ws: ws, settings: settings) }
        slot.patch += 1
        slot.lastPatch = dylib
        slot.covered = scope.covered
        slot.stale = scope.stale
        try GlobalState.update(slot)
        return Result(mode: mode, files: files, extra: scope.extra, stale: scope.stale, compile: tCompile, apply: now() - t1)
    }

    /// The requested fixtures plus the ones the last patch covered, so a reload
    /// for one screen doesn't make the previous one stale; just the requested
    /// ones when both don't fit in one patch.
    static func scope(ws: Workspace, slot: SlotRecord, files: [String], fixtures: [String]?) throws -> PatchScope.Scope {
        guard let fixtures else { return try PatchScope.files(ws: ws, edited: files) }
        let previous = (slot.covered ?? []).filter { !fixtures.contains($0) }
        if !previous.isEmpty, let both = try? PatchScope.files(ws: ws, edited: files, fixtures: fixtures + previous) { return both }
        return try PatchScope.files(ws: ws, edited: files, fixtures: fixtures)
    }

    // MARK: - Compile

    /// Fixtures from `#Preview` blocks live in their own dylib (Previews.swift),
    /// which `simless up` loads. A patch's registry replaces the host's, so its
    /// entry registers them again when that dylib is loaded.
    static let registerPreviews = """
            if let previews = NSClassFromString("SimlessPreviewRegistrations") as? NSObject.Type {
                _ = previews.perform(NSSelectorFromString("registerInto:"), with: NSNumber(value: address))
            }
    """

    /// `prelude` is top-level code for the entry file, `entry` runs after
    /// `simlessFixtures` with `r` (the registry) and `address` in scope.
    static func compile(ws: Workspace, slot: SlotRecord, settings: Workspace.Settings, files: [String],
                        texts: [String: String] = [:], name: String = "SimlessPatch", dir: String? = nil,
                        prelude: String = "", entry entryCode: String = registerPreviews) throws -> String {
        let dir = dir ?? "\(ws.work)/patches"
        try mkdirp(dir)
        let module = "\(name)\(slot.n)x\(slot.patch + 1)x\(Int(Date().timeIntervalSince1970) % 100000)"
        let fixtures = "\(ws.root)/\(ws.config.fixturesFile)"

        // Which module each file comes from: the app target, or a local package
        // module. The patch is one module, so all non-fixture files must share
        // compiler settings; the fixtures file only constructs views and compiles
        // under theirs.
        let packageModules = Packages.modules(ws: ws)
        let appSettings = ModuleSettings(swiftVersion: settings.swiftVersion, isolation: settings.defaultIsolation,
                                         features: settings.upcomingFeatures.sorted())
        var modulesInvolved = [settings.moduleName]
        var settingsByModule: [String: ModuleSettings] = [:]
        for file in files where file != fixtures {
            if let m = Packages.module(of: file, in: packageModules) {
                settingsByModule[m.name] = ModuleSettings(swiftVersion: m.swiftVersion, isolation: m.defaultIsolation,
                                                          features: m.upcomingFeatures)
                if !modulesInvolved.contains(m.name) { modulesInvolved.append(m.name) }
            } else {
                settingsByModule[settings.moduleName] = appSettings
            }
        }
        let distinct = Set(settingsByModule.values)
        if distinct.count > 1 {
            let detail = settingsByModule.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            throw SimlessError("patch can't cover this edit: it spans modules with different compiler settings (\(detail))")
        }
        let effective = distinct.first ?? appSettings

        // Each source gets every involved module in scope (@testable, for internal
        // declarations); its own types shadow theirs.
        let imports = modulesInvolved.map { "@testable import \($0)\n" }.joined()
        var sources: [String] = []
        var originals: [String: String] = [:]   // patch copy -> edited file, for error messages
        for file in [fixtures] + files.filter({ $0 != fixtures }) {
            let dst = "\(dir)/\(module)_\(sources.count)_\((file as NSString).lastPathComponent)"
            originals[dst] = file
            let body = try texts[file] ?? String(contentsOfFile: file, encoding: .utf8)
            try (imports + body).write(toFile: dst, atomically: true, encoding: .utf8)
            sources.append(dst)
        }
        let entry = "\(dir)/\(module)_entry.swift"
        try """
            import Foundation
            @testable import \(settings.moduleName)
            \(prelude)
            // The address crosses into the main actor as an Int (Sendable), so this
            // compiles under Swift 6 whatever the module's default isolation.
            @_cdecl("simless_patch_entry")
            nonisolated public func simless_patch_entry(_ registry: UnsafeMutableRawPointer) {
                let address = Int(bitPattern: registry)
                MainActor.assumeIsolated {
                    let pointer = UnsafeRawPointer(bitPattern: address)!
                    let r = Unmanaged<SimlessRegistry>.fromOpaque(pointer).takeUnretainedValue()
                    simlessFixtures(r)
            \(entryCode)
                }
            }
            """.write(toFile: entry, atomically: true, encoding: .utf8)
        sources.append(entry)

        let sdk = try Shell.check(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let out = "\(dir)/\(module).dylib"
        var args = ["xcrun", "swiftc", "-module-name", module, "-emit-library", "-o", out,
                    "-target", "arm64-apple-ios\(settings.deploymentTarget)", "-sdk", sdk, "-Onone",
                    "-swift-version", effective.swiftVersion,
                    "-I", ws.productsIphoneos, "-F", ws.productsIphoneos, "-Xcc", "-I\(ws.productsIphoneos)/include",
                    "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
                    "-suppress-warnings", "-module-cache-path", "\(ws.work)/ModuleCache",
                    // One frontend job per file: each loads the app's modules once, side by
                    // side (the driver runs one job without -j: 3.5 s against 2.1 s for two
                    // edited files in a 700-file app).
                    "-j", "\(max(1, min(files.count + 1, ProcessInfo.processInfo.activeProcessorCount)))"]
        if let iso = effective.isolation { args += ["-default-isolation", iso] }
        for f in effective.features { args += ["-enable-upcoming-feature", f] }
        for c in settings.conditions { args += ["-D", c] }
        var includes = Set<String>()
        for map in moduleMaps(ws: ws) {
            args += ["-Xcc", "-fmodule-map-file=\(map)"]
            for dir in includeDirs(map: map) where includes.insert(dir).inserted { args += ["-Xcc", "-I\(dir)"] }
        }
        let tc = now()
        let r = try Shell.run(args + sources)
        Log.debug("swiftc \(secs(tc))")
        guard r.code == 0 else {
            throw SimlessError("patch compile failed:\n" + compilerErrors(r.out, originals: originals, lineOffset: modulesInvolved.count))
        }
        let ts = now()
        // By the workspace's mode, not the slot's: previews compile while the
        // slot is being prepared again, when its native marker isn't there yet.
        if ws.native {
            try Native.adopt([out])
        } else {
            let (identity, _) = try Signing.identity(team: settings.team)
            try Signing.sign(out, identity: identity)
        }
        Log.debug("sign \(secs(ts))")
        return out
    }

    struct ModuleSettings: Hashable, CustomStringConvertible {
        let swiftVersion: String
        let isolation: String?
        let features: [String]
        var description: String {
            "Swift \(swiftVersion), \(isolation ?? "nonisolated") default isolation"
                + (features.isEmpty ? "" : ", " + features.joined(separator: "+"))
        }
    }

    /// `path:line:col: error: ...` lines, pointed back at the edited files
    /// (patch copies have `lineOffset` extra import lines at the top).
    static func compilerErrors(_ log: String, originals: [String: String] = [:], lineOffset: Int = 1) -> String {
        var seen = Set<String>()
        var out: [String] = []
        for raw in log.split(separator: "\n") {
            var line = String(raw)
            guard line.range(of: #"^/.+:\d+:\d+: error: "#, options: .regularExpression) != nil else { continue }
            for (copy, original) in originals where line.hasPrefix(copy + ":") {
                let rest = line.dropFirst(copy.count + 1)
                let parts = rest.split(separator: ":", maxSplits: 1)
                if let n = Int(parts[0]), parts.count == 2 { line = "\(original):\(n - lineOffset):\(parts[1])" }
            }
            if seen.insert(line).inserted { out.append("  " + line) }
            if out.count == 20 { break }
        }
        if log.contains("No space left on device") {
            return "  the disk is full (No space left on device); free some space and build again (`simless status` shows what simless uses)"
        }
        if out.isEmpty {
            // Errors without a file (the build system's own): the first few.
            let general = log.split(separator: "\n").filter { $0.hasPrefix("error: ") || $0.hasPrefix("fatal error: ") }.prefix(5).map { "  " + $0 }
            if !general.isEmpty { return general.joined(separator: "\n") }
        }
        return out.isEmpty ? "  (no error lines found)" : out.joined(separator: "\n")
    }

    /// Clang module maps that `import <App>` transitively needs: generated maps
    /// for Swift packages, C targets in package checkouts, binary frameworks'
    /// headers copied to Products/include.
    private static func moduleMaps(ws: Workspace) -> [String] {
        var maps: [String] = []
        let generated = "\(ws.derivedData)/Build/Intermediates.noindex/GeneratedModuleMaps-iphoneos"
        maps += ((try? FileManager.default.contentsOfDirectory(atPath: generated)) ?? [])
            .filter { $0.hasSuffix(".modulemap") }.map { "\(generated)/\($0)" }
        // find(1), not a recursive glob: package checkouts contain symlink cycles.
        // Stdout only, and only when there are checkouts: find's "No such file"
        // on stderr would otherwise become a module map path and fail the patch.
        // Cached until package resolution changes: find takes 0.25 s on a big app.
        let dir = "\(ws.derivedData)/SourcePackages/checkouts"
        let resolved = "\(ws.derivedData)/SourcePackages/workspace-state.json"
        let cache = "\(ws.work)/checkout-modulemaps-\(Int(mtime(dir) * 1000))-\(Int(mtime(resolved) * 1000)).txt"
        var checkouts = (try? String(contentsOfFile: cache, encoding: .utf8)) ?? ""
        if checkouts.isEmpty, exists(dir) {
            checkouts = (try? Shell.run(["/usr/bin/find", dir, "-name", "module.modulemap"], stdoutOnly: true).out) ?? ""
            for old in ((try? FileManager.default.contentsOfDirectory(atPath: ws.work)) ?? []) where old.hasPrefix("checkout-modulemaps-") {
                try? FileManager.default.removeItem(atPath: "\(ws.work)/\(old)")
            }
            try? checkouts.write(toFile: cache, atomically: true, encoding: .utf8)
        }
        maps += checkouts.split(separator: "\n").map(String.init).filter { path in
            path.hasSuffix("module.modulemap") &&
            !["/Tests/", "/Examples/", "/Example/", "/.build/", "/Benchmarks/", "-simulator/", "-maccatalyst/"].contains { path.contains($0) }
        }
        // Binary frameworks' headers copied to Products/include: one map at the
        // top, and static xcframeworks' each in a folder of their own.
        let include = "\(ws.productsIphoneos)/include"
        if exists("\(include)/module.modulemap") { maps.append("\(include)/module.modulemap") }
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: include)) ?? [] where exists("\(include)/\(dir)/module.modulemap") {
            maps.append("\(include)/\(dir)/module.modulemap")
        }
        return maps
    }

    /// Header search paths a module map's headers need: its own folder, and
    /// for a generated map (a package's C target) the folder its umbrella is
    /// in, which is where that target's `#include <Module/Header.h>`s resolve,
    /// as Xcode passes it.
    static func includeDirs(map: String) -> [String] {
        var dirs = [(map as NSString).deletingLastPathComponent]
        let text = (try? String(contentsOfFile: map, encoding: .utf8)) ?? ""
        let umbrella = try! NSRegularExpression(pattern: #"umbrella\s+(header\s+)?"([^"]+)""#)
        for m in umbrella.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            let path = (text as NSString).substring(with: m.range(at: 2))
            guard path.hasPrefix("/") else { continue }
            if m.range(at: 1).location == NSNotFound {
                dirs.append(path)                                    // umbrella "<Public>"
            } else {
                let folder = (path as NSString).deletingLastPathComponent   // <Public>/<Module>/<Module>.h
                dirs += [folder, (folder as NSString).deletingLastPathComponent]
            }
        }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }
    }

    // MARK: - Apply

    /// Live (~0.2 s): SimlessAgent (Full Disk Access) places the patch in the
    /// host's own tmp dir, unquarantined, and the host dlopens it in place.
    /// Returns nil on success, or why live reload isn't available.
    static func live(dylib: String, slot: SlotRecord) throws -> String? {
        if Native.isNative(slot) { return try liveNative(dylib: dylib, slot: slot) }
        guard let agent = try? Agent.client() else { return "agent not running" }
        guard let tmp = slot.stats()?["tmp"] as? String else { return "host not running" }
        let name = (dylib as NSString).lastPathComponent
        let placed = try agent.call(["cmd": "place", "src": dylib, "dst": "\(tmp)/\(name)"])
        guard placed["ok"] as? Bool == true else {
            let why = placed["error"] as? String ?? "agent refused"
            Log.info("  live reload unavailable: \(why)")
            return why
        }
        let r = try slot.client().call(["cmd": "load", "file": name])
        guard r["ok"] as? Bool == true else { throw SimlessError("host failed to load patch: \(r["error"] ?? "?")") }
        return nil
    }

    /// Live without the agent: a native host isn't sandboxed, so nothing
    /// quarantines a file simless puts in its tmp folder.
    private static func liveNative(dylib: String, slot: SlotRecord) throws -> String? {
        guard let tmp = slot.stats()?["tmp"] as? String else { return "host not running" }
        let name = (dylib as NSString).lastPathComponent
        let placed = "\(tmp)/\(name)"
        guard placed.hasPrefix(Native.home(slot) + "/") || URL(fileURLWithPath: placed).standardizedFileURL.path.hasPrefix(Native.home(slot) + "/") else {
            // An app without SimlessRuntime's tmp redirect: never write into the user's shared tmp.
            return "host tmp \(tmp) is outside the slot"
        }
        try? FileManager.default.removeItem(atPath: placed)
        try FileManager.default.copyItem(atPath: dylib, toPath: placed)
        let r = try slot.client().call(["cmd": "load", "file": name])
        guard r["ok"] as? Bool == true else { throw SimlessError("host failed to load patch: \(r["error"] ?? "?")") }
        return nil
    }

    /// Warm (~5–7 s, no permissions): the patch ships inside the slot app,
    /// which is re-signed, reinstalled and relaunched; the host loads it at start.
    static func warm(dylib: String, slot: SlotRecord, ws: Workspace, settings: Workspace.Settings) throws {
        let app = "\(slot.dir)/Debug-iphoneos/\(settings.wrapperName)"
        let dir = "\(app)/SimlessPatches"
        try? FileManager.default.removeItem(atPath: dir)
        try mkdirp(dir)
        try FileManager.default.copyItem(atPath: dylib, toPath: "\(dir)/\((dylib as NSString).lastPathComponent)")
        let signing = try Signing.material(team: settings.team)
        try Signing.sign(app, identity: signing.identity, entitlements: "\(slot.dir)/entitlements.plist")
        try Slots.install(slot, ws: ws)
        try Slots.launch(slot, idleMinutes: ws.idleMinutes)
    }
}
