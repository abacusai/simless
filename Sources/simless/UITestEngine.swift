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
    }

    struct TestID: Hashable {
        let target: String, cls: String, method: String
        var user: String { "\(target)/\(cls)/\(method)" }
        var xctest: String { "\(TestEngine.moduleName(target)).\(cls)/\(method)" }
    }

    // MARK: - Targets

    /// UI test targets in the build (the .xctestrun's UI test bundles), with
    /// their sources (synchronized folders, or a folder named like the target).
    static func targets(_ ws: Workspace) -> [UITarget] {
        guard let file = (try? FileManager.default.contentsOfDirectory(atPath: ws.products))?.first(where: { $0.hasSuffix(".xctestrun") }),
              let data = FileManager.default.contents(atPath: "\(ws.products)/\(file)"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var entries: [[String: Any]] = []
        if let configs = plist["TestConfigurations"] as? [[String: Any]] {
            entries = configs.flatMap { $0["TestTargets"] as? [[String: Any]] ?? [] }
        } else {
            entries = plist.filter { !$0.key.hasPrefix("__") }.compactMap { $0.value as? [String: Any] }
        }
        let names = Set(entries.filter { $0["IsUITestBundle"] as? Bool == true }.compactMap { $0["BlueprintName"] as? String })
        let pbx = (try? String(contentsOfFile: "\(ws.root)/\(ws.config.project)/project.pbxproj", encoding: .utf8)) ?? ""
        return names.sorted().compactMap { name in
            let dirs = synchronizedFolders(target: name, pbx: pbx).map { "\(ws.projectDir)/\($0)" }
                + (ws.config.tests?.uiSources?[name].map { ["\(ws.root)/\($0)"] } ?? [])
            let folders = dirs.isEmpty ? ["\(ws.projectDir)/\(name)"].filter { exists($0) } : dirs
            let sources = folders.flatMap { dir -> [String] in
                guard let e = FileManager.default.enumerator(atPath: dir) else { return [] }
                return e.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.map { "\(dir)/\($0)" }
            }.sorted()
            return sources.isEmpty ? nil : UITarget(name: name, sources: sources)
        }
    }

    /// Paths of the PBXFileSystemSynchronizedRootGroups a target lists.
    static func synchronizedFolders(target: String, pbx: String) -> [String] {
        guard let start = pbx.range(of: "/* \(target) */ = {\n\t\t\tisa = PBXNativeTarget;"),
              let end = pbx.range(of: "\n\t\t};", range: start.upperBound..<pbx.endIndex),
              let groups = pbx[start.upperBound..<end.lowerBound].range(of: #"fileSystemSynchronizedGroups = \(([^)]*)\)"#, options: .regularExpression)
        else { return [] }
        let ids = pbx[groups].matches(of: #/([0-9A-F]{24})/#).map { String($0.1) }
        return ids.compactMap { id in
            guard let g = pbx.range(of: "\t\t\(id) /* "), let gEnd = pbx.range(of: "};", range: g.upperBound..<pbx.endIndex) else { return nil }
            let body = pbx[g.upperBound..<gEnd.lowerBound]
            return body.firstMatch(of: #/path = "?([^";]+)"?;/#).map { String($0.1) }
        }
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
        let newest = (target.sources + shim).map(mtime).max() ?? 0
        if exists(exe), mtime(exe) >= newest, mtime(exe) >= mtime(Bundle.main.executablePath ?? "") { return bundle }
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
        Log.step("built \(target.name) for the Mac in \(secs(t))")
        return bundle
    }

    // MARK: - Run

    static func run(_ args: Args, ws: Workspace, filters: [String]) throws {
        let t = now()
        let all = targets(ws)
        guard !all.isEmpty else { throw SimlessError("no UI test targets in the build (is the UI test target in the scheme?)") }
        let config = ws.config.tests
        let simulatorOnly = config?.simulatorOnly ?? [:]
        let skips = (config?.skip ?? []) + (args.repeated["--skip"] ?? []) + simulatorOnly.keys.sorted()
        let timeout = args.values["--timeout"].flatMap(Double.init) ?? config?.uiTimeout ?? 600

        // Selection.
        var selected: [TestID] = []
        var bundles: [String: String] = [:]
        var markedTests: [String: String] = [:]     // simulator-only tests this run would have run
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
            let ids = asked.filter { id in
                !skips.contains { s in id.user == s.replacingOccurrences(of: "()", with: "") || id.user.hasPrefix(s + "/") || "\(target.name)/\(id.cls)" == s }
            }
            if ids.isEmpty { continue }
            bundles[target.name] = try build(target, ws: ws)
            selected += ids
        }
        guard !selected.isEmpty else { throw SimlessError("no UI tests match \(filters.joined(separator: " "))") }

        // Workers: one host each, tests spread by their last durations (longest
        // first onto the least busy host), each host keeping the source order.
        let durations = loadDurations(ws)
        let jobs = min(selected.count, args.values["--jobs"].flatMap(Int.init) ?? config?.uiJobs ?? defaultJobs)
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

        let artifacts = "\(ws.work)/ui-artifacts"
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
        let failedIDs = selected.filter { results.failed[$0.user] != nil }
        if !failedIDs.isEmpty && failedIDs.count <= 10 {
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
        for id in passedAlone { print("  note: \(id) failed while the run was busy, and passed alone (load, not a failure)") }
        var parts = ["\(r.passed.count) passed", "\(r.failed.count) failed"]
        if !r.skipped.isEmpty { parts.append("\(r.skipped.count) skipped") }
        if !markedTests.isEmpty { parts.append("\(markedTests.count) simulator-only (`simless test --simulator-only` lists them)") }
        if !r.crashed.isEmpty { parts.append("\(r.crashed.count) crashed") }
        print(parts.joined(separator: ", "))
        try saveResults(ws: ws, results: r, marked: markedTests, load: passedAlone)
        let ok = r.failed.isEmpty && r.crashed.isEmpty
        if !ok, let note = SimulatorBranches.note(ws) { print("  \(note)") }
        print("\(ok ? "PASSED" : "FAILED") in \(secs(t)) (screenshots of failures and logs: \(artifacts))")
        if !ok { exit(1) }
    }

    /// UI hosts are light (about 1.5 GB each) and mostly wait on the app, so up to
    /// one per two cores.
    static var defaultJobs: Int { max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)) }

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
        func skip(_ id: String, _ why: String) { lock.lock(); skipped[id] = why; lock.unlock() }
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
            env["SIMLESS_HOST_ENV_SIMLESS_SANDBOX_TOKENS"] = Sandbox.readToken(ws.root) ?? ""
            env["SIMLESS_HOST_ENV_SIMLESS_DEVICE_MODEL"] = canvas.width < 600 ? "iPhone" : "iPad"

            let selection = batch.map(\.xctest).joined(separator: ",")
            let log = "\(artifacts)/runner\(index).log"
            var done = Set<TestID>()
            var current: (TestID, Double)?
            let byName = Dictionary(batch.map { ("\($0.cls)/\($0.method)", $0) }, uniquingKeysWith: { a, _ in a })
            let caseRe = try! NSRegularExpression(pattern: #"Test Case '-\[(?:[\w.]+\.)?(\w+) (\w+)\]' (started|passed|failed|skipped)(?: \((\d+\.\d+) seconds\))?"#)
            let failRe = try! NSRegularExpression(pattern: #"^(.*?):(\d+): error: -\[(?:[\w.]+\.)?(\w+) (\w+)\] : (.*)$"#)
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
                if let m = caseRe.firstMatch(in: line, range: range), let c = Range(m.range(at: 1), in: line),
                   let t = Range(m.range(at: 2), in: line), let e = Range(m.range(at: 3), in: line), let id = byName["\(line[c])/\(line[t])"] {
                    let secs = Range(m.range(at: 4), in: line).flatMap { Double(line[$0]) } ?? 0
                    switch line[e] {
                    case "started": current = (id, now())
                    case "passed": self.results.pass(id.user, secs); done.insert(id); current = nil
                    case "failed": self.results.failedTest(id.user, secs); done.insert(id); current = nil
                    default: self.results.skip(id.user, ""); done.insert(id); current = nil
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

    static func saveResults(ws: Workspace, results r: Results, marked: [String: String], load: [String]) throws {
        // Every test, with what happened to it.
        var tests: [String: [String: Any]] = [:]
        for (id, reason) in marked { tests[id] = ["status": "simulator-only", "reason": reason] }
        for id in r.passed { tests[id] = ["status": load.contains(id) ? "load" : "passed"] }
        for (id, lines) in r.failed { tests[id] = ["status": "failed", "issues": lines] }
        for (id, reason) in r.skipped { tests[id] = ["status": TestEngine.isSimulatorOnly(reason) ? "simulator-only" : "skipped", "reason": reason] }
        for (id, reason) in r.crashed { tests[id] = ["status": "crashed", "reason": reason] }
        for (id, seconds) in r.seconds { tests[id]?["seconds"] = (seconds * 1000).rounded() / 1000 }
        let out: [String: Any] = ["passed": r.passed.sorted(), "failed": r.failed, "skipped": r.skipped,
                                  "crashed": r.crashed.map { ["test": $0.0, "reason": $0.1] }, "seconds": r.seconds,
                                  "simulatorOnly": marked, "tests": tests]
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "\(ws.work)/ui-test-results.json"))
    }
}
