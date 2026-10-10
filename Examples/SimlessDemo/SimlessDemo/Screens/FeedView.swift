// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import SwiftUI

/// A long list in a navigation stack: most rows are below the fold.
struct FeedView: View {
    let items: [DemoData.FeedItem]

    var body: some View {
        NavigationStack {
            List {
                Section("Today") {
                    ForEach(items.prefix(6)) { FeedRow(item: $0) }
                }
                Section("Earlier") {
                    ForEach(items.dropFirst(6)) { FeedRow(item: $0) }
                }
            }
            .navigationTitle("Feed")
        }
    }
}

struct FeedRow: View {
    let item: DemoData.FeedItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.symbol)
                .frame(width: 28, height: 28)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline)
                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            if item.unread {
                Spacer()
                Circle().fill(.blue).frame(width: 8, height: 8).accessibilityLabel("Unread")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
