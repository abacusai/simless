import Foundation

enum Render {
    struct Options {
        var dark = false
        var device = "iphone"
        var pngPath: String?
        var json = false
    }

    static let canvases: [String: (Double, Double)] = [
        "iphone": (402, 874),        // iPhone 17 Pro
        "iphone-small": (375, 667),  // iPhone SE
        "iphone-max": (440, 956),    // iPhone 17 Pro Max
        "ipad": (820, 1180),         // iPad Air 11"
    ]

    /// Renders one fixture and returns the text an agent reads (or JSON).
    static func run(slot: SlotRecord, fixture: String, options: Options) throws -> (text: String, issues: Int) {
        guard let (w, h) = canvases[options.device] else {
            throw SimlessError("unknown device '\(options.device)'; one of \(canvases.keys.sorted().joined(separator: ", "))")
        }
        let client = try slot.client(timeout: 30)
        let r = try client.call(["cmd": "render", "fixture": fixture, "style": options.dark ? "dark" : "light",
                                 "width": w, "height": h, "image": options.pngPath != nil])
        guard r["ok"] as? Bool == true else {
            let known = (r["fixtures"] as? [String])?.joined(separator: ", ") ?? ""
            throw SimlessError("\(r["error"] as? String ?? "render failed")" + (known.isEmpty ? "" : "; fixtures: \(known)"))
        }
        if let path = options.pngPath, let b64 = r["png"] as? String, let data = Data(base64Encoded: b64) {
            try data.write(to: URL(fileURLWithPath: path))
        }
        let nodes = r["nodes"] as? [[String: Any]] ?? []
        let issues = findIssues(nodes, width: w, height: h)
        if options.json {
            var out = r
            out.removeValue(forKey: "png")
            out["issues"] = issues
            let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            return (String(decoding: data, as: UTF8.self), issues.count)
        }

        var lines: [String] = []
        let ms = (r["renderMs"] as? Double).map { String(format: "%.0f ms", $0) } ?? ""
        let patch = (r["patch"] as? Int).map { $0 > 0 ? " · patch \($0)" : "" } ?? ""
        lines.append("\(fixture) · \(options.dark ? "dark" : "light") · \(options.device) \(Int(w))×\(Int(h)) · \(ms)\(patch)")
        for n in nodes {
            let role = (n["role"] as? String ?? "element").padding(toLength: 7, withPad: " ", startingAt: 0)
            var label = (n["label"] as? String).map { "\"\($0)\"" } ?? "(no label)"
            if let v = n["value"] as? String, !v.isEmpty { label += " = \"\(v)\"" }
            let id = (n["id"] as? String).map { " #\($0)" } ?? ""
            lines.append("  \(role) \(label)\(id)  \(frameText(n))")
        }
        if let png = options.pngPath { lines.append("  png: \(png)") }
        lines.append(issues.isEmpty ? "  issues: none" : "  issues (\(issues.count)):")
        lines += issues.map { "    ⚠ " + $0 }
        return (lines.joined(separator: "\n"), issues.count)
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
    static func findIssues(_ nodes: [[String: Any]], width: Double, height: Double) -> [String] {
        var issues: [String] = []
        let interactive: Set<String> = ["button", "link", "search", "adjustable"]
        for n in nodes {
            let role = n["role"] as? String ?? ""
            let label = (n["label"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let (x, y, w, h) = frame(n)
            let name = label.isEmpty ? role : "\(role) \"\(label)\""
            if interactive.contains(role), label.isEmpty {
                issues.append("\(role) without accessibility label \(frameText(n))")
            }
            if w <= 0 || h <= 0 {
                issues.append("\(name) has zero size")
            } else if x < -0.5 || y < -0.5 || x + w > width + 0.5 || y + h > height + 0.5 {
                issues.append("\(name) extends outside the \(Int(width))×\(Int(height)) screen \(frameText(n))")
            }
            // HIG minimum hit target is 44×44 pt: flag either dimension.
            if interactive.contains(role), w > 0, h > 0, w < 44 || h < 44 {
                issues.append("\(name) tap target \(Int(w))×\(Int(h)) is smaller than 44×44")
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
                    issues.append("\"\(label)\" is exposed twice (as the \(c["role"] as? String ?? "control") and as separate text); hide the inner text from accessibility")
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
                    issues.append("controls overlap: \"\(a)\" and \"\(b)\"")
                }
            }
        }
        return issues
    }
}
