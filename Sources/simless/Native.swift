// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import AppKit

/// The native launch mode, simless's default. The app's iOS device build is
/// retagged for Mac Catalyst (MachO) and signed ad hoc, then started directly
/// as a process: no certificate, provisioning profile, xcodebuild install or
/// Full Disk Access, and it runs in a VM or without a login session too.
///
/// The app runs outside the app sandbox, so simless gives it what the sandbox
/// gave it before: its own home folder in the slot (documents, caches, tmp),
/// preferences under the slot's id, and a keychain of its own (the runtime
/// does those; see Runtime/Native.swift). `"mode": "dfi"` in .simless.json
/// (or SIMLESS_MODE=dfi) brings back the signed "Designed for iPad" install.
enum Native {

    // MARK: - Mode

    /// Whether this worktree's hosts run natively.
    static func enabled(_ ws: Workspace) -> Bool {
        let mode = ProcessInfo.processInfo.environment["SIMLESS_MODE"] ?? ws.config.mode ?? "native"
        return mode != "dfi"
    }

    /// Whether the slot was prepared for the native mode (what its launches follow).
    static func isNative(_ slot: SlotRecord) -> Bool { exists(marker(slot)) }

    static func appDir(_ slot: SlotRecord) -> String { "\(slot.dir)/Native" }
    static func home(_ slot: SlotRecord) -> String { "\(slot.dir)/home" }
    private static func marker(_ slot: SlotRecord) -> String { "\(appDir(slot))/.prepared" }

    /// The slot's app bundle.
    static func app(_ slot: SlotRecord) throws -> String {
        let dir = appDir(slot)
        guard isNative(slot), let app = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.first(where: { $0.hasSuffix(".app") }) else {
            throw SimlessError("\(slot.slotID) is not prepared; run `simless up`")
        }
        return "\(dir)/\(app)"
    }

    static func executable(_ app: String) -> String {
        let info = NSDictionary(contentsOfFile: "\(app)/Info.plist")
        let fallback = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
        let wanted = info?["CFBundleExecutable"] as? String ?? fallback
        // A file directly in the bundle, never a path the Info.plist makes up.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: app)) ?? []
        let name = entries.first { $0 == wanted } ?? fallback
        return "\(app)/\(name)"
    }

    // MARK: - Preparing a slot

    /// Clones the fresh build into the slot, renames it to the slot's id,
    /// retags its iOS binaries for Mac Catalyst and signs them ad hoc.
    static func prepare(_ slot: SlotRecord, ws: Workspace, settings: Workspace.Settings, embedded: Bool) throws {
        let t = now()
        let fm = FileManager.default
        // A host still running the previous build would keep the port and answer
        // for the new one (an install stops it in the dfi mode).
        Slots.stop(slot)
        let dir = appDir(slot)
        try? fm.removeItem(atPath: dir)
        try? fm.removeItem(atPath: "\(slot.dir)/Debug-iphoneos")   // a Designed-for-iPad install of this slot
        try mkdirp(dir)
        let app = "\(dir)/\(settings.wrapperName)"
        // APFS clone: near-free, and retagging rewrites only a few header bytes.
        try Shell.check(["/bin/cp", "-c", "-R", "\(ws.productsIphoneos)/\(settings.wrapperName)", app], what: "clone app")
        try? fm.removeItem(atPath: "\(app)/SimlessPatches")
        try? fm.removeItem(atPath: "\(app)/embedded.mobileprovision")

        // Extensions and the watch app are never launched; they stay for tests
        // that look for them, under ids within the slot's.
        for bundle in Slots.embeddedBundles(in: app) {
            if embedded { try Slots.reidentify("\(bundle)/Info.plist", from: settings.bundleID, to: slot.slotID) }
            else { try? fm.removeItem(atPath: bundle) }
        }
        if !embedded { try? fm.removeItem(atPath: "\(app)/Watch") }

        try editInfo("\(app)/Info.plist") { info in
            info["CFBundleIdentifier"] = slot.slotID
            // Never a Dock icon or a window, including in test runs that launch
            // the app without simless's arguments.
            info["LSUIElement"] = true
            info["LSBackgroundOnly"] = true
            // An iPhone-only app would get the phone idiom on the Mac, under which
            // SwiftUI's Stepper overflows the stack while the app's own window
            // draws, so the host dies at launch. With the iPad family too it gets
            // the iPad idiom, as every "Designed for iPad" app does (--idiom phone
            // still gives renders a phone's).
            var families = (info["UIDeviceFamily"] as? [Int]) ?? [1]
            if !families.contains(2) { families.append(2); info["UIDeviceFamily"] = families }
        }
        // Only the binaries that changed need a signature; a watch app's stay as built.
        let exe = executable(app)
        var changed: [String] = []
        for binary in MachO.binaries(in: app) where binary != exe {
            if try MachO.retagForCatalyst(binary) { changed.append(binary) }
        }
        try MachO.retagForCatalyst(exe)
        // The app's own signature last: it seals the nested code and the Info.plist edits.
        try signInsideOut(changed + [exe])

        let runtime = try RuntimeBuild.nativeDylib()
        try? fm.removeItem(atPath: "\(slot.dir)/SimlessRuntime.dylib")
        try fm.copyItem(atPath: runtime, toPath: "\(slot.dir)/SimlessRuntime.dylib")
        try settings.bundleID.write(toFile: "\(slot.dir)/original-id.txt", atomically: true, encoding: .utf8)
        try makeHome(slot)
        fm.createFile(atPath: marker(slot), contents: nil)
        Log.step("slot \(slot.slotID) prepared in \(secs(t))")
    }

    private static func editInfo(_ path: String, _ edit: (inout [String: Any]) -> Void) throws {
        guard let data = FileManager.default.contents(atPath: path),
              var info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SimlessError("could not read \(path)")
        }
        edit(&info)
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: URL(fileURLWithPath: path))
    }

    /// Ad hoc signatures: no identity, no keychain. Several codesign processes
    /// side by side, since signing hashes every page.
    static func signAdHoc(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let lanes = min(paths.count, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        let errors = Locked<[Error]>([])
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
            let mine = paths.enumerated().filter { $0.offset % lanes == lane }.map(\.element)
            do { try Shell.check(["/usr/bin/codesign", "-f", "-s", "-", "--timestamp=none"] + mine, what: "codesign") }
            catch { errors.mutate { $0.append(error) } }
        }
        if let first = errors.value.first { throw first }
    }

    /// Signs binaries inside bundles in the order codesign needs. Signing a
    /// bundle's main executable signs (and seals) the whole bundle, so what's
    /// inside a bundle goes first, the deepest bundles before the ones holding
    /// them, and two signatures never touch one bundle at the same time:
    /// only bundles at the same depth, which don't contain each other, go side by side.
    static func signInsideOut(_ paths: [String]) throws {
        let bundleExts: Set<String> = ["app", "appex", "framework", "xctest", "bundle"]
        /// The innermost bundle around `path`, and whether `path` is its main executable.
        func owner(_ path: String) -> (bundle: String, main: Bool) {
            var dir = (path as NSString).deletingLastPathComponent
            while dir.count > 1 {
                if bundleExts.contains((dir as NSString).pathExtension) {
                    return (dir, executable(dir) == path || "\(dir)/Versions/A/\(((dir as NSString).lastPathComponent as NSString).deletingPathExtension)" == path)
                }
                dir = (dir as NSString).deletingLastPathComponent
            }
            return ((path as NSString).deletingLastPathComponent, false)
        }
        let owners = paths.map { ($0, owner($0)) }
        let depths = Set(owners.map { $0.1.bundle.split(separator: "/").count }).sorted(by: >)
        for depth in depths {
            let level = owners.filter { $0.1.bundle.split(separator: "/").count == depth }
            try signAdHoc(level.filter { !$0.1.main }.map(\.0))   // loose dylibs inside these bundles
            try signAdHoc(level.filter { $0.1.main }.map(\.0))    // then the bundles themselves
        }
    }

    /// Retags a dylib or test bundle simless built (a patch, a package's test
    /// bundle) and signs it ad hoc.
    static func adopt(_ paths: [String]) throws {
        var changed: [String] = []
        for path in paths {
            let binaries = path.hasSuffix(".dylib") ? [path] : MachO.binaries(in: path)
            for b in binaries where try MachO.retagForCatalyst(b) { changed.append(b) }
        }
        try signInsideOut(changed)
    }

    // MARK: - The app's data

    /// The folders a fresh install's container starts with.
    static func makeHome(_ slot: SlotRecord) throws {
        let h = home(slot)
        for sub in ["Documents", "Library/Caches", "Library/Preferences", "Library/Application Support", "tmp"] {
            try mkdirp("\(h)/\(sub)")
        }
    }

    /// Empties the slot's data like a fresh install: its home folder and every
    /// preferences domain under the slot's id. Nothing has to launch for it.
    static func wipe(_ slot: SlotRecord) {
        try? FileManager.default.removeItem(atPath: home(slot))
        try? makeHome(slot)
        wipePreferences(slotID: slot.slotID)
    }

    /// Preferences go through cfprefsd to ~/Library/Preferences, keyed by the
    /// slot's id (the runtime keeps suites under it too), so they're cleared
    /// through CFPreferences: deleting the files behind cfprefsd's back would
    /// hand the next launch its cached values.
    static func wipePreferences(slotID: String, deleteFiles: Bool = false) {
        let dir = "\(Paths.home)/Library/Preferences"
        let domains = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".plist") && ($0 == "\(slotID).plist" || $0.hasPrefix("\(slotID).")) }
            .map { String($0.dropLast(".plist".count)) }
        for domain in Set(domains + [slotID]) {
            let d = domain as CFString
            if let keys = CFPreferencesCopyKeyList(d, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String], !keys.isEmpty {
                CFPreferencesSetMultiple(nil, keys as CFArray, d, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                CFPreferencesSynchronize(d, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            }
        }
        guard deleteFiles else { return }
        // The slot is going: its files too. cfprefsd may write an emptied file
        // again a few seconds later (for a host that has just quit, say), which
        // garbage collection then removes (removeOrphanPreferences).
        for domain in Set(domains + [slotID]) { try? FileManager.default.removeItem(atPath: "\(dir)/\(domain).plist") }
    }

    /// Empty preference files of slots that no longer exist: what cfprefsd wrote
    /// after their slot was removed. Only empty ones, only of simless slot ids.
    static func removeOrphanPreferences(known: Set<String>) {
        let dir = "\(Paths.home)/Library/Preferences"
        let pattern = #"^(.+\.simless\d+(-[a-z0-9]+)?)(\.suite\..+)?\.plist$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            guard let m = re.firstMatch(in: file, range: NSRange(file.startIndex..., in: file)),
                  let r = Range(m.range(at: 1), in: file), !known.contains(String(file[r])) else { continue }
            let path = "\(dir)/\(file)"
            guard let d = FileManager.default.contents(atPath: path), d.count < 100,
                  let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any], plist.isEmpty else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Whether the slot's hosts get a sandbox of their own (SIMLESS_ISOLATE=1 or `"isolate": true`).
    static func isolated(_ ws: Workspace?) -> Bool {
        if let e = ProcessInfo.processInfo.environment["SIMLESS_ISOLATE"] { return e == "1" }
        return ws?.config.isolate ?? false
    }

    /// What every native launch adds to the environment.
    static func environment(_ slot: SlotRecord) -> [String: String] {
        let h = home(slot)
        var env = isolation(slot)
        env.merge(environmentBase(h)) { $1 }
        // An iOS process's malloc returns freed pages to the system; a Mac
        // process's keeps them, which left a render host ~20 MB bigger than a
        // "Designed for iPad" one after a few dozen renders. Returning them at
        // once costs CPU-bound code ~4%, so only render hosts, which live long
        // and side by side, do it; test hosts run as fast as before.
        let spaceEfficient = ProcessInfo.processInfo.environment["SIMLESS_MALLOC_SPACE_EFFICIENT"] ?? (slot.kind == nil ? "1" : nil)
        if let spaceEfficient { env["MallocSpaceEfficient"] = spaceEfficient }
        return env
    }

    /// For an isolated host: what it may write (its slot) and read in the
    /// user's home (its worktree, its build folder, local packages outside it).
    private static func isolation(_ slot: SlotRecord) -> [String: String] {
        let ws = try? Workspace.load(at: slot.worktree)
        guard isolated(ws) else { return [:] }
        var readable = [slot.worktree, Paths.workDir(forWorktree: slot.worktree)]
        for p in ws?.packages ?? [] { readable.append(URL(fileURLWithPath: "\(slot.worktree)/\(p)").standardizedFileURL.path) }
        return ["SIMLESS_ISOLATE_SLOT": slot.dir, "SIMLESS_ISOLATE_USER_HOME": Paths.home,
                "SIMLESS_ISOLATE_READ": readable.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }.joined(separator: "\n"),
                "SIMLESS_ISOLATE_PORT": String(slot.port)]
    }

    private static func environmentBase(_ h: String) -> [String: String] {
        return ["SIMLESS_NATIVE": "1", "CFFIXED_USER_HOME": h, "HOME": h,
                "SIMLESS_TMPDIR": "\(h)/tmp/", "TMPDIR": "\(h)/tmp/",
                "SIMLESS_CACHEDIR": "\(h)/Library/Caches/"]
    }

    // MARK: - Processes

    /// Starts the slot's app with these arguments and environment (on top of a
    /// login-like base, as `open` gives an app), detached from simless, its
    /// output going to `log`.
    @discardableResult
    static func launch(_ slot: SlotRecord, env extra: [String: String], args: [String], log: String) throws -> pid_t {
        let exe = executable(try app(slot))
        var env: [String: String] = [:]
        let mine = ProcessInfo.processInfo.environment
        for key in ["USER", "LOGNAME", "SHELL", "LANG", "SIMLESS_PERMISSIONS", "SIMLESS_DYNAMIC_TYPE"] { env[key] = mine[key] }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        for (k, v) in environment(slot) { env[k] = v }
        for (k, v) in extra { env[k] = v }
        try? FileManager.default.removeItem(atPath: log)
        return try spawn(exe, args: args, env: env, log: log)
    }

    /// posix_spawn in a session of its own, with only stdin (/dev/null) and the
    /// log open, so it outlives simless and never holds simless's own output
    /// open. A thread reaps it if it exits while simless still runs.
    static func spawn(_ path: String, args: [String], env: [String: String], log: String) throws -> pid_t {
        try mkdirp((log as NSString).deletingLastPathComponent)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_addchdir_np(&actions, "/")
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ([path] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, envp)
        guard rc == 0 else { throw SimlessError("could not start \((path as NSString).lastPathComponent): \(String(cString: strerror(rc)))") }
        Thread.detachNewThread { var status: Int32 = 0; waitpid(pid, &status, 0) }
        return pid
    }

    /// Processes running the slot's app (any copy of it under the slot's folder).
    static func pids(_ slot: SlotRecord) -> [pid_t] {
        let prefix = appDir(slot) + "/"
        return allPids().filter { path(of: $0)?.hasPrefix(prefix) ?? false }
    }

    private static func allPids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(0, n)))).filter { $0 > 0 }
    }

    private static func path(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        // Paths under /tmp come back as /private/tmp.
        let p = String(cString: buf)
        return p.hasPrefix("/private/") && !Paths.slots.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p
    }

    /// Terminates every process of the slot, escalating to SIGKILL.
    static func terminate(_ slot: SlotRecord) {
        var running = pids(slot)
        guard !running.isEmpty else { return }
        running.forEach { kill($0, SIGTERM) }
        let deadline = now() + 3
        while now() < deadline {
            running = pids(slot)
            if running.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        running.forEach { kill($0, SIGKILL) }
        let hard = now() + 2
        while now() < hard, !pids(slot).isEmpty { Thread.sleep(forTimeInterval: 0.05) }
    }
}
