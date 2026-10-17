// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// Test runs from several worktrees at once (agents in parallel worktrees)
/// share the Mac's cores instead of each sizing itself for the whole Mac and
/// slowing the others into timeouts. A run leaves a marker in its worktree's
/// cache while it runs, and a new run takes its share of the cores.
enum Budget {
    struct Run: Codable {
        let pid: Int32
        let kind: String        // "unit" or "ui"
        let worktree: String
        let started: Double
        var hosts: Int
    }

    static var cores: Int { ProcessInfo.processInfo.processorCount }

    /// Test runs going on in other worktrees right now.
    static func others(than ws: Workspace) -> [Run] {
        running().filter { $0.worktree != ws.root }
    }

    static func running() -> [Run] {
        let work = "\(Paths.cache)/work"
        return ((try? FileManager.default.contentsOfDirectory(atPath: work)) ?? []).compactMap { dir in
            let path = "\(work)/\(dir)/run.json"
            guard let data = FileManager.default.contents(atPath: path),
                  let run = try? JSONDecoder().decode(Run.self, from: data) else { return nil }
            guard kill(run.pid, 0) == 0 else { try? FileManager.default.removeItem(atPath: path); return nil }
            return run
        }
    }

    /// This run's share of the cores: all of them alone, half with one other run, and so on.
    static func share(_ ws: Workspace) -> Double {
        1.0 / Double(others(than: ws).count + 1)
    }

    /// Marks this worktree's run until the process exits.
    static func start(_ ws: Workspace, kind: String, hosts: Int) {
        let run = Run(pid: getpid(), kind: kind, worktree: ws.root, started: Date().timeIntervalSinceReferenceDate, hosts: hosts)
        try? JSONEncoder().encode(run).write(to: URL(fileURLWithPath: "\(ws.work)/run.json"))
    }

    static func finish(_ ws: Workspace) {
        try? FileManager.default.removeItem(atPath: "\(ws.work)/run.json")
    }
}
