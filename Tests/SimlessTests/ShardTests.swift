// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
@testable import simless

/// One big test target split over hosts by class.
final class ShardTests: XCTestCase {
    let app = TestEngine.Target(name: "AppTests", module: "AppTests", bundle: "/x/AppTests.xctest")
    let kit = TestEngine.Target(name: "KitTests", module: "KitTests", bundle: "/x/KitTests.xctest")

    func testOneTargetIsSplitOverTheHosts() {
        let classes = ["AppTests": (1...10).map { "AppTests/C\($0)" }]
        let shards = TestEngine.shard([[app]], hosts: 4, classes: classes, weights: [:])
        XCTAssertEqual(shards.count, 4)
        // The first host runs everything the others don't: nothing is left out.
        XCTAssertNil(shards[0].classes)
        let others = shards.dropFirst().flatMap { $0.classes ?? [] }
        XCTAssertEqual(Set(shards[0].skip), Set(others))
        XCTAssertEqual(others.count + 3, 10)   // the first host keeps 3 by name
        XCTAssertTrue(shards.allSatisfy { $0.targets.map(\.name) == ["AppTests"] })
    }

    func testOnlyTheHeaviestTargetIsSplit() {
        let classes = ["AppTests": (1...8).map { "AppTests/C\($0)" }, "KitTests": (1...8).map { "KitTests/K\($0)" }]
        let shards = TestEngine.shard([[app], [kit]], hosts: 3, classes: classes, weights: ["AppTests": 900, "KitTests": 30])
        XCTAssertEqual(shards.count, 3)
        XCTAssertEqual(shards.filter { $0.targets[0].name == "AppTests" }.count, 2)
    }

    func testFewClassesAreNotSplit() {
        let shards = TestEngine.shard([[app]], hosts: 4, classes: ["AppTests": ["AppTests/A", "AppTests/B", "AppTests/C"]], weights: [:])
        XCTAssertEqual(shards.count, 1)
        XCTAssertNil(shards[0].classes)
        XCTAssertEqual(shards[0].skip, [])
    }

    func testAgentsWaitTwoMinutesForATest() {
        XCTAssertEqual(TestEngine.defaultTimeout(Args(["test", "--agent"])), 120)
        XCTAssertEqual(TestEngine.defaultTimeout(Args(["test"])), ProcessInfo.processInfo.environment["SIMLESS_AGENT"] == "1" ? 120 : 600)
    }
}
