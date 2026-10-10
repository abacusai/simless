// SPDX-License-Identifier: MIT-0
// Copyright 2026 Abacus.AI, Inc. MIT No Attribution: you may use, copy, modify
// and distribute this file without restriction or attribution. Provided "as is",
// without warranty of any kind.

// Fixtures for `simless render`: each one builds a screen in a deterministic state.
#if DEBUG && os(iOS)
import SwiftUI

@MainActor
func simlessFixtures(_ r: SimlessRegistry) {
    r.add("Welcome") { WelcomeView() }
    r.add("Feed") { FeedView(items: DemoData.feed) }
    r.add("Article") { ArticleView(article: DemoData.article) }
    r.add("Settings") { SettingsView() }
    r.add("Login") { LoginView() }
    r.add("Login.error") { LoginView(showError: true) }
    r.add("Profile") { ProfileView(profile: DemoData.profile) }
}
#endif
