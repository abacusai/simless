// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// simless cleans up after itself:
/// - every command first collects garbage left by worktrees that no longer exist
///   (agents delete their worktrees when done), or that haven't used simless
///   for two weeks: host, slot, the app's data container, build cache;
/// - crash reports of its hosts go after a day, and a test run starts with an
///   empty tmp in the app's container;
/// - hosts exit on their own after 30 idle minutes;
/// - only the newest few patches are kept; the shared compile cache is capped.
enum Cleanup {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    static let keepPatches = 3
    static let compileCacheLimitGB = 8.0

    /// Stops the host, unregisters the install, deletes the slot directory.
    static func removeSlot(_ slot: SlotRecord) {
        Slots.stop(slot)
        Slots.terminateAll(slot)   // test and UI-test hosts don't answer the render protocol
        removeSlotDir(slot.dir)
    }

    private static func removeSlotDir(_ dir: String) {
        let installed = "\(dir)/Debug-iphoneos/.XCInstall"
        for app in (try? FileManager.default.contentsOfDirectory(atPath: installed)) ?? [] where app.hasSuffix(".app") {
            wipeContainer(app: "\(installed)/\(app)", runtime: "\(dir)/SimlessRuntime.dylib")
            _ = try? Shell.run([lsregister, "-u", "\(installed)/\(app)"], useXcode: false)
        }
        removeCrashReports(slotID: (dir as NSString).lastPathComponent, olderThan: 0)
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Empties the slot app's data container. macOS protects app containers
    /// from other processes, so the app does it itself: launched with
    /// SIMLESS_WIPE=1, SimlessRuntime deletes its files and quits.
    /// Returns false when the app wouldn't launch at all.
    @discardableResult
    static func wipeContainer(app: String, runtime: String) -> Bool {
        guard exists(runtime) else { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-W", "-g", "-j", "-n", "--env", "DYLD_INSERT_LIBRARIES=\(runtime)", "--env", "SIMLESS_WIPE=1", app]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let deadline = now() + 20
        while p.isRunning && now() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { p.terminate(); return true }
        return p.terminationStatus == 0
    }

    /// Crash reports macOS wrote for simless hosts (a slot's, or every slot's),
    /// older than `age` seconds.
    static func removeCrashReports(slotID: String? = nil, olderThan age: TimeInterval) {
        let dir = "\(Paths.home)/Library/Logs/DiagnosticReports"
        for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".ips") {
            let path = "\(dir)/\(file)"
            guard Date().timeIntervalSinceReferenceDate - mtime(path) > age,
                  let handle = FileHandle(forReadingAtPath: path) else { continue }
            let head = String(decoding: handle.readData(ofLength: 600), as: UTF8.self)
            try? handle.close()
            guard let r = head.range(of: #""bundleID":"([^"]+)""#, options: .regularExpression) else { continue }
            let id = head[r].dropFirst("\"bundleID\":\"".count).dropLast()
            let ours = slotID.map { id == $0 } ?? (id.range(of: #"\.simless\d+(-[a-z0-9]+)?$"#, options: .regularExpression) != nil)
            if ours { try? FileManager.default.removeItem(atPath: path) }
        }
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
            // Worktrees that exist but haven't used simless for two weeks: their
            // hosts, slots and builds go (`simless up` makes them again).
            let stale = state.slots.filter { slot in
                let work = Paths.workDir(forWorktree: slot.worktree)
                let used = exists("\(work)/last-used") ? mtime("\(work)/last-used") : mtime(work)
                return used > 0 && Date().timeIntervalSinceReferenceDate - used > 14 * 86_400
            }
            for slot in stale {
                Log.step("cleaning up \(slot.slotID): \(slot.worktree) hasn't used simless for two weeks")
                removeSlot(slot)
                try? FileManager.default.removeItem(atPath: Paths.workDir(forWorktree: slot.worktree))
            }
            if !stale.isEmpty {
                state.slots.removeAll { s in stale.contains { $0.slotID == s.slotID } }
                try state.save()
            }
            // Crash reports of simless hosts, after a day.
            removeCrashReports(olderThan: 86_400)
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

    /// Runs a build, and if it failed on a damaged compilation cache (an
    /// entry left half-written, by a full disk for one), clears the cache and
    /// builds once more.
    static func retryingPoisonedCache(_ build: () throws -> Shell.Result) rethrows -> Shell.Result {
        let r = try build()
        guard r.code != 0, r.out.contains("cache poisoned") || r.out.contains("caching backend error") else { return r }
        Log.step("the shared compilation cache is damaged; clearing it and building again")
        try? FileManager.default.removeItem(atPath: "\(Paths.cache)/CompilationCache")
        return try build()
    }

    /// Everything simless keeps, across worktrees, in GB (SIMLESS_DISK_LIMIT_GB overrides).
    static var diskLimitGB: Double { ProcessInfo.processInfo.environment["SIMLESS_DISK_LIMIT_GB"].flatMap(Double.init) ?? 25 }

    static func sizeGB(_ path: String) -> Double {
        guard exists(path), let out = try? Shell.run(["/usr/bin/du", "-sk", path], useXcode: false).out,
              let kb = Double(out.split(separator: "\t").first ?? "") else { return 0 }
        return kb / 1_048_576
    }

    /// Keeps the whole cache under the limit: the builds and slots of the
    /// worktrees that used simless least recently go first (`simless up` there
    /// makes them again), then the shared compilation cache. The current
    /// worktree's are kept.
    static func enforceDiskLimit(keeping current: Workspace) {
        let limit = diskLimitGB
        var total = sizeGB(Paths.cache)
        guard total > limit else { return }
        _ = try? withLock("state") {
            var state = GlobalState.load()
            let work = "\(Paths.cache)/work"
            let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: work)) ?? []).map { "\(work)/\($0)" }
                // Not one in use: another session may be testing there right now.
                .filter { $0 != current.work && Date().timeIntervalSinceReferenceDate - lastUsed($0) > 3600 }
                .sorted { lastUsed($0) < lastUsed($1) }
            for dir in dirs where total > limit {
                let owner = (try? String(contentsOfFile: "\(dir)/worktree.txt", encoding: .utf8)) ?? dir
                let slots = state.slots.filter { Paths.workDir(forWorktree: $0.worktree) == dir }
                let freed = sizeGB(dir) + slots.reduce(0) { $0 + sizeGB("\(Paths.slots)/\($1.slotID)") }
                for slot in slots { removeSlot(slot) }
                state.slots.removeAll { s in slots.contains { $0.slotID == s.slotID } }
                try? FileManager.default.removeItem(atPath: dir)
                total -= freed
                Log.step(String(format: "disk: simless was over %.0f GB, freed %.1f GB of builds for %@ (used least recently)", limit, freed, owner))
            }
            try state.save()
        }
        if total > limit {
            let freed = sizeGB("\(Paths.cache)/CompilationCache")
            try? FileManager.default.removeItem(atPath: "\(Paths.cache)/CompilationCache")
            Log.step(String(format: "disk: simless was over %.0f GB, cleared the shared compilation cache (%.1f GB)", limit, freed))
        }
    }

    private static func lastUsed(_ workDir: String) -> Double {
        exists("\(workDir)/last-used") ? mtime("\(workDir)/last-used") : mtime(workDir)
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
            removeCrashReports(olderThan: 0)
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
            // The render slot and its test and UI-test siblings.
            for slot in GlobalState.load().slots where settings.map({ $0.bundleID == slot.bundleBase }) ?? false && slot.worktree == ws.root {
                removeSlot(slot)
                try GlobalState.release(slot)
            }
            try? FileManager.default.removeItem(atPath: ws.work)
            removeGenerated(ws: ws)
            print("removed this worktree's host, slot and build cache")
        }
    }
}
