// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import SwiftUI

/// The order's action pinned in a bar at regular text sizes and inline in the
/// scroll content at accessibility sizes. The bar stays attached, empty at
/// those sizes, so the scroll position survives a change of text size.
struct CheckoutView: View {
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        let inline = textSize.isAccessibilitySize
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Order summary").font(.title2.bold())
                Text("2 items, 24.00 EUR")
                if inline { placeOrder }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .bottomBar {
            if !inline { placeOrder.padding() }
        }
    }

    private var placeOrder: some View {
        Button("Place order") {}
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
    }
}

private extension View {
    /// `.safeAreaBar` where there is one (iOS 26), else `.safeAreaInset`.
    @ViewBuilder
    func bottomBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 26, *) {
            safeAreaBar(edge: .bottom, content: content)
        } else {
            safeAreaInset(edge: .bottom, content: content)
        }
    }
}

#Preview("Bar") {
    CheckoutView()
}

#Preview("Inline") {
    CheckoutView()
        .environment(\.dynamicTypeSize, .accessibility3)
}
