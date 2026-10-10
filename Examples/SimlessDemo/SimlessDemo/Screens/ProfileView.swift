// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import SwiftUI

/// Equal-width stats, wrapping tags and a Menu with a custom label (a control
/// the Mac exposes differently to accessibility).
struct ProfileView: View {
    let profile: DemoData.Profile

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Circle()
                    .fill(.tint.opacity(0.2))
                    .frame(width: 96, height: 96)
                    .overlay(Text("AR").font(.title.bold()).foregroundStyle(.tint))
                    .accessibilityHidden(true)
                VStack(spacing: 4) {
                    Text(profile.name).font(.title2.bold())
                    Text(profile.handle).foregroundStyle(.secondary)
                }
                Text(profile.bio)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                HStack {
                    ForEach(profile.stats, id: \.label) { stat in
                        VStack {
                            Text(stat.value).font(.headline)
                            Text(stat.label).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)
                    }
                }
                TagWrap(tags: profile.tags)
                HStack(spacing: 12) {
                    Button("Follow") {}
                        .buttonStyle(.borderedProminent)
                    Menu {
                        Button("Share profile") {}
                        Button("Copy link") {}
                        Button("Report", role: .destructive) {}
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)
        }
    }
}

/// Tags that wrap onto as many lines as they need.
struct TagWrap: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
