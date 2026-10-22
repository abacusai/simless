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
        var runtime: String?     // iOS version, e.g. "26.5" (default: newest installed)
        var device: String?      // simulator device type (default: simDeviceType)
        var idiom: String?       // "phone": render the Mac side with the phone idiom
    }

    static func run(ws: Workspace, slot: SlotRecord, options: Options) throws {
        let t = now()
        let host = slot.stats() == nil ? try { try Slots.launch(slot, idleMinutes: ws.idleMinutes); return slot }() : slot
        let fixtures = options.only.map { [$0] } ?? (host.stats()?["fixtures"] as? [String] ?? [])
        guard !fixtures.isEmpty else { throw SimlessError("no fixtures registered in \(ws.config.fixturesFile)") }
        if let dir = options.imagesDir { try mkdirp(dir) }

        let deviceType = options.device ?? simDeviceType
        let udid = try createSimulator(runtime: options.runtime, device: deviceType)
        defer { deleteSimulator(udid) }
        let simPort = slot.port + 1000
        try buildAndLaunch(ws: ws, udid: udid, port: simPort)
        let sim = try LineClient(port: simPort, timeout: 30)
        var mac = try host.client(timeout: 30)
        let simOS = simRuntimeName(udid)
        // Both sides render the simulator's own screen size and safe areas.
        var canvas = try Render.canvas("iphone")
        if let screen = (try? sim.call(["cmd": "stats"]))?["screen"] as? [Double], screen.count == 4 {
            canvas = Render.Canvas(width: screen[0], height: screen[1], safeTop: screen[2], safeBottom: screen[3])
        } else if options.device != nil {
            Log.info("note: the app's SimlessKit is too old to report the simulator's screen; comparing on the iphone canvas (run `simless init`)")
        }

        var matched = 0, total = 0
        var report: [String] = []
        var simlessOnly: [String] = []
        var markdown: [String] = []
        for fixture in fixtures {
            for dark in options.dark ? [false, true] : [false] {
                total += 1
                let style = dark ? "dark" : "light"
                let label = options.dark ? "\(fixture) · \(style)" : fixture
                let wantImage = options.imagesDir != nil
                var a: [String: Any]
                do {
                    a = try mac.call(Render.request(fixture: fixture, dark: dark, canvas: canvas, image: wantImage,
                                                    idiom: options.idiom))
                } catch where options.idiom != nil && host.stats() == nil {
                    // A Stepper under the phone idiom takes the Mac host down (see `render`).
                    Log.info("note: \(fixture) crashed the host under the phone idiom; comparing it with the iPad idiom")
                    try Slots.launch(host, idleMinutes: ws.idleMinutes)
                    mac = try host.client(timeout: 30)
                    a = try mac.call(Render.request(fixture: fixture, dark: dark, canvas: canvas, image: wantImage))
                }
                let b = try sim.call(Render.request(fixture: fixture, dark: dark, canvas: canvas, image: wantImage))
                // Fixtures simless generates (root, #Preview blocks) exist only in its hosts.
                if b["ok"] as? Bool != true, (b["error"] as? String ?? "").hasPrefix("unknown fixture") {
                    if !simlessOnly.contains(fixture) { simlessOnly.append(fixture) }
                    total -= 1
                    continue
                }
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
        print("calibration against \(deviceType) simulator, \(simOS)\(options.idiom.map { ", simless with the \($0) idiom" } ?? "") (frames within \(Int(tolerance)) pt):")
        report.forEach { print("  " + $0) }
        if !simlessOnly.isEmpty {
            print("  not compared: \(simlessOnly.count) fixture(s) only simless has (root and #Preview blocks): \(simlessOnly.prefix(5).joined(separator: ", "))\(simlessOnly.count > 5 ? ", …" : "")")
        }
        print("\(matched)/\(total) renders have the same structure and frames as in the simulator (\(secs(t)))")
        if matched < total {
            print("For mismatching screens, confirm visual changes in the simulator; simless renders of them are less trustworthy.")
        }
        if let dir = options.imagesDir {
            let header = [
                "# simless vs iOS Simulator", "",
                "Each screen rendered by the iOS Simulator (\(deviceType), \(simOS)) and by simless "
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
                let (mr, sr) = (m["role"] as? String ?? "?", onlySim[k]["role"] as? String ?? "?")
                let what = mr != sr ? "role" : (m["id"] as? String) != (onlySim[k]["id"] as? String) ? "identifier" : "value"
                minor.append("\"\(m["label"] as? String ?? "")\" has another \(what) in simless: "
                             + (what == "role" ? "\(mr), a \(sr) in the simulator"
                                : "\"\((what == "identifier" ? m["id"] : m["value"]) ?? "")\", \"\((what == "identifier" ? onlySim[k]["id"] : onlySim[k]["value"]) ?? "")\" in the simulator"))
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

    /// A fresh simulator of `device` on the iOS runtime whose version starts
    /// with `runtime` (e.g. "26.5", or "26" for the newest 26.x), else the newest.
    private static func createSimulator(runtime wanted: String?, device: String) throws -> String {
        deleteStale()
        let runtimes = try Shell.check(["xcrun", "simctl", "list", "runtimes", "-j"], stdoutOnly: true)
        guard let json = try JSONSerialization.jsonObject(with: Data(runtimes.utf8)) as? [String: Any],
              let list = json["runtimes"] as? [[String: Any]] else {
            throw SimlessError("could not list simulator runtimes")
        }
        let installed = list.filter { ($0["platform"] as? String) == "iOS" && ($0["isAvailable"] as? Bool) == true }
        guard !installed.isEmpty else { throw SimlessError("no iOS simulator runtime installed (Xcode → Settings → Components)") }
        let versions = installed.map { $0["version"] as? String ?? "" }
        let match = wanted.map { w in installed.filter { ($0["version"] as? String ?? "") == w || ($0["version"] as? String ?? "").hasPrefix(w + ".") } }
            ?? installed
        guard let runtime = match.compactMap({ $0["identifier"] as? String }).last else {
            throw SimlessError("no iOS \(wanted ?? "") simulator runtime installed; installed: \(versions.joined(separator: ", "))")
        }
        let r = try Shell.run(["xcrun", "simctl", "create", deviceName, device, runtime], stdoutOnly: true)
        guard r.code == 0 else {
            throw SimlessError("could not create a '\(device)' simulator on \(runtime); see `xcrun simctl list devicetypes` for names")
        }
        let udid = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.step("booting \(device) simulator (\(runtime.split(separator: ".").last ?? "")) for calibration")
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
