// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// The render checks: what they flag, and the Mac's sizes they don't.
final class RenderChecksTests: XCTestCase {
    func issues(_ nodes: [[String: Any]]) -> [String] { Render.findIssues(nodes, width: 402, height: 874) }

    func testSystemSizedControlsArentSmallTapTargets() {
        XCTAssertEqual(issues([
            ["role": "switch", "label": "Auto Correct", "value": "1", "frame": [305.0, 884, 61, 28]],
            ["role": "button", "label": "Text size: 3, Decrement", "id": "Decrement", "frame": [276.0, 462, 47, 32]],
            ["role": "field", "placeholder": "Email", "frame": [24.0, 142, 354, 34]],
        ]), [])
        XCTAssertEqual(issues([["role": "button", "label": "Follow", "frame": [113.0, 472, 73, 34]]]),
                       ["button \"Follow\" tap target 73×34 is smaller than 44×44"])
    }

    func testTextFieldNeedsALabelOrAPlaceholder() {
        XCTAssertEqual(issues([["role": "field", "id": "signInEmailField", "frame": [38.0, 640, 302, 22]]]),
                       ["text field without accessibility label or placeholder #signInEmailField @38,640 302×22"])
        XCTAssertEqual(issues([["role": "field", "label": "Email", "frame": [38.0, 640, 302, 44]]]), [])
    }

    func testUnlabeledSwitchIsStillFlagged() {
        XCTAssertEqual(issues([["role": "switch", "value": "0", "frame": [305.0, 456, 61, 28]]]),
                       ["switch without accessibility label @305,456 61×28"])
    }
}
