// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// Xcode's JSON project format (`project.xcproj`), read like a project.pbxproj.
final class XCProjectTests: XCTestCase {
    var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "simless-xcproj-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: "\(root!)/ios/App.xcodeproj", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root!)/ios/Packages/Kit", withIntermediateDirectories: true)
        try "".write(toFile: "\(root!)/ios/Packages/Kit/Package.swift", atomically: true, encoding: .utf8)
        // JSON5 the way Xcode 27 writes it: trailing commas, settings per configuration.
        try """
        {
          // a comment
          "packages": [
            { "kind": "local", "path": "Packages/Kit", },
            { "kind": "remote", "url": "https://example.com/remote", },
          ],
          "files": [
            { "kind": "folder", "path": "App", "target-membership": [ "App" ] },
            { "kind": "group", "path": "Tests", "children": [
              { "kind": "folder", "path": "UI", "target-membership": [ "AppUITests" ] },
              { "kind": "group", "name": "Virtual", "children": [
                { "kind": "folder", "path": "<PROJECT>/Shared", "target-membership": [ "App", "Watch" ] },
              ] },
            ] },
            { "kind": "group", "name": "Products", "children": [
              { "path": "<PRODUCTS>/App.app", "type": "wrapper.application" },
            ] },
          ],
          "targets": [
            { "name": "App", "product-type": "application" },
            { "name": "AppUITests", "product-type": "bundle.ui-testing" },
            { "name": "Watch", "product-type": "application", "build-settings": { "SDKROOT[config=Debug]": "watchos", "SDKROOT": "iphoneos" } },
            { "name": "Agg", "kind": "aggregate" },
          ],
          "build-settings": { "SDKROOT": "iphoneos", },
        }
        """.write(toFile: "\(root!)/ios/App.xcodeproj/project.xcproj", atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
    }

    func testReadsTargetsFoldersAndSDK() throws {
        let p = try XCTUnwrap(XCProject.load("\(root!)/ios/App.xcodeproj"))
        XCTAssertEqual(Set(p.targets.keys), ["App", "AppUITests", "Watch"])
        XCTAssertEqual(p.targets["App"]?.folders, ["App", "Shared"])
        XCTAssertEqual(p.targets["AppUITests"]?.folders, ["Tests/UI"])
        XCTAssertEqual(p.targets["Watch"]?.folders, ["Shared"])
        XCTAssertEqual(p.targets.values.filter(\.isUITests).map(\.name), ["AppUITests"])
        XCTAssertEqual(p.targets["App"]?.sdkroot, "iphoneos")
        XCTAssertEqual(p.targets["Watch"]?.sdkroot, "watchos")
        XCTAssertEqual(p.packages, ["Packages/Kit"])
    }

    func testWorkspaceUsesTheJSONProject() throws {
        let ws = Workspace(root: root, config: Config(project: "ios/App.xcodeproj", scheme: "App", appTarget: "App", testTarget: "",
                                                     kitDir: "ios/App/Simless", sourceDirs: ["ios/App"]))
        XCTAssertEqual(Workspace.localPackages(root: root, project: ws.config.project), ["ios/Packages/Kit"])
        XCTAssertEqual(SimulatorLane.platform("Watch", ws: ws), "watchOS")
        XCTAssertEqual(SimulatorLane.platform("App", ws: ws), "iOS")
        XCTAssertEqual(UITestEngine.uiTestTargets(ws), ["AppUITests"])
    }

    func testNoJSONFileMeansAPBXProject() {
        XCTAssertNil(XCProject.load("\(root!)/missing.xcodeproj"))
    }
}
