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
    }

    // MARK: - Command

    /// Test hosts for a run of `targetCount` targets.
    static func defaultHosts(targetCount: Int, config: Config.Tests?) -> Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return config?.hosts ?? (targetCount >= 4 ? max(2, min(4, cores / 3)) : 1)
    }

    /// Builds every local package's tests, for `simless up` to run next to
    /// the app's build. Failures only leave a note: `simless test` reports them.
    static func buildPackageTests(_ ws: Workspace) {
        for p in Packages.testTargets(ws: ws) where !p.targets.isEmpty {
            do { _ = try Packages.buildTests(p, targets: p.targets, ws: ws) }
            catch { Log.info("note: building \(p.package)'s tests failed; `simless test` will say why") }
        }
    }

    /// After `simless up`: the package test bundles signed and the test hosts'
    /// slots installed, so the first `simless test all` only runs tests.
    static func prewarm(_ ws: Workspace) throws {
        let t = now()
        let settings = try ws.settings()
        var count = 0
        for p in Packages.testTargets(ws: ws) where !p.targets.isEmpty {
            let products = "\(ws.work)/PackageTests/\(p.package)/Build/Products/Debug-iphoneos"
            let bundles = p.targets.map { "\(products)/\($0).xctest" }.filter(exists)
            try prepareBundles(bundles, products: products, team: settings.team)
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

    static func run(_ args: Args) throws {
        let ws = try Workspace.load()
        let t = now()
        let config = ws.config.tests
        if args.flags.contains("--simulator-only") { try printSimulatorOnly(ws); return }

        let timeoutArg = args.values["--timeout"]
        let timeout = timeoutArg.flatMap(Double.init) ?? config?.timeout ?? 600
        if (timeoutArg != nil && Double(timeoutArg!) == nil) || timeout <= 0 {
            throw SimlessError("--timeout takes seconds per test, e.g. --timeout 120")
        }
        let edited = ws.changedSources()
        if !edited.isEmpty { Log.info("note: \(edited.count) file(s) edited since `simless up`; app tests run the last full build (package tests are rebuilt)") }

        // UI tests: `simless test ui`, or a UI test target named.
        let uiTargets = UITestEngine.targets(ws).map(\.name)
        if args.positional == ["ui"] { return try UITestEngine.run(args, ws: ws, filters: []) }
        if !args.positional.isEmpty, args.positional.allSatisfy({ uiTargets.contains(String($0.split(separator: "/").first ?? "")) }) {
            return try UITestEngine.run(args, ws: ws, filters: args.positional)
        }

        // What to run.
        let packages = Packages.testTargets(ws: ws)
        let packageTargets = packages.flatMap(\.targets)
        // Schemes can list package test targets too; those come from the package build.
        let appTargets = try appTestTargets(ws).filter { !packageTargets.contains($0) }
        let all = args.positional == ["all"]
        let filters = all ? [] : args.positional.isEmpty ? [ws.config.testTarget] : args.positional
        let known = Set(appTargets + packageTargets)
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
            try prepareBundles(names.map { "\(products)/\($0).xctest" }, products: products, team: settings.team)
            targets += names.map { Target(name: $0, module: moduleName($0), bundle: "\(products)/\($0).xctest") }
        }
        let firstSlot = try RuntimeHost.slot(kind: "test", ws: ws)
        let app = try RuntimeHost.appBundle(firstSlot)
        for name in appTargets where wanted.contains(name) {
            targets.append(Target(name: name, module: moduleName(name), bundle: "\(app)/PlugIns/\(name).xctest"))
        }

        // Several hosts, each a process of its own: tests on the main actor run
        // one at a time per process, so one host would queue them all behind
        // each other. Targets are spread by how long their tests took last time.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let wantedHosts = args.values["--hosts"].flatMap(Int.init) ?? defaultHosts(targetCount: targets.count, config: config)
        let groups = partition(targets, into: max(1, min(wantedHosts, targets.count)), weights: lastTargetSeconds(ws))
        var slots = [firstSlot]
        for i in 1..<max(1, groups.count) { slots.append(try RuntimeHost.slot(kind: "test\(i + 1)", ws: ws)) }
        if groups.count > 1 { Log.step("running on \(groups.count) hosts: " + groups.map { $0.map(\.name).joined(separator: ", ") }.joined(separator: " | ")) }

        // Swift Testing would start every test at once; capping how many run
        // together keeps load down and, when a test takes the host down, the
        // list of suspects short.
        let width = args.values["--jobs"].flatMap(Int.init) ?? config?.jobs ?? max(4, cores / groups.count + 2)
        // App test targets load from each host's own copy of the app.
        let sessions = try groups.indices.map { i -> Session in
            let ownApp = try RuntimeHost.appBundle(slots[i])
            let own = groups[i].map { t in t.bundle.hasPrefix(app + "/") ? Target(name: t.name, module: t.module, bundle: ownApp + t.bundle.dropFirst(app.count)) : t }
            return Session(ws: ws, slot: slots[i], targets: own, timeout: timeout, width: width)
        }
        let combined = Session(ws: ws, slot: firstSlot, targets: targets, timeout: timeout, width: width)
        let results = Locked<[TestEngine.Result]>([])
        let errors = Locked<[Error]>([])
        DispatchQueue.concurrentPerform(iterations: sessions.count) { i in
            let session = sessions[i]
            let names = Set(session.targets.map(\.name))
            let include: [String]? = all ? nil : filters.filter { names.contains(String($0.split(separator: "/").first ?? "")) }
            do {
                let started = now()
                var result = try session.run(Selection(include: include, skip: skips))
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
        }
        combined.known = sessions.flatMap(\.known)
        let session = combined
        let slot = firstSlot

        // Report.
        for (id, reason) in result.crashes { print("  CRASHED: \(session.userID(id)): \(reason)") }
        for id in result.slow { print("  note: \(session.userID(id)) failed while the run was busy, and passed alone (load, not a failure)") }
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
        print(parts.joined(separator: ", "))
        try saveResults(ws: ws, result: result, session: session, filters: filters, marks: simulatorOnly)
        let ok = result.failed.isEmpty && result.crashes.isEmpty
        if !ok, let note = SimulatorBranches.note(ws) { print("  \(note)") }
        print("\(ok ? "PASSED" : "FAILED") in \(secs(t)) (log: \(slot.dir)/host.log, results: \(ws.work)/test-results.json)")
        if !ok { exit(1) }
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
        guard let d = FileManager.default.contents(atPath: "\(ws.work)/test-results.json"),
              let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return r["targetSeconds"] as? [String: Double] ?? [:]
    }

    /// Targets spread over `count` groups, the longest first onto the lightest group.
    static func partition(_ targets: [Target], into count: Int, weights: [String: Double]) -> [[Target]] {
        guard count > 1 else { return [targets] }
        let known = weights.values.sorted()
        let typical = known.isEmpty ? 1 : known[known.count / 2]
        var groups = Array(repeating: [Target](), count: count)
        var load = Array(repeating: 0.0, count: count)
        for t in targets.sorted(by: { (weights[$0.name] ?? typical, $1.name) > (weights[$1.name] ?? typical, $0.name) }) {
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
        guard let file = (try? FileManager.default.contentsOfDirectory(atPath: ws.products))?.first(where: { $0.hasSuffix(".xctestrun") }),
              let data = FileManager.default.contents(atPath: "\(ws.products)/\(file)"),
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
    /// `Bundle.module` looks.
    static func prepareBundles(_ bundles: [String], products: String, team: String) throws {
        let fm = FileManager.default
        let identity = try Signing.identity(team: team).0
        let resources = ((try? fm.contentsOfDirectory(atPath: products)) ?? []).filter { $0.hasSuffix(".bundle") }
        // Skip what hasn't changed since its last signature.
        let stale = bundles.filter { bundle in
            let exe = "\(bundle)/\(((bundle as NSString).lastPathComponent as NSString).deletingPathExtension)"
            let stamp = "\(bundle)/.simless-signed"
            return !(exists(stamp) && mtime(stamp) >= mtime(exe))
        }
        guard !stale.isEmpty else { return }
        let t = now()
        // Signing hashes every file, so bundles are signed side by side.
        let errors = Locked<[Error]>([])
        DispatchQueue.concurrentPerform(iterations: stale.count) { i in
            let bundle = stale[i]
            do {
                for r in resources {
                    try? FileManager.default.removeItem(atPath: "\(bundle)/\(r)")
                    try Shell.check(["/bin/cp", "-c", "-R", "\(products)/\(r)", "\(bundle)/\(r)"], what: "copy \(r)")
                }
                try Signing.sign(bundle, identity: identity)
                FileManager.default.createFile(atPath: "\(bundle)/.simless-signed", contents: nil)
            } catch {
                errors.mutate { $0.append(error) }
            }
        }
        if let first = errors.value.first { throw first }
        Log.step("signed \(stale.count) test bundle(s) in \(secs(t))")
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
        for g in groups.values.sorted(by: { $0.scheme < $1.scheme }) {
            print("\nxcodebuild test -project \(ws.config.project) -scheme \(g.scheme) \\\n  -destination '\(SimulatorLane.destination(g.platform, ws: ws))' \\")
            print(g.ids.map { "  -only-testing:'\($0)'" }.joined(separator: " \\\n"))
        }
        if !orphans.isEmpty {
            print("\nno shared scheme tests \(orphans.joined(separator: ", ")); share a scheme with its test target in Xcode to get a command")
        }
    }

    /// Whether a user id falls under a mark (a test, or a target, class or suite prefix).
    static func matches(_ id: String, _ mark: String) -> Bool {
        id == mark || id.hasPrefix(mark + "/") || id == mark + "()" || (mark.hasSuffix("()") && id == String(mark.dropLast(2)))
    }

    static func saveResults(ws: Workspace, result: Result, session: Session, filters: [String] = [], marks: [String: String] = [:]) throws {
        var simulatorOnly: [String: String] = [:]
        for (id, reason) in result.skipped where isSimulatorOnly(reason) { simulatorOnly[session.userID(id)] = reason }
        // Every test, with what happened to it.
        var tests: [String: [String: Any]] = [:]
        for id in session.known.map(session.userID) where filters.isEmpty || filters.contains(where: { matches(id, $0) || String(id.split(separator: "/").first ?? "") == $0 }) {
            if let mark = marks.first(where: { matches(id, $0.key) }) {
                simulatorOnly[id] = mark.value
                tests[id] = ["status": "simulator-only", "reason": mark.value]
            }
        }
        for id in result.passed { tests[session.userID(id)] = ["status": result.slow.contains(id) ? "load" : "passed"] }
        for (id, lines) in result.failed { tests[session.userID(id)] = ["status": "failed", "issues": lines] }
        for (id, reason) in result.skipped {
            tests[session.userID(id)] = ["status": isSimulatorOnly(reason) ? "simulator-only" : "skipped", "reason": reason]
        }
        for c in result.crashes { tests[session.userID(c.id)] = ["status": "crashed", "reason": c.reason] }
        for (id, seconds) in result.seconds { tests[session.userID(id)]?["seconds"] = (seconds * 1000).rounded() / 1000 }
        let out: [String: Any] = [
            "passed": result.passed.count,
            "passedTests": result.passed.map { session.userID($0) }.sorted(),
            "failed": Dictionary(uniqueKeysWithValues: result.failed.map { (session.userID($0.key), $0.value) }),
            "crashed": result.crashes.map { ["test": session.userID($0.id), "reason": $0.reason] },
            "skipped": Dictionary(uniqueKeysWithValues: result.skipped.map { (session.userID($0.key), $0.value) }),
            "simulatorOnly": simulatorOnly,
            "tests": tests,
            "slowest": result.seconds.sorted { $0.value > $1.value }.prefix(20).map { ["test": session.userID($0.key), "seconds": $0.value] },
            "targetSeconds": result.seconds.reduce(into: [String: Double]()) { acc, e in
                acc[String(session.userID(e.key).split(separator: "/").first ?? ""), default: 0] += e.value
            },
        ]
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "\(ws.work)/test-results.json"))
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
        env["SIMLESS_SANDBOX_TOKENS"] = dirs.compactMap(Sandbox.readToken).joined(separator: "\n")
        env["SIMLESS_IDLE"] = String(ws.idleMinutes * 60)
        // What earlier runs' tests left in tmp goes when the host starts.
        env["SIMLESS_CLEAN_TMP"] = "1"
        return env
    }

    /// A fresh host: the standby one if it's up and untouched, else a new launch.
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
        let token = UUID().uuidString
        try? "\(token)\n\(mtime("\(slot.dir)/SimlessRuntime.dylib"))".write(toFile: "\(slot.dir)/standby-token", atomically: true, encoding: .utf8)
        let env = RuntimeHost.baseEnvironment(slot).merging(environment()) { $1 }
            .merging(["SIMLESS_RUNTIME_PORT": String(slot.port), "SIMLESS_HOST_TOKEN": token,
                      // A standby host runs the app's idle work (animations, timers) for
                      // nothing; it goes away after 10 minutes without a run.
                      "SIMLESS_IDLE": String(min(ws.idleMinutes, 10) * 60)]) { $1 }
        guard let app = try? RuntimeHost.installedApp(slot) else { return }
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
                case "issue":
                    guard e["failure"] as? Bool == true else { break }
                    let line = "\(e["location"] as? String ?? ""): \(e["message"] as? String ?? "")"
                    result.failed[id, default: []].append(line)
                    print("  \(userID(id)): \(line)")
                    fflush(stdout)
                    if (e["message"] as? String ?? "").contains("Time limit was exceeded") { result.timedOut.append(id) }
                case "ended":
                    running.removeValue(forKey: id)
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
