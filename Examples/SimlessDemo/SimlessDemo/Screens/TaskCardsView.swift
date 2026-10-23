// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import SwiftUI

/// Cards that are buttons, each with a smaller button inside: VoiceOver reads
/// a card as one button, and XCUITest also sees the button inside it.
struct TaskCardsView: View {
    @State private var done: Set<String> = ["Water the plants"]
    @State private var opened: String?
    private let tasks = ["Water the plants", "Call the bank", "Book a table"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(tasks, id: \.self) { task in
                        Button { opened = task } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(task).font(.headline)
                                    Text(done.contains(task) ? "Done" : "To do").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    if done.contains(task) { done.remove(task) } else { done.insert(task) }
                                } label: {
                                    Image(systemName: done.contains(task) ? "checkmark.circle.fill" : "circle").font(.title)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(done.contains(task) ? "Mark not done" : "Mark done")
                                .accessibilityIdentifier("toggle_\(task)")
                            }
                            .padding()
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("card_\(task)")
                    }
                    if let opened { Text("Opened \(opened)") }
                }
                .padding()
            }
            .navigationTitle("Tasks")
        }
    }
}

#Preview("Cards") {
    TaskCardsView()
}
