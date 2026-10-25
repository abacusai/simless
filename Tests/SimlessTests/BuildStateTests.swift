// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// A build machine syncs a project by deleting its sources and untarring fresh
/// ones, which keeps modification times. Content decides what changed.
final class BuildStateTests: XCTestCase {
    var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "simless-buildstate-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: "\(dir!)/src", withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    /// rm -rf the sources, then untar them again (modification times kept).
    func sync(_ files: [String: String]) throws {
        try Shell.check(["/usr/bin/tar", "-cf", "\(dir!)/sync.tar", "-C", dir, "src"])
        try FileManager.default.removeItem(atPath: "\(dir!)/src")
        try Shell.check(["/usr/bin/tar", "-xpf", "\(dir!)/sync.tar", "-C", dir])
        for (name, text) in files {
            let path = "\(dir!)/src/\(name)"
            let date = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as! Date
            try text.write(toFile: path, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
    }

    func testUnchangedContentAfterASyncIsUnchanged() throws {
        try "struct A {}\n".write(toFile: "\(dir!)/src/A.swift", atomically: true, encoding: .utf8)
        let files = ["\(dir!)/src/A.swift"]
        let built = BuildState.entries(files)
        try sync([:])
        XCTAssertEqual(BuildState.changed(from: built, to: BuildState.entries(files, previous: built)), [])
    }

    func testChangedContentWithTheSameSizeAndTimeIsChanged() throws {
        try "struct A {}\n".write(toFile: "\(dir!)/src/A.swift", atomically: true, encoding: .utf8)
        let files = ["\(dir!)/src/A.swift"]
        let built = BuildState.entries(files)
        try sync(["A.swift": "struct B {}\n"])   // same size, modification time put back
        XCTAssertEqual(BuildState.changed(from: built, to: BuildState.entries(files, previous: built)), files)
    }

    /// A new image set in a package's asset catalog is a change, and one a
    /// package test run can't skip the app build for: the tests find the app's
    /// copy of the resource bundle first.
    func testAnAddedImageSetIsAResourceChange() throws {
        let catalog = "\(dir!)/src/Sources/Icons.xcassets"
        try FileManager.default.createDirectory(atPath: catalog, withIntermediateDirectories: true)
        try "struct A {}\n".write(toFile: "\(dir!)/src/Sources/A.swift", atomically: true, encoding: .utf8)
        try "{}\n".write(toFile: "\(catalog)/Contents.json", atomically: true, encoding: .utf8)
        let before = ["\(dir!)/src/Sources/A.swift", "\(catalog)/Contents.json"]
        let built = BuildState.entries(before)
        let set = "\(catalog)/map.imageset"
        try FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
        try "{}\n".write(toFile: "\(set)/Contents.json", atomically: true, encoding: .utf8)
        try "<svg/>\n".write(toFile: "\(set)/map.svg", atomically: true, encoding: .utf8)
        let changed = BuildState.changed(from: built, to: BuildState.entries(before + ["\(set)/Contents.json", "\(set)/map.svg"], previous: built))
        XCTAssertEqual(changed, ["\(set)/Contents.json", "\(set)/map.svg"])
        XCTAssertEqual(BuildState.resources(changed), changed)
        XCTAssertFalse(BuildState.onlyPackageCode(changed, packageDirs: ["\(dir!)/src"]))
    }

    func testOnlyPackageSwiftEditsSkipTheAppBuild() {
        let pkg = "/w/Packages/Kit"
        XCTAssertTrue(BuildState.onlyPackageCode(["\(pkg)/Sources/A/A.swift"], packageDirs: [pkg]))
        XCTAssertFalse(BuildState.onlyPackageCode(["\(pkg)/Package.swift"], packageDirs: [pkg]))
        XCTAssertFalse(BuildState.onlyPackageCode(["\(pkg)/Sources/A/Localizable.xcstrings"], packageDirs: [pkg + "/"]))
        XCTAssertFalse(BuildState.onlyPackageCode(["/w/App/App.swift"], packageDirs: [pkg]))
    }
}
