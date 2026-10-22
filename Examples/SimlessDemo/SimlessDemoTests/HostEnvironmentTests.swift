// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import XCTest
import UIKit

/// What a simulator gives tests, and a simless test host has to as well.
nonisolated final class HostEnvironmentTests: XCTestCase {
    /// Snapshot tests attach their images.
    @MainActor func testAttachmentsCanBeAdded() {
        add(XCTAttachment(string: "simless"))
    }

    /// A window a test sizes for a snapshot keeps that size.
    @MainActor func testAWindowKeepsTheFrameATestGivesIt() throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("no window scene: the host runs without a window server")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 230)
        window.rootViewController = UIViewController()
        window.isHidden = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(window.bounds.size, CGSize(width: 320, height: 230))
        window.isHidden = true
    }
}
