// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// Follows xcodebuild's test output as it streams: which tests are running,
/// what passed and failed, and crashes. XCTest and Swift Testing write to the
/// same stream, and when their output interleaves, lines can carry invisible
/// characters (U+200B) or start mid-line, so events are matched anywhere in a
/// line after removing them.
struct TestOutput {
    private(set) var running: [String: [Double]] = [:]   // test -> start times (names repeat across suites)
    private(set) var started: Set<String> = []
    private(set) var passed = 0, failed = 0
    private(set) var crashes: [String] = []
    private(set) var lastOutput = now()
    private var fatal: String?          // the last "Fatal error" message, for the crash it causes
    private var crashKeys: Set<String> = []
    private var reportedSinceBundle = false

    private static let xctestCase = try! NSRegularExpression(
        pattern: #"Test Case '-\[(?:[\w.]+\.)?(\w+) (\w+)\]' (started|passed|failed|skipped)"#)
    private static let swiftTest = try! NSRegularExpression(
        pattern: #"(?:^|\s)Test (?!run |Suite |Case |case )(.+?) (started|passed after|failed after|skipped)"#)
    /// "param(_:) with 3 test cases passed": the name without the count.
    private static let caseCount = try! NSRegularExpression(pattern: #" with \d+ test cases?$"#)

    /// SF Symbols glyphs (private use), invisible format characters (U+200B,
    /// U+FEFF, ...) and control characters, anywhere in the line.
    static func normalize(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in raw.unicodeScalars {
            switch s.properties.generalCategory {
            case .format, .privateUse, .control where s != "\t": continue
            default: scalars.append(s)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    static func isFailure(_ l: String) -> Bool {
        // XCTest ("<file>:<line>: error: -[Class test] : ..."), Swift Testing
        // ("Test x() recorded an issue at ..." / "... failed after"), and xcodebuild errors.
        l.contains(": error: -[") || l.hasPrefix("xcodebuild: error:") || l.contains("' failed (")
            || l.contains(") recorded an issue") || (l.contains("Test ") && l.contains(" failed after") && !l.contains("Test run with"))
    }

    /// Takes one line of output; returns the lines worth showing right away.
    mutating func consume(_ raw: String, at time: Double = now()) -> [String] {
        let line = Self.normalize(raw)
        guard !line.isEmpty else { return [] }
        lastOutput = time
        var show: [String] = []
        let range = NSRange(line.startIndex..., in: line)
        var name: String?, event: String?
        if let m = Self.xctestCase.firstMatch(in: line, range: range), let c = Range(m.range(at: 1), in: line),
           let f = Range(m.range(at: 2), in: line), let e = Range(m.range(at: 3), in: line) {
            (name, event) = ("\(line[c])/\(line[f])", String(line[e]))
        } else if let m = Self.swiftTest.firstMatch(in: line, range: range),
                  let n = Range(m.range(at: 1), in: line), let e = Range(m.range(at: 2), in: line) {
            let full = String(line[n])
            name = Self.caseCount.stringByReplacingMatches(in: full, range: NSRange(full.startIndex..., in: full), withTemplate: "")
            event = String(line[e])
        }
        if let name, let event {
            if event == "started" {
                running[name, default: []].append(time)
                started.insert(name)
            } else if var starts = running[name] {
                starts.removeFirst()
                running[name] = starts.isEmpty ? nil : starts
            }
            if event.hasPrefix("passed") { passed += 1 }
            if event.hasPrefix("failed") { failed += 1 }
        }
        if Self.isFailure(line) { show.append(line) }

        // Crashes: a trap prints "Fatal error", xcodebuild then restarts the
        // host (twice) and finally reports the crash for the whole bundle.
        if let r = line.range(of: "Fatal error:") {
            let file = line[..<r.lowerBound].split(separator: " ").last.map { ($0 as NSString).lastPathComponent } ?? ""
            fatal = "\(file) Fatal error:\(line[r.upperBound...])".trimmingCharacters(in: .whitespaces)
        }
        if line.contains("Restarting after unexpected exit, crash, or test timeout") {
            // Swift Testing runs tests in parallel, so several can be running;
            // the latest started are the likeliest. The trap message says where.
            let victims = running.compactMap { k, v in v.max().map { (k, $0) } }.sorted { $0.1 > $1.1 }.map(\.0)
            running = [:]
            let names = victims.prefix(3).joined(separator: ", ") + (victims.count > 3 ? " and \(victims.count - 3) more" : "")
            let key = fatal ?? names
            if !crashKeys.contains(key) {
                crashKeys.insert(key)
                show += record("\(fatal ?? "the test host crashed")\(victims.isEmpty ? "" : ", while running \(names)")")
            }
            reportedSinceBundle = true
            fatal = nil
        } else if line.contains("encountered an error ("), line.contains("Crash:") {
            var detail = line.range(of: "Crash:").map { String(line[$0.lowerBound...]) } ?? line
            // Drop the closing parens of the wrapping messages, not the symbol's own.
            while detail.hasSuffix(")"), detail.filter({ $0 == ")" }).count > detail.filter({ $0 == "(" }).count { detail.removeLast() }
            let what = line.components(separatedBy: " encountered an error").first ?? "a test bundle"
            running = [:]
            // xcodebuild's final word on a crash already reported from its restarts.
            if !reportedSinceBundle { show += record("\(what) stopped: \(detail)") }
            reportedSinceBundle = false
        } else if line.hasPrefix("Test crashed with signal") || line.contains("crashed with signal") {
            show += record(line)
        }
        return show
    }

    /// Records a crash once (xcodebuild repeats it for every restart).
    private mutating func record(_ crash: String) -> [String] {
        guard !crashes.contains(crash) else { return [] }
        crashes.append(crash)
        return ["CRASHED: " + crash]
    }

    /// The test that has been running longest, with its start time.
    var oldestRunning: (name: String, since: Double)? {
        running.compactMap { k, v in v.min().map { (k, $0) } }.min { $0.1 < $1.1 }.map { ($0.0, $0.1) }
    }

    /// `--skip` ids whose test still ran (so the id matched nothing).
    func unmatchedSkips(_ skips: [String]) -> [String] {
        skips.filter { id in
            let parts = id.split(separator: "/").map(String.init)
            guard parts.count >= 3, let test = parts.last, let suite = parts.dropLast().last else { return false }
            let base = test.hasSuffix("()") ? String(test.dropLast(2)) : test
            return started.contains { name in
                name == "\(suite)/\(base)" || name == test || name == "\(base)()" || name.hasPrefix(base + "(")
            }
        }
    }
}
