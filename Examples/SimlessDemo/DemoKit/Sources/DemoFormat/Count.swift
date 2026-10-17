// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

/// A count with its noun, singular or plural.
public enum Count {
    public static func text(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}
