// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

/// A greeting for the demo's welcome screen.
public enum Greeting {
    public static func text(for name: String) -> String { name.isEmpty ? "Welcome" : "Welcome, \(name)" }
}
