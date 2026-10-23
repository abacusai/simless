// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

enum Render {
    struct Options {
        var dark = false
        var device = "iphone"
        var pngPath: String?
        var json = false
        var textSize: String?        // Dynamic Type size: xs … xxxl, ax1 … ax5
        var idiom: String?           // "phone": phone idiom on phone canvases
        var settle: Double?          // ms the screen gets for async work (.task, loads) before it's read
        var patch: Int?              // hot reloads since the build (the host also counts loading the previews)
        var notes: [String] = []     // lines after the traits
        var hide: [String] = []      // `hide` in .simless.json: "#id" or part of a label
        var checks = Config.Checks()
    }

    static let textSizes = ["xs", "s", "m", "l", "xl", "xxl", "xxxl", "ax1", "ax2", "ax3", "ax4", "ax5"]

    struct Canvas {
        let width: Double, height: Double
        let safeTop: Double, safeBottom: Double   // portrait safe-area insets of the real device
    }

    static let canvases: [String: Canvas] = [
        "iphone": Canvas(width: 402, height: 874, safeTop: 62, safeBottom: 34),        // iPhone 17 Pro
        "iphone-small": Canvas(width: 375, height: 667, safeTop: 20, safeBottom: 0),   // iPhone SE
        "iphone-max": Canvas(width: 440, height: 956, safeTop: 62, safeBottom: 34),    // iPhone 17 Pro Max
        "ipad": Canvas(width: 820, height: 1180, safeTop: 24, safeBottom: 20),         // iPad Air 11"
    ]

    static func canvas(_ device: String) throws -> Canvas {
        guard let c = canvases[device] else {
            throw SimlessError("unknown device '\(device)'; one of \(canvases.keys.sorted().joined(separator: ", "))")
        }
        return c
    }

    static func request(fixture: String, dark: Bool, canvas c: Canvas, image: Bool,
                        textSize: String? = nil, idiom: String? = nil, settle: Double? = nil) -> [String: Any] {
        var r: [String: Any] = ["cmd": "render", "fixture": fixture, "style": dark ? "dark" : "light", "width": c.width,
                                "height": c.height, "safeTop": c.safeTop, "safeBottom": c.safeBottom, "image": image]
        if let textSize { r["textSize"] = textSize }
        if let idiom, c.width < 600 { r["idiom"] = idiom }
        if let settle, settle > 0 { r["settleMs"] = settle }
        return r
    }

    /// One-line summary of the traits the view saw, plus warnings where they
    /// can't match the requested device.
    static func traitsText(_ r: [String: Any], device: String) -> [String] {
        guard let t = r["traits"] as? [String: Any] else { return [] }
        let safe = (t["safeArea"] as? [Double]) ?? []
        var lines = ["  traits: \(t["horizontalSizeClass"] ?? "?")/\(t["verticalSizeClass"] ?? "?") size class, idiom \(t["idiom"] ?? "?"), safe area top \(Int(safe.first ?? 0)) bottom \(Int(safe.count > 2 ? safe[2] : 0))"]
        let wantPhone = device != "ipad"
        if wantPhone, t["idiom"] as? String != "phone" {
            lines.append("  note: the idiom is \(t["idiom"] ?? "?") on the Mac; layouts that branch on size class look like a phone's, but code that checks userInterfaceIdiom takes its iPad branch, and controls get iPad metrics (--idiom phone matches a phone more closely)")
        } else if wantPhone, t["deviceIdiom"] as? String != "phone" {
            lines.append("  note: UIDevice.current.userInterfaceIdiom still reports \(t["deviceIdiom"] ?? "?"); views reading the trait collection see phone")
        }
        return lines
    }

    /// Renders one fixture and returns the text an agent reads (or JSON).
    static func run(slot: SlotRecord, fixture: String, options: Options) throws -> (text: String, issues: Int) {
        var options = options
        let c = try canvas(options.device)
        let client = try slot.client(timeout: 30)
        try avoidStepperCrash(slot: slot, fixture: fixture, options: &options, canvas: c, client: client)
        let first = try client.call(request(fixture: fixture, dark: options.dark, canvas: c, image: options.pngPath != nil,
                                            textSize: options.textSize, idiom: options.idiom, settle: options.settle))
        let (r, note) = try held(first, fixture: fixture, options: options, canvas: c, client: client)
        if let note { options.notes.append(note) }
        return try format(r, fixture: fixture, options: options, canvas: c)
    }

    /// The screen once it holds still. The render window has no scene, so
    /// nothing drives its screen updates: a change after the first frame that
    /// brings UIKit views (a List that appears once a `.task` loads its data)
    /// only lands when the host is asked for one (`ui.update`), and until then
    /// every read, `--settle`'s included, showed the screen from before. So
    /// after the first read the render asks for one, which costs a few ms when
    /// there's nothing to update, and reads again while updates change the
    /// screen, for up to a second. A screen of a few elements may not have
    /// loaded yet (an empty state before a `.task` fills it): without
    /// `--settle`, it gets one more look 100 ms later. Kits before 5 can't, and
    /// keep the first read.
    static func held(_ first: [String: Any], fixture: String, options: Options, canvas c: Canvas,
                     client: LineClient) throws -> ([String: Any], String?) {
        guard first["ok"] as? Bool == true else { return (first, nil) }
        var tree = request(fixture: fixture, dark: options.dark, canvas: c, image: false,
                           textSize: options.textSize, idiom: options.idiom)
        tree["cmd"] = "tree"
        func elements(_ r: [String: Any]) -> [String] {
            (r["nodes"] as? [[String: Any]] ?? []).map { n in ["role", "label", "value", "id"].map { "\(n[$0] ?? "")" }.joined(separator: "|") }
        }
        let count = { (r: [String: Any]) in (r["nodes"] as? [Any] ?? []).count }
        let start = Date()
        var last = first, changed = false, still = false
        /// Whether there was an update to run; nil when the kit can't (before 5).
        func update() -> Bool? {
            guard let u = try? client.call(["cmd": "ui.update"]), u["ok"] as? Bool == true else { return nil }
            return u["updated"] as? Bool == true
        }
        /// Reads the screen again; whether it changed.
        func reread() throws -> Bool {
            let r = try client.call(tree)
            guard r["ok"] as? Bool == true else { return false }
            defer { last = r }
            return elements(r) != elements(last)
        }
        guard var updated = update() else { return (first, nil) }
        if !updated, options.settle == nil, count(first) <= 5 {
            Thread.sleep(forTimeInterval: 0.1)
            updated = update() ?? false
            if !updated, try reread() { changed = true }
        }
        while updated, try reread() {
            changed = true
            if Date().timeIntervalSince(start) > 1 { still = true; break }
            Thread.sleep(forTimeInterval: 0.05)
            updated = update() ?? false
        }
        guard changed else { return (first, nil) }
        if options.pngPath != nil {
            tree["image"] = true
            last = try client.call(tree)
        }
        let ms = Date().timeIntervalSince(start) * 1000
        last["renderMs"] = (first["renderMs"] as? Double ?? 0) + ms
        last["changedAfterFirstRead"] = ["firstElements": count(first), "ms": Int(ms), "stillChanging": still]
        return (last, "  note: the screen changed after the first read (\(count(first)) elements, then \(count(last)) after \(Int(ms)) ms), as when a .task loads data; this is the screen once it held still"
                    + (still ? ", except it was still changing after 1 s" : ""))
    }

    /// SwiftUI's Stepper takes the Mac host down under the phone idiom: its
    /// default style resolves to itself until the stack overflows (findings.md).
    /// A fixture that shows one renders with the iPad idiom instead. Whether it
    /// does comes from rendering it with the iPad idiom once, kept per fixture
    /// until the next build or patch.
    static func avoidStepperCrash(slot: SlotRecord, fixture: String, options: inout Options, canvas c: Canvas, client: LineClient) throws {
        guard options.idiom == "phone", c.width < 600 else { return }
        struct Probe: Codable { var build: String; var fixtures: [String: Bool] }
        let path = "\(slot.dir)/stepper-fixtures.json", build = "\(slot.builtAt) \(slot.patch)"
        var probe = FileManager.default.contents(atPath: path).flatMap { try? JSONDecoder().decode(Probe.self, from: $0) }
            .flatMap { $0.build == build ? $0 : nil } ?? Probe(build: build, fixtures: [:])
        var shows = probe.fixtures[fixture]
        if shows == nil {
            let r: [String: Any]
            do {
                r = try client.call(request(fixture: fixture, dark: options.dark, canvas: c, image: false,
                                            textSize: options.textSize, idiom: nil, settle: options.settle))
            } catch let error as SimlessError where slot.stats() == nil {
                // The iPad idiom is what crashes this screen: the next try renders
                // it with the phone idiom, without looking for a Stepper again.
                probe.fixtures[fixture] = false
                try? JSONEncoder().encode(probe).write(to: URL(fileURLWithPath: path))
                throw ProbeCrash(description: error.description)
            }
            guard r["ok"] as? Bool == true else { return }
            shows = (r["nodes"] as? [[String: Any]] ?? []).contains { ["Increment", "Decrement"].contains($0["id"] as? String ?? "") }
            probe.fixtures[fixture] = shows
            try? JSONEncoder().encode(probe).write(to: URL(fileURLWithPath: path))
        }
        if shows == true {
            options.idiom = nil
            options.notes.append("  note: rendered with the iPad idiom: this screen shows a Stepper, which crashes SwiftUI on the Mac under the phone idiom")
        }
    }

    /// The iPad-idiom render that looks for a Stepper took the host down.
    struct ProbeCrash: Error, CustomStringConvertible {
        let description: String
    }

    /// A render's answer as the tree, the PNG it asked for and the issues.
    static func format(_ r: [String: Any], fixture: String, options: Options, canvas c: Canvas) throws -> (text: String, issues: Int) {
        let (w, h) = (c.width, c.height)
        guard r["ok"] as? Bool == true else {
            let known = (r["fixtures"] as? [String])?.joined(separator: ", ") ?? ""
            throw SimlessError("\(r["error"] as? String ?? "render failed")" + (known.isEmpty ? "" : "; fixtures: \(known)"))
        }
        if let path = options.pngPath, let b64 = r["png"] as? String, let data = Data(base64Encoded: b64) {
            try data.write(to: URL(fileURLWithPath: path))
        }
        let all = r["nodes"] as? [[String: Any]] ?? []
        let nodes = all.filter { !hidden($0, options.hide) }
        let found = findIssues(nodes, width: w, height: h, minTapTarget: options.checks.minTapTarget ?? 44)
        let ignore = options.checks.ignore ?? []
        let issues = found.filter { issue in !ignore.contains { issue.contains($0) } }
        if options.json {
            var out = r
            out.removeValue(forKey: "png")
            out["nodes"] = nodes
            out["issues"] = issues
            out["ignoredIssues"] = found.count - issues.count
            let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            return (String(decoding: data, as: UTF8.self), issues.count)
        }

        var lines: [String] = []
        let ms = (r["renderMs"] as? Double).map { String(format: "%.0f ms", $0) } ?? ""
        let patch = (options.patch ?? r["patch"] as? Int).map { $0 > 0 ? " · patch \($0)" : "" } ?? ""
        let extras = [r["locale"] as? String, options.textSize.map { "text \($0)" }].compactMap { $0 }.map { " · " + $0 }.joined()
        lines.append("\(fixture) · \(options.dark ? "dark" : "light") · \(options.device) \(Int(w))×\(Int(h))\(extras) · \(ms)\(patch)")
        lines += traitsText(r, device: options.device)
        lines += options.notes
        for n in nodes {
            let role = n["role"] as? String ?? "element"
            let column = role.count < 7 ? role.padding(toLength: 7, withPad: " ", startingAt: 0) : role
            var label = (n["label"] as? String).map { quoted($0) } ?? "(no label)"
            if let p = n["placeholder"] as? String { label += " placeholder \(quoted(p))" }
            if let v = n["value"] as? String, !v.isEmpty { label += " = \(quoted(v))" }
            let id = (n["id"] as? String).map { " #\($0)" } ?? ""
            lines.append("  \(column) \(label)\(id)  \(frameText(n))")
        }
        if all.count > nodes.count { lines.append("  hidden: \(all.count - nodes.count) element(s), by `hide` in \(Workspace.configName)") }
        let below = nodes.filter { frame($0).1 + frame($0).3 > h + 0.5 }.count
        if below > 0 { lines.append("  below the fold: \(below) element(s) (scroll content, listed above)") }
        if let png = options.pngPath { lines.append("  png: \(png)") }
        let ignored = found.count - issues.count
        let ignoredText = ignored > 0 ? " (\(ignored) ignored by \(Workspace.configName))" : ""
        lines.append(issues.isEmpty ? "  issues: none\(ignoredText)" : "  issues (\(issues.count))\(ignoredText):")
        lines += issues.map { "    ⚠ " + $0 }
        return (lines.joined(separator: "\n"), issues.count)
    }

    /// Text longer than this is cut in the text output (`--json` keeps all of it).
    static let longText = 200

    /// `"text"`, or for long text its start and how long it is: `"start…" (4,812 chars)`.
    static func quoted(_ text: String) -> String {
        guard text.count > longText else { return "\"\(text)\"" }
        return "\"\(text.prefix(longText))…\" (\(text.count.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))) chars)"
    }

    /// Whether `hide` drops a node: `#id` by identifier, else part of its label.
    static func hidden(_ n: [String: Any], _ hide: [String]) -> Bool {
        guard !hide.isEmpty else { return false }
        let id = n["id"] as? String, label = n["label"] as? String ?? ""
        return hide.contains { h in h.hasPrefix("#") ? id == String(h.dropFirst()) : !h.isEmpty && label.contains(h) }
    }

    private static func frame(_ n: [String: Any]) -> (Double, Double, Double, Double) {
        let f = n["frame"] as? [Double] ?? [0, 0, 0, 0]
        return (f[0], f[1], f[2], f[3])
    }

    private static func frameText(_ n: [String: Any]) -> String {
        let (x, y, w, h) = frame(n)
        func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
        return "@\(fmt(x)),\(fmt(y)) \(fmt(w))×\(fmt(h))"
    }

    /// Deterministic checks; an agent should look at the tree for the rest.
    static func findIssues(_ nodes: [[String: Any]], width: Double, height: Double, minTapTarget: Double = 44) -> [String] {
        var issues: [String] = []
        let interactive: Set<String> = ["button", "link", "search", "adjustable", "switch", "field"]
        for n in nodes {
            let role = n["role"] as? String ?? ""
            let label = (n["label"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let (x, _, w, h) = frame(n)
            let name = label.isEmpty ? role : "\(role) \(quoted(label))"
            // A text field VoiceOver reads by its placeholder when it has no label.
            if role == "field", label.isEmpty, (n["placeholder"] as? String ?? "").isEmpty {
                issues.append("text field without accessibility label or placeholder\((n["id"] as? String).map { " #\($0)" } ?? "") \(frameText(n))")
            } else if interactive.contains(role), role != "field", label.isEmpty {
                issues.append("\(role) without accessibility label \(frameText(n))")
            }
            if w <= 0 || h <= 0 {
                issues.append("\(name) has zero size")
            } else if (x < -0.5 && x + w > 0.5) || (x < width - 0.5 && x + w > width + 0.5) {
                // Cut off at a side edge. Elements wholly beyond an edge are scroll
                // content (below the fold, or later pages of a horizontal list), not a
                // layout problem, so only partial clipping is flagged.
                issues.append("\(name) is cut off at the \(x < 0 ? "left" : "right") edge \(frameText(n))")
            }
            // UIKit's own controls (bar buttons), switches, text fields and a stepper's
            // halves are sized by the system, not the app.
            let systemSized = n["system"] as? Bool == true || role == "switch" || role == "field"
                || ["Increment", "Decrement"].contains(n["id"] as? String ?? "")
            if interactive.contains(role), !systemSized, w > 0, h > 0, w < minTapTarget || h < minTapTarget {
                let m = Int(minTapTarget)
                issues.append("\(name) tap target \(Int(w))×\(Int(h)) is smaller than \(m)×\(m)")
            }
        }
        // A control's label also exposed as a separate element at the same spot:
        // VoiceOver reads it twice (typically a Menu/Button label not combined).
        for c in nodes where interactive.contains(c["role"] as? String ?? "") {
            let (cx, cy, cw, ch) = frame(c)
            for n in nodes where !interactive.contains(n["role"] as? String ?? "") {
                let (nx, ny, nw, nh) = frame(n)
                let inside = nx >= cx - 1 && ny >= cy - 1 && nx + nw <= cx + cw + 1 && ny + nh <= cy + ch + 1
                if inside, let label = n["label"] as? String, !label.isEmpty,
                   (c["label"] as? String ?? "").contains(label) {
                    issues.append("\(quoted(label)) is exposed twice (as the \(c["role"] as? String ?? "control") and as separate text); hide the inner text from accessibility")
                }
            }
        }
        // Overlapping controls (identical frames are one control exposed twice).
        let controls = nodes.filter { interactive.contains($0["role"] as? String ?? "") }
        for i in controls.indices {
            for j in controls.indices where j > i {
                let (ax, ay, aw, ah) = frame(controls[i]); let (bx, by, bw, bh) = frame(controls[j])
                let ix = max(0, min(ax + aw, bx + bw) - max(ax, bx)), iy = max(0, min(ay + ah, by + bh) - max(ay, by))
                let same = abs(ax - bx) < 1 && abs(ay - by) < 1 && abs(aw - bw) < 1 && abs(ah - bh) < 1
                if !same, ix > 4, iy > 4 {
                    let a = controls[i]["label"] as? String ?? "?", b = controls[j]["label"] as? String ?? "?"
                    issues.append("controls overlap: \(quoted(a)) and \(quoted(b))")
                }
            }
        }
        return issues
    }
}

/// What macOS's crash report says about a host that died.
enum CrashReport {
    /// The exception and the first frames in the app or SwiftUI, from the
    /// newest report for `slot` written after `since`. Reports appear a few
    /// seconds after the crash.
    static func summary(slot: SlotRecord, since: Date, wait: Double = 4) -> String? {
        lastSymbols = []
        let dir = "\(Paths.home)/Library/Logs/DiagnosticReports"
        let deadline = now() + wait
        repeat {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".ips") }
                .map { "\(dir)/\($0)" }
                .filter { (try? FileManager.default.attributesOfItem(atPath: $0)[.creationDate] as? Date).map { $0 >= since } ?? false }
            for path in files {
                guard let text = try? String(contentsOfFile: path, encoding: .utf8), let nl = text.firstIndex(of: "\n"),
                      let header = try? JSONSerialization.jsonObject(with: Data(text[..<nl].utf8)) as? [String: Any],
                      header["bundleID"] as? String == slot.slotID,
                      let body = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: nl)...].utf8)) as? [String: Any]
                else { continue }
                return describe(body) + " (report: \(path))"
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while now() < deadline
        if let trap = hostTrap(slot) { return trap + " (no crash report from macOS this time)" }
        if let frames = handlerFrames(slot) { return frames }
        return "the host process died, and macOS wrote no crash report this time (it limits repeated ones); run it in a simulator to see the crash"
    }

    /// The crashed thread's top frames as SimlessRuntime's crash handler
    /// printed them to the host's log, described like a crash report.
    static func handlerFrames(_ slot: SlotRecord) -> String? {
        let log = (try? String(contentsOfFile: "\(slot.dir)/host.log", encoding: .utf8)) ?? ""
        let mangled = log.split(separator: "\n").filter { $0.hasPrefix("simless-crash-frame: ") }.map { String($0.dropFirst("simless-crash-frame: ".count)) }
        guard !mangled.isEmpty else { return nil }
        let frames = demangle(mangled)
        let interesting = frames.filter { !$0.hasPrefix("_sigtramp") && !$0.contains("simless_crash") }
        var seen = Set<String>()
        let top = interesting.filter { seen.insert($0).inserted }.prefix(3).map { $0.count > 90 ? String($0.prefix(90)) + "…" : $0 }
        var text = "crashed in " + top.joined(separator: " ← ") + " (no crash report from macOS this time; frames from the host's log)"
        if interesting.prefix(6).contains(where: { $0.contains("StyleableView._makeViewList") || $0.contains("StyleModifier") || $0.contains("SubstGenericParametersFromMetadata") }) {
            text += ". This is SwiftUI's Stepper crash on the Mac, not your code; mark the test simulator-only"
        }
        return text
    }

    /// Swift symbols demangled (simplified); anything else (C, Objective-C) as it is.
    static func demangle(_ symbols: [String]) -> [String] {
        let swift = symbols.map { $0.hasPrefix("_$") ? String($0.dropFirst()) : $0 }
        let mangled = swift.filter { $0.hasPrefix("$s") || $0.hasPrefix("$S") }
        guard !mangled.isEmpty, let out = try? Shell.run(["xcrun", "swift-demangle", "--simplified"] + mangled).out else { return swift }
        let lines = out.split(separator: "\n").map(String.init)
        guard lines.count == mangled.count else { return swift }
        var map: [String: String] = [:]
        for (m, d) in zip(mangled, lines) { map[m] = d }
        return swift.map { map[$0] ?? $0 }
    }

    /// The last trap message (`Fatal error: ...`) the host printed.
    static func hostTrap(_ slot: SlotRecord) -> String? {
        let log = (try? String(contentsOfFile: "\(slot.dir)/host.log", encoding: .utf8)) ?? ""
        return log.split(separator: "\n").last(where: { $0.contains("Fatal error:") || $0.contains("Assertion failed:") || $0.contains("Precondition failed:") })
            .map { visibleText(String($0)) }
    }

    /// Every symbol on the crashed thread of the last report `summary` read.
    nonisolated(unsafe) static var lastSymbols: [String] = []

    private static func describe(_ body: [String: Any]) -> String {
        lastSymbols = ((body["threads"] as? [[String: Any]] ?? []).first { $0["triggered"] as? Bool == true }?["frames"] as? [[String: Any]] ?? [])
            .compactMap { $0["symbol"] as? String }
        let exception = body["exception"] as? [String: Any] ?? [:]
        var what = exception["type"] as? String ?? "crash"
        if let message = exception["message"] as? String, message.contains("stack guard") { what += ", stack overflow" }
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
        let thread = (body["threads"] as? [[String: Any]] ?? []).first { $0["triggered"] as? Bool == true } ?? [:]
        let frames = (thread["frames"] as? [[String: Any]] ?? []).compactMap { f -> String? in
            guard let i = f["imageIndex"] as? Int, i < images.count, let symbol = f["symbol"] as? String else { return nil }
            let image = images[i]
            let interesting = image.hasPrefix("SwiftUI") || image.hasPrefix("UIKit") || image.hasSuffix(".debug.dylib")
                || image == (body["procName"] as? String)
            return interesting ? "\(image): \(symbol.count > 90 ? String(symbol.prefix(90)) + "…" : symbol)" : nil
        }
        var seen = Set<String>()
        let top = frames.filter { seen.insert($0).inserted }.prefix(3)
        var text = top.isEmpty ? what : "\(what) in " + top.joined(separator: " ← ")
        // A stack overflow inside one runtime conformance check under SwiftUI's
        // style resolution: SwiftUI on the Mac, not the app (seen with Stepper
        // drawn by ImageRenderer or under the phone idiom).
        if what.contains("stack overflow"), frames.prefix(4).contains(where: { $0.contains("StyleableView._makeViewList") || $0.contains("StyleModifier") }) {
            text += ". This is a SwiftUI crash on the Mac, not your code (a Stepper drawn by ImageRenderer or under the phone idiom); mark the test simulator-only"
        }
        return text
    }
}

/// Without SF Symbols glyphs (private use), invisible format characters
/// (U+200B, U+FEFF, ...) and control characters, trimmed.
func visibleText(_ raw: String) -> String {
    var scalars = String.UnicodeScalarView()
    for s in raw.unicodeScalars {
        switch s.properties.generalCategory {
        case .format, .privateUse, .control where s != "\t": continue
        default: scalars.append(s)
        }
    }
    return String(scalars).trimmingCharacters(in: .whitespaces)
}
