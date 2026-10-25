// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// What the app's last full build was built from. Tests run against that build
/// (the app and its hosted test targets live in the installed slot), so a run
/// must never use it once a file it was built from has changed: the run builds
/// again first, or doesn't run.
enum BuildState {
    struct Entry: Codable {
        var size: Int
        var mtime: Double
        var digest: String
        var ctime: Double?   // status change time, which tar and rsync can't set
        var inode: Int?
    }

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

    /// The inputs as they are now.
    static func current(_ ws: Workspace, previous: [String: Entry] = [:]) -> [String: Entry] {
        entries(inputs(ws), previous: previous)
    }

    /// Each file's size, times and content digest. The digest decides whether a
    /// file changed. A previous digest is reused only for a file nothing has
    /// touched since: same size, modification time, status change time and
    /// inode. A build machine that replaces the sources on every sync (rm -rf,
    /// then untar) keeps modification times, so they alone can't say a file is
    /// the same; the new files' status change times say it may not be.
    static func entries(_ files: [String], previous: [String: Entry] = [:]) -> [String: Entry] {
        var out: [String: Entry] = [:]
        for file in files {
            var st = stat()
            guard stat(file, &st) == 0 else { continue }
            let size = Int(st.st_size)
            let time = Double(st.st_mtimespec.tv_sec) - Date.timeIntervalBetween1970AndReferenceDate + Double(st.st_mtimespec.tv_nsec) / 1e9
            let changed = Double(st.st_ctimespec.tv_sec) + Double(st.st_ctimespec.tv_nsec) / 1e9
            let inode = Int(st.st_ino)
            if let p = previous[file], p.size == size, p.mtime == time, p.ctime == changed, p.inode == inode { out[file] = p; continue }
            out[file] = Entry(size: size, mtime: time, digest: Workspace.digest(file) ?? "", ctime: changed, inode: inode)
        }
        return out
    }

    /// Files whose content differs between two records (added and removed ones too).
    static func changed(from built: [String: Entry], to now: [String: Entry]) -> [String] {
        Set(built.keys).union(now.keys).filter { built[$0]?.digest != now[$0]?.digest }.sorted()
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
        return changed(from: built, to: current(ws, previous: built))
    }

    /// Changed files a hot-reload patch can't carry: everything but Swift
    /// sources (asset catalogs, string catalogs, plists, a package manifest).
    /// Only a full build puts them in the app, where `Bundle.module` and
    /// `Bundle.main` look first. Empty when there's no record of the last build.
    static func changedResources(_ ws: Workspace) -> [String] {
        guard let built = load(ws) else { return [] }
        return resources(changed(from: built, to: current(ws, previous: built)))
    }

    /// The files of a change list that aren't Swift code: the manifest counts
    /// as a resource, since it can add or drop resources.
    static func resources(_ changed: [String]) -> [String] {
        changed.filter { !$0.hasSuffix(".swift") || ($0 as NSString).lastPathComponent == "Package.swift" }
    }

    /// Whether a package test run can skip the app's build: every changed file
    /// is Swift code in a local package, which the package's test build
    /// compiles from current sources. A changed resource can't be skipped: the
    /// tests run in the app, and a package's `Bundle.module` finds the app's
    /// copy of its resource bundle (from the last full build) before the one
    /// next to the test bundle.
    static func onlyPackageCode(_ changed: [String], packageDirs: [String]) -> Bool {
        let dirs = packageDirs.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        return resources(changed).isEmpty && changed.allSatisfy { f in dirs.contains { f.hasPrefix($0) } }
    }
}
