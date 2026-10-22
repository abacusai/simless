// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import AppKit

/// Hosts driven by SimlessRuntime instead of SimlessKit's render protocol:
/// the unit-test host (slot kind "test") and UI-test app hosts ("ui1"...).
/// Each is its own installed copy of the app (macOS runs one instance per
/// bundle id), prepared from the same build as the render slot.
enum RuntimeHost {
    /// The `kind` slot, prepared and installed from the current build if it
    /// isn't already.
    static func slot(kind: String, ws: Workspace) throws -> SlotRecord {
        let settings = try ws.settings()
        let main = try currentSlot(ws)
        var slot = try GlobalState.slot(bundleBase: settings.bundleID, worktree: ws.root, kind: kind)
        let installed = ws.native ? Native.isNative(slot)
            : (try? FileManager.default.contentsOfDirectory(atPath: "\(slot.dir)/Debug-iphoneos/.XCInstall"))?.contains { $0.hasSuffix(".app") } ?? false
        if !installed || slot.builtAt < main.builtAt || !exists("\(slot.dir)/SimlessRuntime.dylib") {
            Slots.terminateAll(slot)
            try Slots.prepare(slot, ws: ws, settings: settings, embedded: ws.config.embeddedBundles ?? true)
            do {
                try Slots.install(slot, ws: ws)
            } catch where ws.config.embeddedBundles ?? true {
                try Slots.prepare(slot, ws: ws, settings: settings, embedded: false)
                try Slots.install(slot, ws: ws)
            }
            slot.builtAt = main.builtAt
            try GlobalState.update(slot)
        }
        try refreshRuntime(slot, team: settings.team)
        return slot
    }

    /// A newer simless brings a newer runtime; slots pick it up without a reinstall.
    static func refreshRuntime(_ slot: SlotRecord, team: String) throws {
        let runtime = Native.isNative(slot) ? try RuntimeBuild.nativeDylib() : try RuntimeBuild.dylib(team: team)
        let copy = "\(slot.dir)/SimlessRuntime.dylib"
        if mtime(copy) < mtime(runtime) || (try? FileManager.default.attributesOfItem(atPath: copy)[.size] as? Int) != (try? FileManager.default.attributesOfItem(atPath: runtime)[.size] as? Int) {
            try? FileManager.default.removeItem(atPath: copy)
            try FileManager.default.copyItem(atPath: runtime, toPath: copy)
        }
    }

    static func installedApp(_ slot: SlotRecord) throws -> String {
        if Native.isNative(slot) { return try Native.app(slot) }
        let dir = "\(slot.dir)/Debug-iphoneos/.XCInstall"
        guard let app = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.first(where: { $0.hasSuffix(".app") }) else {
            throw SimlessError("\(slot.slotID) is not installed")
        }
        return "\(dir)/\(app)"
    }

    /// The app inside the installed wrapper, where its bundle resources and PlugIns are.
    static func appBundle(_ slot: SlotRecord) throws -> String {
        let wrapper = try installedApp(slot)
        let inner = "\(wrapper)/Wrapper"
        let app = (try? FileManager.default.contentsOfDirectory(atPath: inner))?.first { $0.hasSuffix(".app") }
        return app.map { "\(inner)/\($0)" } ?? wrapper
    }

    /// Environment every simless launch gets: the runtime, the original bundle
    /// id, and read access to the repository.
    static func baseEnvironment(_ slot: SlotRecord) -> [String: String] {
        var env: [String: String] = ["SIMLESS_HEADLESS": "1", "SIMLESS_SLOT_ID": slot.slotID]
        // The device the canvas stands for, as UIDevice.model reports it.
        if let ws = try? Workspace.load(at: slot.worktree) { env["SIMLESS_DEVICE_MODEL"] = ws.config.device == "ipad" ? "iPad" : "iPhone" }
        let runtime = "\(slot.dir)/SimlessRuntime.dylib"
        if exists(runtime) { env["DYLD_INSERT_LIBRARIES"] = runtime }
        if let original = try? String(contentsOfFile: "\(slot.dir)/original-id.txt", encoding: .utf8) {
            env["SIMLESS_ORIGINAL_BUNDLE_ID"] = original
        }
        if Native.isNative(slot) { env.merge(Native.environment(slot)) { $1 } }
        if let ws = try? Workspace.load(at: slot.worktree), let network = networkPolicy(ws, testHost: slot.kind != nil) {
            env["SIMLESS_NETWORK"] = network
        }
        return env
    }

    /// What a host may reach, as SimlessRuntime reads it (Runtime/Network.swift),
    /// or nil for the real network. Render hosts get none by default, test hosts
    /// keep it unless `network.tests` is set, and SIMLESS_NETWORK=allow lets
    /// everything through for one command.
    static func networkPolicy(_ ws: Workspace, testHost: Bool) -> String? {
        let n = ws.config.network
        if ProcessInfo.processInfo.environment["SIMLESS_NETWORK"] == "allow" || n?.block == false { return nil }
        if testHost && n?.tests != true { return nil }
        var stubs: [String: String] = [:]
        for (pattern, file) in n?.stub ?? [:] { stubs[pattern] = file.hasPrefix("/") ? file : "\(ws.root)/\(file)" }
        let policy: [String: Any] = ["allow": n?.allow ?? [], "stub": stubs]
        return (try? JSONSerialization.data(withJSONObject: policy, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Requests the host blocked that `simless render` hasn't reported yet, as
    /// one line: per host, the first paths. Read from the host's log, so it
    /// works in the sandbox too.
    static func newlyBlocked(_ slot: SlotRecord) -> String? {
        let log = "\(slot.dir)/host.log"
        guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return nil }
        let urls = text.split(separator: "\n").compactMap { line -> URL? in
            guard let r = line.range(of: "simless-network: blocked ") else { return nil }
            return line[r.upperBound...].split(separator: " ", maxSplits: 1).last.flatMap { URL(string: String($0)) }
        }
        // Reported already: counted per log (a relaunch starts a new one).
        let seenPath = "\(slot.dir)/network-reported"
        let created = (try? FileManager.default.attributesOfItem(atPath: log))?[.creationDate] as? Date
        let stamp = "\(Int((created?.timeIntervalSince1970 ?? 0) * 1000))"
        let seen = (try? String(contentsOfFile: seenPath, encoding: .utf8))?.split(separator: " ").map(String.init) ?? []
        let already = seen.count == 2 && seen[0] == stamp ? Int(seen[1]) ?? 0 : 0
        guard urls.count > already else { return nil }
        try? "\(stamp) \(urls.count)".write(toFile: seenPath, atomically: true, encoding: .utf8)
        var byHost: [(host: String, paths: [String])] = []
        for u in urls.dropFirst(already) {
            let host = u.host ?? "?", path = u.path.isEmpty ? "/" : u.path
            if let i = byHost.firstIndex(where: { $0.host == host }) {
                if !byHost[i].paths.contains(path) { byHost[i].paths.append(path) }
            } else { byHost.append((host, [path])) }
        }
        let hosts = byHost.map { h in
            h.host + " (" + h.paths.prefix(3).joined(separator: ", ") + (h.paths.count > 3 ? ", +\(h.paths.count - 3)" : "") + ")"
        }
        let n = urls.count - already
        return "network: blocked \(n) request\(n == 1 ? "" : "s"): " + hosts.joined(separator: "; ")
            + "; .simless.json \"network.allow\" lets a host through"
    }

    /// Launches the host with the runtime listening on the slot's port.
    /// Returns once the runtime answers.
    static func launch(_ slot: SlotRecord, env extra: [String: String], args: [String] = [], timeout: Double = 120) throws {
        do {
            try launchOnce(slot, env: extra, args: args, timeout: timeout)
        } catch let e as Exited {
            // Now and then a host quits while it starts, with no crash and
            // nothing in its log: start it once more, as render hosts do.
            Log.debug("\(e.message); starting it again")
            do { try launchOnce(slot, env: extra, args: args, timeout: timeout) } catch let again as Exited { throw SimlessError(again.message) }
        }
    }

    private struct Exited: Error { let message: String }

    private static func launchOnce(_ slot: SlotRecord, env extra: [String: String], args: [String], timeout: Double) throws {
        terminateAll(slot)
        let app = try installedApp(slot)
        var env = baseEnvironment(slot)
        env["SIMLESS_RUNTIME_PORT"] = String(slot.port)
        for (k, v) in extra { env[k] = v }
        try? FileManager.default.removeItem(atPath: "\(slot.dir)/host.log")
        if Native.isNative(slot) {
            try Native.launch(slot, env: env, args: args, log: "\(slot.dir)/host.log")
        } else {
            var cmd = ["/usr/bin/open", "-g", "-j", "--stderr", "\(slot.dir)/host.log", "--stdout", "\(slot.dir)/host.log"]
            for (k, v) in env.sorted(by: { $0.key < $1.key }) { cmd += ["--env", "\(k)=\(v)"] }
            cmd.append(app)
            if !args.isEmpty { cmd += ["--args"] + args }
            let r = try Shell.run(cmd)
            guard r.code == 0 else { throw SimlessError("could not launch \(slot.slotID): \(r.out)") }
        }
        let deadline = now() + timeout
        while now() < deadline {
            if let c = try? LineClient(port: slot.port, timeout: 2), let h = try? c.call(["cmd": "hello"]), h["ok"] as? Bool == true {
                return
            }
            if now() > deadline - timeout + 5, !hasProcess(slot) {
                if let trap = CrashReport.hostTrap(slot) {
                    throw SimlessError("\(slot.slotID) exited while starting: \(trap); log: \(slot.dir)/host.log")
                }
                throw Exited(message: "\(slot.slotID) exited while starting; log: \(slot.dir)/host.log")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw SimlessError("\(slot.slotID) did not start within \(Int(timeout))s; log: \(slot.dir)/host.log")
    }

    /// Any process of the slot, answering or not.
    static func hasProcess(_ slot: SlotRecord) -> Bool {
        !Native.pids(slot).isEmpty || !NSRunningApplication.runningApplications(withBundleIdentifier: slot.slotID).isEmpty
    }

    static func isRunning(_ slot: SlotRecord) -> Bool {
        guard let c = try? LineClient(port: slot.port, timeout: 1) else { return false }
        return (try? c.call(["cmd": "hello"])) != nil
    }

    static func terminateAll(_ slot: SlotRecord) { Slots.terminateAll(slot) }

    /// Memory and CPU of the slot's process, for `simless status`.
    static func usage(_ slot: SlotRecord) -> (mb: Double, cpu: Double)? {
        guard let pid = Native.pids(slot).first ?? NSRunningApplication.runningApplications(withBundleIdentifier: slot.slotID).first?.processIdentifier
        else { return nil }
        let out = (try? Shell.run(["/bin/ps", "-o", "rss=,%cpu=", "-p", String(pid)]).out) ?? ""
        let parts = out.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0] / 1024, parts[1])
    }
}
