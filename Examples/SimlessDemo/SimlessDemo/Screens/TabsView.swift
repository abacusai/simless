// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import SwiftUI

/// Sections in a tab view that adapts: a tab bar on an iPhone, a floating tab
/// bar on an iPad that opens into a sidebar on request.
struct TabsView: View {
    var body: some View {
        if #available(iOS 18, *) {
            TabView {
                Tab("Feed", systemImage: "newspaper") { FeedView(items: DemoData.feed) }
                Tab("Profile", systemImage: "person") { ProfileView(profile: DemoData.profile) }
                Tab("Settings", systemImage: "gear") { SettingsView() }
            }
            .tabViewStyle(.sidebarAdaptable)
        } else {
            TabView {
                FeedView(items: DemoData.feed).tabItem { Label("Feed", systemImage: "newspaper") }
                ProfileView(profile: DemoData.profile).tabItem { Label("Profile", systemImage: "person") }
                SettingsView().tabItem { Label("Settings", systemImage: "gear") }
            }
        }
    }
}
