// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Testing
@testable import SimlessDemo

struct DemoDataTests {
    @Test func feedIsDeterministic() {
        #expect(DemoData.feed.count == 24)
        #expect(DemoData.feed.first?.title == "Update 1: weekly summary")
    }

    @Test func profileHasThreeStats() {
        #expect(DemoData.profile.stats.map(\.label) == ["Posts", "Following", "Followers"])
    }
}
