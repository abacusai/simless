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
                        textSize: String? = nil, idiom: String? = nil) -> [String: Any] {
        var r: [String: Any] = ["cmd": "render", "fixture": fixture, "style": dark ? "dark" : "light", "width": c.width,
                                "height": c.height, "safeTop": c.safeTop, "safeBottom": c.safeBottom, "image": image]
        if let textSize { r["textSize"] = textSize }
        if let idiom, c.width < 600 { r["idiom"] = idiom }
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
        if let size = t["textSize"] as? String, t["onMac"] as? Bool == true {
            lines.append("  note: text size \(size) applies to layout (dynamicTypeSize branches, scaled metrics), but the Mac draws text at the default size; check text scaling itself in a simulator")
        }
        return lines
    }

    /// Renders one fixture and returns the text an agent reads (or JSON).
    static func run(slot: SlotRecord, fixture: String, options: Options) throws -> (text: String, issues: Int) {
        let c = try canvas(options.device)
        let (w, h) = (c.width, c.height)
        let client = try slot.client(timeout: 30)
        let r = try client.call(request(fixture: fixture, dark: options.dark, canvas: c, image: options.pngPath != nil,
                                        textSize: options.textSize, idiom: options.idiom))
        guard r["ok"] as? Bool == true else {
            let known = (r["fixtures"] as? [String])?.joined(separator: ", ") ?? ""
            throw SimlessError("\(r["error"] as? String ?? "render failed")" + (known.isEmpty ? "" : "; fixtures: \(known)"))
        }
        if let path = options.pngPath, let b64 = r["png"] as? String, let data = Data(base64Encoded: b64) {
            try data.write(to: URL(fileURLWithPath: path))
        }
        let nodes = r["nodes"] as? [[String: Any]] ?? []
        let found = findIssues(nodes, width: w, height: h, minTapTarget: options.checks.minTapTarget ?? 44)
        let ignore = options.checks.ignore ?? []
        let issues = found.filter { issue in !ignore.contains { issue.contains($0) } }
        if options.json {
            var out = r
            out.removeValue(forKey: "png")
            out["issues"] = issues
            out["ignoredIssues"] = found.count - issues.count
            let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            return (String(decoding: data, as: UTF8.self), issues.count)
        }

        var lines: [String] = []
        let ms = (r["renderMs"] as? Double).map { String(format: "%.0f ms", $0) } ?? ""
        let patch = (r["patch"] as? Int).map { $0 > 0 ? " · patch \($0)" : "" } ?? ""
        let extras = [r["locale"] as? String, options.textSize.map { "text \($0)" }].compactMap { $0 }.map { " · " + $0 }.joined()
        lines.append("\(fixture) · \(options.dark ? "dark" : "light") · \(options.device) \(Int(w))×\(Int(h))\(extras) · \(ms)\(patch)")
        lines += traitsText(r, device: options.device)
        for n in nodes {
            let role = n["role"] as? String ?? "element"
            let column = role.count < 7 ? role.padding(toLength: 7, withPad: " ", startingAt: 0) : role
            var label = (n["label"] as? String).map { "\"\($0)\"" } ?? "(no label)"
            if let v = n["value"] as? String, !v.isEmpty { label += " = \"\(v)\"" }
            let id = (n["id"] as? String).map { " #\($0)" } ?? ""
            lines.append("  \(column) \(label)\(id)  \(frameText(n))")
        }
        let below = nodes.filter { frame($0).1 + frame($0).3 > h + 0.5 }.count
        if below > 0 { lines.append("  below the fold: \(below) element(s) (scroll content, listed above)") }
        if let png = options.pngPath { lines.append("  png: \(png)") }
        let ignored = found.count - issues.count
        let ignoredText = ignored > 0 ? " (\(ignored) ignored by \(Workspace.configName))" : ""
        lines.append(issues.isEmpty ? "  issues: none\(ignoredText)" : "  issues (\(issues.count))\(ignoredText):")
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
    static func findIssues(_ nodes: [[String: Any]], width: Double, height: Double, minTapTarget: Double = 44) -> [String] {
        var issues: [String] = []
        let interactive: Set<String> = ["button", "link", "search", "adjustable"]
        for n in nodes {
            let role = n["role"] as? String ?? ""
            let label = (n["label"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let (x, _, w, h) = frame(n)
            let name = label.isEmpty ? role : "\(role) \"\(label)\""
            if interactive.contains(role), label.isEmpty {
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
            // UIKit's own controls (bar buttons) are sized by the system, not the app.
            if interactive.contains(role), n["system"] as? Bool != true, w > 0, h > 0, w < minTapTarget || h < minTapTarget {
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
