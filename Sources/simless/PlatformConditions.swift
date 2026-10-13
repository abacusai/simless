// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// UI test sources are written for iOS but compiled for macOS, where
/// `#if os(iOS)` is false and `#if os(macOS)` is true. Before compiling, the
/// platform conditions are rewritten to what a test run in an iPhone simulator
/// sees, and test discovery skips the blocks that run wouldn't compile.
enum PlatformConditions {
    static let trueFlag = "SIMLESS_PLATFORM_TRUE"
    static let falseFlag = "SIMLESS_PLATFORM_FALSE"

    private static let rules: [(String, Bool)] = [
        (#"os\(\s*iOS\s*\)"#, true),
        (#"os\(\s*(macOS|OSX|watchOS|tvOS|visionOS|xrOS)\s*\)"#, false),
        (#"targetEnvironment\(\s*macCatalyst\s*\)"#, false),
        (#"targetEnvironment\(\s*simulator\s*\)"#, true),
        (#"canImport\(\s*AppKit\s*\)"#, false),
    ]

    /// The source with its `#if`/`#elseif` platform conditions replaced by
    /// flags the compile defines (true) or doesn't (false). Lines stay where
    /// they are, so file and line numbers don't move.
    static func rewrite(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#if") || trimmed.hasPrefix("#elseif") else { return line }
            var out = line
            for (pattern, value) in rules {
                out = out.replacingOccurrences(of: pattern, with: value ? trueFlag : falseFlag, options: .regularExpression)
            }
            return out
        }.joined(separator: "\n")
    }

    /// Whether any line needs rewriting.
    static func needsRewrite(_ text: String) -> Bool {
        rules.contains { text.range(of: $0.0, options: .regularExpression) != nil }
    }

    /// The lines that are compiled, after `rewrite`: inactive `#if` branches
    /// left out. Conditions it can't judge (custom flags) count as true.
    static func activeLines(_ text: String) -> [Substring] {
        var stack: [(active: Bool, taken: Bool)] = []
        var out: [Substring] = []
        for line in rewrite(text).split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            let parentActive = stack.allSatisfy(\.active)
            if t.hasPrefix("#if ") || t.hasPrefix("#if(") {
                let v = evaluate(String(t.dropFirst(3)))
                stack.append((parentActive && v, v))
            } else if t.hasPrefix("#elseif"), !stack.isEmpty {
                let last = stack.removeLast()
                let v = !last.taken && evaluate(String(t.dropFirst(7)))
                stack.append((stack.allSatisfy(\.active) && v, last.taken || v))
            } else if t.hasPrefix("#else"), !stack.isEmpty {
                let last = stack.removeLast()
                stack.append((stack.allSatisfy(\.active) && !last.taken, true))
            } else if t.hasPrefix("#endif"), !stack.isEmpty {
                stack.removeLast()
            } else if stack.allSatisfy(\.active) {
                out.append(line)
            }
        }
        return out
    }

    /// `!`, `&&`, `||`, parentheses over the two flags; anything else is true.
    static func evaluate(_ expression: String) -> Bool {
        var tokens: [String] = []
        var i = expression.startIndex
        while i < expression.endIndex {
            let c = expression[i]
            if c.isWhitespace { i = expression.index(after: i); continue }
            if "()!".contains(c) { tokens.append(String(c)); i = expression.index(after: i); continue }
            if expression[i...].hasPrefix("&&") || expression[i...].hasPrefix("||") {
                tokens.append(String(expression[i...].prefix(2))); i = expression.index(i, offsetBy: 2); continue
            }
            if expression[i...].hasPrefix("//") { break }
            var j = i
            var depth = 0
            while j < expression.endIndex {
                let d = expression[j]
                if d == "(" { depth += 1 } else if d == ")" { if depth == 0 { break }; depth -= 1 }
                else if depth == 0 && (d.isWhitespace || d == "!" || d == "&" || d == "|") { break }
                j = expression.index(after: j)
            }
            tokens.append(String(expression[i..<j]))
            i = j
        }
        var pos = 0
        func primary() -> Bool {
            guard pos < tokens.count else { return true }
            let t = tokens[pos]; pos += 1
            if t == "!" { return !primary() }
            if t == "(" { let v = or(); if pos < tokens.count, tokens[pos] == ")" { pos += 1 }; return v }
            if t == falseFlag || t == "false" { return false }
            return true
        }
        func and() -> Bool { var v = primary(); while pos < tokens.count, tokens[pos] == "&&" { pos += 1; let r = primary(); v = v && r }; return v }
        func or() -> Bool { var v = and(); while pos < tokens.count, tokens[pos] == "||" { pos += 1; let r = and(); v = v || r }; return v }
        return or()
    }
}
