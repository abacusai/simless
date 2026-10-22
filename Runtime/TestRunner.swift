// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation
import UIKit
import ObjectiveC

/// Runs loaded test bundles in this process and streams one event per line:
///   {"event":"started","id":...}
///   {"event":"issue","id":...,"message":...,"location":"File.swift:12","failure":true}
///   {"event":"ended","id":...,"result":"passed|failed|skipped","seconds":...,"reason":...}
///   {"event":"done","swift":true|false|null}
/// Test ids: Swift Testing "Module.Suite/test()", XCTest "Module.Class/testMethod".
final class TestRunner {
    let connection: Connection
    let request: [String: Any]

    init(connection: Connection, request: [String: Any]) {
        self.connection = connection
        self.request = request
    }

    // MARK: Listing

    func list() {
        var swift: [String] = []
        if let ep = SwiftTesting.entryPoint() {
            let done = DispatchSemaphore(value: 0)
            let lock = NSLock()
            Task.detached {
                _ = try? await SwiftTesting.run(ep, config: ["listTests": true]) { record in
                    if let kind = record["kind"] as? String, kind == "test",
                       let p = record["payload"] as? [String: Any], (p["kind"] as? String) == "function",
                       let id = p["id"] as? String {
                        lock.lock(); swift.append(SwiftTesting.testName(id)); lock.unlock()
                    }
                }
                done.signal()
            }
            done.wait()
        }
        let xctest = onMainRunLoop { XCTestSide.leaves().map(XCTestSide.id) }
        connection.send(["ok": true, "swift": swift, "xctest": xctest])
    }

    // MARK: Running

    func run() {
        Scenes.waitForFirst()
        var swiftResult: Bool?
        if let swift = request["swift"] as? [String: Any], let ep = SwiftTesting.entryPoint() {
            var config: [String: Any] = ["parallel": request["parallel"] as? Bool ?? true]
            if let f = swift["filter"] as? [String], !f.isEmpty { config["filter"] = f }
            if let s = swift["skip"] as? [String], !s.isEmpty { config["skip"] = s }
            if let w = request["width"] as? Int { config["experimentalMaximumParallelizationWidth"] = w }
            let done = DispatchSemaphore(value: 0)
            let state = SwiftEvents(connection: connection)
            var outcome: Bool?
            Task.detached {
                do {
                    outcome = try await SwiftTesting.run(ep, config: config) { state.handle($0) }
                } catch {
                    state.connection.send(["event": "error", "message": "Swift Testing: \(error)"])
                }
                done.signal()
            }
            done.wait()
            swiftResult = outcome
        }
        if let x = request["xctest"] as? [String: Any] {
            let include = x["include"] as? [String]
            let exclude = x["exclude"] as? [String] ?? []
            onMainRunLoop { [connection] in XCTestSide.run(include: include, exclude: exclude, connection: connection) }
        }
        connection.send(["event": "done", "swift": swiftResult as Any])
    }
}

// MARK: - Swift Testing

enum SwiftTesting {
    typealias EntryPoint = @convention(thin) @Sendable (
        UnsafeRawBufferPointer?, @escaping @Sendable (UnsafeRawBufferPointer) -> Void
    ) async throws -> Bool

    static func entryPoint() -> EntryPoint? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swt_abiv0_getEntryPoint") else { return nil }
        typealias Get = @convention(c) () -> UnsafeRawPointer
        return unsafeBitCast(unsafeBitCast(sym, to: Get.self)(), to: EntryPoint.self)
    }

    static func run(_ ep: EntryPoint, config: [String: Any], record: @escaping ([String: Any]) -> Void) async throws -> Bool {
        var c = config
        c["eventStreamSchemaVersion"] = "0"
        let json = try JSONSerialization.data(withJSONObject: c)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: json.count, alignment: 1)
        defer { buffer.deallocate() }
        json.copyBytes(to: buffer)
        return try await ep(UnsafeRawBufferPointer(buffer)) { raw in
            if let obj = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any] { record(obj) }
        }
    }

    /// "Module.Suite/test()/File.swift:15:6" -> "Module.Suite/test()".
    static func testName(_ id: String) -> String {
        guard let slash = id.lastIndex(of: "/") else { return id }
        let last = id[id.index(after: slash)...]
        return last.range(of: #"\.swift:\d+:\d+$"#, options: .regularExpression) != nil ? String(id[..<slash]) : id
    }

    static func isFunction(_ id: String) -> Bool { testName(id) != id }
}

/// Turns Swift Testing's event records into the runner's events.
final class SwiftEvents: @unchecked Sendable {
    let connection: Connection
    private let lock = NSLock()
    private var starts: [String: Double] = [:]
    private var failed: Set<String> = []

    init(connection: Connection) { self.connection = connection }

    func handle(_ record: [String: Any]) {
        guard record["kind"] as? String == "event", let p = record["payload"] as? [String: Any],
              let kind = p["kind"] as? String, let raw = p["testID"] as? String,
              SwiftTesting.isFunction(raw) else { return }
        let id = SwiftTesting.testName(raw)
        let at = ((p["instant"] as? [String: Any])?["absolute"] as? Double) ?? CFAbsoluteTimeGetCurrent()
        let text = ((p["messages"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
        lock.lock(); defer { lock.unlock() }
        switch kind {
        case "testStarted":
            starts[id] = at
            connection.send(["event": "started", "id": id])
        case "issueRecorded":
            let issue = p["issue"] as? [String: Any] ?? [:]
            let failure = (issue["isFailure"] as? Bool ?? true) && !(issue["isKnown"] as? Bool ?? false)
            if failure { failed.insert(id) }
            var location = ""
            if let loc = issue["sourceLocation"] as? [String: Any] {
                location = "\(((loc["fileID"] as? String) ?? "").split(separator: "/").last ?? ""):\(loc["line"] as? Int ?? 0)"
            }
            connection.send(["event": "issue", "id": id, "message": text, "location": location, "failure": failure])
        case "testSkipped":
            connection.send(["event": "ended", "id": id, "result": "skipped", "seconds": 0, "reason": text])
        case "testEnded":
            let seconds = starts[id].map { max(0, at - $0) } ?? 0
            connection.send(["event": "ended", "id": id, "result": failed.contains(id) ? "failed" : "passed", "seconds": seconds])
        default:
            break
        }
    }
}

// MARK: - XCTest

/// XCTest through its Objective-C runtime: the runtime doesn't link XCTest,
/// it uses whichever copy the test bundles loaded.
enum XCTestSide {
    /// "-[Module.Class testMethod]" -> "Module.Class/testMethod".
    /// The class part comes from the class itself: XCTest's name drops the module.
    static func id(_ test: NSObject) -> String {
        let name = (test.value(forKey: "name") as? String) ?? ""
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "-[]"))
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return trimmed }
        return "\(NSStringFromClass(type(of: test)))/\(parts[1])"
    }

    /// Every test case in the default suite (all loaded bundles).
    static func leaves() -> [NSObject] {
        guard let suiteClass = NSClassFromString("XCTestSuite") as? NSObject.Type,
              let suite = suiteClass.perform(NSSelectorFromString("defaultTestSuite"))?.takeUnretainedValue() as? NSObject
        else { return [] }
        var out: [NSObject] = []
        func walk(_ t: NSObject) {
            if t.isKind(of: suiteClass) {
                for child in (t.value(forKey: "tests") as? [NSObject]) ?? [] { walk(child) }
            } else {
                out.append(t)
            }
        }
        walk(suite)
        return out
    }

    static func matches(_ id: String, _ patterns: [String]) -> Bool {
        patterns.contains { p in id == p || id.hasPrefix(p + "/") || id.hasPrefix(p + ".") }
    }

    /// `add(XCTAttachment)` needs activities, which XCTest only reports when its
    /// configuration says so. xcodebuild hands the process one; a host has none
    /// ("Attachments cannot be added to the test because activities are disabled"),
    /// so it makes one that reports them.
    static func enableActivities() {
        guard let cls = NSClassFromString("XCTestConfiguration") as? NSObject.Type else { return }
        var config = cls.perform(NSSelectorFromString("activeTestConfiguration"))?.takeUnretainedValue() as? NSObject
        if config == nil {
            let made = cls.init()
            cls.perform(NSSelectorFromString("setActiveTestConfiguration:"), with: made)
            config = made
        }
        guard let config, config.responds(to: NSSelectorFromString("setReportActivities:")) else { return }
        config.setValue(true, forKey: "reportActivities")
    }

    static func run(include: [String]?, exclude: [String], connection: Connection) {
        guard let suiteClass = NSClassFromString("XCTestSuite") as? NSObject.Type,
              let center = (NSClassFromString("XCTestObservationCenter") as? NSObject.Type)?
                .perform(NSSelectorFromString("sharedTestObservationCenter"))?.takeUnretainedValue() as? NSObject
        else { return }
        let cases = leaves().filter { t in
            let id = id(t)
            return (include.map { matches(id, $0) } ?? true) && !matches(id, exclude)
        }
        if cases.isEmpty { return }
        enableActivities()
        guard let suite = suiteClass.perform(NSSelectorFromString("testSuiteWithName:"), with: "simless")?
            .takeUnretainedValue() as? NSObject else { return }
        for c in cases { suite.perform(NSSelectorFromString("addTest:"), with: c) }
        let observer = XCTestObserver(connection: connection)
        if let proto = objc_getProtocol("XCTestObservation") { class_addProtocol(XCTestObserver.self, proto) }
        center.perform(NSSelectorFromString("addTestObserver:"), with: observer)
        suite.perform(NSSelectorFromString("runTest"))
        center.perform(NSSelectorFromString("removeTestObserver:"), with: observer)
    }
}

final class XCTestObserver: NSObject {
    let connection: Connection
    private var starts: [String: Double] = [:]
    private var failed: Set<String> = []

    private var skipReasons: [String: String] = [:]

    /// XCTest's internal observation of an XCTSkip, with its message.
    @objc(testCase:didRecordSkipWithDescription:sourceCodeContext:)
    func testCase(_ testCase: NSObject, didRecordSkipWithDescription description: NSString, sourceCodeContext: NSObject?) {
        skipReasons[XCTestSide.id(testCase)] = description as String
    }

    init(connection: Connection) {
        self.connection = connection
        SkipMessages.install()
    }

    @objc func testCaseWillStart(_ testCase: NSObject) {
        let id = XCTestSide.id(testCase)
        starts[id] = CFAbsoluteTimeGetCurrent()
        connection.send(["event": "started", "id": id])
    }

    @objc(testCase:didRecordIssue:) func testCase(_ testCase: NSObject, didRecord issue: NSObject) {
        let id = XCTestSide.id(testCase)
        let message = (issue.value(forKey: "compactDescription") as? String) ?? "\(issue)"
        var location = ""
        if let context = issue.value(forKey: "sourceCodeContext") as? NSObject,
           let loc = context.value(forKey: "location") as? NSObject,
           let url = loc.value(forKey: "fileURL") as? URL {
            location = "\(url.lastPathComponent):\(loc.value(forKey: "lineNumber") as? Int ?? 0)"
        }
        // XCTIssue.type: 0 assertionFailure, 1 thrownError, 2 uncaughtException, 3 performanceRegression, 4 system, 5 unmatchedExpectedFailure
        failed.insert(id)
        connection.send(["event": "issue", "id": id, "message": message, "location": location, "failure": true])
    }

    @objc func testCaseDidFinish(_ testCase: NSObject) {
        let id = XCTestSide.id(testCase)
        // Key-value lookups only for keys the object has: an unknown key throws an
        // Objective-C exception, which would take the host down.
        func value(_ o: NSObject?, _ key: String) -> Any? {
            guard let o, o.responds(to: NSSelectorFromString(key)) else { return nil }
            return o.value(forKey: key)
        }
        let run = value(testCase, "testRun") as? NSObject
        let skipped = value(run, "hasBeenSkipped") as? Bool ?? false
        var reason = skipReasons[id] ?? ""
        if skipped && reason.isEmpty, let run { reason = SkipMessages.message(for: run) ?? "" }
        if skipped && reason.isEmpty {
            if let context = value(run, "skippedTestContext") as? NSObject {
                reason = (value(context, "message") as? String) ?? (value(context, "explanation") as? String) ?? ""
            }
        }
        if skipped && reason.isEmpty {
            for holder in [run, testCase] {
                for key in ["skip", "skipIssue", "_skip"] {
                    if let skip = value(holder, key) as? NSObject {
                        reason = (value(skip, "message") as? String) ?? (value(skip, "summary") as? String) ?? (value(skip, "compactDescription") as? String) ?? ""
                    }
                    if !reason.isEmpty { break }
                }
                if !reason.isEmpty { break }
            }
        }
        let result = skipped ? "skipped" : (failed.contains(id) ? "failed" : "passed")
        let seconds = starts[id].map { CFAbsoluteTimeGetCurrent() - $0 } ?? 0
        connection.send(["event": "ended", "id": id, "result": result, "seconds": seconds, "reason": reason])
    }
}

/// Runs `body` on the main thread as a run loop block and waits for it. Unlike
/// DispatchQueue.main.sync, the main queue keeps draining while `body` spins
/// the run loop (an XCTest wait, an expectation fulfilled from main-queue work).
/// The app's scene connects a moment after launch, and tests that look for
/// it (`connectedScenes.first as? UIWindowScene`) found none when they ran
/// first. The first run waits for it, up to 3 s: without a window server it
/// never comes.
enum Scenes {
    private static var waited = false

    static func waitForFirst() {
        guard !waited else { return }
        waited = true
        guard Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") != nil else { return }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, onMainRunLoop({ UIApplication.shared.connectedScenes.isEmpty }) { usleep(50_000) }
    }
}

func onMainRunLoop<T>(_ body: @escaping () -> T) -> T {
    if Thread.isMainThread { return body() }
    var result: T?
    let done = DispatchSemaphore(value: 0)
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
        result = body()
        done.signal()
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
    done.wait()
    return result!
}

/// XCTSkip's message: XCTest hands it to the test run and keeps no getter for
/// it, so the run's recordSkip method is wrapped to note it.
enum SkipMessages {
    private static var installed = false
    private static var messages: [ObjectIdentifier: String] = [:]
    private static let lock = NSLock()

    static func install() {
        guard !installed, let cls = NSClassFromString("XCTestCaseRun") else { return }
        installed = true
        let sel = NSSelectorFromString("recordSkipWithDescription:sourceCodeContext:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias Record = @convention(c) (AnyObject, Selector, NSString?, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(m), to: Record.self)
        let block: @convention(block) (AnyObject, NSString?, AnyObject?) -> Void = { run, description, context in
            if let description {
                lock.lock(); messages[ObjectIdentifier(run)] = description as String; lock.unlock()
            }
            original(run, sel, description, context)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    static func message(for run: NSObject) -> String? {
        lock.lock(); defer { lock.unlock() }
        // XCTest words it "Test skipped - <message>"; the message is what matters
        // (one starting "simulator only" marks a simulator-only test).
        return messages.removeValue(forKey: ObjectIdentifier(run)).map {
            $0.hasPrefix("Test skipped - ") ? String($0.dropFirst("Test skipped - ".count)) : $0
        }
    }
}
