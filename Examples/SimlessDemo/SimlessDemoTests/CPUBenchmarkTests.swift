// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation
import Testing

/// Plain CPU work, to compare simless's speed with a simulator's: each case
/// sorts and hashes a large array. `simless test` and an xcodebuild run in a
/// simulator should take about as long for the whole test.
nonisolated struct CPUBenchmarkTests {
    @Test(arguments: 0..<8)
    func sortsAndHashesALargeArray(seed: Int) {
        var generator = SplitMix(seed: UInt64(seed))
        var values = (0..<400_000).map { _ in generator.next() }
        var digest: UInt64 = 0
        for round in 0..<6 {
            values.sort()
            for (i, v) in values.enumerated() where i % 3 == round % 3 { digest = digest &* 31 &+ v }
            values = values.map { $0 ^ (digest >> 7) }
        }
        #expect(digest != 0)
    }

    /// Generic-heavy string work, like a fuzzy word matcher in a debug build:
    /// edit distances between words, through `contains(where:)` and Sets.
    @Test(arguments: 0..<8)
    func matchesWordsWithTypos(seed: Int) {
        var generator = SplitMix(seed: UInt64(seed))
        let letters = Array("abcdefghijklmnopqrstuvwxyzčćšžđ")
        let words = (0..<2_500).map { _ in String((0..<(4 + Int(generator.next() % 8))).map { _ in letters[Int(generator.next() % UInt64(letters.count))] }) }
        let vocabulary = Set(words)
        var found = 0
        for word in words.prefix(600) {
            let typo = String(word.dropLast()) + "x"
            if vocabulary.contains(typo) { found += 1 }
            if words.contains(where: { Self.editDistance(Array($0), Array(typo), limit: 1) <= 1 }) { found += 1 }
        }
        #expect(found > 0)
    }

    static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                current[j + 1] = Swift.min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// A small deterministic random number generator.
nonisolated struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
