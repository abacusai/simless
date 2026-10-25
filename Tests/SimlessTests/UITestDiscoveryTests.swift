// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// UI test classes found in a target's sources.
final class UITestDiscoveryTests: XCTestCase {
    var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "simless-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Classes on a shared base class, in another file, run like Xcode runs them.
    func testClassesOnASharedBaseClassAreFound() throws {
        try """
        import XCTest

        class BaseUITestCase: XCTestCase {
            func launch() {}
        }

        open class JourneyBase: BaseUITestCase {}
        """.write(toFile: "\(dir!)/Base.swift", atomically: true, encoding: .utf8)
        try """
        import XCTest
        import SharedUITestKit

        final class JourneyUITests: JourneyBase {
            func testSignUp() {}
        }

        private struct Fixture {
            func testData() {}
        }

        @MainActor
        final class DirectUITests: XCTest.XCTestCase {
            func testLaunch() {}
        }

        class Helper: NSObject {
            func testNotATest() {}
        }

        final class ElsewhereUITests: SharedUITestCase {
            func testFromAnotherModule() {}
        }
        """.write(toFile: "\(dir!)/Tests.swift", atomically: true, encoding: .utf8)
        let target = UITestEngine.UITarget(name: "AppUITests", sources: ["\(dir!)/Base.swift", "\(dir!)/Tests.swift"])
        let (tests, skipped) = UITestEngine.discover(target)
        XCTAssertEqual(Set(tests.map { "\($0.cls)/\($0.method)" }), ["JourneyUITests/testSignUp", "DirectUITests/testLaunch"])
        XCTAssertEqual(skipped, ["ElsewhereUITests", "Helper"])
    }
}
