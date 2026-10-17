// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import DemoFormat
import DemoKit
import Testing

struct DemoKitTests {
    @Test func greetsByName() {
        #expect(Greeting.text(for: "Ana") == "Welcome, Ana")
        #expect(Greeting.text(for: "") == "Welcome")
    }

    @Test func countsInSingularAndPlural() {
        #expect(Count.text(1, "note") == "1 note")
        #expect(Count.text(3, "note") == "3 notes")
    }
}
