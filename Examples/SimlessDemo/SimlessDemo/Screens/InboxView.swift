// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import SwiftUI

/// An empty state until a `.task` loads the messages, then a List. On the Mac
/// the List's rows only reach the screen when simless asks for an update.
struct InboxView: View {
    @State private var messages: [String] = []

    var body: some View {
        NavigationStack {
            Group {
                if messages.isEmpty {
                    ContentUnavailableView("No Messages", systemImage: "tray")
                } else {
                    List(messages, id: \.self) { Text($0) }
                }
            }
            .navigationTitle("Inbox")
        }
        .task {
            try? await Task.sleep(for: .milliseconds(30))
            messages = ["Welcome to the demo", "Your weekly summary", "Someone followed you"]
        }
    }
}

#Preview("Loaded") {
    InboxView()
}
