// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest

/// A base class UI test classes share, as suites often have: the classes on it
/// run with `simless test ui` the way Xcode runs them.
class DemoUITestCase: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func launch(_ lab: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-SimlessDemoLab", lab]
        app.launch()
        return app
    }
}

final class SharedBaseUITests: DemoUITestCase {
    @MainActor
    func testATestOnASharedBaseClassRuns() throws {
        let app = launch("gestures")
        XCTAssertTrue(app.staticTexts["lab.counts"].waitForExistence(timeout: 10))
    }
}
