// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// `simless test`: unit tests in a warm host, without xcodebuild.
///
/// The test slot (its own install of the app) is launched with SimlessRuntime,
/// which loads the test bundles into that one process and runs them: the app's
/// hosted test targets and every local package test target, together. A run
/// costs one app startup, and a host for the next run is started in the
/// background as soon as this one finishes, so it's usually already up.
///
/// A test that crashes the host or runs past the time limit doesn't end the
/// run: simless notes which test it was (with the crash's frames), starts a
/// fresh host, and runs only what didn't finish. Tests that were running when
/// the host went down are run again one at a time, so a crash is pinned on
/// the right test.
enum TestEngine {
    struct Target {
        let name: String        // target name, as in Target/Suite/test()
        let module: String      // Swift module name
        let bundle: String      // .xctest path to load
    }

    struct Selection {
        var include: [String]?  // nil: everything loaded
        var skip: [String]
    }

    struct Result {
        var passed: [String] = []
        var failed: [String: [String]] = [:]       // id -> issue lines
        var skipped: [String: String] = [:]        // id -> reason
        var crashes: [(id: String, reason: String)] = []
        var timedOut: [String] = []
        var slow: [String] = []                    // timed out under load, passed alone
        var seconds: [String: Double] = [:]
        /// Per target, when its first test started and its last one ended:
        /// its wall time, which is what spreading targets over hosts needs.
        var spans: [String: (start: Double, end: Double)] = [:]
    }

    // MARK: - Command

    /// Test hosts for a run of `targetCount` targets.
    static func defaultHosts(targetCount: Int, config: Config.Tests?, share: Double = 1, classes: Int = 0) -> Int {
        let cores = Double(ProcessInfo.processInfo.processorCount) * share
        if let hosts = config?.hosts { return hosts }
        if targetCount >= 4 { return max(1, min(4, Int(cores / 3))) }
        // A target with many classes runs on several hosts, split by class.
        return classes >= 8 ? max(1, min(6, Int(cores / 2))) : 1
    }

    /// After `simless up`: the package test bundles signed and the test hosts'
    /// slots installed, so the first `simless test all` only runs tests.
    static func prewarm(_ ws: Workspace) throws {
        let t = now()
        let settings = try ws.settings()
        var count = 0
        for p in Packages.testTargets(ws: ws) where !p.targets.isEmpty {
            let products = ws.productsIphoneos
            let bundles = p.targets.map { "\(products)/\($0).xctest" }.filter(exists)
            try prepareBundles(bundles, products: products, team: settings.team, native: ws.native)
            count += bundles.count
        }
        let appTargets = (try? appTestTargets(ws)) ?? []
        let hosts = defaultHosts(targetCount: count + appTargets.count, config: ws.config.tests)
        let errors = Locked<[Error]>([])
        DispatchQueue.concurrentPerform(iterations: hosts) { i in
            do { _ = try RuntimeHost.slot(kind: i == 0 ? "test" : "test\(i + 1)", ws: ws) }
            catch { errors.mutate { $0.append(error) } }
        }
        if let e = errors.value.first { throw e }
        Log.step("test hosts ready in \(secs(t)) (\(hosts) slot(s))")
    }

    /// `simless test`: unit tests, UI tests, or both when a selection names
    /// both. Exits non-zero unless everything selected ran and passed.
    static func run(_ given: Args) throws {
        let ws = try Workspace.load()
        if given.flags.contains("--simulator-only") { try printSimulatorOnly(ws); return }
        // The results files this run answers for: both until the selection is
        // known, then the unit or UI one, or both. They never keep an earlier
        // run's answer: they say ok: false while this run goes, and say why
        // when it stops early.
        var files = [unitResults, uiResults]
        do {
            try runParts(given, ws: ws) { files = $0 }
        } catch {
            for f in files { writeFailure(ws: ws, file: f, reason: "\(error)") }
            throw error
        }
    }

    /// Tests never run against a build older than the files on disk: the app
    /// and its hosted test targets come from the last full build, so when a
    /// file it was built from changed, `simless up` runs first. (A run of
    /// package test targets alone after package edits doesn't need it: those
    /// build from current sources every run.) If that build fails, nothing runs.
    static func ensureCurrentBuild(_ ws: Workspace, unitPart: [String]?, ui: Bool) throws {
        let changed = BuildState.changed(ws)
        if changed.isEmpty { return }
        let packageDirs = ws.packages.map { URL(fileURLWithPath: "\(ws.root)/\($0)").standardizedFileURL.path + "/" }
        let packageOnly = changed.allSatisfy { f in packageDirs.contains { f.hasPrefix($0) } }
        let packageTargets = Set(Packages.testTargets(ws: ws).flatMap(\.targets))
        let onlyPackageTests = !ui && (unitPart ?? []).count > 0
            && unitPart!.allSatisfy { packageTargets.contains(String($0.split(separator: "/").first ?? "")) }
        if packageOnly && onlyPackageTests { return }
        let shown = changed.prefix(3).map { $0.hasPrefix(ws.root + "/") ? String($0.dropFirst(ws.root.count + 1)) : $0 }
        Log.step("\(changed.count) file(s) changed since the last build (\(shown.joined(separator: ", "))\(changed.count > 3 ? ", ..." : "")): building again before testing")
        do {
            try cmdUp(Args([]))
        } catch {
            throw SimlessError("the tests can't run against the files on disk: building them failed, and the last build is older than your edits.\n\(error)")
        }
    }

    static let unitResults = "test-results.json"
    static let uiResults = "ui-test-results.json"

    /// A results file that says the run didn't get to an answer.
    static func writeFailure(ws: Workspace, file: String, reason: String) {
        let out: [String: Any] = ["ok": false, "error": reason, "selected": 0, "notRun": [String](), "flaky": [String](), "tests": [String: Any]()]
        try? mkdirp(ws.work)
        try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "\(ws.work)/\(file)"))
    }

    private static func runParts(_ given: Args, ws: Workspace, planned: ([String]) -> Void) throws {
        var args = given
        // Ids from a file (or stdin with "-"), one per line, as the results JSON writes them.
        if let from = args.values["--from"] {
            let text = from == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                : try String(contentsOfFile: from, encoding: .utf8)
            let ids = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
            if ids.isEmpty { throw SimlessError("--from \(from) has no test ids") }
            args.positional += ids
        }
        // UI tests: `simless test ui [selection]`, or UI test targets named.
        let uiTargets = UITestEngine.targets(ws, includingUnbuilt: true).map(\.name)
        let isUI = { (f: String) in uiTargets.contains(String(f.split(separator: "/").first ?? "")) }
        var positional = args.positional
        let uiOnly = positional.first == "ui"
        if uiOnly { positional.removeFirst() }
        let uiPart = uiOnly ? positional : positional.filter(isUI)
        let unitPart = uiOnly ? [] : positional.filter { !isUI($0) }
        if uiOnly, let wrong = uiPart.first(where: { !isUI($0) }) {
            throw SimlessError("\(wrong) isn't in a UI test target; UI test targets: \(uiTargets.joined(separator: ", "))")
        }
        let runsUnit = !uiOnly && (positional.isEmpty || !unitPart.isEmpty)
        let runsUI = uiOnly || !uiPart.isEmpty
        let files = (runsUnit ? [unitResults] : []) + (runsUI ? [uiResults] : [])
        planned(files)
        for f in files { writeFailure(ws: ws, file: f, reason: "running") }
        try ensureCurrentBuild(ws, unitPart: runsUnit ? unitPart : nil, ui: runsUI)
        var ok = true
        if runsUnit {
            var unitArgs = args
            unitArgs.positional = unitPart
            ok = try runUnit(unitArgs, ws: ws) && ok
        }
        if runsUI {
            ok = try UITestEngine.runDevices(args, ws: ws, filters: uiPart) && ok
        }
        if !ok { exit(1) }
    }

    static func runUnit(_ args: Args, ws: Workspace) throws -> Bool {
        let t = now()
        let config = ws.config.tests

        let timeoutArg = args.values["--timeout"]
        let timeout = timeoutArg.flatMap(Double.init) ?? config?.timeout ?? defaultTimeout(args)
        if (timeoutArg != nil && Double(timeoutArg!) == nil) || timeout <= 0 {
            throw SimlessError("--timeout takes seconds per test, e.g. --timeout 120")
        }

        // What to run.
        let packages = Packages.testTargets(ws: ws)
        let packageTargets = packages.flatMap(\.targets)
        // Schemes can list package test targets too; those come from the package build.
        let appTargets = try appTestTargets(ws).filter { !packageTargets.contains($0) }
        let all = args.positional == ["all"]
        let filters = all ? [] : args.positional.isEmpty ? [ws.config.testTarget] : args.positional
        let known = Set(appTargets + packageTargets)
        if known.isEmpty {
            throw SimlessError("\(ws.config.scheme) has no unit-test targets (and no local package has tests), so there's nothing to run")
        }
        for f in filters where !known.contains(String(f.split(separator: "/").first ?? "")) {
            throw SimlessError("unknown test target in \(f); targets: \((appTargets + packageTargets).sorted().joined(separator: ", "))")
        }
        let wanted = all ? Set(known) : Set(filters.map { String($0.split(separator: "/").first ?? "") })
        let simulatorOnly = config?.simulatorOnly ?? [:]
        let skips = (config?.skip ?? []) + (args.repeated["--skip"] ?? []) + simulatorOnly.keys.sorted()
        // The marked tests this run would have run.
        let markedHere = simulatorOnly.keys.filter { k in
            let target = String(k.split(separator: "/").first ?? "")
            return wanted.contains(target) && (filters.isEmpty || filters.contains { f in f == target || k == f || k.hasPrefix(f + "/") })
        }

        // Package tests are built for iOS devices from current sources.
        var targets: [Target] = []
        let settings = try ws.settings()
        for p in packages {
            let names = p.targets.filter(wanted.contains)
            if names.isEmpty { continue }
            let products = try Packages.buildTests(p, targets: names, ws: ws)
            let bundles = try prepareBundles(names.map { "\(products)/\($0).xctest" }, products: products, team: settings.team, native: ws.native)
            targets += zip(names, bundles).map { Target(name: $0, module: moduleName($0), bundle: $1) }
        }
        let firstSlot = try RuntimeHost.slot(kind: "test", ws: ws)
        let app = try RuntimeHost.appBundle(firstSlot)
        for name in appTargets where wanted.contains(name) {
            targets.append(Target(name: name, module: moduleName(name), bundle: "\(app)/PlugIns/\(name).xctest"))
        }

        // Several hosts, each a process of its own: tests on the main actor run
        // one at a time per process, so one host would queue them all behind
        // each other. Targets are spread by how long their tests took last time.
        // Test runs in other worktrees get their share of the cores too.
        let share = Budget.share(ws)
        let cores = max(2, Int(Double(ProcessInfo.processInfo.processorCount) * share))
        if share < 1 { Log.step("sharing the Mac with \(Int((1 / share).rounded()) - 1) other test run(s): using \(cores) of \(ProcessInfo.processInfo.processorCount) cores") }
        // A big target can be most of a run: its classes are split over hosts too.
        let splittable = shardableClasses(targets, ws: ws, whole: all || filters.allSatisfy { !$0.contains("/") })
        let wantedHosts = args.values["--hosts"].flatMap(Int.init)
            ?? defaultHosts(targetCount: targets.count, config: config, share: share, classes: splittable.values.map(\.count).max() ?? 0)
        let groups = partition(targets, into: max(1, min(wantedHosts, targets.count)), weights: lastTargetSeconds(ws))
        let shards = shard(groups, hosts: wantedHosts, classes: splittable, weights: lastTargetSeconds(ws))
        var slots = [firstSlot]
        for i in 1..<max(1, shards.count) { slots.append(try RuntimeHost.slot(kind: "test\(i + 1)", ws: ws)) }
        // The plan and why, every time: a run on fewer hosts than usual should say so.
        let why = args.values["--hosts"] != nil ? "--hosts" : config?.hosts != nil ? "tests.hosts"
            : shards.count > groups.count ? "a target split by class" : targets.count < 4 ? "fewer than 4 targets"
            : share < 1 ? "sharing the Mac" : "\(ProcessInfo.processInfo.processorCount) cores"
        Log.step("running on \(shards.count) host(s) (\(why)): " + shards.map { s in
            s.targets.map(\.name).joined(separator: ", ") + (s.classes.map { " (\($0.count) classes)" } ?? (s.skip.isEmpty ? "" : " (the rest)"))
        }.joined(separator: " | "))

        // Swift Testing would start every test at once; capping how many run
        // together keeps load down and, when a test takes the host down, the
        // list of suspects short.
        let width = args.values["--jobs"].flatMap(Int.init) ?? config?.jobs ?? max(4, cores / shards.count + 2)
        // App test targets load from each host's own copy of the app.
        let sessions = try shards.indices.map { i -> Session in
            let ownApp = try RuntimeHost.appBundle(slots[i])
            let own = shards[i].targets.map { t in t.bundle.hasPrefix(app + "/") ? Target(name: t.name, module: t.module, bundle: ownApp + t.bundle.dropFirst(app.count)) : t }
            return Session(ws: ws, slot: slots[i], targets: own, timeout: timeout, width: width)
        }
        let combined = Session(ws: ws, slot: firstSlot, targets: targets, timeout: timeout, width: width)
        Budget.start(ws, kind: "unit", hosts: sessions.count)
        defer { Budget.finish(ws) }
        let results = Locked<[TestEngine.Result]>([])
        let errors = Locked<[Error]>([])
        DispatchQueue.concurrentPerform(iterations: sessions.count) { i in
            let session = sessions[i]
            let names = Set(session.targets.map(\.name))
            let include: [String]? = shards[i].classes ?? (all ? nil : filters.filter { names.contains(String($0.split(separator: "/").first ?? "")) })
            do {
                let started = now()
                var result = try session.run(Selection(include: include, skip: skips + shards[i].skip))
                if sessions.count > 1 {
                    Log.step("host \(i + 1) (\(session.targets.count) targets) finished in \(secs(started))")
                }
                // Tests that ran out of time while the whole run was busy get one more
                // chance alone; passing then means load, not a broken test.
                // So do failures, when there are few: a timing-sensitive test can
                // lose a race only because the rest of the run keeps the CPU busy.
                var loadSuspects = Set(result.timedOut.filter { id in result.failed[id] != nil || result.crashes.contains(where: { $0.id == id }) })
                if result.failed.count <= 30 { loadSuspects.formUnion(result.failed.keys) }
                if !loadSuspects.isEmpty {
                    Log.step("running \(loadSuspects.count) failed test(s) again, one at a time, to rule out load")
                    let again = try session.run(Selection(include: loadSuspects.sorted().map { session.userID($0) }, skip: []), parallel: false)
                    for id in loadSuspects where again.passed.contains(id) {
                        result.failed.removeValue(forKey: id)
                        result.crashes.removeAll { $0.id == id }
                        result.passed.append(id)
                        result.slow.append(id)
                    }
                }
                session.standby()
                results.mutate { $0.append(result) }
            } catch {
                errors.mutate { $0.append(error) }
            }
        }
        if let first = errors.value.first { throw first }
        var result = TestEngine.Result()
        for r in results.value {
            result.passed += r.passed
            result.failed.merge(r.failed) { a, _ in a }
            result.skipped.merge(r.skipped) { a, _ in a }
            result.crashes += r.crashes
            result.timedOut += r.timedOut
            result.slow += r.slow
            result.seconds.merge(r.seconds) { a, _ in a }
            // A target split over hosts ran from its first shard's start to its last one's end.
            result.spans.merge(r.spans) { a, b in (min(a.start, b.start), max(a.end, b.end)) }
        }
        var seenKnown = Set<String>()
        combined.known = sessions.flatMap(\.known).filter { seenKnown.insert($0).inserted }
        let session = combined
        let slot = firstSlot

        // Report.
        for (id, reason) in result.crashes { print("  CRASHED: \(session.userID(id)): \(reason)") }
        for id in result.slow { print("  flaky: \(session.userID(id)) failed while the run was busy, and passed alone (load, or a flaky test)") }
        for id in output(skips: skips, result: result, session: session) { print("  note: --skip \(id) didn't match any test that ran") }
        // Marked tests, counted one by one (a mark can name a whole class).
        let knownHere = session.known.map(session.userID).filter { id in filters.isEmpty || filters.contains { matches(id, $0) || String(id.split(separator: "/").first ?? "") == $0 } }
        let markedTests = knownHere.isEmpty ? markedHere.count : knownHere.filter { id in simulatorOnly.keys.contains { matches(id, $0) } }.count
        let simOnly = result.skipped.filter { isSimulatorOnly($0.value) }.count + markedTests
        let plainSkipped = result.skipped.count - result.skipped.filter { isSimulatorOnly($0.value) }.count
        var parts = ["\(result.passed.count) passed", "\(result.failed.count) failed"]
        if plainSkipped > 0 { parts.append("\(plainSkipped) skipped") }
        if simOnly > 0 { parts.append("\(simOnly) simulator-only (`simless test --simulator-only` lists them)") }
        if !result.crashes.isEmpty { parts.append("\(result.crashes.count) crashed") }
        if !result.slow.isEmpty { parts.append("\(result.slow.count) flaky") }
        // The targets this run had to cover, from the scheme and the packages
        // rather than the build: a target that went missing from the build
        // must fail the run, not pass it with fewer tests.
        let expected = all ? expectedTargets(ws, packageTargets: packageTargets) : Array(wanted)
        let outcome = try saveResults(ws: ws, result: result, session: session, filters: filters, marks: simulatorOnly,
                                      excluded: (config?.skip ?? []) + (args.repeated["--skip"] ?? []), expectedTargets: expected,
                                      allowMissing: args.flags.contains("--allow-missing"))
        if !outcome.notRun.isEmpty { parts.append("\(outcome.notRun.count) didn't run") }
        print(parts.joined(separator: ", "))
        for id in outcome.notRun.prefix(20) { print("  NOT RUN: \(id)") }
        if outcome.notRun.count > 20 { print("  … and \(outcome.notRun.count - 20) more (test-results.json lists them)") }
        if outcome.selected == 0 { print("  NOTHING RAN: no test matched \(filters.isEmpty ? "the run" : filters.joined(separator: " "))") }
        let ok = result.failed.isEmpty && result.crashes.isEmpty && outcome.notRun.isEmpty && outcome.selected > 0
        if !ok, let note = SimulatorBranches.note(ws) { print("  \(note)") }
        print("\(ok ? "PASSED" : "FAILED") in \(secs(t)) (log: \(slot.dir)/host.log, results: \(ws.work)/test-results.json)")
        return ok
    }

    /// Skips the user named whose test ran anyway (exact ids, so a test with
    /// the same name in another suite doesn't count).
    private static func output(skips: [String], result: Result, session: Session) -> [String] {
        let ran = Set(result.passed + Array(result.failed.keys)).map { session.userID($0) }
        return skips.filter { skip in
            let s = skip.hasSuffix("()") ? String(skip.dropLast(2)) : skip
            return ran.contains { $0 == skip || $0 == s || $0.hasPrefix(s + "(") }
        }
    }

    /// How long each target's tests took in the last run (the sum of its tests' times).
    static func lastTargetSeconds(_ ws: Workspace) -> [String: Double] {
        // The history first: only full runs write it, while a run of a few
        // tests leaves test-results.json with times for a few targets.
        for path in [historyPath(ws), "\(ws.work)/test-results.json"] {
            if let d = FileManager.default.contents(atPath: path),
               let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let seconds = r["targetSeconds"] as? [String: Double], !seconds.isEmpty { return seconds }
        }
        return [:]
    }

    /// Target times kept per repository (by its origin, else its folder), outside
    /// the build cache: they survive `simless clean`, and a new worktree of the
    /// same repository spreads its first run well too.
    static func historyPath(_ ws: Workspace) -> String {
        let origin = (try? Shell.check(["git", "-C", ws.root, "remote", "get-url", "origin"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(Paths.support)/history/\(shortHash((origin.flatMap { $0.isEmpty ? nil : $0 } ?? ws.root) + "|" + ws.config.project)).json"
    }

    /// Seconds per test: 120 for an agent (`--agent` or SIMLESS_AGENT=1), which
    /// shouldn't wait out a hung test for 10 minutes, else 600 like Xcode.
    static func defaultTimeout(_ args: Args) -> Double {
        args.flags.contains("--agent") || ProcessInfo.processInfo.environment["SIMLESS_AGENT"] == "1" ? 120 : 600
    }

    /// One host's share of a run: its targets, and for a target split over
    /// hosts, its classes (or everything but the other hosts' classes).
    struct Shard {
        var targets: [Target]
        var classes: [String]?   // "Target/Class" ids this host runs
        var skip: [String] = []  // the classes other hosts run
    }

    /// Each target's test classes ("Target/Class"), for targets a run takes whole:
    /// from the last run's results, else from the sources.
    static func shardableClasses(_ targets: [Target], ws: Workspace, whole: Bool) -> [String: [String]] {
        guard whole else { return [:] }
        var out: [String: [String]] = [:]
        if let d = FileManager.default.contents(atPath: "\(ws.work)/test-results.json"),
           let tests = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["tests"] as? [String: Any] {
            for id in tests.keys {
                let parts = id.split(separator: "/")
                guard parts.count >= 3 else { continue }
                out[String(parts[0]), default: []].append("\(parts[0])/\(parts[1])")
            }
        }
        for t in targets where out[t.name] == nil {
            let dir = "\(ws.projectDir)/\(t.name)"
            guard let e = FileManager.default.enumerator(atPath: dir) else { continue }
            var classes = Set<String>()
            let decl = try! NSRegularExpression(
                pattern: #"^(?:@\w+(?:\([^)\n]*\))?\s+)*(?:(?:final|public|internal|private|fileprivate)\s+)*(?:class|struct|actor|enum)\s+(\w+)([^{\n]*)\{"#,
                options: .anchorsMatchLines)
            while let rel = e.nextObject() as? String {
                guard rel.hasSuffix(".swift"), let text = try? String(contentsOfFile: "\(dir)/\(rel)", encoding: .utf8) else { continue }
                let ns = text as NSString
                let found = decl.matches(in: text, range: NSRange(location: 0, length: ns.length))
                // A suite: an XCTestCase, or a type with @Test functions before the next top-level type.
                for (n, m) in found.enumerated() {
                    let end = n + 1 < found.count ? found[n + 1].range.location : ns.length
                    let body = ns.substring(with: NSRange(location: m.range.location, length: end - m.range.location))
                    if ns.substring(with: m.range(at: 2)).contains("XCTestCase") || body.range(of: #"(?m)^\s+@Test\b"#, options: .regularExpression) != nil {
                        classes.insert("\(t.name)/\(ns.substring(with: m.range(at: 1)))")
                    }
                }
            }
            out[t.name] = classes.sorted()
        }
        return out.mapValues { Array(Set($0)).sorted() }
    }

    /// Hosts beyond one per target go to the targets that take longest, split
    /// by class: the classes weighed by their tests' last times (or counted).
    /// The first host of a split target runs everything the others don't, so a
    /// class nobody listed (or a test outside a class) still runs.
    static func shard(_ groups: [[Target]], hosts: Int, classes: [String: [String]], weights: [String: Double]) -> [Shard] {
        var shards = groups.map { Shard(targets: $0) }
        var spare = hosts - shards.count
        while spare > 0 {
            // The heaviest group that's one target with classes to split.
            guard let i = shards.indices.filter({ shards[$0].targets.count == 1 && shards[$0].classes == nil && shards[$0].skip.isEmpty
                        && (classes[shards[$0].targets[0].name]?.count ?? 0) >= 4 })
                    .max(by: { (weights[shards[$0].targets[0].name] ?? 0) < (weights[shards[$1].targets[0].name] ?? 0) }) else { break }
            let t = shards[i].targets[0]
            let list = classes[t.name] ?? []
            let parts = min(spare + 1, list.count / 2)
            guard parts > 1 else { break }
            var buckets = Array(repeating: [String](), count: parts)
            for (n, c) in list.enumerated() { buckets[n % parts].append(c) }
            let others = buckets.dropFirst().flatMap { $0 }
            shards[i] = Shard(targets: [t], classes: nil, skip: others)
            for b in buckets.dropFirst() { shards.append(Shard(targets: [t], classes: b)) }
            spare -= parts - 1
        }
        return shards
    }

    /// Targets spread over `count` groups, the longest first onto the lightest group.
    static func partition(_ targets: [Target], into count: Int, weights: [String: Double]) -> [[Target]] {
        guard count > 1 else { return [targets] }
        let known = weights.values.sorted()
        let typical = known.isEmpty ? 1 : known[known.count / 2]
        let sorted = targets.sorted { (weights[$0.name] ?? typical, $1.name) > (weights[$1.name] ?? typical, $0.name) }
        // A target that takes half again as long as any other sets the run's
        // length on its own: it gets a host to itself, so nothing else
        // competes with it for that host's cores.
        if count >= 3, sorted.count > count, let first = sorted.first, let w0 = weights[first.name],
           let w1 = weights[sorted[1].name], w0 >= 1.5 * w1 {
            return [[first]] + partition(Array(sorted.dropFirst()), into: count - 1, weights: weights)
        }
        var groups = Array(repeating: [Target](), count: count)
        var load = Array(repeating: 0.0, count: count)
        for t in sorted {
            let i = load.indices.min { load[$0] < load[$1] }!
            groups[i].append(t)
            load[i] += weights[t.name] ?? typical
        }
        return groups.filter { !$0.isEmpty }
    }

    // MARK: - Targets

    static func moduleName(_ target: String) -> String { target.replacingOccurrences(of: "-", with: "_") }

    /// The app's hosted unit-test targets, from the build's .xctestrun (UI test
    /// bundles excluded).
    static func appTestTargets(_ ws: Workspace) throws -> [String] {
        // A scheme without tests builds no .xctestrun: the app has no test targets.
        if ws.appXCTestRun == nil, ws.config.testTarget.isEmpty, exists(ws.settingsPath) { return [] }
        guard let file = ws.appXCTestRun,
              let data = FileManager.default.contents(atPath: file),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SimlessError("not built yet; run `simless up`")
        }
        var targets: [[String: Any]] = []
        if let configs = plist["TestConfigurations"] as? [[String: Any]] {
            targets = configs.flatMap { $0["TestTargets"] as? [[String: Any]] ?? [] }
        } else {
            targets = plist.filter { !$0.key.hasPrefix("__") }.compactMap { $0.value as? [String: Any] }
        }
        // Only bundles the build actually put in the app.
        let app = try? ws.settings().wrapperName
        return Array(Set(targets.filter { $0["IsUITestBundle"] as? Bool != true && $0["TestHostPath"] != nil }
            .compactMap { $0["BlueprintName"] as? String }
            .filter { name in app.map { exists("\(ws.productsIphoneos)/\($0)/PlugIns/\(name).xctest") } ?? true })).sorted()
    }

    /// Package test bundles are built unsigned: sign them so the host can load
    /// them, and put the package's resource bundles inside each, where
    /// `Bundle.module` looks. That happens to a clone next to Xcode's bundle
    /// (`<Name>.simless.xctest`, so relative load paths resolve the same): a
    /// bundle changed in place made the next build link all of them again, and
    /// sign them all again after it. Returns the bundles to load.
    @discardableResult
    static func prepareBundles(_ bundles: [String], products: String, team: String, native: Bool) throws -> [String] {
        let fm = FileManager.default
        let identity = native ? "-" : try Signing.identity(team: team).0
        let resources = ((try? fm.contentsOfDirectory(atPath: products)) ?? []).filter { $0.hasSuffix(".bundle") }
        let stampName = ".simless-\(native ? "native" : "signed")"
        // Skip what hasn't changed since it was prepared: the bundle's files and
        // the resource bundles copied into it.
        let resourcesChanged = resources.map { newestChange("\(products)/\($0)") }.max() ?? 0
        let stale = bundles.filter { bundle in
            let stamp = "\(prepared(bundle))/\(stampName)"
            return !(exists(stamp) && mtime(stamp) >= max(newestChange(bundle), resourcesChanged))
        }
        guard !stale.isEmpty else { return bundles.map(prepared) }
        let t = now()
        // Signing hashes every file, so bundles are signed side by side.
        let errors = Locked<[Error]>([])
        DispatchQueue.concurrentPerform(iterations: stale.count) { i in
            let bundle = stale[i], copy = prepared(stale[i])
            do {
                try? fm.removeItem(atPath: copy)
                try cloneWritable(bundle, to: copy, what: "clone \((bundle as NSString).lastPathComponent)")
                for r in resources {
                    try? fm.removeItem(atPath: "\(copy)/\(r)")
                    try Shell.check(["/bin/cp", "-c", "-R", "\(products)/\(r)", "\(copy)/\(r)"], what: "copy \(r)")
                }
                if native { try Native.adopt([copy]) } else { try Signing.sign(copy, identity: identity) }
                fm.createFile(atPath: "\(copy)/\(stampName)", contents: nil)
            } catch {
                errors.mutate { $0.append(error) }
            }
        }
        if let first = errors.value.first { throw first }
        Log.step("signed \(stale.count) test bundle(s) in \(secs(t))")
        return bundles.map(prepared)
    }

    /// simless's copy of a test bundle Xcode built.
    static func prepared(_ bundle: String) -> String { (bundle as NSString).deletingPathExtension + ".simless.xctest" }

    /// The newest modification of a file or anything in a folder.
    static func newestChange(_ path: String) -> Double {
        var newest = mtime(path)
        let url = URL(fileURLWithPath: path)
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) else { return newest }
        for case let f as URL in files {
            let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            newest = max(newest, d)
        }
        return newest
    }

    // MARK: - Simulator-only

    static func isSimulatorOnly(_ reason: String) -> Bool {
        reason.lowercased().hasPrefix("simulator only") || reason.lowercased().hasPrefix("simulator-only")
    }

    static func printSimulatorOnly(_ ws: Workspace) throws {
        var list = ws.config.tests?.simulatorOnly ?? [:]
        if let d = FileManager.default.contents(atPath: "\(ws.work)/test-results.json"),
           let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let skipped = r["simulatorOnly"] as? [String: String] {
            for (k, v) in skipped where list[k] == nil { list[k] = v }
        }
        if list.isEmpty { print("no simulator-only tests (mark them in .simless.json tests.simulatorOnly, or skip them with a reason starting \"simulator only\")"); return }
        print("\(list.count) test(s) or group(s) to run on a simulator:")
        for (id, reason) in list.sorted(by: { $0.key < $1.key }) { print("  \(id)\(reason.isEmpty ? "" : "  (\(reason))")") }
        // One command per scheme and platform: each target runs with the scheme
        // that tests it, on a simulator of its platform.
        let schemes = SimulatorLane.schemes(ws)
        var groups: [String: (scheme: String, platform: String, ids: [String])] = [:]
        var orphans: [String] = []
        for id in list.keys.sorted() {
            let target = String(id.split(separator: "/").first ?? "")
            guard let scheme = schemes[target] else { orphans.append(id); continue }
            let platform = SimulatorLane.platform(target, ws: ws)
            groups["\(scheme)|\(platform)", default: (scheme, platform, [])].ids.append(id)
        }
        var missing = false
        for g in groups.values.sorted(by: { $0.scheme < $1.scheme }) {
            switch SimulatorLane.destination(g.platform, ws: ws) {
            case .ready(let destination):
                print("\nxcodebuild test -project \(ws.config.project) -scheme \(g.scheme) \\\n  -destination '\(destination)' \\")
                print(g.ids.map { "  -only-testing:'\($0)'" }.joined(separator: " \\\n"))
            case .missing(let why):
                missing = true
                print("\nMISSING for -scheme \(g.scheme) (\(g.ids.count) test(s) or group(s)): \(why)")
            }
        }
        if !orphans.isEmpty {
            missing = true
            print("\nMISSING: no shared scheme tests \(orphans.joined(separator: ", ")). Share a scheme with its test target in Xcode to get a command")
        }
        if missing { exit(1) }
    }

    /// Whether a user id falls under a mark (a test, or a target, class or suite prefix).
    static func matches(_ id: String, _ mark: String) -> Bool {
        id == mark || id.hasPrefix(mark + "/") || id == mark + "()" || (mark.hasSuffix("()") && id == String(mark.dropLast(2)))
    }

    /// The unit-test targets `test all` must run: the app scheme's iOS ones
    /// (test plans included) and every local package's.
    static func expectedTargets(_ ws: Workspace, packageTargets: [String]) -> [String] {
        let pbx = (try? String(contentsOfFile: "\(ws.root)/\(ws.config.project)/project.pbxproj", encoding: .utf8)) ?? ""
        let ui = UITestEngine.uiTestTargets(pbx: pbx)
        // Only targets that exist: a scheme can still list one that was removed.
        let projectTargets = Set(pbx.matches(of: #/\/\* ([^*]+) \*\/ = \{\s*isa = PBXNativeTarget;/#).map { String($0.1) })
        let scheme = SimulatorLane.schemes(ws).filter { $0.value == ws.config.scheme }.keys
            .filter { projectTargets.contains($0) && !ui.contains($0) && SimulatorLane.platform($0, ws: ws) == "iOS" }
        return Array(Set(scheme).union(packageTargets)).sorted()
    }

    /// What a merge check needs beyond pass and fail.
    struct Outcome { var selected = 0; var notRun: [String] = []; var flaky: [String] = [] }

    /// Writes test-results.json. `excluded`: --skip and tests.skip patterns,
    /// which aren't expected to run.
    @discardableResult
    static func saveResults(ws: Workspace, result: Result, session: Session, filters: [String] = [], marks: [String: String] = [:],
                            excluded: [String] = [], expectedTargets: [String] = [], allowMissing: Bool = false) throws -> Outcome {
        var simulatorOnly: [String: String] = [:]
        for (id, reason) in result.skipped where isSimulatorOnly(reason) { simulatorOnly[session.userID(id)] = reason }
        // Every test, with what happened to it.
        var tests: [String: [String: Any]] = [:]
        let selected = session.known.map(session.userID).filter { id in
            filters.isEmpty || filters.contains(where: { matches(id, $0) || String(id.split(separator: "/").first ?? "") == $0 })
        }
        for id in selected {
            if let mark = marks.first(where: { matches(id, $0.key) }) {
                simulatorOnly[id] = mark.value
                tests[id] = ["status": "simulator-only", "reason": mark.value]
            } else if excluded.contains(where: { matches(id, $0) }) {
                tests[id] = ["status": "excluded", "reason": "--skip or tests.skip"]
            }
        }
        // Passed only when run again alone: flaky, not plain green.
        for id in result.passed {
            tests[session.userID(id)] = result.slow.contains(id)
                ? ["status": "flaky", "reason": "failed in the full run, passed when run again alone"] : ["status": "passed"]
        }
        for (id, lines) in result.failed { tests[session.userID(id)] = ["status": "failed", "issues": lines] }
        for (id, reason) in result.skipped {
            tests[session.userID(id)] = ["status": isSimulatorOnly(reason) ? "simulator-only" : "skipped", "reason": reason]
        }
        for c in result.crashes { tests[session.userID(c.id)] = ["status": "crashed", "reason": c.reason] }
        for (id, seconds) in result.seconds { tests[session.userID(id)]?["seconds"] = (seconds * 1000).rounded() / 1000 }
        // Selected and expected, but nothing came back: the run didn't cover it.
        var outcome = Outcome(selected: selected.count)
        for id in selected where tests[id] == nil {
            tests[id] = ["status": "not-run", "reason": "selected, but it never ran"]
            outcome.notRun.append(id)
        }
        // A target with no test in the run at all (its bundle never loaded, or
        // the build left it out) is one not-run entry for the whole target.
        for target in expectedTargets where !selected.contains(where: { $0.hasPrefix(target + "/") })
            && !marks.keys.contains(where: { matches(target, $0) }) && !excluded.contains(where: { matches(target, $0) }) {
            tests[target] = ["status": "not-run", "reason": "no test from this target ran (its bundle didn't load, or the build left it out)"]
            outcome.notRun.append(target)
        }
        // An id asked for that matches no test (renamed, deleted, mistyped) is
        // not run either: a list of tests mustn't shrink without anyone noticing.
        if !allowMissing {
            let all = session.known.map(session.userID)
            for f in filters where !all.contains(where: { matches($0, f) || String($0.split(separator: "/").first ?? "") == f })
                && !marks.keys.contains(where: { matches(f, $0) || matches($0, f) }) {
                tests[f] = ["status": "not-run", "reason": "matches no test"]
                outcome.notRun.append(f)
            }
        }
        outcome.notRun.sort()
        outcome.flaky = result.slow.map(session.userID).sorted()
        let ok = result.failed.isEmpty && result.crashes.isEmpty && outcome.notRun.isEmpty && !selected.isEmpty
        let out: [String: Any] = [
            "ok": ok,
            "selected": selected.count,
            "notRun": outcome.notRun,
            "flaky": outcome.flaky,
            "passed": result.passed.count,
            "passedTests": result.passed.map { session.userID($0) }.sorted(),
            "failed": Dictionary(uniqueKeysWithValues: result.failed.map { (session.userID($0.key), $0.value) }),
            "crashed": result.crashes.map { ["test": session.userID($0.id), "reason": $0.reason] },
            "skipped": Dictionary(uniqueKeysWithValues: result.skipped.map { (session.userID($0.key), $0.value) }),
            "simulatorOnly": simulatorOnly,
            "tests": tests,
            "slowest": result.seconds.sorted { $0.value > $1.value }.prefix(20).map { ["test": session.userID($0.key), "seconds": $0.value] },
            // Wall time per target. Tests run side by side, so their sum says little.
            "targetSeconds": result.spans.mapValues { (($0.end - $0.start) * 10).rounded() / 10 },
        ]
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "\(ws.work)/test-results.json"))
        // A full run's target times, for the next run's spread (even after a clean).
        if filters.isEmpty, !result.spans.isEmpty {
            let history = historyPath(ws)
            try? mkdirp((history as NSString).deletingLastPathComponent)
            try? JSONSerialization.data(withJSONObject: ["targetSeconds": out["targetSeconds"] ?? [:]])
                .write(to: URL(fileURLWithPath: history))
        }
        return outcome
    }
}

// MARK: - Session

/// One `simless test` run against the test slot's warm host.
final class Session {
    let ws: Workspace
    let slot: SlotRecord
    let targets: [TestEngine.Target]
    let timeout: Double
    let width: Int?
    /// Every test in this session's bundles (runtime ids), from its first load.
    var known: [String] = []

    init(ws: Workspace, slot: SlotRecord, targets: [TestEngine.Target], timeout: Double, width: Int?) {
        self.ws = ws
        self.slot = slot
        self.targets = targets
        self.timeout = timeout
        self.width = width
    }

    /// "Module.Suite/test()" -> "Target/Suite/test()".
    func userID(_ id: String) -> String {
        for t in targets where id.hasPrefix(t.module + ".") { return t.name + "/" + id.dropFirst(t.module.count + 1) }
        return id
    }

    /// "Target/Suite/test()" -> runtime id prefix "Module.Suite/test()".
    func runtimeID(_ user: String) -> String {
        let parts = user.split(separator: "/", maxSplits: 1).map(String.init)
        guard let t = targets.first(where: { $0.name == parts[0] }) else { return user }
        return parts.count == 1 ? t.module : "\(t.module).\(parts[1])"
    }

    /// Swift Testing filters are regular expressions over test ids.
    /// Loose for what users type (with or without "()"), exact for ids that
    /// came from a run.
    private func regex(_ runtimeID: String, exact: Bool = false) -> String {
        if exact { return "^\(NSRegularExpression.escapedPattern(for: runtimeID))(/|$)" }
        let base = runtimeID.hasSuffix("()") ? String(runtimeID.dropLast(2)) : runtimeID
        let escaped = NSRegularExpression.escapedPattern(for: base)
        return runtimeID.contains("/") ? "^\(escaped)(\\(|/|$)" : "^\(escaped)(\\.|/|$)"
    }

    /// XCTest ids have no parentheses.
    private func xctestID(_ runtimeID: String) -> String {
        runtimeID.hasSuffix("()") ? String(runtimeID.dropLast(2)) : runtimeID
    }

    // MARK: Host

    private func environment() -> [String: String] {
        var env = RuntimeBuild.testFrameworkEnv
        var dirs = [ws.root, ws.work]
        for p in ws.packages {
            let dir = URL(fileURLWithPath: "\(ws.root)/\(p)").standardizedFileURL.path
            if !dir.hasPrefix(URL(fileURLWithPath: ws.root).standardizedFileURL.path + "/") { dirs.append(dir) }
        }
        // A native host isn't sandboxed: it reads them as they are.
        if !Native.isNative(slot) { env["SIMLESS_SANDBOX_TOKENS"] = dirs.compactMap(Sandbox.readToken).joined(separator: "\n") }
        env["SIMLESS_IDLE"] = String(ws.idleMinutes * 60)
        // Windows tests make get the device's size and safe areas.
        if let c = try? Render.canvas(ws.config.device) { env["SIMLESS_UNIT_CANVAS"] = "\(c.width),\(c.height),\(c.safeTop),\(c.safeBottom)" }
        // What earlier runs' tests left in tmp goes when the host starts.
        env["SIMLESS_CLEAN_TMP"] = "1"
        return env
    }

    /// A fresh host: the standby one if it's up and untouched, else a new launch.
    /// Every run starts from a fresh install's data, like a simulator's clone:
    /// files, preferences and caches earlier runs saved would make results
    /// depend on how often the tests ran before.
    private func wipe() {
        if Native.isNative(slot) { return Native.wipe(slot) }
        guard let app = try? RuntimeHost.installedApp(slot) else { return }
        Cleanup.wipeContainer(app: app, runtime: "\(slot.dir)/SimlessRuntime.dylib")
    }

    private func freshHost() throws -> LineClient {
        // Only a standby host this simless started (its token matches) and that hasn't run anything.
        // The token file also names the runtime build the standby host loaded: a
        // newer simless means a fresh host.
        let saved = (try? String(contentsOfFile: "\(slot.dir)/standby-token", encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        let token = saved.first
        let sameRuntime = saved.count > 1 && saved[1] == String(mtime("\(slot.dir)/SimlessRuntime.dylib"))
        if sameRuntime, let c = try? LineClient(port: slot.port, timeout: 2), let h = try? c.call(["cmd": "hello"]),
           (h["loaded"] as? [String] ?? []).isEmpty, let token, h["token"] as? String == token {
            // The standby host's output becomes this run's log.
            try? FileManager.default.removeItem(atPath: "\(slot.dir)/host.log")
            try? FileManager.default.moveItem(atPath: "\(slot.dir)/standby.log", toPath: "\(slot.dir)/host.log")
            return c
        }
        let t = now()
        RuntimeHost.terminateAll(slot)
        wipe()
        do {
            try RuntimeHost.launch(slot, env: environment())
        } catch let error as SimlessError where error.description.contains("cannot be opened") {
            // LaunchServices occasionally loses an installed copy; installing it again fixes that.
            Log.info("note: \(slot.slotID) wouldn't open (\(error)); installing it again")
            try Slots.install(slot, ws: ws)
            try RuntimeHost.launch(slot, env: environment())
        }
        Log.debug("test host up in \(secs(t))")
        return try LineClient(port: slot.port, timeout: 30)
    }

    /// Leaves a fresh host starting in the background for the next run.
    func standby() {
        RuntimeHost.terminateAll(slot)
        wipe()
        let token = UUID().uuidString
        try? "\(token)\n\(mtime("\(slot.dir)/SimlessRuntime.dylib"))".write(toFile: "\(slot.dir)/standby-token", atomically: true, encoding: .utf8)
        let env = RuntimeHost.baseEnvironment(slot).merging(environment()) { $1 }
            .merging(["SIMLESS_RUNTIME_PORT": String(slot.port), "SIMLESS_HOST_TOKEN": token,
                      // A standby host runs the app's idle work (animations, timers) for
                      // nothing; it goes away after 10 minutes without a run.
                      "SIMLESS_IDLE": String(ws.standbyIdleMinutes * 60)]) { $1 }
        guard let app = try? RuntimeHost.installedApp(slot) else { return }
        if Native.isNative(slot) {
            _ = try? Native.launch(slot, env: env, args: [], log: "\(slot.dir)/standby.log")
            return
        }
        var cmd = ["/usr/bin/open", "-g", "-j", "--stderr", "\(slot.dir)/standby.log", "--stdout", "\(slot.dir)/standby.log"]
        for (k, v) in env.sorted(by: { $0.key < $1.key }) { cmd += ["--env", "\(k)=\(v)"] }
        try? FileManager.default.removeItem(atPath: "\(slot.dir)/standby.log")
        _ = try? Shell.run(cmd + [app])
    }

    // MARK: Running

    /// Runs the selection to the end, across host crashes and timeouts.
    ///
    /// When a host goes down with several tests running, the one on the crash's
    /// stack is blamed if there is one. The others (or all of them, if the stack
    /// names none) run again after the main run, together in a fresh host, and
    /// a group that brings its host down again is split in half until the crash
    /// lands on one test.
    func run(_ selection: TestEngine.Selection, parallel: Bool = true) throws -> TestEngine.Result {
        var result = TestEngine.Result()
        var done = Set<String>()           // finished, crashed or timed out: never run again
        var groups: [[String]] = []        // cut short by a crash or timeout: run again later
        var include = selection.include
        var inGroup = !parallel            // running one of those groups (or everything one at a time)
        var restarts = 0
        while true {
            let outcome = try runOnce(include: include, skip: selection.skip, exact: Array(done) + groups.flatMap { $0 },
                                      parallel: parallel, result: &result)
            done.formUnion(outcome.finished)
            switch outcome.end {
            case .completed:
                guard !groups.isEmpty else { return result }
                let next = groups.removeFirst()
                include = next.map { userID($0) }
                inGroup = true
                continue
            case .hostDied(let running, let reason):
                let open = running.filter { !done.contains($0) }
                if open.count == 1 || (!parallel && !open.isEmpty) {
                    result.crashes.append((open[0], reason))
                    done.insert(open[0])
                } else if let culprit = Self.onStack(open, CrashReport.lastSymbols) {
                    result.crashes.append((culprit, reason))
                    done.insert(culprit)
                    groups.append(open.filter { $0 != culprit })
                } else if open.isEmpty {
                    result.crashes.append(("(between tests)", reason))
                } else if inGroup {
                    let half = open.count / 2
                    groups.insert(Array(open[half...]), at: 0)
                    groups.insert(Array(open[..<half]), at: 0)
                } else {
                    Log.info("  … the host went down with \(open.count) tests running (\(reason)); running those again after the others, to find which one it was")
                    groups.append(open)
                }
            case .timedOut(let id, let others):
                result.crashes.append((id, "ran past the \(Int(timeout)) s time limit (--timeout), so its host was stopped"))
                result.timedOut.append(id)
                done.insert(id)
                let rest = others.filter { !done.contains($0) }
                if !rest.isEmpty { groups.append(rest) }
            }
            restarts += 1
            if restarts > 60 { throw SimlessError("gave up after 60 host restarts; see \(slot.dir)/host.log") }
            // The same selection again: what finished or waits in a group is left out.
        }
    }

    /// The test-bundle frames the runtime's crash handler printed for the host
    /// that just went down, demangled.
    static func testFramesFromLog(_ slot: SlotRecord) -> [String] {
        let log = (try? String(contentsOfFile: "\(slot.dir)/host.log", encoding: .utf8)) ?? ""
        let mangled = log.split(separator: "\n").filter { $0.hasPrefix("simless-test-frame: ") }.map { String($0.dropFirst("simless-test-frame: ".count)) }
        guard !mangled.isEmpty else { return [] }
        return CrashReport.demangle(mangled)
    }

    /// The running test whose function is on the crashed thread's stack, if exactly one is.
    static func onStack(_ running: [String], _ symbols: [String]) -> String? {
        guard !symbols.isEmpty else { return nil }
        let hits = running.filter { id in
            let parts = id.split(separator: "/").map(String.init)
            guard let method = parts.last?.split(separator: "(").first.map(String.init), !method.isEmpty else { return false }
            let suite = parts.count >= 2 ? (parts[parts.count - 2].split(separator: ".").last.map(String.init) ?? "") : ""
            return symbols.contains { $0.contains("\(suite).\(method)(") || (suite.isEmpty && $0.contains("\(method)(")) }
        }
        return hits.count == 1 ? hits[0] : nil
    }

    enum End {
        case completed
        case hostDied(running: [String], reason: String)
        case timedOut(String, others: [String])
    }

    /// `skip`: user ids (loose match). `exact`: runtime ids already handled.
    private func runOnce(include: [String]?, skip: [String], exact: [String], parallel: Bool,
                         result: inout TestEngine.Result) throws -> (end: End, finished: Set<String>) {
        let since = Date()
        var bundles = targets.map(\.bundle)
        if let include {
            let names = Set(include.map { String($0.split(separator: "/").first ?? "") })
            bundles = targets.filter { names.contains($0.name) }.map(\.bundle)
        }
        // Loading runs every bundle's initializers, which takes a while on a
        // busy Mac. A host that doesn't answer gets one more try, fresh.
        var load: [String: Any] = [:]
        for attempt in 1...2 {
            do {
                let client = try freshHost()
                client.setTimeout(300)
                load = try client.call(["cmd": "load", "bundles": bundles])
                // Every test the bundles hold, once, so results can name the ones
                // that didn't run (simulator-only marks name suites too).
                if known.isEmpty, let list = try? client.call(["cmd": "list"]) {
                    known = (list["swift"] as? [String] ?? []) + (list["xctest"] as? [String] ?? [])
                }
                break
            } catch where attempt == 1 {
                RuntimeHost.terminateAll(slot)
            }
        }
        if let errors = load["errors"] as? [String], !errors.isEmpty {
            throw SimlessError("could not load test bundles:\n  " + errors.joined(separator: "\n  "))
        }
        let inc = include?.map(runtimeID)
        let skp = skip.map(runtimeID)
        var xctest: [String: Any] = ["exclude": skp.map(xctestID) + exact.map(xctestID)]
        if let inc { xctest["include"] = inc.map(xctestID) }
        var request: [String: Any] = ["cmd": "run", "parallel": parallel, "xctest": xctest,
                                      "swift": ["filter": inc.map { $0.map { regex($0) } } ?? [],
                                                "skip": skp.map { regex($0) } + exact.map { regex($0, exact: true) }]]
        if let width { request["width"] = width }
        // Short reads so the watchdog runs between events.
        let stream = try LineClient(port: slot.port, timeout: 0.5)
        try stream.send(request)
        var running: [String: Double] = [:]
        var finished = Set<String>()
        while true {
            switch stream.next() {
            case .line(let e):
                guard let event = e["event"] as? String else { continue }
                let id = e["id"] as? String ?? ""
                switch event {
                case "started":
                    running[id] = now()
                    let target = String(userID(id).split(separator: "/").first ?? "")
                    if result.spans[target] == nil { result.spans[target] = (now(), now()) }
                case "issue":
                    guard e["failure"] as? Bool == true else { break }
                    let line = "\(e["location"] as? String ?? ""): \(e["message"] as? String ?? "")"
                    result.failed[id, default: []].append(line)
                    print("  \(userID(id)): \(line)")
                    fflush(stdout)
                    if (e["message"] as? String ?? "").contains("Time limit was exceeded") { result.timedOut.append(id) }
                case "ended":
                    running.removeValue(forKey: id)
                    let target = String(userID(id).split(separator: "/").first ?? "")
                    if let span = result.spans[target] { result.spans[target] = (span.start, max(span.end, now())) }
                    finished.insert(id)
                    result.seconds[id] = e["seconds"] as? Double
                    switch e["result"] as? String {
                    case "passed": result.passed.append(id); result.failed.removeValue(forKey: id)
                    case "skipped": result.skipped[id] = e["reason"] as? String ?? ""
                    default: if result.failed[id] == nil { result.failed[id] = ["failed"] }
                    }
                case "error":
                    Log.info("  \(e["message"] as? String ?? "")")
                case "done":
                    return (.completed, finished)
                default:
                    break
                }
            case .timeout:
                break
            case .closed:
                let reason = CrashReport.summary(slot: slot, since: since) ?? "the host exited"
                CrashReport.lastSymbols += Self.testFramesFromLog(slot)
                RuntimeHost.terminateAll(slot)
                return (.hostDied(running: running.sorted { $0.value > $1.value }.map(\.key), reason: reason), finished)
            }
            if let (id, start) = running.min(by: { $0.value < $1.value }), now() - start > timeout {
                RuntimeHost.terminateAll(slot)
                return (.timedOut(id, others: running.keys.filter { $0 != id }), finished)
            }
            Progress.shared.update(self, passed: result.passed.count, failed: result.failed.count, running: running.count)
        }
    }
}

/// One progress line every 10 s for all hosts of a run together.
final class Progress: @unchecked Sendable {
    static let shared = Progress()
    private let lock = NSLock()
    private var counts: [ObjectIdentifier: (passed: Int, failed: Int, running: Int)] = [:]
    private var last = now()

    func update(_ session: Session, passed: Int, failed: Int, running: Int) {
        lock.lock(); defer { lock.unlock() }
        counts[ObjectIdentifier(session)] = (passed, failed, running)
        guard now() - last >= 10 else { return }
        last = now()
        let total = counts.values.reduce((0, 0, 0)) { ($0.0 + $1.passed, $0.1 + $1.failed, $0.2 + $1.running) }
        Log.info("  … \(total.0) passed, \(total.1) failed, \(total.2) running")
    }
}
