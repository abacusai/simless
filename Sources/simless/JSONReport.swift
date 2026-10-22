// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// `simless up --json` and `simless reload --json`: the command as a
/// pipeline's compile step. Its usual output goes to stderr, and stdout gets
/// one JSON object: whether it worked, what it did, and the compiler's
/// diagnostics (file, line, column, severity, message), from the full build
/// or the patch.
enum JSONReport {
    static func up(_ args: Args) -> Never {
        report(args) { _ in
            try cmdUp(args)
            return ["mode": "build"]
        }
    }

    static func reload(_ args: Args) -> Never {
        report(args) { ws in
            let before = try currentSlot(ws)
            let files = ws.changedSources().map { relative($0, ws) }
            try cmdReload(args)
            let after = try currentSlot(ws)
            let mode = after.builtAt != before.builtAt ? "build"
                : after.patch > before.patch ? "patch"
                : after.patch == 0 && before.patch > 0 ? "restart" : "none"
            return ["mode": mode, "edited": files]
        }
    }

    private static func report(_ args: Args, _ body: (Workspace) throws -> [String: Any]) -> Never {
        let t = now()
        // The command's own output goes to stderr; stdout is the JSON.
        fflush(stdout)
        let stdoutCopy = dup(1)
        dup2(2, 1)
        var out: [String: Any]
        var ok = true
        let ws = try? Workspace.load()
        do {
            guard let ws else { throw SimlessError("no \(Workspace.configName) here; run `simless init`") }
            out = try body(ws)
        } catch {
            ok = false
            out = ["error": "\(error)"]
        }
        fflush(stdout)
        dup2(stdoutCopy, 1)
        close(stdoutCopy)
        out["ok"] = ok
        out["seconds"] = ((now() - t) * 10).rounded() / 10
        var diagnostics = parse(out["error"] as? String ?? "")
        // A failed build: every diagnostic in its log, warnings included.
        if let ws, (out["error"] as? String ?? "").contains("build failed"),
           let log = try? String(contentsOfFile: "\(ws.work)/build.log", encoding: .utf8) {
            diagnostics = parse(log)
        }
        out["diagnostics"] = diagnostics.map { d in
            var d = d
            if let ws, let f = d["file"] as? String { d["file"] = relative(f, ws) }
            return d
        }
        // Which code the host runs, for a pipeline to check: the full build's
        // sources, the sources its code reflects (with the newest patch), the
        // sources on disk, and the fixtures that still render older code.
        // `current` is true only when the host reflects the sources on disk and
        // the fixtures rendered aren't stale. A failed build leaves the host on
        // the last one that worked.
        if let ws, let slot = try? currentSlot(ws) {
            let sources = ws.currentSourcesID(), stale = slot.stale ?? []
            out["build"] = slot.build ?? NSNull()
            out["hostSources"] = slot.sources ?? slot.build ?? NSNull()
            out["sources"] = sources
            out["patch"] = slot.patch
            out["stale"] = stale
            // With `--render X`, whether X shows them; else every fixture.
            let rendered = args.values["--render"].flatMap { $0 == "all" ? nil : [$0] }
            out["current"] = (slot.sources ?? slot.build) == sources && (rendered.map { Set($0).isDisjoint(with: stale) } ?? stale.isEmpty)
            if let stats = slot.stats() {
                out["host"] = ["slot": slot.slotID, "port": slot.port, "patch": slot.patch, "fixtures": stats["fixtures"] ?? []]
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data("{\"ok\":false}".utf8)
        print(String(decoding: data, as: UTF8.self))
        exit(ok ? 0 : 1)
    }

    private static let line = try! NSRegularExpression(
        pattern: #"^\s*(/[^:\n]+):(\d+):(\d+): (error|warning): (.*)$"#, options: .anchorsMatchLines)

    /// `path:line:column: severity: message` lines, each once, at most 200.
    static func parse(_ text: String) -> [[String: Any]] {
        var seen = Set<String>(), out: [[String: Any]] = []
        let ns = text as NSString
        for m in line.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let whole = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            guard seen.insert(whole).inserted, out.count < 200 else { continue }
            out.append(["file": ns.substring(with: m.range(at: 1)), "line": Int(ns.substring(with: m.range(at: 2))) ?? 0,
                        "column": Int(ns.substring(with: m.range(at: 3))) ?? 0, "severity": ns.substring(with: m.range(at: 4)),
                        "message": ns.substring(with: m.range(at: 5))])
        }
        return out
    }

    /// Relative to the worktree, whichever spelling of it the path uses (/tmp, /private/tmp).
    private static func relative(_ path: String, _ ws: Workspace) -> String {
        let real = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        let (p, root) = (real(path), real(ws.root))
        return p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : path
    }
}
