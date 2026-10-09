// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// `simless calibrate`: how far simless's renders can be trusted for this app.
/// Runs the same SimlessKit inside one iOS Simulator, renders every fixture on
/// both the Mac host and the simulator, and compares the accessibility trees:
/// same elements, labels and order, frames within a tolerance. This is the only
/// simless command that boots a simulator; it is meant to be run once per app
/// (and after big UI changes), not in the edit loop.
enum Calibrate {
    static let tolerance = 2.0   // points
    static let deviceName = "simless-calibrate"

    static func run(ws: Workspace, slot: SlotRecord, only: String?) throws {
        let t = now()
        let host = slot.stats() == nil ? try { try Slots.launch(slot, idleMinutes: ws.idleMinutes); return slot }() : slot
        let fixtures = only.map { [$0] } ?? (host.stats()?["fixtures"] as? [String] ?? [])
        guard !fixtures.isEmpty else { throw SimlessError("no fixtures registered in \(ws.config.fixturesFile)") }
        let canvas = try Render.canvas("iphone")

        let udid = try createSimulator()
        defer { deleteSimulator(udid) }
        let simPort = slot.port + 1000
        try buildAndLaunch(ws: ws, udid: udid, port: simPort)
        let sim = try LineClient(port: simPort, timeout: 30)
        let mac = try host.client(timeout: 30)

        var matched = 0
        var report: [String] = []
        for fixture in fixtures {
            let a = try mac.call(Render.request(fixture: fixture, dark: false, canvas: canvas, image: false))
            let b = try sim.call(Render.request(fixture: fixture, dark: false, canvas: canvas, image: false))
            guard a["ok"] as? Bool == true, b["ok"] as? Bool == true else {
                report.append("✗ \(fixture): render failed (\(a["error"] ?? b["error"] ?? "?"))")
                continue
            }
            let (ok, lines) = compare(a["nodes"] as? [[String: Any]] ?? [], b["nodes"] as? [[String: Any]] ?? [])
            if ok { matched += 1 }
            report.append("\(ok ? "✓" : "✗") \(fixture)")
            report += lines.map { "    " + $0 }
        }
        print("calibration against \(Self.simDeviceType) simulator (frames within \(Int(tolerance)) pt):")
        report.forEach { print("  " + $0) }
        print("\(matched)/\(fixtures.count) fixtures render the same as in the simulator (\(secs(t)))")
        if matched < fixtures.count {
            print("For mismatching fixtures, confirm visual changes in the simulator; simless renders of them are less trustworthy.")
        }
    }

    // MARK: - Comparison

    private static func key(_ n: [String: Any]) -> String {
        "\(n["role"] ?? "")|\(n["label"] ?? "")|\(n["id"] ?? "")"
    }

    private static func frame(_ n: [String: Any]) -> [Double] { n["frame"] as? [Double] ?? [0, 0, 0, 0] }

    /// Aligns the two trees (longest common subsequence of role/label/id), then
    /// checks frames of the aligned elements.
    static func compare(_ mac: [[String: Any]], _ sim: [[String: Any]]) -> (Bool, [String]) {
        let a = mac.map(key), b = sim.map(key)
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var lines: [String] = []
        var i = 0, j = 0, worst = 0.0
        func describe(_ n: [String: Any]) -> String {
            "\(n["role"] ?? "element") \((n["label"] as? String).map { "\"\($0)\"" } ?? "(no label)")"
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                let fa = frame(mac[i]), fb = frame(sim[j])
                let d = zip(fa, fb).map { abs($0 - $1) }.max() ?? 0
                worst = max(worst, d)
                if d > tolerance {
                    lines.append(String(format: "%@ differs by %.1f pt: mac @%.0f,%.0f %.0f×%.0f, simulator @%.0f,%.0f %.0f×%.0f",
                                        describe(mac[i]), d, fa[0], fa[1], fa[2], fa[3], fb[0], fb[1], fb[2], fb[3]))
                }
                i += 1; j += 1
            } else if j < b.count, i == a.count || dp[i][j + 1] >= dp[i + 1][j] {
                lines.append("only in simulator: \(describe(sim[j]))"); j += 1
            } else {
                lines.append("only in simless: \(describe(mac[i]))"); i += 1
            }
        }
        if lines.isEmpty { lines.append(String(format: "%d elements, largest frame difference %.1f pt", mac.count, worst)) }
        return (lines.count == 1 && lines[0].hasSuffix("pt") && !lines[0].contains("differs"), lines)
    }

    // MARK: - Simulator

    static let simDeviceType = "iPhone 17 Pro"

    private static func createSimulator() throws -> String {
        deleteStale()
        let runtimes = try Shell.check(["xcrun", "simctl", "list", "runtimes", "-j"], stdoutOnly: true)
        guard let json = try JSONSerialization.jsonObject(with: Data(runtimes.utf8)) as? [String: Any],
              let list = json["runtimes"] as? [[String: Any]],
              let runtime = list.filter({ ($0["platform"] as? String) == "iOS" && ($0["isAvailable"] as? Bool) == true })
                .compactMap({ $0["identifier"] as? String }).last else {
            throw SimlessError("no iOS simulator runtime installed (Xcode → Settings → Components)")
        }
        let udid = try Shell.check(["xcrun", "simctl", "create", deviceName, simDeviceType, runtime], stdoutOnly: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Log.step("booting \(simDeviceType) simulator for calibration")
        _ = try Shell.run(["xcrun", "simctl", "boot", udid])
        try Shell.check(["xcrun", "simctl", "bootstatus", udid, "-b"], what: "simulator boot")
        return udid
    }

    private static func deleteStale() {
        let list = (try? Shell.run(["xcrun", "simctl", "list", "devices"]).out) ?? ""
        for line in list.split(separator: "\n") where line.contains(deviceName + " (") {
            if let r = line.range(of: #"[0-9A-F-]{36}"#, options: .regularExpression) { deleteSimulator(String(line[r])) }
        }
    }

    private static func deleteSimulator(_ udid: String) {
        _ = try? Shell.run(["xcrun", "simctl", "shutdown", udid])
        _ = try? Shell.run(["xcrun", "simctl", "delete", udid])
    }

    private static func buildAndLaunch(ws: Workspace, udid: String, port: Int) throws {
        let project = try ws.buildProject()
        let dd = "\(ws.work)/SimDerivedData"
        let log = "\(ws.work)/calibrate-build.log"
        let settings = try ws.settings()
        try withBuildToken(count: ws.config.buildConcurrency ?? max(1, ProcessInfo.processInfo.activeProcessorCount / 5)) {
            Log.step("building \(ws.config.scheme) for the simulator (log: \(log))")
            let r = try Shell.run(["xcodebuild", "build", "-project", project, "-scheme", ws.config.scheme,
                                   "-configuration", "Debug", "-destination", "platform=iOS Simulator,id=\(udid)",
                                   "-derivedDataPath", dd, "-skipMacroValidation", "-skipPackagePluginValidation",
                                   "CODE_SIGNING_ALLOWED=NO"], cwd: ws.root, logPath: log)
            guard r.code == 0 else { throw SimlessError("simulator build failed:\n" + Patch.compilerErrors(r.out)) }
        }
        let app = "\(dd)/Build/Products/Debug-iphonesimulator/\(settings.wrapperName)"
        try Shell.check(["xcrun", "simctl", "install", udid, app], what: "install in simulator")
        try Shell.check(["xcrun", "simctl", "launch", udid, settings.bundleID, "--simless-port", String(port)],
                        what: "launch in simulator")
        let deadline = now() + 90
        while now() < deadline {
            if let c = try? LineClient(port: port, timeout: 3), (try? c.call(["cmd": "stats"]))?["ok"] as? Bool == true { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw SimlessError("the app did not start its render server in the simulator")
    }
}
