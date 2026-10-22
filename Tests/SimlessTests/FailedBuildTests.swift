// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// The agent's loop: a build fails, the edit is fixed, then a reload. The host
/// still runs the last build that worked, so the reload has to compare with
/// that build's sources and say which code each screen shows.
final class FailedBuildTests: XCTestCase {
    var root: String!
    var ws: Workspace!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "simless-failed-build-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: "\(root!)/Src", withIntermediateDirectories: true)
        try """
            {"project": "App.xcodeproj", "scheme": "App", "appTarget": "App", "testTarget": "", "kitDir": "Src/Simless", "sourceDirs": ["Src"], "device": "iphone"}
            """.write(toFile: "\(root!)/.simless.json", atomically: true, encoding: .utf8)
        ws = try Workspace.load(at: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: ws.work)
        try? FileManager.default.removeItem(atPath: root)
    }

    func write(_ title: String) throws {
        try "struct Notes { var title = \"\(title)\" }\n".write(toFile: "\(root!)/Src/Notes.swift", atomically: true, encoding: .utf8)
    }

    /// `up` as cmdUp does it: snapshot, build, then keep or put back.
    func up(builds: Bool) throws -> String {
        let previous = try? Data(contentsOf: URL(fileURLWithPath: ws.snapshotPath))
        let id = try ws.snapshotSources()
        if builds { ws.pruneSnapshotCopies() } else { ws.restoreSnapshot(previous) }
        return id
    }

    func testAFailedBuildKeepsTheSourcesOfTheBuildTheHostRuns() throws {
        let file = "\(root!)/Src/Notes.swift"
        try write("Notes C")
        let good = try up(builds: true)
        try write("Notes broken")
        _ = try up(builds: false)
        try write("Notes D")
        // The reload compares with "Notes C", the build the host runs.
        XCTAssertEqual(ws.snapshotText(of: file), "struct Notes { var title = \"Notes C\" }\n")
        XCTAssertEqual(ws.changedSources(), [file])
        XCTAssertNotEqual(ws.currentSourcesID(), good)
        // A build that works records the new sources and drops the old copies.
        let next = try up(builds: true)
        XCTAssertEqual(ws.currentSourcesID(), next)
        XCTAssertEqual(ws.changedSources(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "\(ws.work)/snapshot").count, 1)
    }

    func testTheSameSourcesHaveTheSameIDWhereverTheyAre() throws {
        try write("Notes C")
        let here = ws.currentSourcesID()
        let elsewhere = NSTemporaryDirectory() + "simless-failed-build-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: elsewhere) }
        try FileManager.default.copyItem(atPath: root, toPath: elsewhere)
        XCTAssertEqual(try Workspace.load(at: elsewhere).currentSourcesID(), here)
        try write("Notes D")
        XCTAssertNotEqual(ws.currentSourcesID(), here)
    }
}
