// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

let usage = """
simless: fast, headless, simulator-free SwiftUI checks for AI agents.

  simless init [--no-hook]         set up this repo (.simless.json, SimlessKit, fixtures, App.init hook)
  simless up                       build (Designed for iPad), install this worktree's slot, start its host
  simless render <fixture|all>     render and print the accessibility tree + issues
        [--dark] [--device iphone|iphone-small|iphone-max|ipad] [--matrix] [--png <file|dir>] [--json]
        --matrix: light+dark × iphone, iphone-small, ipad
  simless reload [files...]        hot-reload edited view files (default: all edited since `simless up`)
        [--render <fixture|all>] [--no-fallback]
  simless test [Target[/Class[/method]]...]   unit tests on the Mac, no simulator
  simless status                   slots, hosts, live-reload availability
  simless down [--all]             stop this worktree's host (or every host); relaunches on next use
  simless clean [--all]            remove this worktree's host, slot and build cache (--all: everything simless created)
  simless skill install            install the Claude Code skill so agents know how to use simless
  simless agent install            build + start SimlessAgent (enables ~1.5 s live reload; needs Full Disk Access)

  -v, --verbose               show every command simless runs

AI agents: `simless skill install` gives Claude Code a skill describing the whole workflow.
Other agents: see the "For AI agents" section of the README in the simless source folder.
"""

struct Args {
    var positional: [String] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]

    init(_ raw: [String]) {
        let valued: Set<String> = ["--device", "--png", "--render", "--kit-dir", "--scheme", "--project", "--test-target"]
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if valued.contains(a), i + 1 < raw.count { values[a] = raw[i + 1]; i += 2; continue }
            if a.hasPrefix("-") { flags.insert(a) } else { positional.append(a) }
            i += 1
        }
    }
}

// MARK: - Commands

func cmdInit(_ args: Args) throws {
    let cwd = FileManager.default.currentDirectoryPath
    let root = (try? Shell.check(["git", "-C", cwd, "rev-parse", "--show-toplevel"]))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? cwd
    let fm = FileManager.default
    let project = args.values["--project"] ?? ((try? fm.contentsOfDirectory(atPath: root)) ?? [])
        .filter { $0.hasSuffix(".xcodeproj") && !$0.hasSuffix(".simless.xcodeproj") }.sorted().first
    guard let project else { throw SimlessError("no .xcodeproj in \(root) (workspaces are not supported yet)") }

    // `-list` can't take -derivedDataPath and may create a folder in the default
    // DerivedData; remove one only if this call created it.
    let defaultDD = "\(Paths.home)/Library/Developer/Xcode/DerivedData"
    let existing = Set((try? fm.contentsOfDirectory(atPath: defaultDD)) ?? [])
    let listing = try Shell.check(["xcodebuild", "-list", "-json", "-project", project], cwd: root, stdoutOnly: true)
    let projectName = (project as NSString).deletingPathExtension
    for dir in (try? fm.contentsOfDirectory(atPath: defaultDD)) ?? [] where !existing.contains(dir) && dir.hasPrefix("\(projectName)-") {
        try? fm.removeItem(atPath: "\(defaultDD)/\(dir)")
    }
    guard let start = listing.firstIndex(of: "{"),
          let json = try JSONSerialization.jsonObject(with: Data(listing[start...].utf8)) as? [String: Any],
          let p = json["project"] as? [String: Any] else { throw SimlessError("could not list \(project)") }
    let schemes = p["schemes"] as? [String] ?? []
    let targets = p["targets"] as? [String] ?? []
    let base = (project as NSString).deletingPathExtension
    let scheme = args.values["--scheme"] ?? (schemes.contains(base) ? base : schemes.first ?? base)
    let appTarget = targets.contains(scheme) ? scheme : base
    let testTarget = args.values["--test-target"]
        ?? (targets.contains("\(appTarget)Tests") ? "\(appTarget)Tests"
            : targets.first { $0.hasSuffix("Tests") && !$0.hasSuffix("UITests") })
    guard let testTarget else {
        throw SimlessError("no unit-test target found; simless installs hosts through an app-hosted unit-test target (pass --test-target)")
    }
    let sourceDir = fm.fileExists(atPath: "\(root)/\(appTarget)") ? appTarget : "."
    let kitDir = args.values["--kit-dir"] ?? (sourceDir == "." ? "Simless" : "\(sourceDir)/Simless")

    let config = Config(project: project, scheme: scheme, appTarget: appTarget, testTarget: testTarget,
                        kitDir: kitDir, sourceDirs: [sourceDir])
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(config).write(to: URL(fileURLWithPath: "\(root)/\(Workspace.configName)"))

    try mkdirp("\(root)/\(kitDir)")
    let kit = "\(root)/\(config.kitFile)"
    try? fm.removeItem(atPath: kit)
    try fm.copyItem(atPath: "\(Paths.toolRoot)/Templates/SimlessKit.swift", toPath: kit)
    let fixtures = "\(root)/\(config.fixturesFile)"
    if !fm.fileExists(atPath: fixtures) {
        try fm.copyItem(atPath: "\(Paths.toolRoot)/Templates/SimlessFixtures.swift", toPath: fixtures)
    }

    // The generated build-variant project and test plans stay out of git
    // without touching .gitignore.
    if let exclude = try? Shell.check(["git", "-C", root, "rev-parse", "--git-path", "info/exclude"])
        .trimmingCharacters(in: .whitespacesAndNewlines) {
        let path = exclude.hasPrefix("/") ? exclude : "\(root)/\(exclude)"
        var current = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let missing = ["*.simless.xcodeproj", "*.simless.xctestplan"].filter { !current.contains($0) }
        if !missing.isEmpty {
            try mkdirp((path as NSString).deletingLastPathComponent)
            if !current.isEmpty && !current.hasSuffix("\n") { current += "\n" }
            try (current + missing.map { $0 + "\n" }.joined()).write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    let pbx = (try? String(contentsOfFile: "\(root)/\(project)/project.pbxproj", encoding: .utf8)) ?? ""
    let synced = pbx.contains("PBXFileSystemSynchronizedRootGroup")
    let hook = args.flags.contains("--no-hook") ? nil : try insertHook(in: "\(root)/\(sourceDir)")
    print("""
        wrote \(Workspace.configName): scheme \(scheme), app \(appTarget), tests \(testTarget)
        wrote \(config.kitFile) and \(config.fixturesFile)

        Next:
          1. \(synced ? "Both files are in a synchronized folder, so Xcode picks them up." : "Add both files to the \(appTarget) target.")
          2. \(hook.map { "App hook: \($0)" } ?? """
        In your App's init(), add:
                 #if DEBUG && os(iOS)
                 SimlessHost.startIfRequested()
                 #endif
        """)
          3. Register screens in \((config.fixturesFile as NSString).lastPathComponent), then run `simless up`.
          4. Agents: `simless skill install` (once per machine) teaches Claude Code the workflow.
        """)
}

/// Adds `SimlessHost.startIfRequested()` to the `@main` App's init().
/// Returns what it did, or nil when it couldn't find a safe place.
func insertHook(in sourceDir: String) throws -> String? {
    let call = "SimlessHost.startIfRequested()"
    func block(_ indent: String) -> String {
        ["#if DEBUG && os(iOS)", call, "#endif"].map { indent + $0 + "\n" }.joined()
    }
    guard let e = FileManager.default.enumerator(atPath: sourceDir) else { return nil }
    while let rel = e.nextObject() as? String {
        guard rel.hasSuffix(".swift"), !rel.contains("Simless/") else { continue }
        let path = "\(sourceDir)/\(rel)"
        guard var s = try? String(contentsOfFile: path, encoding: .utf8),
              let decl = s.range(of: #"@main\s+struct\s+\w+\s*:\s*([\w.]+\s*,\s*)*App\b[^{]*\{"#, options: .regularExpression)
        else { continue }
        if s.contains(call) { return "already present in \(rel)" }
        // An existing init(): add the call as its first statement.
        if let initRange = s.range(of: #"\n([ \t]*)init\(\)\s*\{[ \t]*\n"#, options: .regularExpression, range: decl.upperBound..<s.endIndex) {
            let indent = String(s[initRange].dropFirst().prefix { $0 == " " || $0 == "\t" }) + "    "
            s.insert(contentsOf: block(indent), at: initRange.upperBound)
            try s.write(toFile: path, atomically: true, encoding: .utf8)
            return "added to init() in \(rel)"
        }
        // No init(): add one right after the declaration.
        s.insert(contentsOf: "\n    init() {\n" + block("        ") + "    }\n", at: decl.upperBound)
        try s.write(toFile: path, atomically: true, encoding: .utf8)
        return "added an init() to the App in \(rel)"
    }
    return nil
}

func cmdSkill(_ args: Args) throws {
    guard args.positional.first == "install" else { throw SimlessError("usage: simless skill install") }
    let dir = "\(Paths.home)/.claude/skills/simless"
    try mkdirp(dir)
    let dst = "\(dir)/SKILL.md"
    try? FileManager.default.removeItem(atPath: dst)
    try FileManager.default.copyItem(atPath: "\(Paths.toolRoot)/Templates/SKILL.md", toPath: dst)
    print("installed Claude Code skill: \(dst)")
}

func currentSlot(_ ws: Workspace) throws -> SlotRecord {
    let settings = try ws.settings()
    let state = GlobalState.load()
    guard let slot = state.slots.first(where: { $0.bundleBase == settings.bundleID && $0.worktree == ws.root }) else {
        throw SimlessError("no host for this worktree; run `simless up`")
    }
    return slot
}

/// The slot with a running host, launching it if it is installed but stopped.
func runningSlot(_ ws: Workspace) throws -> SlotRecord {
    let slot = try currentSlot(ws)
    if slot.stats() == nil { try Slots.launch(slot, idleMinutes: ws.idleMinutes) }
    return slot
}

func cmdUp(_ args: Args) throws {
    let ws = try Workspace.load()
    Cleanup.capCompileCache()
    let t = now()
    let buildStart = Date().timeIntervalSinceReferenceDate
    // Mark the build cache as ours before creating anything in it, so another
    // agent's garbage collection never mistakes it for an orphan.
    try mkdirp(ws.work)
    try ws.root.write(toFile: "\(ws.work)/worktree.txt", atomically: true, encoding: .utf8)
    let previousSnapshot = try? Data(contentsOf: URL(fileURLWithPath: ws.snapshotPath))
    try ws.snapshotSources()
    do { try ws.build() } catch {
        // A failed build must not hide edits from the next `simless reload`.
        if let previousSnapshot { try? previousSnapshot.write(to: URL(fileURLWithPath: ws.snapshotPath)) }
        else { try? FileManager.default.removeItem(atPath: ws.snapshotPath) }
        throw error
    }
    let settings = try ws.settings()
    var slot = try GlobalState.slot(bundleBase: settings.bundleID, worktree: ws.root)
    try Slots.prepare(slot, ws: ws, settings: settings)
    // The fresh build contains every edit; earlier patches must not be re-applied.
    slot.builtAt = buildStart
    slot.patch = 0
    slot.lastPatch = nil
    try GlobalState.update(slot)
    try Slots.install(slot, ws: ws)
    try Slots.launch(slot, idleMinutes: ws.idleMinutes)
    let stats = slot.stats() ?? [:]
    let fixtures = stats["fixtures"] as? [String] ?? []
    print("ready in \(secs(t)): \(slot.slotID) on :\(slot.port), \(stats["footprintMB"] ?? "?") MB")
    print("fixtures (\(fixtures.count)): \(fixtures.isEmpty ? "none; register some in \(ws.config.fixturesFile)" : fixtures.joined(separator: ", "))")
    print("live reload: \(Agent.liveStatus(probeSlot: slot).map { "off (\($0)); reloads use warm mode" } ?? "on")")
}

func cmdRender(_ args: Args) throws {
    let ws = try Workspace.load()
    guard let target = args.positional.first else { throw SimlessError("usage: simless render <fixture|all>") }
    let slot = try runningSlot(ws)
    try render(slot: slot, target: target, args: args, ws: ws)
}

func render(slot: SlotRecord, target: String, args: Args, ws: Workspace) throws {
    let fixtures = target == "all" ? (slot.stats()?["fixtures"] as? [String] ?? []) : [target]
    if fixtures.isEmpty { throw SimlessError("no fixtures registered in \(ws.config.fixturesFile)") }
    let variants: [(dark: Bool, device: String)] = args.flags.contains("--matrix")
        ? [false, true].flatMap { d in ["iphone", "iphone-small", "ipad"].map { (d, $0) } }
        : [(args.flags.contains("--dark"), args.values["--device"] ?? ws.config.device)]
    var total = 0, count = 0
    for fixture in fixtures {
        for v in variants {
            var options = Render.Options(dark: v.dark, device: v.device, json: args.flags.contains("--json"))
            if var png = args.values["--png"] {
                while png.count > 1 && png.hasSuffix("/") { png.removeLast() }
                let isDir = fixtures.count > 1 || variants.count > 1 || args.values["--png"]!.hasSuffix("/")
                if isDir { try mkdirp(png) }
                options.pngPath = isDir ? "\(png)/\(fixture)\(v.dark ? "-dark" : "")-\(v.device).png" : png
            }
            let (text, issues) = try Render.run(slot: slot, fixture: fixture, options: options)
            print(text)
            total += issues
            count += 1
        }
    }
    if count > 1 { print("\(count) renders (\(fixtures.count) fixture(s) × \(variants.count) variant(s)), \(total) issue(s)") }
}

func cmdReload(_ args: Args) throws {
    let ws = try Workspace.load()
    var slot = try runningSlot(ws)
    let t = now()
    if args.positional.isEmpty && !exists(ws.snapshotPath) {
        throw SimlessError("no source snapshot for this worktree yet; run `simless up` once")
    }
    let files = args.positional.isEmpty
        ? ws.changedSources()
        : args.positional.map { $0.hasPrefix("/") ? $0 : "\(FileManager.default.currentDirectoryPath)/\($0)" }
    let kit = "\(ws.root)/\(ws.config.kitFile)"
    if files.isEmpty {
        print("nothing edited since the last `simless up`")
    } else if files.contains(kit) {
        Log.step("SimlessKit changed; full rebuild")
        try cmdUp(args)
        slot = try currentSlot(ws)
    } else {
        do {
            let r = try Patch.apply(ws: ws, slot: &slot, files: files)
            let names = r.files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            print(String(format: "reloaded (%@) in %.1fs: compile %.1fs + apply %.1fs; files edited since `simless up`: %@",
                         r.mode.rawValue, now() - t, r.compile, r.apply, names))
        } catch let error as SimlessError where error.description.hasPrefix("patch compile failed") {
            print(error.description)
            if args.flags.contains("--no-fallback") { exit(1) }
            // Either a real compile error or an edit a patch can't express (stored
            // properties, signatures, new types used elsewhere): the full build decides.
            Log.step("falling back to a full rebuild")
            try cmdUp(args)
            slot = try currentSlot(ws)
        }
    }
    if let target = args.values["--render"] { try render(slot: slot, target: target, args: args, ws: ws) }
}

func cmdTest(_ args: Args) throws {
    let ws = try Workspace.load()
    let slot = try currentSlot(ws)
    let edited = ws.changedSources()
    if !edited.isEmpty { Log.info("note: \(edited.count) file(s) edited since `simless up`; tests run the last full build") }
    let filters = args.positional.isEmpty ? [ws.config.testTarget] : args.positional
    let t = now()
    // Tests run inside the slot app, so the host stops for the duration.
    Slots.stop(slot)
    defer { try? Slots.launch(slot, idleMinutes: ws.idleMinutes) }
    let r = try withLock("install") {
        try Shell.run(["xcodebuild", "test-without-building", "-xctestrun", "\(slot.dir)/slot.xctestrun",
                       "-derivedDataPath", ws.derivedData,
                       "-destination", Workspace.dfiDestination] + filters.map { "-only-testing:\($0)" },
                      cwd: ws.root, logPath: "\(slot.dir)/test.log")
    }
    let lines = r.out.split(separator: "\n")
    // XCTest failures ("<file>:<line>: error: -[Class test] : ...") and xcodebuild errors only.
    for l in lines where l.contains(": error: -[") || l.hasPrefix("xcodebuild: error:") || l.contains("' failed (") { print(l) }
    if let summary = lines.last(where: { $0.contains("Executed") }) { print(summary.trimmingCharacters(in: .whitespaces)) }
    print("\(r.code == 0 ? "PASSED" : "FAILED") in \(secs(t)) (log: \(slot.dir)/test.log)")
    if r.code != 0 { exit(1) }
}

func cmdStatus(_ args: Args) throws {
    let state = GlobalState.load()
    if state.slots.isEmpty { print("no hosts"); return }
    for s in state.slots.sorted(by: { $0.port < $1.port }) {
        if let st = s.stats() {
            print("\(s.slotID)  :\(s.port)  up  \(st["footprintMB"] ?? "?") MB  patch \(st["patch"] ?? 0)  renders \(st["renders"] ?? 0)  \(s.worktree)")
        } else {
            print("\(s.slotID)  :\(s.port)  down  \(s.worktree)")
        }
    }
    let probe = state.slots.first { $0.stats() != nil }
    print("live reload: \(Agent.liveStatus(probeSlot: probe).map { "off (\($0))" } ?? "on")")
}

func cmdDown(_ args: Args) throws {
    let slots: [SlotRecord]
    if args.flags.contains("--all") {
        slots = GlobalState.load().slots
    } else {
        slots = [try currentSlot(try Workspace.load())]
    }
    // Only stops: the next render/reload relaunches in ~1 s. `simless clean` (or the
    // automatic cleanup when a worktree is deleted) removes slots and caches.
    for s in slots {
        Slots.stop(s)
        print("stopped \(s.slotID)")
    }
}

func cmdAgent(_ args: Args) throws {
    switch args.positional.first {
    case "install":
        let team = (try? Workspace.load()).flatMap { try? $0.settings().team }
        guard let team = team ?? ProcessInfo.processInfo.environment["SIMLESS_TEAM"] else {
            throw SimlessError("run inside a repo after `simless up` (or set SIMLESS_TEAM) so simless knows your team")
        }
        try Agent.install(team: team)
        print("""
            SimlessAgent installed at \(Paths.agentApp)
            For ~1.5 s live reload, grant it Full Disk Access:
              System Settings → Privacy & Security → Full Disk Access → + → SimlessAgent.app
            It can only copy simless's patch dylibs into the temp folder of Simless render-host containers.
            """)
    default:
        let probe = GlobalState.load().slots.first { $0.stats() != nil }
        print("live reload: \(Agent.liveStatus(probeSlot: probe).map { "off (\($0))" } ?? "on")")
    }
}

// MARK: - Main

var raw = Array(CommandLine.arguments.dropFirst())
if raw.contains("-v") || raw.contains("--verbose") { Log.verbose = true; raw.removeAll { $0 == "-v" || $0 == "--verbose" } }
guard let command = raw.first else { print(usage); exit(0) }
let args = Args(Array(raw.dropFirst()))

do {
    if !["help", "-h", "--help", "init", "skill"].contains(command) { Cleanup.collectGarbage() }
    switch command {
    case "init": try cmdInit(args)
    case "up": try cmdUp(args)
    case "render": try cmdRender(args)
    case "reload": try cmdReload(args)
    case "test": try cmdTest(args)
    case "status": try cmdStatus(args)
    case "down": try cmdDown(args)
    case "agent": try cmdAgent(args)
    case "clean": try Cleanup.clean(all: args.flags.contains("--all"))
    case "skill": try cmdSkill(args)
    case "help", "-h", "--help": print(usage)
    default: print(usage); exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
