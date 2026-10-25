// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// Which of the build's .xctestrun files unit and UI tests run from.
final class XCTestRunTests: XCTestCase {
    var ws: Workspace!

    override func setUpWithError() throws {
        let root = NSTemporaryDirectory() + "simless-tests-" + UUID().uuidString
        ws = Workspace(root: root, config: Config(project: "App.xcodeproj", scheme: "App", appTarget: "App", testTarget: "AppTests",
                                                  kitDir: "App/Simless", sourceDirs: ["App"]))
        try FileManager.default.createDirectory(atPath: ws.products, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: ws.work)
        try? FileManager.default.removeItem(atPath: ws.root)
    }

    private func write(_ name: String, targets: [[String: Any]], modified: Date) throws {
        let plist: [String: Any] = ["TestConfigurations": [["Name": "Test Scheme Action", "TestTargets": targets]],
                                    "__xctestrun_metadata__": ["FormatVersion": 2]]
        let path = "\(ws.products)/\(name)"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
    }

    private let unit: [String: Any] = ["BlueprintName": "AppTests", "TestHostPath": "__TESTROOT__/Debug-iphoneos/App.app"]
    private let ui: [String: Any] = ["BlueprintName": "AppUITests", "IsUITestBundle": true]

    /// A scheme with a test plan for unit tests and one for UI tests: each kind
    /// runs from its plan's file, whichever was written last.
    func testEachKindRunsFromThePlanThatHoldsIt() throws {
        let now = Date()
        for (unitTime, uiTime) in [(now, now.addingTimeInterval(-1)), (now.addingTimeInterval(-1), now)] {
            try write("App_Unit_iphoneos27.1-arm64.xctestrun", targets: [unit], modified: unitTime)
            try write("App_UI_iphoneos27.1-arm64.xctestrun", targets: [ui], modified: uiTime)
            XCTAssertEqual(ws.appXCTestRun.map { ($0 as NSString).lastPathComponent }, "App_Unit_iphoneos27.1-arm64.xctestrun")
            XCTAssertEqual(ws.appXCTestRun(ui: true).map { ($0 as NSString).lastPathComponent }, "App_UI_iphoneos27.1-arm64.xctestrun")
        }
    }

    /// One plan with both kinds, next to a package's own file: the scheme's.
    func testOnePlanServesBothKinds() throws {
        try write("App_App_iphoneos27.1-arm64.xctestrun", targets: [unit, ui], modified: Date().addingTimeInterval(-1))
        try write("DemoKit_DemoKit_iphoneos27.1-arm64.xctestrun", targets: [["BlueprintName": "DemoKitTests"]], modified: Date())
        XCTAssertEqual(ws.appXCTestRun.map { ($0 as NSString).lastPathComponent }, "App_App_iphoneos27.1-arm64.xctestrun")
        XCTAssertEqual(ws.appXCTestRun(ui: true).map { ($0 as NSString).lastPathComponent }, "App_App_iphoneos27.1-arm64.xctestrun")
    }
}
