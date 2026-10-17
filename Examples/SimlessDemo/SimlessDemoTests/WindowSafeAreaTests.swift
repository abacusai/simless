// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import SwiftUI
import Testing
import UIKit

/// A test that shows a view in a window of its own sees an iPhone's window:
/// the status bar's safe area on top, the home indicator's at the bottom.
struct WindowSafeAreaTests {
    @Test func aWindowOnTheSceneHasThePhonesSafeAreas() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: VStack { Text("Title"); Spacer() })
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<5 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(window.safeAreaInsets.top == 62, "The window's top inset is \(window.safeAreaInsets.top)")
        #expect(host.view.safeAreaInsets.top == 62, "The content's top inset is \(host.view.safeAreaInsets.top)")
        #expect(host.view.safeAreaInsets.bottom == 34, "The content's bottom inset is \(host.view.safeAreaInsets.bottom)")
    }
}
