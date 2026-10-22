// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// `simless act`: renders a fixture, works it the way a finger and a keyboard
/// would, and prints the screen afterwards. The input is SimlessRuntime's UI
/// automation, the same that runs XCUITest code in UI tests (taps as
/// accessibility activations or real touches, focus and typing, swipes, long
/// presses, waiting for the app to settle), in the render host's own canvas.
enum Act {
    enum Step {
        case tap(String), type(String, String), swipe(String, on: String?), longPress(String), wait(Double)

        var text: String {
            switch self {
            case .tap(let t): "tap \"\(t)\""
            case .type(let t, let s): "type \"\(s)\" into \"\(t)\""
            case .swipe(let d, let on): "swipe \(d)" + (on.map { " on \"\($0)\"" } ?? "")
            case .longPress(let t): "longpress \"\(t)\""
            case .wait(let ms): "wait \(Int(ms)) ms"
            }
        }
    }

    static let usage = """
        simless act <fixture> <step>...   steps run in order, then the screen is printed
          tap "<label or #id>"            type "<#id or label>" "<text>"       longpress "<label or #id>"
          swipe up|down|left|right [on "<label or #id>"]                      wait <ms>
        """

    static func parse(_ words: [String]) throws -> [Step] {
        var steps: [Step] = [], i = 0
        func next(_ what: String) throws -> String {
            guard i < words.count else { throw SimlessError("\(what) is missing\n\(usage)") }
            defer { i += 1 }
            return words[i]
        }
        while i < words.count {
            let verb = words[i].lowercased(); i += 1
            switch verb {
            case "tap": steps.append(.tap(try next("tap: the element")))
            case "type": steps.append(.type(try next("type: the field"), try next("type: the text")))
            case "longpress", "long-press": steps.append(.longPress(try next("longpress: the element")))
            case "swipe":
                let dir = try next("swipe: the direction").lowercased()
                guard ["up", "down", "left", "right"].contains(dir) else { throw SimlessError("swipe goes up, down, left or right, not '\(dir)'") }
                var on: String?
                if i < words.count, words[i].lowercased() == "on" { i += 1; on = try next("swipe on: the element") }
                steps.append(.swipe(dir, on: on))
            case "wait":
                guard let ms = Double(try next("wait: milliseconds")) else { throw SimlessError("wait takes milliseconds") }
                steps.append(.wait(ms))
            default:
                throw SimlessError("unknown step '\(verb)'\n\(usage)")
            }
        }
        return steps
    }

    static func run(_ args: Args) throws {
        guard args.positional.count >= 2 else { throw SimlessError(usage) }
        let fixture = args.positional[0]
        let steps = try parse(Array(args.positional.dropFirst()))
        let ws = try Workspace.load()
        let slot = try runningSlot(ws)
        if (slot.stats()?["kit"] as? Int ?? 1) < actKit {
            throw SimlessError("`simless act` needs a newer \(ws.config.kitFile); run `simless init`, then `simless up`")
        }
        var options = Render.Options(dark: args.flags.contains("--dark"), device: args.values["--device"] ?? ws.config.device,
                                     json: args.flags.contains("--json"))
        options.textSize = args.values["--text-size"]
        options.settle = args.values["--settle"].flatMap(Double.init) ?? ws.config.settle
        options.idiom = ws.phoneIdiom(args.values["--idiom"])
        options.checks = ws.config.checks ?? .init()
        if let png = args.values["--png"] {
            if png.hasSuffix("/") { try mkdirp(png) }
            options.pngPath = png.hasSuffix("/") ? "\(png)\(fixture)-act.png" : png
        }
        let c = try Render.canvas(options.device)
        let client = try slot.client(timeout: 120)
        try Render.avoidStepperCrash(slot: slot, fixture: fixture, options: &options, canvas: c, client: client)
        var render = Render.request(fixture: fixture, dark: options.dark, canvas: c, image: false,
                                    textSize: options.textSize, idiom: options.idiom, settle: options.settle)
        let mounted = try client.call(render)
        guard mounted["ok"] as? Bool == true else {
            let known = (mounted["fixtures"] as? [String])?.joined(separator: ", ") ?? ""
            throw SimlessError("\(mounted["error"] as? String ?? "render failed")" + (known.isEmpty ? "" : "; fixtures: \(known)"))
        }
        var failed: String?
        var lines = ["\(fixture) · act"]
        for step in steps {
            do {
                let how = try perform(step, client: client, canvas: c)
                lines.append("  ✓ \(step.text)" + (how.map { " (\($0))" } ?? ""))
            } catch {
                lines.append("  ✗ \(step.text): \(error)")
                failed = "\(step.text): \(error)"
                break
            }
        }
        render["cmd"] = "tree"
        render["image"] = options.pngPath != nil
        let (text, _) = try Render.format(try client.call(render), fixture: fixture, options: options, canvas: c)
        if !options.json { print(lines.joined(separator: "\n")) }
        print(text)
        if let failed { throw SimlessError("step failed: \(failed)") }
    }

    /// Does one step; returns how, when it's worth saying.
    private static func perform(_ step: Step, client: LineClient, canvas c: Render.Canvas) throws -> String? {
        func call(_ req: [String: Any]) throws -> [String: Any] {
            let r = try client.call(req)
            guard r["ok"] as? Bool != false else { throw SimlessError(r["error"] as? String ?? "failed") }
            return r
        }
        func settle() { _ = try? client.call(["cmd": "ui.idle", "timeout": 2.0]) }
        func target(_ query: String) throws -> (node: [String: Any], generation: Int) {
            let snap = try call(["cmd": "ui.snapshot"])
            let nodes = snap["nodes"] as? [[String: Any]] ?? []
            let generation = snap["generation"] as? Int ?? 0
            guard let n = find(query, in: nodes) else {
                let labels = nodes.compactMap { n -> String? in
                    guard n["hittable"] as? Bool == true else { return nil }
                    return (n["label"] as? String).map { "\"\($0)\"" } ?? (n["id"] as? String).map { "#\($0)" }
                }
                var seen = Set<String>()
                let some = labels.filter { seen.insert($0).inserted }.prefix(12).joined(separator: ", ")
                throw SimlessError("nothing on screen matches \"\(query)\"" + (some.isEmpty ? "" : "; on screen: \(some)"))
            }
            return (n, generation)
        }
        func center(_ n: [String: Any]) -> (Double, Double) {
            let f = n["frame"] as? [Double] ?? [0, 0, 0, 0]
            return (f[0] + f[2] / 2, f[1] + f[3] / 2)
        }
        switch step {
        case .tap(let q), .longPress(let q):
            let (n, g) = try target(q)
            let (x, y) = center(n)
            var req: [String: Any] = ["cmd": "ui.tap", "x": x, "y": y, "ref": n["ref"] ?? -1, "generation": g]
            if case .longPress = step { req["duration"] = 1.0 }
            let r = try call(req)
            settle()
            return r["how"] as? String
        case .type(let q, let text):
            let (n, g) = try target(q)
            if n["focused"] as? Bool != true {
                let (x, y) = center(n)
                _ = try call(["cmd": "ui.tap", "x": x, "y": y, "ref": n["ref"] ?? -1, "generation": g])
                settle()
            }
            _ = try call(["cmd": "ui.type", "text": text])
            settle()
            return nil
        case .swipe(let dir, let on):
            var x = c.width / 2, y = c.height / 2, w = c.width, h = c.height
            if let on {
                let (n, _) = try target(on)
                let f = n["frame"] as? [Double] ?? [0, 0, w, h]
                (x, y, w, h) = (f[0] + f[2] / 2, f[1] + f[3] / 2, f[2], f[3])
            }
            let (dx, dy): (Double, Double) = ["up": (0, -1), "down": (0, 1), "left": (-1, 0), "right": (1, 0)][dir]!
            _ = try call(["cmd": "ui.swipe", "x": x, "y": y, "dx": dx, "dy": dy, "width": w, "height": h, "velocity": 1000.0])
            settle()
            return nil
        case .wait(let ms):
            Thread.sleep(forTimeInterval: ms / 1000)
            settle()
            return nil
        }
    }

    /// `#id` by identifier; otherwise the label, exactly, then ignoring case, then
    /// as a part of it (then the identifier or placeholder). On-screen elements first.
    static func find(_ query: String, in nodes: [[String: Any]]) -> [String: Any]? {
        let candidates = nodes.filter { $0["automationOnly"] as? Bool != true }
        let ranked = candidates.filter { $0["hittable"] as? Bool == true } + candidates.filter { $0["hittable"] as? Bool != true }
        if query.hasPrefix("#") {
            let id = String(query.dropFirst())
            return ranked.first { $0["id"] as? String == id }
        }
        let tests: [([String: Any]) -> Bool] = [
            { $0["label"] as? String == query },
            { ($0["label"] as? String)?.caseInsensitiveCompare(query) == .orderedSame },
            { $0["id"] as? String == query || $0["placeholder"] as? String == query },
            { ($0["label"] as? String)?.localizedCaseInsensitiveContains(query) == true },
        ]
        for test in tests { if let n = ranked.first(where: test) { return n } }
        return nil
    }
}
