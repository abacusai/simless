// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

final class ActTests: XCTestCase {
    func testStepsParseInOrder() throws {
        let steps = try Act.parse(["tap", "#login.email", "type", "#login.email", "a@b.com", "swipe", "up", "on", "Feed",
                                   "longpress", "Row 1", "wait", "300", "swipe", "left"])
        XCTAssertEqual(steps.map(\.text), ["tap \"#login.email\"", "type \"a@b.com\" into \"#login.email\"", "swipe up on \"Feed\"",
                                           "longpress \"Row 1\"", "wait 300 ms", "swipe left"])
    }

    func testBadStepsSayWhat() {
        XCTAssertThrowsError(try Act.parse(["type", "#email"])) { XCTAssertTrue("\($0)".contains("the text")) }
        XCTAssertThrowsError(try Act.parse(["swipe", "sideways"])) { XCTAssertTrue("\($0)".contains("sideways")) }
        XCTAssertThrowsError(try Act.parse(["click", "OK"])) { XCTAssertTrue("\($0)".contains("unknown step 'click'")) }
        XCTAssertThrowsError(try Act.parse(["wait", "soon"]))
    }

    func testFindPrefersIdsExactLabelsAndWhatsOnScreen() {
        let nodes: [[String: Any]] = [
            ["ref": 0, "label": "Continue with Apple", "hittable": true],
            ["ref": 1, "label": "Continue", "hittable": false],
            ["ref": 2, "label": "Continue", "hittable": true, "id": "authContinueButton"],
            ["ref": 3, "id": "signInEmailField", "placeholder": "Email", "hittable": true],
            ["ref": 4, "label": "Hidden", "automationOnly": true],
        ]
        XCTAssertEqual(Act.find("Continue", in: nodes)?["ref"] as? Int, 2)
        XCTAssertEqual(Act.find("continue", in: nodes)?["ref"] as? Int, 2)
        XCTAssertEqual(Act.find("#signInEmailField", in: nodes)?["ref"] as? Int, 3)
        XCTAssertEqual(Act.find("Email", in: nodes)?["ref"] as? Int, 3)
        XCTAssertEqual(Act.find("Apple", in: nodes)?["ref"] as? Int, 0)
        XCTAssertNil(Act.find("Hidden", in: nodes))
        XCTAssertNil(Act.find("#nope", in: nodes))
    }
}
