// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// SimlessAgent lifecycle. The agent is optional: without it (or without
/// Full Disk Access) reloads fall back to warm mode.
enum Agent {
    static func client() throws -> LineClient {
        if let c = try? LineClient(unixPath: Paths.agentSocket), (try? c.call(["cmd": "ping"]))?["ok"] as? Bool == true {
            return c
        }
        guard exists(Paths.agentApp) else { throw SimlessError("agent not installed (`simless agent install`)") }
        _ = try? Shell.run(["/usr/bin/open", "-g", "-j", Paths.agentApp, "--args", Paths.agentSocket])
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.1)
            if let c = try? LineClient(unixPath: Paths.agentSocket), (try? c.call(["cmd": "ping"]))?["ok"] as? Bool == true {
                return c
            }
        }
        throw SimlessError("agent did not start")
    }

    /// Builds SimlessAgent.app from the bundled source and signs it with the
    /// team's development identity. Rebuilding with the same identity and bundle
    /// id keeps an existing Full Disk Access grant.
    static func install(team: String) throws {
        let src = "\(Paths.toolRoot)/Agent"
        let app = Paths.agentApp
        let (identity, name) = try Signing.identity(team: team)
        Log.step("building SimlessAgent (signed by \(name))")
        _ = try? Shell.run(["/usr/bin/pkill", "-f", "SimlessAgent.app/Contents/MacOS/SimlessAgent"])
        try? FileManager.default.removeItem(atPath: app)
        try mkdirp("\(app)/Contents/MacOS")
        try Shell.check(["xcrun", "swiftc", "-O", "\(src)/main.swift", "-o", "\(app)/Contents/MacOS/SimlessAgent"],
                        what: "compile agent")
        try FileManager.default.copyItem(atPath: "\(src)/Info.plist", toPath: "\(app)/Contents/Info.plist")
        try Shell.check(["/usr/bin/codesign", "-f", "-s", identity, "--options", "runtime", app], what: "sign agent")
        _ = try client()
        Log.step("agent running: \(app)")
    }

    /// nil when live reload works, else the reason it doesn't.
    static func liveStatus(probeSlot: SlotRecord?) -> String? {
        guard let agent = try? client() else { return "agent not installed or not running (`simless agent install`)" }
        guard let slot = probeSlot, let tmp = slot.stats()?["tmp"] as? String else { return nil }
        // An empty placement probes Full Disk Access without writing anything useful.
        let r = try? agent.call(["cmd": "place", "src": "\(Paths.cache)/.probe.dylib", "dst": "\(tmp)/.probe.dylib"])
        if let e = r?["error"] as? String, e.contains("Full Disk Access") { return e }
        return nil
    }
}
