// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// App-wide state that every screen talks to, like a production app's store.
/// It names screens (for analytics) without building any of them. Hot reload
/// once counted that as a path from every screen to every other one, so an edit
/// to one screen patched all of them; CI checks that it patches only the edit.
final class AppModel {
    static let shared = AppModel()

    private static let screens: [(type: Any.Type, name: String)] = [
        (WelcomeView.self, "welcome"), (FeedView.self, "feed"), (ArticleView.self, "article"),
        (SettingsView.self, "settings"), (LoginView.self, "login"), (ProfileView.self, "profile"), (TabsView.self, "tabs"),
    ]

    private(set) var shown: [String] = []

    func didShow(_ screen: Any.Type) {
        if let name = Self.screens.first(where: { $0.type == screen })?.name { shown.append(name) }
    }
}
