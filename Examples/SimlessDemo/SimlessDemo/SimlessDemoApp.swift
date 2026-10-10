// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import SwiftUI

@main
struct SimlessDemoApp: App {
    init() {
        #if DEBUG && os(iOS)
        SimlessHost.startIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// The app's real navigation. simless renders the screens directly through
/// fixtures (Simless/SimlessFixtures.swift), so it never needs to navigate here.
struct RootView: View {
    var body: some View {
        TabView {
            FeedView(items: DemoData.feed).tabItem { Label("Feed", systemImage: "list.bullet") }
            ArticleView(article: DemoData.article).tabItem { Label("Article", systemImage: "doc.text") }
            ProfileView(profile: DemoData.profile).tabItem { Label("Profile", systemImage: "person.crop.circle") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
