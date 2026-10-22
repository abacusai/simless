// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// Just enough of a project.pbxproj to know which folders Xcode compiles
/// straight from disk: the synchronized folders (Xcode 16+) a target lists.
/// A synchronized folder can sit inside classic groups, and its `path` is then
/// relative to its parent group, so paths are resolved through the group tree.
enum PBX {
    struct Object {
        let isa: String
        let path: String?
        let sourceTree: String?
        let children: [String]
        let body: String
    }

    private static let start = try! NSRegularExpression(pattern: #"^\t\t([0-9A-Za-z]+) /\*[^\n]*?\*/ = \{"#, options: .anchorsMatchLines)
    private static let ids = try! NSRegularExpression(pattern: #"([0-9A-Za-z]{16,}) /\*"#)

    private static func field(_ name: String, _ body: String) -> String? {
        guard let r = body.range(of: #"\b\#(name) = ("[^"]*"|[^;]+);"#, options: .regularExpression) else { return nil }
        let v = String(body[r]).dropFirst(name.count + 3).dropLast()
        return v.hasPrefix("\"") ? String(v.dropFirst().dropLast()) : String(v)
    }

    private static func list(_ name: String, _ body: String) -> [String] {
        guard let r = body.range(of: #"\b\#(name) = \(([^)]*)\)"#, options: .regularExpression) else { return [] }
        let s = String(body[r])
        return ids.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map { (s as NSString).substring(with: $0.range(at: 1)) }
    }

    static func objects(_ pbx: String) -> [String: Object] {
        let ns = pbx as NSString
        var out: [String: Object] = [:]
        for m in start.matches(in: pbx, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            let from = NSMaxRange(m.range)
            let lineEnd = ns.range(of: "\n", range: NSRange(location: from, length: ns.length - from)).location
            let rest = ns.substring(with: NSRange(location: from, length: (lineEnd == NSNotFound ? ns.length : lineEnd) - from))
            let body: String
            if rest.hasSuffix("};") {
                body = rest   // one line
            } else {
                let end = ns.range(of: "\n\t\t};", range: NSRange(location: from, length: ns.length - from)).location
                guard end != NSNotFound else { continue }
                body = ns.substring(with: NSRange(location: from, length: end - from))
            }
            out[id] = Object(isa: field("isa", body) ?? "", path: field("path", body), sourceTree: field("sourceTree", body),
                             children: list("children", body), body: body)
        }
        return out
    }

    /// The synchronized folders `target` compiles, relative to the project's directory.
    static func synchronizedFolders(target: String, pbx: String) -> [String] {
        let objects = objects(pbx)
        var parent: [String: String] = [:]
        for (id, o) in objects { for c in o.children { parent[c] = id } }
        func fullPath(_ id: String, depth: Int = 0) -> String? {
            guard depth < 64, let o = objects[id] else { return nil }
            if o.sourceTree == "SOURCE_ROOT" { return o.path ?? "" }
            guard o.sourceTree == "<group>" else { return nil }
            let up = parent[id].flatMap { fullPath($0, depth: depth + 1) } ?? ""
            guard let p = o.path, !p.isEmpty else { return up }
            return up.isEmpty ? p : "\(up)/\(p)"
        }
        guard let t = objects.values.first(where: { $0.isa == "PBXNativeTarget" && field("name", $0.body) == target }) else { return [] }
        return list("fileSystemSynchronizedGroups", t.body).compactMap { fullPath($0) }
    }
}
