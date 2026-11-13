// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// Just enough of Apple's JSON project format (`project.xcproj`, Xcode 27) to
/// answer what `PBX` answers for a `project.pbxproj`: the targets, their SDK,
/// the synchronized folders they compile and the local packages. Xcode builds
/// the project as it is, simless never converts it.
/// Format: https://github.com/apple/xcode-project-format
struct XCProject {
    struct Target {
        let name: String
        let productType: String
        let sdkroot: String?
        /// Synchronized folders, relative to the project's directory.
        var folders: [String] = []
        var isUITests: Bool { productType.hasSuffix("bundle.ui-testing") }
    }

    var targets: [String: Target] = [:]
    /// Local package paths, relative to the project's directory.
    var packages: [String] = []

    /// The project's JSON file, when it has one, or nil (a project.pbxproj project).
    static func load(_ bundle: String) -> XCProject? {
        let path = "\(bundle)/project.xcproj"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: Any] else { return nil }
        return XCProject(json: json)
    }

    init(json: [String: Any]) {
        // Build settings can be a string or a list, and per configuration (`KEY[config=Debug]`).
        func setting(_ key: String, _ object: [String: Any]) -> String? {
            let settings = object["build-settings"] as? [String: Any] ?? [:]
            let value = settings["\(key)[config=Debug]"] ?? settings[key]
            return value as? String ?? (value as? [String])?.joined(separator: " ")
        }
        let projectSDK = setting("SDKROOT", json)
        for t in json["targets"] as? [[String: Any]] ?? [] where (t["kind"] as? String ?? "native") == "native" {
            guard let name = t["name"] as? String else { continue }
            targets[name] = Target(name: name, productType: t["product-type"] as? String ?? "",
                                   sdkroot: setting("SDKROOT", t) ?? projectSDK)
        }
        for p in json["packages"] as? [[String: Any]] ?? [] where p["kind"] as? String == "local" {
            if let path = p["path"] as? String { packages.append(path) }
        }
        // A file's `path` is relative to its group's, or to the project's
        // directory with `<PROJECT>/`. Other bases (`<PRODUCTS>`, `<SDKROOT>`)
        // and absolute paths are never source folders of the project.
        func resolve(_ path: String?, in parent: String) -> String? {
            guard let path, !path.isEmpty else { return parent }
            if path.hasPrefix("<PROJECT>/") { return String(path.dropFirst("<PROJECT>/".count)) }
            if path.hasPrefix("<") || path.hasPrefix("/") { return nil }
            return parent.isEmpty ? path : "\(parent)/\(path)"
        }
        func walk(_ files: [[String: Any]], _ parent: String) {
            for f in files {
                guard let path = resolve(f["path"] as? String, in: parent) else { continue }
                switch f["kind"] as? String {
                case "group": walk(f["children"] as? [[String: Any]] ?? [], path)
                case "folder":
                    for name in f["target-membership"] as? [String] ?? [] { targets[name]?.folders.append(path) }
                default: break
                }
            }
        }
        walk(json["files"] as? [[String: Any]] ?? [], "")
    }
}
