// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// What the app's last full build was built from. Tests run against that build
/// (the app and its hosted test targets live in the installed slot), so a run
/// must never use it once a file it was built from has changed: the run builds
/// again first, or doesn't run.
enum BuildState {
    struct Entry: Codable { var size: Int; var mtime: Double; var digest: String }

    static func path(_ ws: Workspace) -> String { "\(ws.work)/build-inputs.json" }

    /// Folders under the project and the local packages that aren't build inputs.
    private static let skipped: Set<String> = [".git", ".build", ".swiftpm", "DerivedData", "build", "Pods", "node_modules", "xcuserdata"]

    /// Every file the app's build can read: everything under the project's
    /// folder and the local packages, minus build output and the UI test
    /// sources (simless builds those itself, from current sources, every run).
    static func inputs(_ ws: Workspace) -> [String] {
        let uiSources = Set(UITestEngine.targets(ws, includingUnbuilt: true).flatMap(\.sources))
        let roots = [ws.projectDir] + ws.packages.map { URL(fileURLWithPath: "\(ws.root)/\($0)").standardizedFileURL.path }
        var out = Set<String>()
        let fm = FileManager.default
        for root in Set(roots) {
            guard let e = fm.enumerator(atPath: root) else { continue }
            while let rel = e.nextObject() as? String {
                let name = (rel as NSString).lastPathComponent
                if skipped.contains(name) || name.hasSuffix(".simless.xcodeproj") || name.hasSuffix(".simless.xctestplan") || name.hasPrefix(".") {
                    if e.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { e.skipDescendants() }
                    continue
                }
                guard e.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
                let path = "\(root)/\(rel)"
                if !uiSources.contains(path) { out.insert(path) }
            }
        }
        return out.sorted()
    }

    /// The inputs as they are now, reusing digests of files whose size and
    /// modification time didn't change.
    static func current(_ ws: Workspace, previous: [String: Entry] = [:]) -> [String: Entry] {
        var out: [String: Entry] = [:]
        for file in inputs(ws) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file) else { continue }
            let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
            let time = (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            if let p = previous[file], p.size == size, p.mtime == time { out[file] = p; continue }
            out[file] = Entry(size: size, mtime: time, digest: Workspace.digest(file) ?? "")
        }
        return out
    }

    static func load(_ ws: Workspace) -> [String: Entry]? {
        FileManager.default.contents(atPath: path(ws)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) }
    }

    static func save(_ ws: Workspace, _ state: [String: Entry]) {
        try? JSONEncoder().encode(state).write(to: URL(fileURLWithPath: path(ws)))
    }

    /// Files added, removed or changed since the last full build (all of
    /// them when there's no record of it).
    static func changed(_ ws: Workspace) -> [String] {
        guard let built = load(ws) else { return ["(no record of what the last build was built from)"] }
        let now = current(ws, previous: built)
        let keys = Set(built.keys).union(now.keys)
        return keys.filter { built[$0]?.digest != now[$0]?.digest }.sorted()
    }
}
