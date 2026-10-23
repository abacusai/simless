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
            ["ref": 4, "label": "Mark done", "id": "toggle", "automationOnly": true, "hittable": true],
            ["ref": 5, "label": "Continue", "automationOnly": true, "hittable": true],
        ]
        XCTAssertEqual(Act.find("Continue", in: nodes)?["ref"] as? Int, 2)
        XCTAssertEqual(Act.find("continue", in: nodes)?["ref"] as? Int, 2)
        XCTAssertEqual(Act.find("#signInEmailField", in: nodes)?["ref"] as? Int, 3)
        XCTAssertEqual(Act.find("Email", in: nodes)?["ref"] as? Int, 3)
        XCTAssertEqual(Act.find("Apple", in: nodes)?["ref"] as? Int, 0)
        XCTAssertNil(Act.find("#nope", in: nodes))
        // A button inside a card: by its label or #id when nothing outside a card matches.
        XCTAssertEqual(Act.find("Mark done", in: nodes)?["ref"] as? Int, 4)
        XCTAssertEqual(Act.find("#toggle", in: nodes)?["ref"] as? Int, 4)
        XCTAssertEqual(Act.find("Continue", in: nodes)?["ref"] as? Int, 2)
    }

    func testNestedControlsAreListedUnderTheirCard() {
        let nodes: [[String: Any]] = [
            ["parent": -1, "type": 4],
            ["parent": 0, "type": 9, "label": "Drink Water, 5 day streak", "id": "card"],
            ["parent": 1, "type": 48, "label": "Drink Water", "automationOnly": true],
            ["parent": 1, "type": 1, "automationOnly": true],
            ["parent": 3, "type": 9, "label": "Mark complete", "id": "toggle", "automationOnly": true],
            ["parent": 0, "type": 9, "label": "Add habit"],
        ]
        let groups = Act.nested(["nodes": nodes])
        XCTAssertEqual(groups.map(\.outer), ["Drink Water, 5 day streak"])
        XCTAssertEqual(groups.first?.parts, [["role": "button", "label": "Mark complete", "id": "toggle"]])
    }
}
