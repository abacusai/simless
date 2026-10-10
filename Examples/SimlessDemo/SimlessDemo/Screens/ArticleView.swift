// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import SwiftUI

/// Long wrapped text in a scroll view: where line breaks can differ.
struct ArticleView: View {
    let article: DemoData.Article

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(article.title)
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(article.byline)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(article.paragraphs, id: \.self) { paragraph in
                    Text(paragraph).font(.body)
                }
            }
            .padding(20)
        }
    }
}
