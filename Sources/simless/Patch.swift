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
        let compile: Double
        let apply: Double
    }

    static func apply(ws: Workspace, slot: inout SlotRecord, files: [String]) throws -> Result {
        let settings = try ws.settings()
        let t0 = now()
        let scope = try PatchScope.files(ws: ws, edited: files)
        let dylib = try compile(ws: ws, slot: slot, settings: settings, files: scope.all)
        Cleanup.prunePatches(ws: ws)
        let tCompile = now() - t0

        let t1 = now()
        var mode = Mode.warm
        do {
            if try live(dylib: dylib, slot: slot) == nil { mode = .live }
        } catch {
            Log.info("  live reload failed (\(error)); falling back to warm reload")
        }
        if mode == .warm { try warm(dylib: dylib, slot: slot, ws: ws, settings: settings) }
        slot.patch += 1
        slot.lastPatch = dylib
        try GlobalState.update(slot)
        return Result(mode: mode, files: files, extra: scope.extra, compile: tCompile, apply: now() - t1)
    }

    // MARK: - Compile

    static func compile(ws: Workspace, slot: SlotRecord, settings: Workspace.Settings, files: [String]) throws -> String {
        let dir = "\(ws.work)/patches"
        try mkdirp(dir)
        let module = "SimlessPatch\(slot.n)x\(slot.patch + 1)x\(Int(Date().timeIntervalSince1970) % 100000)"
        let fixtures = "\(ws.root)/\(ws.config.fixturesFile)"

        // Each source gets the app module in scope; its own types shadow the app's.
        var sources: [String] = []
        var originals: [String: String] = [:]   // patch copy -> edited file, for error messages
        for file in [fixtures] + files.filter({ $0 != fixtures }) {
            let dst = "\(dir)/\(module)_\((file as NSString).lastPathComponent)"
            originals[dst] = file
            let body = try String(contentsOfFile: file, encoding: .utf8)
            try ("@testable import \(settings.moduleName)\n" + body).write(toFile: dst, atomically: true, encoding: .utf8)
            sources.append(dst)
        }
        let entry = "\(dir)/\(module)_entry.swift"
        try """
            @testable import \(settings.moduleName)

            @_cdecl("simless_patch_entry")
            nonisolated public func simless_patch_entry(_ registry: UnsafeMutableRawPointer) {
                MainActor.assumeIsolated {
                    simlessFixtures(Unmanaged<SimlessRegistry>.fromOpaque(registry).takeUnretainedValue())
                }
            }
            """.write(toFile: entry, atomically: true, encoding: .utf8)
        sources.append(entry)

        let sdk = try Shell.check(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let out = "\(dir)/\(module).dylib"
        var args = ["xcrun", "swiftc", "-module-name", module, "-emit-library", "-o", out,
                    "-target", "arm64-apple-ios\(settings.deploymentTarget)", "-sdk", sdk, "-Onone",
                    "-swift-version", settings.swiftVersion,
                    "-I", ws.productsIphoneos, "-F", ws.productsIphoneos,
                    "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
                    "-suppress-warnings", "-module-cache-path", "\(ws.work)/ModuleCache"]
        if let iso = settings.defaultIsolation { args += ["-default-isolation", iso] }
        for f in settings.upcomingFeatures { args += ["-enable-upcoming-feature", f] }
        for c in settings.conditions { args += ["-D", c] }
        for map in moduleMaps(ws: ws) { args += ["-Xcc", "-fmodule-map-file=\(map)", "-Xcc", "-I\((map as NSString).deletingLastPathComponent)"] }
        let tc = now()
        let r = try Shell.run(args + sources)
        Log.debug("swiftc \(secs(tc))")
        guard r.code == 0 else {
            throw SimlessError("patch compile failed:\n" + compilerErrors(r.out, originals: originals))
        }
        let ts = now()
        let (identity, _) = try Signing.identity(team: settings.team)
        try Signing.sign(out, identity: identity)
        Log.debug("sign \(secs(ts))")
        return out
    }

    /// `path:line:col: error: ...` lines, pointed back at the edited files
    /// (patch copies have one extra import line at the top).
    static func compilerErrors(_ log: String, originals: [String: String] = [:]) -> String {
        var seen = Set<String>()
        var out: [String] = []
        for raw in log.split(separator: "\n") {
            var line = String(raw)
            guard line.range(of: #"^/.+:\d+:\d+: error: "#, options: .regularExpression) != nil else { continue }
            for (copy, original) in originals where line.hasPrefix(copy + ":") {
                let rest = line.dropFirst(copy.count + 1)
                let parts = rest.split(separator: ":", maxSplits: 1)
                if let n = Int(parts[0]), parts.count == 2 { line = "\(original):\(n - 1):\(parts[1])" }
            }
            if seen.insert(line).inserted { out.append("  " + line) }
            if out.count == 20 { break }
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
        let checkouts = (try? Shell.run(["/usr/bin/find", "\(ws.derivedData)/SourcePackages/checkouts",
                                         "-name", "module.modulemap"]).out) ?? ""
        maps += checkouts.split(separator: "\n").map(String.init).filter { path in
            !["/Tests/", "/Examples/", "/Example/", "/.build/", "/Benchmarks/"].contains { path.contains($0) }
        }
        let include = "\(ws.productsIphoneos)/include/module.modulemap"
        if exists(include) { maps.append(include) }
        return maps
    }

    // MARK: - Apply

    /// Live (~0.2 s): SimlessAgent (Full Disk Access) places the patch in the
    /// host's own tmp dir, unquarantined, and the host dlopens it in place.
    /// Returns nil on success, or why live reload isn't available.
    static func live(dylib: String, slot: SlotRecord) throws -> String? {
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
