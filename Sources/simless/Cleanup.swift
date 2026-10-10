// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// simless cleans up after itself:
/// - every command first collects garbage left by worktrees that no longer exist
///   (agents delete their worktrees when done): host, slot, build cache;
/// - hosts exit on their own after 30 idle minutes;
/// - only the newest few patches are kept; the shared compile cache is capped.
enum Cleanup {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    static let keepPatches = 3
    static let compileCacheLimitGB = 12.0

    /// Stops the host, unregisters the install, deletes the slot directory.
    static func removeSlot(_ slot: SlotRecord) {
        Slots.stop(slot)
        removeSlotDir(slot.dir)
    }

    private static func removeSlotDir(_ dir: String) {
        let installed = "\(dir)/Debug-iphoneos/.XCInstall"
        for app in (try? FileManager.default.contentsOfDirectory(atPath: installed)) ?? [] where app.hasSuffix(".app") {
            _ = try? Shell.run([lsregister, "-u", "\(installed)/\(app)"], useXcode: false)
        }
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Cheap enough to run on every invocation.
    static func collectGarbage() {
        _ = try? withLock("state") {
            var state = GlobalState.load()
            let gone = state.slots.filter { !exists("\($0.worktree)/\(Workspace.configName)") }
            for slot in gone {
                Log.step("cleaning up \(slot.slotID): worktree \(slot.worktree) no longer exists")
                removeSlot(slot)
                try? FileManager.default.removeItem(atPath: Paths.workDir(forWorktree: slot.worktree))
            }
            state.slots.removeAll { s in gone.contains { $0.slotID == s.slotID } }
            if !gone.isEmpty { try state.save() }

            // Slot dirs no record points at (e.g. after a crash mid-`simless up`).
            let known = Set(state.slots.map(\.slotID))
            for dir in (try? FileManager.default.contentsOfDirectory(atPath: Paths.slots)) ?? [] where !known.contains(dir) {
                removeSlotDir("\(Paths.slots)/\(dir)")
            }
            // Build caches of worktrees that no longer exist.
            let work = "\(Paths.cache)/work"
            for dir in (try? FileManager.default.contentsOfDirectory(atPath: work)) ?? [] {
                let owner = try? String(contentsOfFile: "\(work)/\(dir)/worktree.txt", encoding: .utf8)
                // Unmarked and recent: possibly being created right now.
                let recent = Date().timeIntervalSinceReferenceDate - mtime("\(work)/\(dir)") < 1800
                if owner.map({ !exists("\($0)/\(Workspace.configName)") }) ?? !recent {
                    try? FileManager.default.removeItem(atPath: "\(work)/\(dir)")
                }
            }
        }
    }

    /// Keeps the newest patches of this worktree (the newest one is re-applied on relaunch).
    static func prunePatches(ws: Workspace) {
        let dir = "\(ws.work)/patches"
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        let modules = files.filter { $0.hasSuffix(".dylib") }
            .sorted { mtime("\(dir)/\($0)") > mtime("\(dir)/\($1)") }
            .map { String($0.dropLast(".dylib".count)) }
        for old in modules.dropFirst(keepPatches) {
            for f in files where f == "\(old).dylib" || f.hasPrefix("\(old)_") || f == "\(old).json" {
                try? fm.removeItem(atPath: "\(dir)/\(f)")
            }
        }
    }

    /// The shared compile cache only speeds up first builds; drop it when large.
    static func capCompileCache() {
        let path = "\(Paths.cache)/CompilationCache"
        guard exists(path), let out = try? Shell.run(["/usr/bin/du", "-sk", path], useXcode: false).out,
              let kb = Double(out.split(separator: "\t").first ?? "") else { return }
        if kb / 1_048_576 > compileCacheLimitGB {
            Log.step(String(format: "shared compile cache is %.1f GB; clearing it", kb / 1_048_576))
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Generated build-variant files next to the user's project.
    static func removeGenerated(ws: Workspace) {
        let fm = FileManager.default
        for dir in Set([ws.root, ws.projectDir]) {
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            where f.hasSuffix(".simless.xcodeproj") || f.hasSuffix(".simless.xctestplan") {
                try? fm.removeItem(atPath: "\(dir)/\(f)")
            }
        }
    }

    /// `simless clean`: this worktree. `simless clean --all`: everything simless created except
    /// the agent and the files in your repos (SimlessKit, fixtures, config).
    static func clean(all: Bool) throws {
        if all {
            let state = GlobalState.load()
            for slot in state.slots { removeSlot(slot) }
            // Every worktree simless built for (slot records and build-cache owner
            // markers), so generated project variants go too.
            let work = "\(Paths.cache)/work"
            var worktrees = Set(state.slots.map(\.worktree))
            for dir in (try? FileManager.default.contentsOfDirectory(atPath: work)) ?? [] {
                if let owner = try? String(contentsOfFile: "\(work)/\(dir)/worktree.txt", encoding: .utf8) { worktrees.insert(owner) }
            }
            for root in worktrees where exists("\(root)/\(Workspace.configName)") {
                if let ws = try? Workspace.load(at: root) { removeGenerated(ws: ws) }
            }
            let fm = FileManager.default
            for item in (try? fm.contentsOfDirectory(atPath: Paths.cache)) ?? [] {
                try? fm.removeItem(atPath: "\(Paths.cache)/\(item)")
            }
            print("removed all simless hosts, slots and caches (\(Paths.cache))")
        } else {
            let ws = try Workspace.load()
            let settings = try? ws.settings()
            if let settings, let slot = GlobalState.load().slots.first(where: {
                $0.bundleBase == settings.bundleID && $0.worktree == ws.root }) {
                removeSlot(slot)
                try GlobalState.release(slot)
            }
            try? FileManager.default.removeItem(atPath: ws.work)
            removeGenerated(ws: ws)
            print("removed this worktree's host, slot and build cache")
        }
    }
}
