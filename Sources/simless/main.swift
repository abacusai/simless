// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

let version = "0.6.0"

let usage = """
simless: fast, headless, simulator-free SwiftUI checks for AI agents.

  simless init [--no-hook] [--template <dir>]         set up this repo (.simless.json, SimlessKit, fixtures, App.init hook)
  simless up [--no-tests]          build for iOS, install this worktree's slot (unsigned), start its host;
        also prepares local packages' tests and the test hosts (--no-tests skips that)
  simless render <fixture|all>     render and print the accessibility tree + issues
  simless act <fixture> <step>...  render, then tap/type/swipe/longpress/wait, then print the tree + issues
        steps: tap "<label|#id>"  type "<#id|label>" "<text>"  swipe up|down|left|right [on "<label|#id>"]
               longpress "<label|#id>"  wait <ms>   (and --device, --dark, --png, --json like render)
        [--dark] [--device iphone|iphone-small|iphone-max|ipad] [--matrix] [--png <file|dir>] [--json]
        [--locale <lang, e.g. hr>] [--text-size xs…xxxl|ax1…ax5] [--idiom phone] [--settle <ms>]
        --matrix: light+dark × iphone, iphone-small, ipad
  simless reload [files...]        hot-reload edited view files (default: all edited since `simless up`)
        [--render <fixture|all>] [--no-fallback] [--dry-run]
        with --render X, only X (and the screens the last patch covered) get the edit;
        other screens that reach it are listed as stale until the next full build
  simless test [Target[/Class[/method]]...|all]   unit tests on the Mac, no simulator
        local package test targets too; all: every unit test target
        [--skip Target[/Class[/method]]]... [--timeout <seconds per test, default 600>]
        [--hosts <test hosts side by side, default up to 4>] [--jobs <tests at once per host>]
        [--from <file|->]: test ids from a file or stdin, one per line, as the results JSON writes them
        (unit and UI ids can be mixed: both run, one exit code)
        [--allow-missing]: an id that matches no test is fine (by default it's not run, and the run fails)
  simless test ui [UITarget[/Class[/method]]...]   XCUITest UI tests, unchanged, in hidden hosts
        (naming a UI test target, class or test runs it the same way)
        [--jobs <hosts, default up to 4>] [--device iphone|ipad|iphone,ipad] [--timeout <seconds per test, default 600>]
  simless test --simulator-only    list the tests marked as needing a simulator (tests.simulatorOnly)
        and the xcodebuild command that runs just those on calibrate.device and calibrate.runtime
        (exits 1 and says what to install or create when that simulator isn't there)
        exit code 0 only when every selected test ran and passed (simulator-only ones aside)
        results: test-results.json and ui-test-results.json in the work folder (`simless status` shows it),
        every test with its status: passed, failed, crashed, skipped, flaky, not-run, simulator-only, excluded, not-built
  simless calibrate [fixture]     compare renders with an iOS Simulator (boots one, once per app)
        [--dark] [--png <dir>]: also dark mode; save both renders of every screen + a side-by-side report.md
        [--runtime <iOS version, e.g. 26.5>] [--sim-device <name, e.g. "iPhone 16e">]
  simless status                   hosts, test runs going on and their share of the Mac, disk use
  simless down [--all]             stop this worktree's hosts, render, test and UI (or every worktree's); they start again on next use
  simless clean [--all]            remove this worktree's host, slot and build cache (--all: everything simless created)
  simless skill install            install the Claude Code skill so agents know how to use simless
  simless agent install            build + start SimlessAgent (enables ~1.5 s live reload; needs Full Disk Access)

  simless version             version, Xcode and macOS (include in bug reports)
  -v, --verbose               show every command simless runs

AI agents: `simless skill install` gives Claude Code a skill describing the whole workflow.
Other agents: see the "For AI agents" section of the README in the simless source folder.
"""

struct Args {
    var positional: [String] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]
    var repeated: [String: [String]] = [:]

    init(_ raw: [String]) {
        let valued: Set<String> = ["--hosts", "--device", "--png", "--render", "--kit-dir", "--scheme", "--project", "--test-target", "--template",
                                   "--locale", "--text-size", "--idiom", "--settle", "--timeout", "--runtime", "--sim-device", "--jobs", "--from"]
        let repeatable: Set<String> = ["--skip"]
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if repeatable.contains(a), i + 1 < raw.count { repeated[a, default: []].append(raw[i + 1]); i += 2; continue }
            if valued.contains(a), i + 1 < raw.count { values[a] = raw[i + 1]; i += 2; continue }
            if a.hasPrefix("-") { flags.insert(a) } else { positional.append(a) }
            i += 1
        }
    }
}

// MARK: - Commands

func cmdInit(_ args: Args) throws {
    if let template = args.values["--template"] { return try initTemplate(template, args) }
    let cwd = FileManager.default.currentDirectoryPath
    let root = (try? Shell.check(["git", "-C", cwd, "rev-parse", "--show-toplevel"]))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? cwd
    let fm = FileManager.default
    let project = try args.values["--project"] ?? findProject(in: root)
    guard exists("\(root)/\(project)/project.pbxproj") else { throw SimlessError("\(project) is not an Xcode project") }
    let projectDir = (project as NSString).deletingLastPathComponent        // "" or e.g. "ios"
    let base = ((project as NSString).lastPathComponent as NSString).deletingPathExtension
    func inProjectDir(_ p: String) -> String { projectDir.isEmpty ? p : "\(projectDir)/\(p)" }

    // `-list` can't take -derivedDataPath and may create a folder in the default
    // DerivedData; the guard removes one only if this call created it.
    let listing = try withDefaultDerivedDataGuard(projectNames: [base]) {
        try Shell.check(["xcodebuild", "-list", "-json", "-project", project], cwd: root, stdoutOnly: true)
    }
    guard let start = listing.firstIndex(of: "{"),
          let json = try JSONSerialization.jsonObject(with: Data(listing[start...].utf8)) as? [String: Any],
          let p = json["project"] as? [String: Any] else { throw SimlessError("could not list \(project)") }
    let schemes = p["schemes"] as? [String] ?? []
    let targets = p["targets"] as? [String] ?? []
    let scheme = args.values["--scheme"] ?? (schemes.contains(base) ? base : schemes.first ?? base)
    let appTarget = targets.contains(scheme) ? scheme : base
    // Only the dfi mode needs one (it installs hosts through it); without one, `simless test` has no app targets.
    let testTarget = args.values["--test-target"]
        ?? (targets.contains("\(appTarget)Tests") ? "\(appTarget)Tests"
            : targets.first { $0.hasSuffix("Tests") && !$0.hasSuffix("UITests") }) ?? ""
    // The app's sources usually sit next to the project, in a folder named like the target.
    // Else (a generated project, say, with everything under Sources/) the top
    // folder of the one holding the `@main` App: the kit must sit among the
    // files the target compiles.
    let sourceDir = fm.fileExists(atPath: "\(root)/\(inProjectDir(appTarget))") ? inProjectDir(appTarget)
        : mainAppFolder(in: projectDir.isEmpty ? root : "\(root)/\(projectDir)").map(inProjectDir)
        ?? (projectDir.isEmpty ? "." : projectDir)
    // The kit must be compiled by the app target: in a synchronized folder of
    // the target's (checked for the folder it goes into, since a classic group
    // can hold synchronized subfolders), or else added to the target by hand.
    let pbx = (try? String(contentsOfFile: "\(root)/\(project)/project.pbxproj", encoding: .utf8)) ?? ""
    let synchronized = PBX.synchronizedFolders(target: appTarget, pbx: pbx).map(inProjectDir)
    func isSynchronized(_ dir: String) -> Bool { synchronized.contains { dir == $0 || dir.hasPrefix($0 + "/") || $0 == "." } }
    var kitDir = args.values["--kit-dir"] ?? (sourceDir == "." ? "Simless" : "\(sourceDir)/Simless")
    if args.values["--kit-dir"] == nil, !isSynchronized(kitDir) {
        // One of the target's synchronized folders, inside its sources when it can be.
        let inside = synchronized.filter { sourceDir == "." || $0.hasPrefix(sourceDir + "/") }
        let pick = inside.first { ($0 as NSString).lastPathComponent == "Debug" }
            ?? (inside.isEmpty ? synchronized : inside).min { ($0.count, $0) < ($1.count, $1) }
        if let pick { kitDir = "\(pick)/Simless" }
    }

    // Local Swift packages the project references: their views can be hot-reloaded too.
    let packages = Workspace.localPackages(root: root, project: project)

    // An existing .simless.json is kept (re-running init updates SimlessKit);
    // --force writes a fresh one.
    let configPath = "\(root)/\(Workspace.configName)"
    let existing = args.flags.contains("--force") ? nil : (try? Workspace.load(at: root))?.config
    let config = existing ?? Config(project: project, scheme: scheme, appTarget: appTarget, testTarget: testTarget,
                                    kitDir: kitDir, sourceDirs: [sourceDir], packages: packages.isEmpty ? nil : packages)
    if existing == nil {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: URL(fileURLWithPath: configPath))
    }

    try mkdirp("\(root)/\(kitDir)")
    let kit = "\(root)/\(config.kitFile)"
    try? fm.removeItem(atPath: kit)
    try fm.copyItem(atPath: "\(Paths.toolRoot)/Templates/SimlessKit.swift", toPath: kit)
    let fixtures = "\(root)/\(config.fixturesFile)"
    let newFixtures = !fm.fileExists(atPath: fixtures)
    if newFixtures {
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

    let synced = isSynchronized(config.kitDir)
    let hook = args.flags.contains("--no-hook") ? nil : try insertHook(in: "\(root)/\(sourceDir)")
    let configLine = existing != nil ? "kept \(Workspace.configName) (--force rewrites it)"
        : "wrote \(Workspace.configName): project \(project), scheme \(scheme), app \(appTarget), tests \(testTarget.isEmpty ? "none" : testTarget)\(packages.isEmpty ? "" : ", packages " + packages.joined(separator: ", "))"
    print("""
        \(configLine)
        wrote \(config.kitFile)\(newFixtures ? " and \(config.fixturesFile)" : "")

        Next:
          1. \(synced ? "Both files are in a synchronized folder of \(appTarget), so Xcode picks them up."
                : "\(config.kitDir) isn't in a folder Xcode syncs for \(appTarget): add both files to the \(appTarget) target (in Xcode: File > Add Files, with \(appTarget) checked under Targets)\(synchronized.isEmpty ? "" : ", or move the folder into one of \(synchronized.prefix(5).joined(separator: ", "))"). Until then, `simless up` fails with \"cannot find 'SimlessHost' in scope\".")
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

/// The .xcodeproj at the repository root, or in a subdirectory (e.g. ios/).
func findProject(in root: String) throws -> String {
    let skip: Set<String> = ["Pods", "node_modules", "Carthage", "DerivedData", "build", ".build", "vendor"]
    var found: [(path: String, depth: Int)] = []
    func scan(_ rel: String, _ depth: Int) {
        let dir = rel.isEmpty ? root : "\(root)/\(rel)"
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() {
            let path = rel.isEmpty ? name : "\(rel)/\(name)"
            if name.hasSuffix(".xcodeproj") {
                if !name.hasSuffix(".simless.xcodeproj") { found.append((path, depth)) }
            } else if depth < 3, !name.hasPrefix("."), !skip.contains(name), !name.hasSuffix(".xcworkspace"),
                      (try? FileManager.default.attributesOfItem(atPath: "\(dir)/\(name)")[.type] as? FileAttributeType) == .typeDirectory {
                scan(path, depth + 1)
            }
        }
    }
    scan("", 0)
    guard let shallowest = found.map(\.depth).min() else {
        throw SimlessError("no .xcodeproj found in \(root) or its subdirectories (workspaces are not supported yet)")
    }
    let candidates = found.filter { $0.depth == shallowest }.map(\.path)
    guard candidates.count == 1 else {
        throw SimlessError("several projects found (\(candidates.joined(separator: ", "))); pass --project <path>")
    }
    return candidates[0]
}


/// The top-level folder (relative to `dir`) of the file that declares the `@main` App.
func mainAppFolder(in dir: String) -> String? {
    let skip: Set<String> = ["Pods", "node_modules", "Carthage", "DerivedData", "build", ".build", "vendor"]
    guard let e = FileManager.default.enumerator(atPath: dir) else { return nil }
    while let rel = e.nextObject() as? String {
        let first = String(rel.split(separator: "/").first ?? "")
        if skip.contains(first) || first.hasPrefix(".") || first.hasSuffix(".xcodeproj") { e.skipDescendants(); continue }
        guard rel.hasSuffix(".swift"), rel.contains("/"),
              let s = try? String(contentsOfFile: "\(dir)/\(rel)", encoding: .utf8),
              s.range(of: #"@main\s+struct\s+\w+\s*:\s*([\w.]+\s*,\s*)*App\b"#, options: .regularExpression) != nil else { continue }
        return first
    }
    return nil
}

/// `simless init --template <dir>`: an xcodegen app template, whose project
/// is generated again on every build. It writes `.simless.json` and the kit
/// into the template's sources and touches no project file. It prints the
/// App hook to add, and the `project.yml` change when the kit is outside the
/// app target's sources.
func initTemplate(_ dir: String, _ args: Args) throws {
    let root = URL(fileURLWithPath: dir, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
    guard exists("\(root)/project.yml") else { throw SimlessError("\(dir) has no project.yml (`--template` takes an xcodegen app template)") }
    let dump: String
    do {
        dump = try Shell.check(["xcodegen", "dump", "--type", "json", "--spec", "\(root)/project.yml"], cwd: root, stdoutOnly: true)
    } catch {
        throw SimlessError("couldn't read project.yml with xcodegen (`brew install xcodegen`): \(error)")
    }
    guard let spec = try JSONSerialization.jsonObject(with: Data(dump.utf8)) as? [String: Any], let name = spec["name"] as? String else {
        throw SimlessError("xcodegen gave no project name for \(dir)/project.yml")
    }
    let targets = spec["targets"] as? [String: [String: Any]] ?? [:]
    func sources(_ t: [String: Any]) -> [String] {
        (t["sources"] as? [Any] ?? []).compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["path"] as? String) }
    }
    guard let (appTarget, app) = targets.sorted(by: { $0.key < $1.key })
            .first(where: { ($0.value["type"] as? String) == "application" && ($0.value["platform"] as? String ?? "iOS").hasPrefix("iOS") }) else {
        throw SimlessError("project.yml has no iOS application target")
    }
    let testTarget = targets.first { ($0.value["type"] as? String) == "bundle.unit-test" }?.key ?? ""
    let sourceDirs = sources(app)
    guard let sourceDir = sourceDirs.first else { throw SimlessError("\(appTarget) lists no sources in project.yml") }
    let kitDir = args.values["--kit-dir"] ?? "\(sourceDir)/Simless"
    let packages = (spec["packages"] as? [String: [String: Any]] ?? [:]).compactMap { $0.value["path"] as? String }.sorted()

    let configPath = "\(root)/\(Workspace.configName)"
    let keep = exists(configPath) && !args.flags.contains("--force")
    let config = Config(project: "\(name).xcodeproj", scheme: appTarget, appTarget: appTarget, testTarget: testTarget,
                        kitDir: kitDir, sourceDirs: sourceDirs, packages: packages.isEmpty ? nil : packages)
    if !keep {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: URL(fileURLWithPath: configPath))
    }
    try mkdirp("\(root)/\(kitDir)")
    try? FileManager.default.removeItem(atPath: "\(root)/\(config.kitFile)")
    try FileManager.default.copyItem(atPath: "\(Paths.toolRoot)/Templates/SimlessKit.swift", toPath: "\(root)/\(config.kitFile)")
    let newFixtures = !exists("\(root)/\(config.fixturesFile)")
    if newFixtures { try FileManager.default.copyItem(atPath: "\(Paths.toolRoot)/Templates/SimlessFixtures.swift", toPath: "\(root)/\(config.fixturesFile)") }

    let compiled = sourceDirs.contains { kitDir == $0 || kitDir.hasPrefix($0 + "/") }
    let appFile: String? = {
        guard let e = FileManager.default.enumerator(atPath: "\(root)/\(sourceDir)") else { return nil }
        while let rel = e.nextObject() as? String {
            guard rel.hasSuffix(".swift"), let text = try? String(contentsOfFile: "\(root)/\(sourceDir)/\(rel)", encoding: .utf8),
                  text.range(of: #"@main\s+struct\s+\w+\s*:\s*([\w.]+\s*,\s*)*App\b"#, options: .regularExpression) != nil else { continue }
            return "\(sourceDir)/\(rel)"
        }
        return nil
    }()
    let hooked = appFile.flatMap { try? String(contentsOfFile: "\(root)/\($0)", encoding: .utf8) }?.contains("SimlessHost.startIfRequested()") == true
    print("""
        \(keep ? "kept" : "wrote") \(Workspace.configName): project \(name).xcodeproj, app \(appTarget), tests \(testTarget.isEmpty ? "none" : testTarget)
        wrote \(config.kitFile)\(newFixtures ? " and \(config.fixturesFile)" : "")
        """)
    if compiled {
        print("project.yml: nothing to add, \(kitDir) is inside \(appTarget)'s sources (\(sourceDirs.joined(separator: ", ")))")
    } else {
        print("""
            project.yml: add the kit to \(appTarget)'s sources:

              targets:
                \(appTarget):
                  sources:
                    - path: \(kitDir)
            """)
    }
    if hooked {
        print("App hook: already in \(appFile!)")
    } else {
        print("""
            App hook: add this to the App's init()\(appFile.map { " in \($0)" } ?? ""), so the app answers simless:

                #if DEBUG && os(iOS)
                SimlessHost.startIfRequested()
                #endif
            """)
    }
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
    // A link, not a copy, so the skill keeps up with simless updates.
    try FileManager.default.createSymbolicLink(atPath: dst, withDestinationPath: "\(Paths.toolRoot)/Templates/SKILL.md")
    print("installed Claude Code skill: \(dst) (linked to \(Paths.toolRoot)/Templates/SKILL.md)")
}

/// A note when the installed skill is an older copy than this simless's.
func skillNote() -> String? {
    let dst = "\(Paths.home)/.claude/skills/simless/SKILL.md"
    guard (try? FileManager.default.destinationOfSymbolicLink(atPath: dst)) == nil,
          let installed = FileManager.default.contents(atPath: dst),
          let current = FileManager.default.contents(atPath: "\(Paths.toolRoot)/Templates/SKILL.md"),
          installed != current else { return nil }
    return "note: the Claude Code skill is from an older simless; `simless skill install` updates it"
}

func currentSlot(_ ws: Workspace) throws -> SlotRecord {
    let settings = try ws.settings()
    let state = GlobalState.load()
    guard let slot = state.slots.first(where: { $0.bundleBase == settings.bundleID && $0.worktree == ws.root && $0.kind == nil }) else {
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
    // What this build is built from, as of its start (recorded once it succeeds).
    let inputs = BuildState.current(ws, previous: BuildState.load(ws) ?? [:])
    try? FileManager.default.removeItem(atPath: BuildState.path(ws))
    // Local packages' tests: the scheme's build-for-testing usually builds them
    // with the app. Sources as of now, for marking those bundles current.
    let packages = Packages.testTargets(ws: ws)
    let packageSources = Dictionary(packages.map { ($0.package, Packages.newestSource($0.dir)) }, uniquingKeysWith: { a, _ in a })
    let packageBuild = DispatchGroup()
    defer { packageBuild.wait() }
    DispatchQueue.global().async(group: packageBuild) { RuntimeBuild.prebuild() }
    // Previews compile against this build: the last build's must not load meanwhile.
    try? FileManager.default.removeItem(atPath: Previews.dir(ws))
    do { try ws.build() } catch {
        // A failed build must not hide edits from the next `simless reload`.
        if let previousSnapshot { try? previousSnapshot.write(to: URL(fileURLWithPath: ws.snapshotPath)) }
        else { try? FileManager.default.removeItem(atPath: ws.snapshotPath) }
        throw error
    }
    BuildState.save(ws, inputs)
    // Package tests the app build made are current; the rest build now, in the
    // app's build folder, while the host starts.
    if !args.flags.contains("--no-tests") {
        for p in packages {
            let built = Packages.markBuilt(p, newest: packageSources[p.package] ?? 0, ws: ws)
            let missing = p.targets.filter { !built.contains($0) }
            if !missing.isEmpty {
                DispatchQueue.global().async(group: packageBuild) {
                    do { _ = try Packages.buildTests(p, targets: missing, ws: ws) }
                    catch { Log.info("note: building \(p.package)'s tests failed; `simless test` will say why") }
                }
            }
        }
    }
    // The render slot's record says what build is current before anything
    // else looks: the test slots prepared next compare themselves with it.
    let settings = try ws.settings()
    var slot = try GlobalState.slot(bundleBase: settings.bundleID, worktree: ws.root)
    // The fresh build contains every edit; earlier patches must not be re-applied.
    slot.builtAt = buildStart
    slot.patch = 0
    slot.lastPatch = nil
    slot.covered = nil
    slot.stale = nil
    try GlobalState.update(slot)
    // The test hosts get ready while the render host installs and starts.
    let testsReady = DispatchGroup()
    if !args.flags.contains("--no-tests") {
        DispatchQueue.global().async(group: testsReady) {
            packageBuild.wait()
            do { try TestEngine.prewarm(ws) } catch { Log.info("note: preparing test hosts failed (\(error)); `simless test` will retry") }
        }
    }
    defer { testsReady.wait() }
    // Fixtures from #Preview blocks and the App, compiled while the slot gets ready.
    let previewsBuilt = DispatchGroup()
    var previewsError: Error?
    if ws.config.previews != false {
        DispatchQueue.global().async(group: previewsBuilt) {
            do { try Previews.build(ws: ws, slot: slot, settings: settings) } catch { previewsError = error }
        }
    }
    let embedded = ws.config.embeddedBundles ?? true
    try Slots.prepare(slot, ws: ws, settings: settings, embedded: embedded)
    do {
        try Slots.install(slot, ws: ws)
    } catch where embedded {
        // An extension or watch app the slot can't sign for shouldn't block renders.
        Log.info("note: installing with app extensions and the watch app failed; retrying without them (\(error))")
        try Slots.prepare(slot, ws: ws, settings: settings, embedded: false)
        try Slots.install(slot, ws: ws)
    }
    try Slots.launch(slot, idleMinutes: ws.idleMinutes)
    previewsBuilt.wait()
    if let previewsError { Log.info("note: fixtures from #Preview blocks weren't built: \(previewsError)") }
    else { Previews.load(slot) }
    let stats = slot.stats() ?? [:]
    let fixtures = stats["fixtures"] as? [String] ?? []
    if let kit = stats["kit"] as? Int ?? (stats.isEmpty ? nil : 1), kit < requiredKit {
        Log.info("note: \(ws.config.kitFile) is from an older simless; run `simless init` to update it (keeps .simless.json and your fixtures). Until then, features that need the newer kit are off (see the changelog).")
    }
    print("ready in \(secs(t)): \(slot.slotID) on :\(slot.port), \(stats["footprintMB"] ?? "?") MB")
    print("fixtures (\(fixtures.count)): \(fixtures.isEmpty ? "none; register some in \(ws.config.fixturesFile)" : fixtures.joined(separator: ", "))")
    if let previews = Previews.summary(ws) { print(previews) }
    print("live reload: \(Agent.liveStatus(probeSlot: slot).map { "off (\($0)); reloads use warm mode" } ?? "on")\(Native.isNative(slot) ? " (native: unsigned, no agent needed)" : "")")
    if let note = skillNote() { print(note) }
    testsReady.wait()
    Cleanup.enforceDiskLimit(keeping: ws)
}

func cmdRender(_ args: Args) throws {
    let ws = try Workspace.load()
    guard let target = args.positional.first else { throw SimlessError("usage: simless render <fixture|all>") }
    let slot = try runningSlot(ws)
    try render(slot: slot, target: target, args: args, ws: ws)
}

/// SimlessKit version this simless needs for every feature (see `kitVersion` in the kit).
let requiredKit = 5
/// The kit each feature first needs (older kits keep working without it).
let localeKit = 3, settleKit = 4, actKit = 5

func render(slot: SlotRecord, target: String, args: Args, ws: Workspace) throws {
    if let size = args.values["--text-size"], !Render.textSizes.contains(size) {
        throw SimlessError("unknown text size '\(size)'; one of \(Render.textSizes.joined(separator: ", "))")
    }
    if let idiom = args.values["--idiom"] ?? ws.config.idiom, idiom != "phone", idiom != "pad" {
        throw SimlessError("unknown idiom '\(idiom)'; phone or pad")
    }
    // The language is process-wide: relaunch the host when it differs.
    let locale = args.values["--locale"]
    var stats = slot.stats() ?? [:]
    if stats["locale"] as? String != locale {
        if locale != nil, (stats["kit"] as? Int ?? 1) < localeKit {
            throw SimlessError("--locale needs a newer \(ws.config.kitFile); run `simless init`, then `simless up`")
        }
        if locale != nil || stats["locale"] != nil {
            Slots.stop(slot)
            try Slots.launch(slot, idleMinutes: ws.idleMinutes, locale: locale)
            stats = slot.stats() ?? [:]
        }
    }
    if (args.values["--settle"].flatMap(Double.init) ?? ws.config.settle ?? 0) > 0, (stats["kit"] as? Int ?? 1) < settleKit {
        throw SimlessError("--settle needs a newer \(ws.config.kitFile); run `simless init`, then `simless up`")
    }
    let fixtures = target == "all" ? (stats["fixtures"] as? [String] ?? []) : [target]
    if fixtures.isEmpty { throw SimlessError("no fixtures registered in \(ws.config.fixturesFile)") }
    let variants: [(dark: Bool, device: String)] = args.flags.contains("--matrix")
        ? [false, true].flatMap { d in ["iphone", "iphone-small", "ipad"].map { (d, $0) } }
        : [(args.flags.contains("--dark"), args.values["--device"] ?? ws.config.device)]
    var total = 0, count = 0
    var crashed: [(fixture: String, reason: String)] = []
    for fixture in fixtures {
        for v in variants {
            var options = Render.Options(dark: v.dark, device: v.device, json: args.flags.contains("--json"))
            options.textSize = args.values["--text-size"]
            options.settle = args.values["--settle"].flatMap(Double.init) ?? ws.config.settle
            options.idiom = ws.phoneIdiom(args.values["--idiom"])
            options.checks = ws.config.checks ?? .init()
            options.patch = slot.patch
            if var png = args.values["--png"] {
                while png.count > 1 && png.hasSuffix("/") { png.removeLast() }
                let isDir = fixtures.count > 1 || variants.count > 1 || args.values["--png"]!.hasSuffix("/")
                if isDir { try mkdirp(png) }
                options.pngPath = isDir ? "\(png)/\(fixture)\(v.dark ? "-dark" : "")-\(v.device).png" : png
            }
            var text = "", issues = 0
            var attempt = Date()
            do {
                (text, issues) = try Render.run(slot: slot, fixture: fixture, options: options)
            } catch let error as SimlessError where slot.stats() == nil {
                // The render took the host down. SwiftUI's Stepper does that on the
                // Mac, most often under the phone idiom: retry with the iPad idiom.
                let reason = CrashReport.summary(slot: slot, since: attempt) ?? error.description
                try Slots.launch(slot, idleMinutes: ws.idleMinutes, locale: locale)
                if options.idiom != nil {
                    Log.info("note: \(fixture) crashed the host under the phone idiom (\(reason)). Rendering it with the iPad idiom.")
                    options.idiom = nil
                    attempt = Date()
                    do {
                        (text, issues) = try Render.run(slot: slot, fixture: fixture, options: options)
                    } catch let error as SimlessError where slot.stats() == nil {
                        crashed.append((fixture, CrashReport.summary(slot: slot, since: attempt) ?? error.description))
                        try Slots.launch(slot, idleMinutes: ws.idleMinutes, locale: locale)
                    }
                } else {
                    crashed.append((fixture, reason))
                }
            }
            if let crash = crashed.last, crash.fixture == fixture {
                print("\(fixture) · \(v.dark ? "dark" : "light") · \(v.device)\n  ✗ crashed the render host: \(crash.reason)")
                count += 1
                continue
            }
            if slot.stale?.contains(fixture) == true, !options.json {
                text += "\n  note: stale: this screen reaches code edited since the last full build that the newest patch doesn't cover; `simless reload --render \(fixture)` patches it"
            }
            if !options.json, let blocked = RuntimeHost.newlyBlocked(slot) { text += "\n  " + blocked }
            print(text)
            total += issues
            count += 1
        }
    }
    if count > 1 { print("\(count) renders (\(fixtures.count) fixture(s) × \(variants.count) variant(s)), \(total) issue(s)\(crashed.isEmpty ? "" : ", \(crashed.count) crashed the host")") }
    if !crashed.isEmpty {
        throw SimlessError("\(Set(crashed.map(\.fixture)).sorted().joined(separator: ", ")) crashed the render host; the crash is in the view (or SwiftUI on the Mac), so check it in a simulator")
    }
}

func cmdReload(_ args: Args) throws {
    let ws = try Workspace.load()
    if args.flags.contains("--dry-run") { return try reloadDryRun(ws, args) }
    var slot = try runningSlot(ws)
    let t = now()
    if args.positional.isEmpty && !exists(ws.snapshotPath) {
        throw SimlessError("no source snapshot for this worktree yet; run `simless up` once")
    }
    let files = args.positional.isEmpty
        ? ws.changedSources()
        : args.positional.map { $0.hasPrefix("/") ? $0 : "\(FileManager.default.currentDirectoryPath)/\($0)" }
    let kit = "\(ws.root)/\(ws.config.kitFile)"
    if files.isEmpty && slot.patch > 0 {
        // The edits were undone: the host still runs the last patch, so start it
        // again from the build, which is what the sources say now.
        Slots.stop(slot)
        slot.patch = 0
        slot.lastPatch = nil
        slot.covered = nil
        slot.stale = nil
        try GlobalState.update(slot)
        try Slots.launch(slot, idleMinutes: ws.idleMinutes)
        print("edits since the last `simless up` were undone; the host shows that build again")
    } else if files.isEmpty {
        print("nothing edited since the last `simless up`")
    } else if files.contains(kit) {
        Log.step("SimlessKit changed; full rebuild")
        try cmdUp(args)
        slot = try currentSlot(ws)
    } else {
        // `--render X` only needs the views between X and the edit.
        let target = args.values["--render"]
        let fixtures = target.flatMap { $0 == "all" ? nil : [$0] }
        do {
            let r = try Patch.apply(ws: ws, slot: &slot, files: files, fixtures: fixtures)
            let names = r.files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            print(String(format: "reloaded (%@) in %.1fs: compile %.1fs + apply %.1fs; files edited since `simless up`: %@",
                         r.mode.rawValue, now() - t, r.compile, r.apply, names))
            if !r.extra.isEmpty {
                print("  also patched (they embed an edited view on the way to a fixture): "
                      + r.extra.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
            }
            if !r.stale.isEmpty {
                print("  stale until the next full build (they reach the edit through views this patch left out): "
                      + r.stale.joined(separator: ", "))
            }
        } catch let error as SimlessError where error.description.hasPrefix("patch compile failed")
                    || error.description.hasPrefix("patch can't cover") {
            print(error.description)
            if args.flags.contains("--no-fallback") { if args.flags.contains("--json") { throw error }; exit(1) }
            // Either a real compile error or an edit a patch can't express (stored
            // properties, signatures, new types used elsewhere): the full build decides.
            Log.step("falling back to a full rebuild")
            try cmdUp(args)
            slot = try currentSlot(ws)
        }
    }
    if let target = args.values["--render"] { try render(slot: slot, target: target, args: args, ws: ws) }
}

/// What `simless reload` would patch, without compiling or touching the host.
func reloadDryRun(_ ws: Workspace, _ args: Args) throws {
    let files = args.positional.isEmpty
        ? ws.changedSources()
        : args.positional.map { $0.hasPrefix("/") ? $0 : "\(FileManager.default.currentDirectoryPath)/\($0)" }
    if files.isEmpty { print("nothing edited since the last `simless up`"); return }
    let fixtures = args.values["--render"].flatMap { $0 == "all" ? nil : [$0] }
    let slot = try? currentSlot(ws)
    let t = now()
    let s = try slot.map { try Patch.scope(ws: ws, slot: $0, files: files, fixtures: fixtures) }
        ?? PatchScope.files(ws: ws, edited: files, fixtures: fixtures)
    print("would patch \(s.all.count) file(s) (scoped in \(secs(t))): " + s.all.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
    print("  covers: \(s.covered.isEmpty ? "none" : s.covered.joined(separator: ", "))")
    if !s.stale.isEmpty { print("  stale until the next full build: \(s.stale.joined(separator: ", "))") }
}

/// `simless status --json`, for a daemon that watches a build machine.
func statusJSON() throws {
    let state = GlobalState.load()
    var hosts: [[String: Any]] = []
    for s in state.slots.sorted(by: { $0.port < $1.port }) {
        var h: [String: Any] = ["slot": s.slotID, "port": s.port, "worktree": s.worktree,
                                "role": s.kind.map { $0.hasPrefix("test") ? "unit-tests" : "ui-tests" } ?? "renders"]
        if let use = RuntimeHost.usage(s) {
            h["state"] = "up"; h["memoryMB"] = (use.mb * 10).rounded() / 10; h["cpuPercent"] = (use.cpu * 10).rounded() / 10
            if s.kind == nil, let st = s.stats() { h["patch"] = s.patch; h["renders"] = st["renders"] ?? 0 }
        } else {
            h["state"] = "down"
        }
        hosts.append(h)
    }
    let runs = Budget.running().map { r -> [String: Any] in
        ["kind": r.kind == "ui" ? "ui-tests" : "unit-tests", "hosts": r.hosts, "seconds": Int(now() - r.started), "worktree": r.worktree]
    }
    let work = "\(Paths.cache)/work"
    let worktrees = ((try? FileManager.default.contentsOfDirectory(atPath: work)) ?? []).map { dir -> [String: Any] in
        let worktree = (try? String(contentsOfFile: "\(work)/\(dir)/worktree.txt", encoding: .utf8)) ?? dir
        return ["worktree": worktree, "gb": (Cleanup.sizeGB("\(work)/\(dir)") * 100).rounded() / 100]
    }
    let cas = Cleanup.sizeGB("\(Paths.cache)/CompilationCache"), slots = Cleanup.sizeGB(Paths.slots)
    let total = worktrees.reduce(0) { $0 + ($1["gb"] as? Double ?? 0) } + cas + slots
    let out: [String: Any] = [
        "simless": version, "hosts": hosts, "hostsUp": hosts.filter { $0["state"] as? String == "up" }.count, "testRuns": runs,
        "disk": ["path": Paths.cache, "totalGB": (total * 100).rounded() / 100, "limitGB": Cleanup.diskLimitGB(),
                 "compilationCacheGB": (cas * 100).rounded() / 100, "slotsGB": (slots * 100).rounded() / 100, "worktrees": worktrees],
    ]
    let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

/// Whether this Mac can run simless: for a build daemon to gate on.
func cmdDoctor(_ args: Args) throws {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    var arm = utsname()
    uname(&arm)
    let machine = withUnsafeBytes(of: &arm.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    let developerDir = (try? Shell.check(["/usr/bin/xcode-select", "-p"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    let xcodeLines = (try? Shell.run(["xcodebuild", "-version"]).out.split(separator: "\n").map(String.init)) ?? []
    let xcode = xcodeLines.first?.replacingOccurrences(of: "Xcode ", with: "")
    let xcodeBuild = xcodeLines.dropFirst().first?.replacingOccurrences(of: "Build version ", with: "")
    let sdk = (try? Shell.check(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
    let free = (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0
    let freeGB = (free / 1_073_741_824 * 10).rounded() / 10
    let checks: [(String, Bool, String)] = [
        ("Apple Silicon", machine.hasPrefix("arm64"), machine),
        ("macOS 15 or later", os.majorVersion >= 15, "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
        ("Xcode selected, not the Command Line Tools", developerDir.hasSuffix("/Contents/Developer"), developerDir),
        ("Xcode 26 or later", (xcode.flatMap { Int($0.split(separator: ".").first ?? "") } ?? 0) >= 26, xcode ?? "not found"),
        ("iOS SDK", sdk != nil, sdk ?? "not found"),
        ("10 GB free in the home folder's volume", freeGB >= 10, "\(freeGB) GB free"),
    ]
    let ok = checks.allSatisfy(\.1)
    if args.flags.contains("--json") {
        let out: [String: Any] = [
            "ok": ok, "simless": version, "macOS": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", "arch": machine,
            "xcode": xcode ?? NSNull(), "xcodeBuild": xcodeBuild ?? NSNull(), "developerDir": developerDir, "iosSDK": sdk ?? NSNull(),
            "freeGB": freeGB, "checks": checks.map { ["check": $0.0, "ok": $0.1, "found": $0.2] },
        ]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else {
        print("simless \(version)")
        for (check, passed, found) in checks { print("  \(passed ? "✓" : "✗") \(check): \(found)") }
        print(ok ? "this Mac can run simless" : "this Mac can't run simless yet; fix what's marked ✗")
    }
    if !ok { exit(1) }
}

func cmdTest(_ args: Args) throws { try TestEngine.run(args) }

func cmdStatus(_ args: Args) throws {
    if args.flags.contains("--json") { return try statusJSON() }
    let state = GlobalState.load()
    if state.slots.isEmpty { print("no hosts"); return }
    var totalMB = 0.0, running = 0
    for s in state.slots.sorted(by: { $0.port < $1.port }) {
        let role = s.kind.map { $0.hasPrefix("test") ? "unit tests" : "UI tests" } ?? "renders"
        if let use = RuntimeHost.usage(s) {
            totalMB += use.mb
            running += 1
            var line = "\(s.slotID)  :\(s.port)  up    \(role)  \(Int(use.mb)) MB  \(String(format: "%.0f", use.cpu))% CPU"
            if s.kind == nil, let st = s.stats() { line += "  patch \(st["patch"] ?? 0)  renders \(st["renders"] ?? 0)" }
            // What the app keeps in its data container (only test and UI hosts can say).
            if s.kind != nil, let c = try? LineClient(port: s.port, timeout: 2), let u = try? c.call(["cmd": "usage"]),
               let bytes = u["containerBytes"] as? Int {
                line += "  data \(bytes / 1_048_576) MB"
            }
            print(line + "  \(s.worktree)")
        } else {
            print("\(s.slotID)  :\(s.port)  down  \(role)  \(s.worktree)")
        }
    }
    print("\(running) host(s) running, \(Int(totalMB)) MB")
    // Test runs going on now, and the share of the Mac each gets.
    let runs = Budget.running()
    if !runs.isEmpty {
        let cores = ProcessInfo.processInfo.processorCount
        print("test runs: \(runs.count), each with about \(cores / runs.count) of \(cores) cores")
        for r in runs { print("  \(r.kind == "ui" ? "UI tests" : "unit tests")  \(r.hosts) host(s)  \(secs(r.started))  \(r.worktree)") }
    }
    // Disk, by what it's for and what frees it.
    func gb(_ path: String) -> Double {
        guard exists(path) else { return 0 }
        return ((try? Shell.run(["/usr/bin/du", "-sk", path]).out.split(separator: "\t").first).flatMap { Double($0) } ?? 0) / 1_048_576
    }
    let builds = ((try? FileManager.default.contentsOfDirectory(atPath: "\(Paths.cache)/work")) ?? []).map { dir -> (String, Double) in
        let worktree = (try? String(contentsOfFile: "\(Paths.cache)/work/\(dir)/worktree.txt", encoding: .utf8)) ?? dir
        return (worktree, gb("\(Paths.cache)/work/\(dir)"))
    }
    let cas = gb("\(Paths.cache)/CompilationCache"), slots = gb("\(Paths.cache)/slots")
    let total = builds.reduce(0) { $0 + $1.1 } + cas + slots
    print(String(format: "disk: %.1f GB in %@", total, Paths.cache))
    for (worktree, size) in builds.sorted(by: { $0.1 > $1.1 }) {
        print(String(format: "  %.1f GB  builds and results for %@ (`simless clean` there frees it)", size, worktree))
    }
    print(String(format: "  %.1f GB  shared compilation cache (makes builds in new worktrees fast; cleared above %.0f GB)", cas, Cleanup.compileCacheLimitGB))
    print(String(format: "  %.1f GB  installed slots, as du counts them (mostly APFS clones of the builds, so less on the disk)", slots))
    print("  `simless clean --all` frees everything")
    let probe = state.slots.first { $0.kind == nil && $0.stats() != nil }
    print("live reload: \(Agent.liveStatus(probeSlot: probe).map { "off (\($0))" } ?? "on")")
}

func cmdDown(_ args: Args) throws {
    var slots: [SlotRecord]
    let here = try? Workspace.load()
    if args.flags.contains("--all") {
        slots = GlobalState.load().slots
        // Another session's test run keeps its hosts: stopping them would fail its tests.
        let busy = Set(Budget.running().map(\.worktree))
        for worktree in busy.sorted() where worktree != here?.root {
            print("kept the hosts of \(worktree): a test run is going on there")
        }
        slots.removeAll { busy.contains($0.worktree) && $0.worktree != here?.root }
    } else {
        // This worktree's render host and its test and UI hosts.
        guard let here else { throw SimlessError("not in a simless worktree; `simless down --all` stops every worktree's hosts") }
        slots = GlobalState.load().slots.filter { $0.worktree == here.root }
    }
    // Only stops: the next render/reload relaunches in ~1 s. `simless clean` (or the
    // automatic cleanup when a worktree is deleted) removes slots and caches.
    let running = slots.filter { RuntimeHost.hasProcess($0) }
    if running.isEmpty { print("nothing was running"); return }
    // Say what goes, per worktree, before it goes.
    for (worktree, list) in Dictionary(grouping: running, by: \.worktree).sorted(by: { $0.key < $1.key }) {
        let mine = worktree == here?.root ? " (this worktree)" : ""
        print("stopping \(list.count) host(s) of \(worktree)\(mine): \(list.map(\.slotID).joined(separator: ", "))")
    }
    for s in running { Slots.stop(s) }
    print("stopped \(running.count) host(s); they start again on next use")
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
// `simless <command> --help` prints that command's part of the help and runs nothing.
if args.flags.contains("--help") || args.flags.contains("-h") {
    var lines: [Substring] = []
    var inCommand = false
    for line in usage.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("  simless ") { inCommand = line.hasPrefix("  simless \(command) ") || line == "  simless \(command)" }
        else if !line.hasPrefix("        ") { inCommand = false }
        if inCommand { lines.append(line) }
    }
    print(lines.isEmpty ? usage : lines.joined(separator: "\n"))
    exit(0)
}

do {
    if !["help", "-h", "--help", "init", "skill", "version", "--version"].contains(command) { Cleanup.collectGarbage() }
    switch command {
    case "init": try cmdInit(args)
    case "up": if args.flags.contains("--json") { JSONReport.up(args) } else { try cmdUp(args) }
    case "render": try cmdRender(args)
    case "reload": if args.flags.contains("--json") { JSONReport.reload(args) } else { try cmdReload(args) }
    case "act": try Act.run(args)
    case "test": try cmdTest(args)
    case "status": try cmdStatus(args)
    case "doctor": try cmdDoctor(args)
    case "down": try cmdDown(args)
    case "agent": try cmdAgent(args)
    case "clean": try Cleanup.clean(all: args.flags.contains("--all"))
    case "calibrate":
        let ws = try Workspace.load()
        try Calibrate.run(ws: ws, slot: try currentSlot(ws),
                          options: .init(only: args.positional.first, imagesDir: args.values["--png"],
                                         dark: args.flags.contains("--dark"),
                                         runtime: args.values["--runtime"] ?? ws.config.calibrate?.runtime,
                                         device: args.values["--sim-device"] ?? ws.config.calibrate?.device,
                                         idiom: ws.phoneIdiom(args.values["--idiom"])))
    case "skill": try cmdSkill(args)
    case "help", "-h", "--help": print(usage)
    case "version", "--version":
        let xcode = (try? Shell.run(["xcodebuild", "-version"]).out.split(separator: "\n").first.map(String.init)) ?? nil
        print("simless \(version) · \(xcode ?? "Xcode not found") · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    default: print(usage); exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
