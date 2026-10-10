// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// Fixed sample content, so every render of every screen is identical.
enum DemoData {
    struct FeedItem: Identifiable, Hashable {
        let id: Int
        let title: String
        let subtitle: String
        let symbol: String
        let unread: Bool
    }

    struct Article {
        let title: String
        let byline: String
        let paragraphs: [String]
    }

    struct Profile {
        let name: String
        let handle: String
        let bio: String
        let stats: [(label: String, value: String)]
        let tags: [String]
    }

    static let feed: [FeedItem] = (1...24).map { i in
        FeedItem(id: i,
                 title: i % 5 == 0 ? "A longer headline that needs two lines to fit on a phone screen, item \(i)" : "Update \(i): weekly summary",
                 subtitle: ["Design", "Engineering", "Support", "Research"][i % 4] + " · \(i)h ago",
                 symbol: ["sparkles", "hammer", "bubble.left", "magnifyingglass"][i % 4],
                 unread: i % 3 == 0)
    }

    static let article = Article(
        title: "How layout differs between platforms",
        byline: "Sample article · 4 min read",
        paragraphs: [
            "This screen is mostly body text. Text is where rendering differences show up first: font metrics decide where each line breaks, and a single word moving to the next line changes the height of everything below it.",
            "Comparing this screen in the iOS Simulator and in simless shows how close the two are for long paragraphs, and where a line break lands differently.",
            "Short paragraph.",
            "The last paragraph sits below the fold, so the render reports it as scroll content rather than as an element outside the screen.",
        ])

    static let profile = Profile(
        name: "Alex Rivera",
        handle: "@alex",
        bio: "Builds small, careful apps. Likes clear type, good defaults and tests that run fast.",
        stats: [("Posts", "128"), ("Following", "312"), ("Followers", "2.4k")],
        tags: ["SwiftUI", "Accessibility", "Design systems", "Testing", "Swift 6"])
}
