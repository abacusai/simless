// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import AppKit

/// UI tests without a simulator.
///
/// The UI test target's sources are compiled unchanged for macOS together with
/// simless's XCUITest API (Templates/XCUI), whose XCUIApplication, XCUIElement
/// and queries shadow XCTest's. The tests run in `xctest` on the Mac and drive
/// headless hosts of the app through SimlessRuntime: queries read the app's
/// accessibility tree, taps and gestures are real touches in its process.
/// Several hosts run side by side (UI slots "ui1"...), each its own installed
/// copy of the app, so test classes run in parallel without simulator clones.
enum UITestEngine {
    struct UITarget {
        let name: String
        let sources: [String]
        /// In the scheme's build. A UI test target that isn't (a watch app's,
        /// say) can't run here, but its tests are still listed.
        var built = true
    }

    struct TestID: Hashable {
        let target: String, cls: String, method: String
        var user: String { "\(target)/\(cls)/\(method)" }
        var xctest: String { "\(TestEngine.moduleName(target)).\(cls)/\(method)" }
    }

    // MARK: - Targets

    /// UI test targets in the build (the .xctestrun's UI test bundles), with
    /// their sources (synchronized folders, or a folder named like the target).
    static func targets(_ ws: Workspace, includingUnbuilt: Bool = false) -> [UITarget] {
        var names = Set<String>()
        if let file = ws.appXCTestRun(ui: true) {
            names = Set(Workspace.testTargets(inXCTestRun: file)
                .filter { $0["IsUITestBundle"] as? Bool == true }.compactMap { $0["BlueprintName"] as? String })
        }
        let pbx = (try? String(contentsOfFile: "\(ws.root)/\(ws.config.project)/project.pbxproj", encoding: .utf8)) ?? ""
        let unbuilt = includingUnbuilt ? uiTestTargets(pbx: pbx).subtracting(names) : []
        return (names.union(unbuilt)).sorted().compactMap { name in
            let dirs = PBX.synchronizedFolders(target: name, pbx: pbx).map { "\(ws.projectDir)/\($0)" }
                + (ws.config.tests?.uiSources?[name].map { ["\(ws.root)/\($0)"] } ?? [])
            let folders = dirs.isEmpty ? ["\(ws.projectDir)/\(name)"].filter { exists($0) } : dirs
            let sources = folders.flatMap { dir -> [String] in
                guard let e = FileManager.default.enumerator(atPath: dir) else { return [] }
                return e.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.map { "\(dir)/\($0)" }
            }.sorted()
            return sources.isEmpty ? nil : UITarget(name: name, sources: sources, built: !unbuilt.contains(name))
        }
    }

    /// Every UI test target in the project, built or not.
    static func uiTestTargets(pbx: String) -> Set<String> {
        var out = Set<String>()
        for block in pbx.components(separatedBy: "isa = PBXNativeTarget;").dropFirst() {
            let body = block.components(separatedBy: "\n\t\t};").first ?? ""
            guard body.contains("com.apple.product-type.bundle.ui-testing"),
                  let name = body.firstMatch(of: #/\n\t\t\tname = "?([^";]+)"?;/#) else { continue }
            out.insert(String(name.1))
        }
        return out
    }

    /// Test methods per class, from the sources (XCTestCase subclasses).
    static func tests(in target: UITarget) -> [TestID] {
        var out: [TestID] = []
        for file in target.sources {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            var cls: String?
            // Only what an iPhone simulator run would compile (see PlatformConditions).
            for line in PlatformConditions.activeLines(text) {
                if let m = line.firstMatch(of: #/^(?:final\s+)?(?:@\w+\s+)*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b/#) { cls = String(m.1) }
                else if line.firstMatch(of: #/^(?:final\s+)?(?:public\s+)?(?:struct|class|enum|extension)\s/#) != nil { cls = nil }
                if let c = cls, let m = line.firstMatch(of: #/^\s+(?:@\w+\s+)*func\s+(test\w*)\s*\(\s*\)/#) {
                    out.append(TestID(target: target.name, cls: c, method: String(m.1)))
                }
            }
        }
        return out
    }

    // MARK: - Build

    /// The UI test target compiled for macOS with simless's XCUITest API.
    static func build(_ target: UITarget, ws: Workspace) throws -> String {
        let dir = "\(ws.work)/UITests"
        let bundle = "\(dir)/\(target.name).xctest"
        let exe = "\(bundle)/Contents/MacOS/\(target.name)"
        let shim = ((try? FileManager.default.contentsOfDirectory(atPath: "\(Paths.toolRoot)/Templates/XCUI")) ?? [])
            .filter { $0.hasSuffix(".swift") }.map { "\(Paths.toolRoot)/Templates/XCUI/\($0)" }
        // Built from exactly these files with exactly this content (a deleted
        // file or one put back to an older version counts too), by this simless.
        let key = shortHash(((target.sources + shim).sorted().map { "\($0) \(Workspace.digest($0) ?? "")" }
                             + ["\(mtime(Bundle.main.executablePath ?? ""))"]).joined(separator: "\n"))
        let keyFile = "\(bundle)/Contents/simless-sources"
        if exists(exe), (try? String(contentsOfFile: keyFile, encoding: .utf8)) == key { return bundle }
        try? FileManager.default.removeItem(atPath: keyFile)
        let t = now()
        let p = "\(RuntimeBuild.developerDir)/Platforms/MacOSX.platform/Developer"
        let sdk = try Shell.check(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try mkdirp("\(bundle)/Contents/MacOS")
        let settings = try ws.settings()
        let log = "\(dir)/build-\(target.name).log"
        // Sources with platform conditions are compiled from a rewritten copy that
        // keeps the original's file name and line numbers.
        let rewritten = "\(dir)/sources-\(target.name)"
        try? FileManager.default.removeItem(atPath: rewritten)
        try mkdirp(rewritten)
        var sources: [String] = []
        for (i, file) in target.sources.enumerated() {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8), PlatformConditions.needsRewrite(text) else {
                sources.append(file); continue
            }
            let copy = "\(rewritten)/\(i)-\((file as NSString).lastPathComponent)"
            try ("#sourceLocation(file: \"\(file)\", line: 1)\n" + PlatformConditions.rewrite(text))
                .write(toFile: copy, atomically: true, encoding: .utf8)
            sources.append(copy)
        }
        let r = try Shell.run(["xcrun", "swiftc", "-D", PlatformConditions.trueFlag, "-emit-library", "-Onone", "-g", "-module-name", TestEngine.moduleName(target.name),
                               "-target", "arm64-apple-macos14.0", "-sdk", sdk, "-swift-version", settings.swiftVersion,
                               "-F", "\(p)/Library/Frameworks", "-I", "\(p)/usr/lib", "-L", "\(p)/usr/lib",
                               "-framework", "XCTest", "-Xlinker", "-bundle",
                               "-Xlinker", "-rpath", "-Xlinker", "\(p)/Library/Frameworks",
                               "-Xlinker", "-rpath", "-Xlinker", "\(p)/usr/lib",
                               "-o", exe] + sources + shim, cwd: ws.root, logPath: log)
        guard r.code == 0 else {
            throw SimlessError("building \(target.name) for simless failed (log: \(log)):\n" + Patch.compilerErrors(r.out))
        }
        let info: [String: Any] = ["CFBundleExecutable": target.name, "CFBundleIdentifier": "simless.uitests.\(target.name)",
                                   "CFBundlePackageType": "BNDL", "CFBundleName": target.name,
                                   "NSPrincipalClass": "SimlessXCUIObserver"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: "\(bundle)/Contents/Info.plist"))
        try key.write(toFile: keyFile, atomically: true, encoding: .utf8)
        Log.step("built \(target.name) for the Mac in \(secs(t))")
        return bundle
    }

    // MARK: - Run

    /// UI tests on every device asked for, one after another, with one
    /// results file for all. `--device iphone,ipad` runs everything on each;
    /// tests.uiDevices adds devices that run only the tests listed for them.
    static func runDevices(_ args: Args, ws: Workspace, filters: [String]) throws -> Bool {
        var plan: [(device: String, filters: [String])] = []
        if let asked = args.values["--device"] {
            plan = asked.split(separator: ",").map { (String($0), filters) }
        } else {
            plan = [(ws.config.device, filters)]
            for (device, ids) in (ws.config.tests?.uiDevices ?? [:]).sorted(by: { $0.key < $1.key }) where device != ws.config.device {
                // The device's own tests, narrowed to what this run selected.
                let wanted = ids.isEmpty ? filters : filters.isEmpty ? ids
                    : ids.filter { id in filters.contains { f in TestEngine.matches(id, f) || TestEngine.matches(f, id) } }
                        + filters.filter { f in ids.contains { TestEngine.matches(f, $0) } }
                if ids.isEmpty || !wanted.isEmpty { plan.append((device, Array(Set(wanted)).sorted())) }
            }
        }
        guard plan.count > 1 else { return try run(args, ws: ws, filters: plan.first?.filters ?? filters) }
        let path = "\(ws.work)/ui-test-results.json"
        var ok = true
        var perDevice: [String: [String: Any]] = [:]
        for (device, selection) in plan {
            var one = args
            one.values["--device"] = device
            print("\n== UI tests on \(device)\(selection.isEmpty ? "" : ": \(selection.count) selection(s)") ==")
            ok = try run(one, ws: ws, filters: selection) && ok
            if let d = FileManager.default.contents(atPath: path), let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                perDevice[device] = r
                try? d.write(to: URL(fileURLWithPath: "\(ws.work)/ui-test-results-\(device).json"))
            }
        }
        try saveMatrix(perDevice, to: path)
        print("\(ok ? "PASSED" : "FAILED") on \(plan.map(\.device).joined(separator: " and ")) (results: \(path))")
        return ok
    }

    /// One status per test across devices: a failure anywhere fails it, else
    /// a pass anywhere passes it (a test can skip itself on a phone and run on an iPad).
    static func saveMatrix(_ perDevice: [String: [String: Any]], to path: String) throws {
        let rank = ["failed": 6, "crashed": 6, "not-run": 5, "flaky": 4, "passed": 3, "simulator-only": 2, "not-built": 1, "excluded": 1, "skipped": 0]
        var tests: [String: [String: Any]] = [:]
        for (device, r) in perDevice {
            for (id, entry) in (r["tests"] as? [String: [String: Any]]) ?? [:] {
                var merged = tests[id] ?? ["devices": [String: Any]()]
                var devices = merged["devices"] as? [String: Any] ?? [:]
                devices[device] = entry
                merged["devices"] = devices
                let status = entry["status"] as? String ?? "skipped"
                let current = merged["status"] as? String
                // Failures win, then a pass over a skip.
                if (rank[status] ?? 0) >= (current.flatMap { rank[$0] } ?? -1) { merged["status"] = status }
                tests[id] = merged
            }
        }
        func with(_ statuses: Set<String>) -> [String] { tests.filter { statuses.contains($0.value["status"] as? String ?? "") }.keys.sorted() }
        // The same fields as one device's file, so a merge script reads both the same way.
        let notRun = Set(perDevice.values.flatMap { $0["notRun"] as? [String] ?? [] }).union(with(["not-run"])).sorted()
        let bad = with(["failed", "crashed"])
        let out: [String: Any] = ["ok": bad.isEmpty && notRun.isEmpty && perDevice.values.allSatisfy { $0["ok"] as? Bool ?? false },
                                  "selected": with(["passed", "failed", "crashed", "skipped", "flaky", "not-run"]).count,
                                  "notRun": notRun, "flaky": with(["flaky"]), "failing": bad,
                                  "devices": perDevice.keys.sorted(), "tests": tests]
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }

    static func run(_ args: Args, ws: Workspace, filters: [String]) throws -> Bool {
        let t = now()
        let every = targets(ws, includingUnbuilt: true)
        let all = every.filter(\.built)
        guard !all.isEmpty else { throw SimlessError("no UI test targets in the build (is the UI test target in the scheme?)") }
        let config = ws.config.tests
        let simulatorOnly = config?.simulatorOnly ?? [:]
        let skips = (config?.skip ?? []) + (args.repeated["--skip"] ?? []) + simulatorOnly.keys.sorted()
        let timeout = args.values["--timeout"].flatMap(Double.init) ?? config?.uiTimeout ?? TestEngine.defaultTimeout(args)

        // Selection.
        var selected: [TestID] = []
        var bundles: [String: String] = [:]
        var markedTests: [String: String] = [:]     // simulator-only tests this run would have run
        var excluded: [String] = []                 // --skip and tests.skip
        var unbuiltTests: [String] = []             // in a UI test target the scheme doesn't build
        var named: [String] = []                    // ...and asked for by name
        var missing: [String] = []                  // in the scheme, yet not in the build: never fine
        let inScheme = Set(SimulatorLane.schemes(ws).filter { $0.value == ws.config.scheme }.keys)
        for target in every where !target.built {
            let wanted = filters.isEmpty || filters.contains { $0 == target.name || $0.hasPrefix(target.name + "/") }
            if !wanted { continue }
            for id in tests(in: target) {
                if let mark = simulatorOnly.first(where: { TestEngine.matches(id.user, $0.key) }) { markedTests[id.user] = mark.value }
                else if inScheme.contains(target.name) && SimulatorLane.platform(target.name, ws: ws) == "iOS" { missing.append(id.user) }
                else {
                    unbuiltTests.append(id.user)
                    if !filters.isEmpty { named.append(id.user) }
                }
            }
        }
        // An id asked for that matches no UI test (renamed, deleted, mistyped)
        // counts as not run, unless --allow-missing.
        var unmatched: [String] = []
        if !args.flags.contains("--allow-missing") {
            let everyID = every.flatMap { tests(in: $0) }.map(\.user)
            for f in filters where !everyID.contains(where: { id in id == f || id.hasPrefix(f + "/") || f == String(id.split(separator: "/")[0])
                || id == f.replacingOccurrences(of: "()", with: "") }) {
                unmatched.append(f)
            }
        }
        if !missing.isEmpty {
            let targets = Set(missing.map { String($0.split(separator: "/")[0]) }).sorted()
            Log.info("note: \(targets.joined(separator: ", ")) is in the \(ws.config.scheme) scheme but not in the build; its \(missing.count) test(s) count as not run")
        }
        for target in all {
            let wanted = filters.isEmpty || filters.contains { $0 == target.name || $0.hasPrefix(target.name + "/") }
            if !wanted { continue }
            let asked = tests(in: target).filter { id in
                filters.isEmpty || filters.contains { f in id.user == f || id.user.hasPrefix(f + "/") || f == target.name
                    || id.user == f.replacingOccurrences(of: "()", with: "") }
            }
            for id in asked {
                if let mark = simulatorOnly.first(where: { TestEngine.matches(id.user, $0.key) }) { markedTests[id.user] = mark.value }
            }
            let skipped = { (id: TestID) in
                skips.contains { s in id.user == s.replacingOccurrences(of: "()", with: "") || id.user.hasPrefix(s + "/") || "\(target.name)/\(id.cls)" == s }
            }
            let ids = asked.filter { !skipped($0) }
            excluded += asked.filter { skipped($0) && markedTests[$0.user] == nil }.map(\.user)
            if ids.isEmpty { continue }
            bundles[target.name] = try build(target, ws: ws)
            selected += ids
        }
        if selected.isEmpty {
            // Nothing to run here is only fine when everything asked for is simulator-only.
            if !missing.isEmpty { throw SimlessError("no UI test ran: \(missing.count) test(s) in the \(ws.config.scheme) scheme aren't in the build (run `simless up`)") }
            if !unmatched.isEmpty { throw SimlessError("no UI test matches \(unmatched.joined(separator: " "))") }
            if !markedTests.isEmpty && named.isEmpty {
                try saveResults(ws: ws, results: Results(), selected: [], marked: markedTests, load: [], excluded: excluded, unbuilt: unbuiltTests)
                print("0 run here, \(markedTests.count) simulator-only (`simless test --simulator-only` lists them)")
                print("PASSED in \(secs(t))")
                return true
            }
            if !named.isEmpty { throw SimlessError("\(named[0]) is in a UI test target the scheme doesn't build, so it can't run here") }
            throw SimlessError("no UI tests match \(filters.joined(separator: " "))")
        }

        // Workers: one host each, tests spread by their last durations (longest
        // first onto the least busy host), each host keeping the source order.
        let durations = loadDurations(ws)
        let share = Budget.share(ws)
        let jobs = min(selected.count, args.values["--jobs"].flatMap(Int.init) ?? config?.uiJobs ?? max(1, Int(Double(defaultJobs) * share)))
        if share < 1 { Log.step("sharing the Mac with \(Int((1 / share).rounded()) - 1) other test run(s): \(jobs) UI host(s) instead of \(defaultJobs)") }
        Budget.start(ws, kind: "ui", hosts: jobs)
        defer { Budget.finish(ws) }
        var assigned = Array(repeating: [Int](), count: jobs)
        var load = Array(repeating: 0.0, count: jobs)
        for i in selected.indices.sorted(by: { (durations[selected[$0].user] ?? 10) > (durations[selected[$1].user] ?? 10) }) {
            let h = load.indices.min { load[$0] < load[$1] }!
            assigned[h].append(i)
            load[h] += durations[selected[i].user] ?? 10
        }
        let shards = assigned.map { $0.sorted().map { selected[$0] } }
        // The device the app runs as: an iPhone unless --device or .simless.json says otherwise.
        let device = args.values["--device"] ?? ws.config.device
        _ = try Render.canvas(device)
        Log.step("running \(selected.count) UI test(s) on \(jobs) host(s)\(device == "iphone" ? "" : " as \(device)")")
        var slots: [SlotRecord] = []
        for i in 1...jobs { slots.append(try RuntimeHost.slot(kind: "ui\(i)", ws: ws)) }
        // Every run starts from a fresh install's data, like a simulator's
        // clones: what earlier runs saved (counters, history, settings) would
        // make results depend on how often the suite ran before.
        // That launch also checks the slot: an install macOS won't open anymore
        // is installed again, rather than failing every test it gets.
        let settings = try ws.settings()
        DispatchQueue.concurrentPerform(iterations: slots.count) { i in
            let slot = slots[i]
            Slots.terminateAll(slot)
            if Native.isNative(slot) { return Native.wipe(slot) }
            let runtime = "\(slot.dir)/SimlessRuntime.dylib"
            guard let app = try? RuntimeHost.installedApp(slot), !Cleanup.wipeContainer(app: app, runtime: runtime) else { return }
            Log.step("\(slot.slotID)'s app wouldn't launch, installing it again")
            do {
                try Slots.prepare(slot, ws: ws, settings: settings, embedded: ws.config.embeddedBundles ?? true)
                try Slots.install(slot, ws: ws)
                if let app = try? RuntimeHost.installedApp(slot) { Cleanup.wipeContainer(app: app, runtime: runtime) }
            } catch {
                Log.info("note: installing \(slot.slotID) again failed (\(error))")
            }
        }

        // One folder per device, so a second device's run keeps the first one's screenshots.
        let artifacts = "\(ws.work)/ui-artifacts" + (args.values["--device"].map { $0 == ws.config.device ? "" : "-\($0)" } ?? "")
        try? FileManager.default.removeItem(atPath: artifacts)
        try mkdirp(artifacts)
        let results = Results()
        let group = DispatchGroup()
        for (i, shard) in shards.enumerated() where !shard.isEmpty {
            group.enter()
            let worker = Worker(index: i + 1, slot: slots[i], ws: ws, bundles: bundles, tests: shard, timeout: timeout,
                                artifacts: artifacts, results: results, device: device)
            Thread.detachNewThread {
                worker.run()
                group.leave()
            }
        }
        group.wait()
        // A few failures get one more run, alone on a quiet Mac: a timed gesture
        // or a wait can lose only because every host was busy.
        var passedAlone: [String] = []
        // Tests whose app never launched always run again (a host's whole
        // share can fail that way), the rest when there are few.
        let launchFailures = selected.filter { (results.failed[$0.user] ?? []).contains { $0.contains("could not launch the app") } }
        let others = selected.filter { results.failed[$0.user] != nil && !launchFailures.contains($0) }
        let failedIDs = launchFailures + (others.count <= 10 ? others : [])
        if !failedIDs.isEmpty {
            Log.step("running \(failedIDs.count) failed UI test(s) again, one per host, to rule out load")
            let again = Results()
            // One test per host at a time, the hosts side by side.
            let lanes = min(slots.count, failedIDs.count)
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                let mine = failedIDs.enumerated().filter { $0.offset % lanes == lane }.map(\.element)
                Worker(index: slots.count + 1 + lane, slot: slots[lane], ws: ws, bundles: bundles, tests: mine, timeout: timeout,
                       artifacts: artifacts, results: again, device: device).run()
            }
            for id in failedIDs where again.passed.contains(id.user) {
                results.recover(id.user)
                passedAlone.append(id.user)
            }
        }
        for slot in slots { Slots.terminateAll(slot) }

        // Report.
        let r = results
        for (id, reason) in r.crashed { print("  CRASHED: \(id): \(reason)") }
        for id in passedAlone { print("  flaky: \(id) failed while the run was busy, and passed alone (load, or a flaky test)") }
        let notRun = try saveResults(ws: ws, results: r, selected: selected.map(\.user) + missing + unmatched, marked: markedTests, load: passedAlone,
                                     excluded: excluded, unbuilt: unbuiltTests)
        var parts = ["\(r.passed.count) passed", "\(r.failed.count) failed"]
        if !r.skipped.isEmpty { parts.append("\(r.skipped.count) skipped") }
        if !markedTests.isEmpty { parts.append("\(markedTests.count) simulator-only (`simless test --simulator-only` lists them)") }
        if !r.crashed.isEmpty { parts.append("\(r.crashed.count) crashed") }
        if !passedAlone.isEmpty { parts.append("\(passedAlone.count) flaky") }
        if !notRun.isEmpty { parts.append("\(notRun.count) didn't run") }
        print(parts.joined(separator: ", "))
        for id in notRun.prefix(20) { print("  NOT RUN: \(id)") }
        if !unbuiltTests.isEmpty {
            let targets = Set(unbuiltTests.map { String($0.split(separator: "/")[0]) }).sorted()
            print("  note: \(targets.joined(separator: ", ")) isn't in the scheme's build, so its \(unbuiltTests.count) test(s) are listed as not built")
        }
        let ok = r.failed.isEmpty && r.crashed.isEmpty && notRun.isEmpty
        if !ok, let note = SimulatorBranches.note(ws) { print("  \(note)") }
        print("\(ok ? "PASSED" : "FAILED") in \(secs(t)) (screenshots of failures and logs: \(artifacts))")
        return ok
    }

    /// UI hosts are light (about 1.5 GB each) and mostly wait on the app, so up to
    /// one per two cores.
    static var defaultJobs: Int { max(1, min(4, ProcessInfo.processInfo.processorCount / 2)) }

    final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var passed: [String] = []
        private(set) var failed: [String: [String]] = [:]
        private(set) var skipped: [String: String] = [:]
        private(set) var crashed: [(String, String)] = []
        private(set) var seconds: [String: Double] = [:]
        func pass(_ id: String, _ s: Double) { lock.lock(); passed.append(id); seconds[id] = s; lock.unlock() }
        func fail(_ id: String, _ line: String) { lock.lock(); failed[id, default: []].append(line); lock.unlock() }
        func failedTest(_ id: String, _ s: Double) { lock.lock(); seconds[id] = s; if failed[id] == nil { failed[id] = ["failed"] }; lock.unlock() }
        func skip(_ id: String, _ why: String, _ s: Double) { lock.lock(); skipped[id] = why; seconds[id] = s; lock.unlock() }
        func crash(_ id: String, _ why: String) { lock.lock(); crashed.append((id, why)); lock.unlock() }
        /// A failure that didn't happen again alone.
        func recover(_ id: String) { lock.lock(); failed.removeValue(forKey: id); passed.append(id); lock.unlock() }
    }

    /// One xctest process driving one host, through its share of the tests.
    final class Worker: @unchecked Sendable {
        let index: Int, slot: SlotRecord, ws: Workspace, bundles: [String: String], tests: [TestID]
        let timeout: Double, artifacts: String, results: Results, device: String

        init(index: Int, slot: SlotRecord, ws: Workspace, bundles: [String: String], tests: [TestID], timeout: Double,
             artifacts: String, results: Results, device: String) {
            self.index = index; self.slot = slot; self.ws = ws; self.bundles = bundles; self.tests = tests
            self.timeout = timeout; self.artifacts = artifacts; self.results = results; self.device = device
        }

        func run() {
            var remaining = tests
            var attempts = 0
            while !remaining.isEmpty && attempts < 20 {
                attempts += 1
                let target = remaining[0].target
                let batch = remaining.filter { $0.target == target }
                let done = runBatch(batch, bundle: bundles[target] ?? "")
                remaining.removeAll { done.contains($0) }
            }
        }

        /// Runs tests until xctest exits; returns the tests that are finished
        /// (passed, failed, or the one that hung or crashed the runner).
        private func runBatch(_ batch: [TestID], bundle: String) -> Set<TestID> {
            var env = ProcessInfo.processInfo.environment
            // TEST_RUNNER_FOO reaches the tests as FOO, like with xcodebuild.
            for (k, v) in env where k.hasPrefix("TEST_RUNNER_") { env[String(k.dropFirst("TEST_RUNNER_".count))] = v }
            env["SIMLESS_UI_PORT"] = String(slot.port)
            env["SIMLESS_UI_APP"] = (try? RuntimeHost.installedApp(slot)) ?? ""
            env["SIMLESS_UI_SLOT"] = slot.slotID
            env["SIMLESS_UI_LOG"] = "\(artifacts)/host\(index).log"
            env["SIMLESS_UI_ARTIFACTS"] = artifacts
            let canvas = (try? Render.canvas(device)) ?? Render.canvases["iphone"]!
            env["SIMLESS_UI_CANVAS"] = "\(canvas.width),\(canvas.height),\(canvas.safeTop),\(canvas.safeBottom)"
            env["SIMLESS_UI_IDIOM"] = canvas.width < 600 ? "phone" : "pad"
            // The app's real launch, as XCUITest gives it: no SIMLESS_HEADLESS (apps
            // read it as "render host, skip side effects"); the runtime keeps it hidden.
            for (k, v) in RuntimeHost.baseEnvironment(slot) where k != "SIMLESS_HEADLESS" { env["SIMLESS_HOST_ENV_\(k)"] = v }
            if Native.isNative(slot) {
                // Started directly, not with `open`: the shim runs the app's executable.
                env["SIMLESS_UI_EXEC"] = (try? Native.executable(Native.app(slot))) ?? ""
            } else {
                env["SIMLESS_HOST_ENV_SIMLESS_SANDBOX_TOKENS"] = Sandbox.readToken(ws.root) ?? ""
            }
            env["SIMLESS_HOST_ENV_SIMLESS_DEVICE_MODEL"] = canvas.width < 600 ? "iPhone" : "iPad"

            let selection = batch.map(\.xctest).joined(separator: ",")
            let log = "\(artifacts)/runner\(index).log"
            var done = Set<TestID>()
            var current: (TestID, Double)?
            let byName = Dictionary(batch.map { ("\($0.cls)/\($0.method)", $0) }, uniquingKeysWith: { a, _ in a })
            let caseRe = try! NSRegularExpression(pattern: #"Test Case '-\[(?:[\w.]+\.)?(\w+) (\w+)\]' (started|passed|failed|skipped)(?: \((\d+\.\d+) seconds\))?"#)
            let failRe = try! NSRegularExpression(pattern: #"^(.*?):(\d+): error: -\[(?:[\w.]+\.)?(\w+) (\w+)\] : (.*)$"#)
            let skipRe = try! NSRegularExpression(pattern: #"-\[(?:[\w.]+\.)?(\w+) (\w+)\] : Test skipped(?: - (.*))?$"#)
            var skipReasons: [String: String] = [:]
            let r = try? Shell.stream(["xcrun", "xctest", "-XCTest", selection, bundle], cwd: ws.root, logPath: log, env: env, onLine: { raw in
                let line = visibleText(raw)
                let range = NSRange(line.startIndex..., in: line)
                if let m = failRe.firstMatch(in: line, range: range), let f = Range(m.range(at: 1), in: line), let l = Range(m.range(at: 2), in: line),
                   let c = Range(m.range(at: 3), in: line), let t = Range(m.range(at: 4), in: line), let msg = Range(m.range(at: 5), in: line),
                   let id = byName["\(line[c])/\(line[t])"] {
                    let text = "\((String(line[f]) as NSString).lastPathComponent):\(line[l]): \(line[msg])"
                    self.results.fail(id.user, text)
                    print("  \(id.user): \(text)")
                    fflush(stdout)
                }
                if let m = skipRe.firstMatch(in: line, range: range), let c = Range(m.range(at: 1), in: line), let t = Range(m.range(at: 2), in: line) {
                    skipReasons["\(line[c])/\(line[t])"] = Range(m.range(at: 3), in: line).map { String(line[$0]) } ?? "skipped"
                }
                if let m = caseRe.firstMatch(in: line, range: range), let c = Range(m.range(at: 1), in: line),
                   let t = Range(m.range(at: 2), in: line), let e = Range(m.range(at: 3), in: line), let id = byName["\(line[c])/\(line[t])"] {
                    let secs = Range(m.range(at: 4), in: line).flatMap { Double(line[$0]) } ?? 0
                    switch line[e] {
                    case "started": current = (id, now())
                    case "passed": self.results.pass(id.user, secs); done.insert(id); current = nil
                    case "failed": self.results.failedTest(id.user, secs); done.insert(id); current = nil
                    default:
                        self.results.skip(id.user, skipReasons["\(id.cls)/\(id.method)"] ?? "skipped", secs)
                        done.insert(id); current = nil
                    }
                }
            }, tick: {
                if let (id, start) = current, now() - start > self.timeout {
                    self.results.crash(id.user, "ran past the \(Int(self.timeout)) s time limit")
                    done.insert(id)
                    current = nil
                    Slots.terminateAll(self.slot)
                    return false
                }
                return true
            })
            if let (id, _) = current {
                // xctest exited in the middle of a test: the runner itself crashed.
                let why = (r?.out.split(separator: "\n").suffix(3).joined(separator: " ")).map { String($0.prefix(300)) } ?? "the test runner exited"
                results.crash(id.user, why)
                done.insert(id)
            }
            // Tests xctest never got to (it exited early) stay for the next attempt.
            if done.isEmpty { done = Set(batch) }
            return done
        }
    }

    // MARK: - Results

    static func loadDurations(_ ws: Workspace) -> [String: Double] {
        guard let d = FileManager.default.contents(atPath: "\(ws.work)/ui-test-results.json"),
              let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return r["seconds"] as? [String: Double] ?? [:]
    }

    /// Writes ui-test-results.json; returns the selected tests that never ran.
    @discardableResult
    static func saveResults(ws: Workspace, results r: Results, selected: [String], marked: [String: String], load: [String],
                            excluded: [String], unbuilt: [String]) throws -> [String] {
        // Every test, with what happened to it.
        var tests: [String: [String: Any]] = [:]
        for (id, reason) in marked { tests[id] = ["status": "simulator-only", "reason": reason] }
        for id in excluded { tests[id] = ["status": "excluded", "reason": "--skip or tests.skip"] }
        for id in unbuilt { tests[id] = ["status": "not-built", "reason": "its target isn't in the scheme's build"] }
        for id in r.passed {
            tests[id] = load.contains(id) ? ["status": "flaky", "reason": "failed in the full run, passed when run again alone"] : ["status": "passed"]
        }
        for (id, lines) in r.failed { tests[id] = ["status": "failed", "issues": lines] }
        for (id, reason) in r.skipped { tests[id] = ["status": TestEngine.isSimulatorOnly(reason) ? "simulator-only" : "skipped", "reason": reason] }
        for (id, reason) in r.crashed { tests[id] = ["status": "crashed", "reason": reason] }
        for (id, seconds) in r.seconds { tests[id]?["seconds"] = (seconds * 1000).rounded() / 1000 }
        let notRun = selected.filter { tests[$0] == nil }.sorted()
        for id in notRun { tests[id] = ["status": "not-run", "reason": "selected, but it never ran"] }
        let ok = r.failed.isEmpty && r.crashed.isEmpty && notRun.isEmpty
        let out: [String: Any] = ["ok": ok, "selected": selected.count, "notRun": notRun, "flaky": load.sorted(),
                                  "passed": r.passed.sorted(), "failed": r.failed, "skipped": r.skipped,
                                  "crashed": r.crashed.map { ["test": $0.0, "reason": $0.1] }, "seconds": r.seconds,
                                  "simulatorOnly": marked, "tests": tests]
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "\(ws.work)/ui-test-results.json"))
        return notRun
    }
}
