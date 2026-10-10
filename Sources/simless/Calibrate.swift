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

    struct Options {
        var only: String?
        var imagesDir: String?   // save both renders of every screen + report.md here
        var dark = false         // also compare dark mode
    }

    static func run(ws: Workspace, slot: SlotRecord, options: Options) throws {
        let t = now()
        let host = slot.stats() == nil ? try { try Slots.launch(slot, idleMinutes: ws.idleMinutes); return slot }() : slot
        let fixtures = options.only.map { [$0] } ?? (host.stats()?["fixtures"] as? [String] ?? [])
        guard !fixtures.isEmpty else { throw SimlessError("no fixtures registered in \(ws.config.fixturesFile)") }
        let canvas = try Render.canvas("iphone")
        if let dir = options.imagesDir { try mkdirp(dir) }

        let udid = try createSimulator()
        defer { deleteSimulator(udid) }
        let simPort = slot.port + 1000
        try buildAndLaunch(ws: ws, udid: udid, port: simPort)
        let sim = try LineClient(port: simPort, timeout: 30)
        let mac = try host.client(timeout: 30)
        let simOS = simRuntimeName(udid)

        var matched = 0, total = 0
        var report: [String] = []
        var markdown: [String] = []
        for fixture in fixtures {
            for dark in options.dark ? [false, true] : [false] {
                total += 1
                let style = dark ? "dark" : "light"
                let label = options.dark ? "\(fixture) · \(style)" : fixture
                let wantImage = options.imagesDir != nil
                let a = try mac.call(Render.request(fixture: fixture, dark: dark, canvas: canvas, image: wantImage))
                let b = try sim.call(Render.request(fixture: fixture, dark: dark, canvas: canvas, image: wantImage))
                guard a["ok"] as? Bool == true, b["ok"] as? Bool == true else {
                    report.append("✗ \(label): render failed (\(a["error"] ?? b["error"] ?? "?"))")
                    continue
                }
                let (ok, lines) = compare(a["nodes"] as? [[String: Any]] ?? [], b["nodes"] as? [[String: Any]] ?? [])
                if ok { matched += 1 }
                report.append("\(ok ? "✓" : "✗") \(label)")
                report += lines.map { "    " + $0 }
                if let dir = options.imagesDir {
                    let base = "\(fixture)-\(style)".replacingOccurrences(of: "/", with: "_")
                    for (side, r) in [("simulator", b), ("simless", a)] {
                        if let b64 = r["png"] as? String, let data = Data(base64Encoded: b64) {
                            try data.write(to: URL(fileURLWithPath: "\(dir)/\(base)-\(side).png"))
                        }
                    }
                    markdown += [
                        "## \(label): \(ok ? "✓ matches" : "✗ differs")", "",
                        "| iOS Simulator | simless |", "|:-:|:-:|",
                        "| <img src=\"\(base)-simulator.png\" width=\"320\"> | <img src=\"\(base)-simless.png\" width=\"320\"> |", "",
                    ] + lines.map { "- " + $0 } + [""]
                }
            }
        }
        print("calibration against \(Self.simDeviceType) simulator (frames within \(Int(tolerance)) pt):")
        report.forEach { print("  " + $0) }
        print("\(matched)/\(total) renders have the same structure and frames as in the simulator (\(secs(t)))")
        if matched < total {
            print("For mismatching screens, confirm visual changes in the simulator; simless renders of them are less trustworthy.")
        }
        if let dir = options.imagesDir {
            let header = [
                "# simless vs iOS Simulator", "",
                "Each screen rendered by the iOS Simulator (\(Self.simDeviceType), \(simOS)) and by simless "
                    + "(the same app running natively on the Mac). The list under each pair is what `simless calibrate` "
                    + "found when comparing the accessibility trees: elements present on one side only, and frames "
                    + "that differ by more than \(Int(tolerance)) pt. Text that only renders slightly wider or narrower "
                    + "(same lines, same place) and elements exposed with a different role are listed as minor.", "",
                "\(matched) of \(total) renders match.", "",
            ]
            try (header + markdown).joined(separator: "\n").write(toFile: "\(dir)/report.md", atomically: true, encoding: .utf8)
            print("images and report: \(dir)/report.md")
        }
    }

    private static func simRuntimeName(_ udid: String) -> String {
        let out = (try? Shell.run(["xcrun", "simctl", "list", "devices"]).out) ?? ""
        var runtime = "iOS"
        for line in out.split(separator: "\n") {
            if line.hasPrefix("-- iOS") { runtime = line.replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespaces) }
            if line.contains(udid) { return runtime }
        }
        return runtime
    }

    // MARK: - Comparison

    private static func key(_ n: [String: Any]) -> String {
        "\(n["role"] ?? "")|\(n["label"] ?? "")|\(n["id"] ?? "")"
    }

    private static func frame(_ n: [String: Any]) -> [Double] { n["frame"] as? [Double] ?? [0, 0, 0, 0] }

    /// Aligns the two trees (longest common subsequence of role/label/id), then
    /// checks frames of the aligned elements.
    /// Aligns the two trees (longest common subsequence of role/label/id), then
    /// classifies every difference:
    /// - **real** (fails the screen): an element on one side only, or a frame that
    ///   moved or changed height or non-text width by more than the tolerance;
    /// - **minor** (reported, doesn't fail): text whose width alone differs
    ///   (same line count and position, glyphs render slightly wider or narrower),
    ///   and an element exposed with a different role at the same place.
    static func compare(_ mac: [[String: Any]], _ sim: [[String: Any]]) -> (Bool, [String]) {
        let a = mac.map(key), b = sim.map(key)
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        func describe(_ n: [String: Any]) -> String {
            "\(n["role"] ?? "element") \((n["label"] as? String).map { "\"\($0)\"" } ?? "(no label)")"
        }
        func frameText(_ f: [Double]) -> String { String(format: "@%.0f,%.0f %.0f×%.0f", f[0], f[1], f[2], f[3]) }
        let textRoles: Set<String> = ["text", "header", "link"]

        var real: [String] = [], minor: [String] = [], widthRatios: [Double] = []
        var onlyMac: [[String: Any]] = [], onlySim: [[String: Any]] = []
        var i = 0, j = 0, worst = 0.0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                let fa = frame(mac[i]), fb = frame(sim[j])
                let dx = abs(fa[0] - fb[0]), dy = abs(fa[1] - fb[1]), dw = abs(fa[2] - fb[2]), dh = abs(fa[3] - fb[3])
                let isText = textRoles.contains(mac[i]["role"] as? String ?? "")
                if dy <= tolerance && dh <= tolerance && isText && fb[2] > 0 && dw / fb[2] <= 0.08 {
                    // Same lines in the same place; only glyph widths differ (x moves with
                    // the width for centered or trailing text).
                    if dw > tolerance { widthRatios.append(fa[2] / fb[2]) }
                    worst = max(worst, dy, dh)
                } else if max(dx, dy, dw, dh) > tolerance {
                    real.append(String(format: "%@ differs by %.1f pt: simless %@, simulator %@",
                                       describe(mac[i]), max(dx, dy, dw, dh), frameText(fa), frameText(fb)))
                } else {
                    worst = max(worst, dx, dy, dw, dh)
                }
                i += 1; j += 1
            } else if j < b.count, i == a.count || dp[i][j + 1] >= dp[i + 1][j] {
                onlySim.append(sim[j]); j += 1
            } else {
                onlyMac.append(mac[i]); i += 1
            }
        }
        // Same label at the same place but a different role: exposed differently.
        for m in onlyMac {
            if let k = onlySim.firstIndex(where: { s in
                (s["label"] as? String) == (m["label"] as? String) && (m["label"] as? String) != nil
                    && zip(frame(m), frame(s)).allSatisfy { abs($0 - $1) <= 4 * tolerance } }) {
                minor.append("\"\(m["label"] as? String ?? "")\" is a \(m["role"] ?? "?") in simless, a \(onlySim[k]["role"] ?? "?") in the simulator")
                onlySim.remove(at: k)
            } else {
                real.append("only in simless: \(describe(m))")
            }
        }
        real += onlySim.map { "only in simulator: \(describe($0))" }
        if !widthRatios.isEmpty {
            let avg = widthRatios.reduce(0, +) / Double(widthRatios.count)
            minor.append(String(format: "%d text element(s) render %.0f%% %@ (same lines and positions)",
                                widthRatios.count, abs(avg - 1) * 100, avg > 1 ? "wider" : "narrower"))
        }
        let ok = real.isEmpty
        var lines = real
        if ok { lines.append(String(format: "%d elements match, largest layout difference %.1f pt", mac.count, worst)) }
        lines += minor.map { "minor: " + $0 }
        return (ok, lines)
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
