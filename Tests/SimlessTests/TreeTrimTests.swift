// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// What a tree costs an agent: long labels cut in text, and `hide`.
final class TreeTrimTests: XCTestCase {
    let trace = String(repeating: "log ", count: 1203)   // 4,812 characters

    func render(_ nodes: [[String: Any]], json: Bool = false, hide: [String] = []) throws -> String {
        var options = Render.Options(dark: false, device: "iphone", json: json)
        options.hide = hide
        let r: [String: Any] = ["ok": true, "nodes": nodes, "renderMs": 1.0]
        return try Render.format(r, fixture: "Auth", options: options, canvas: Render.canvas("iphone")).text
    }

    var nodes: [[String: Any]] {
        [["role": "element", "label": trace, "id": "debugTrace", "frame": [200.0, 467, 1, 1]],
         ["role": "button", "label": "Continue", "id": "authContinueButton", "frame": [24.0, 794, 354, 48]]]
    }

    func testLongLabelsAreCutInTextAndKeptInJSON() throws {
        let text = try render(nodes)
        XCTAssertTrue(text.contains("\"" + String(trace.prefix(200)) + "…\" (4,812 chars) #debugTrace"))
        XCTAssertLessThan(text.count, 1_000)
        XCTAssertTrue(try render(nodes, json: true).contains(trace))
        XCTAssertEqual(Render.quoted("Continue"), "\"Continue\"")
    }

    func testHideDropsNodesFromTreesAndChecks() throws {
        // The 1×1 trace element is a small tap target only if it's an issue at all; hide it by id.
        for hide in [["#debugTrace"], ["log log"]] {
            let text = try render(nodes, hide: hide)
            XCTAssertFalse(text.contains("debugTrace"))
            XCTAssertTrue(text.contains("hidden: 1 element(s)"))
            XCTAssertTrue(text.contains("#authContinueButton"))
            XCTAssertFalse(try render(nodes, json: true, hide: hide).contains("debugTrace"))
        }
        let issues = Render.findIssues(nodes.filter { !Render.hidden($0, ["#debugTrace"]) }, width: 402, height: 874)
        XCTAssertEqual(issues, [])
        XCTAssertFalse(Render.hidden(nodes[1], ["#debugTrace", ""]))
    }
}
