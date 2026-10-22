// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// Local Swift packages whose views hot reload can patch. Each library target
/// is a module with its own compiler settings; a patch that mixes files from
/// modules with different settings can't be compiled as one module and falls
/// back to a full build.
struct PackageModule: Codable {
    let name: String            // module name, as imported
    let dir: String             // absolute source directory
    let swiftVersion: String    // language mode: "5" or "6"
    let defaultIsolation: String?
    let upcomingFeatures: [String]
    let dependencies: [String]  // modules this one can import (targets in the package, and products)
}

enum Packages {
    /// The package's manifest as JSON. SwiftPM's scratch folder goes to a
    /// temporary place, not a `.build` in the user's package.
    static func dumpPackage(_ dir: String) throws -> String {
        let scratch = "\(Paths.cache)/swiftpm/\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        return try Shell.check(["swift", "package", "--scratch-path", scratch, "dump-package"], cwd: dir, stdoutOnly: true)
    }

    /// Modules of every local package in the config, cached per Package.swift mtime.
    static func modules(ws: Workspace) -> [PackageModule] {
        var result: [PackageModule] = []
        for rel in ws.packages {
            let dir = "\(ws.root)/\(rel)"
            let manifest = "\(dir)/Package.swift"
            guard exists(manifest) else { continue }
            let cache = "\(ws.work)/package-\(shortHash(dir))-\(Int(mtime(manifest))).json"
            if let d = FileManager.default.contents(atPath: cache),
               let cached = try? JSONDecoder().decode([PackageModule].self, from: d) {
                result += cached
                continue
            }
            guard let modules = try? describe(packageDir: dir, manifest: manifest) else {
                Log.info("  warning: couldn't read \(rel)/Package.swift; its views will hot-reload via full builds")
                continue
            }
            try? mkdirp(ws.work)
            try? JSONEncoder().encode(modules).write(to: URL(fileURLWithPath: cache))
            result += modules
        }
        return result
    }

    private static func describe(packageDir: String, manifest: String) throws -> [PackageModule] {
        let out = try dumpPackage(packageDir)
        guard let json = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let targets = json["targets"] as? [[String: Any]] else { throw SimlessError("unexpected dump-package output") }

        // Package language mode: explicit swiftLanguageVersions, else the tools version.
        let header = (try? String(contentsOfFile: manifest, encoding: .utf8))?.split(separator: "\n").first ?? ""
        let toolsMajor = header.range(of: #"\d+"#, options: .regularExpression).map { Int(header[$0]) ?? 5 } ?? 5
        let declared = (json["swiftLanguageVersions"] as? [Any])?.compactMap { v -> String? in
            (v as? String) ?? ((v as? [String: Any]).flatMap { $0.values.first as? String })
        }.compactMap { $0.split(separator: ".").first.map(String.init) }.max()
        let packageMode = declared ?? (toolsMajor >= 6 ? "6" : "5")

        return targets.compactMap { t in
            guard let name = t["name"] as? String, (t["type"] as? String) == "regular" else { return nil }
            let path = (t["path"] as? String) ?? "Sources/\(name)"
            var isolation: String?
            var features: [String] = []
            var mode = packageMode
            for setting in (t["settings"] as? [[String: Any]]) ?? [] where (setting["tool"] as? String) == "swift" {
                guard let kind = setting["kind"] as? [String: Any] else { continue }
                if let iso = kind["defaultIsolation"] as? [String: Any] { isolation = iso["_0"] as? String }
                if let f = kind["enableUpcomingFeature"] as? [String: Any], let v = f["_0"] as? String { features.append(v) }
                if let m = kind["swiftLanguageMode"] as? [String: Any], let v = m["_0"] as? String {
                    mode = v.split(separator: ".").first.map(String.init) ?? mode
                }
            }
            // dependencies: [{"byName": ["X", null]}, {"target": ["X", null]}, {"product": ["X", "pkg", ...]}]
            let deps = ((t["dependencies"] as? [[String: Any]]) ?? []).compactMap { dep -> String? in
                for key in ["byName", "target", "product"] {
                    if let v = dep[key] as? [Any], let n = v.first as? String { return n.replacingOccurrences(of: "-", with: "_") }
                }
                return nil
            }
            return PackageModule(name: name.replacingOccurrences(of: "-", with: "_"),
                                 dir: "\(packageDir)/\(path)", swiftVersion: mode,
                                 defaultIsolation: isolation, upcomingFeatures: features.sorted(), dependencies: deps)
        }
    }

    /// The module a source file belongs to, if it's in one of the packages.
    static func module(of file: String, in modules: [PackageModule]) -> PackageModule? {
        modules.filter { file.hasPrefix($0.dir + "/") }.max { $0.dir.count < $1.dir.count }
    }
}

/// A local package's test targets. The Mac can't run them on their own: Xcode
/// drops hostless test bundles for "Designed for iPad", and `swift test` builds
/// for macOS, where iOS-only imports fail. simless builds them for iOS devices
/// (the slot app runs iOS binaries) and hosts them in the slot app.
struct PackageTests: Codable {
    let package: String         // package name
    let dir: String             // absolute package directory
    let targets: [String]
}

extension Packages {
    static func testTargets(ws: Workspace) -> [PackageTests] {
        ws.packages.compactMap { rel in
            let dir = "\(ws.root)/\(rel)"
            let manifest = "\(dir)/Package.swift"
            guard exists(manifest) else { return nil }
            let cache = "\(ws.work)/package-tests-\(shortHash(dir))-\(Int(mtime(manifest))).json"
            if let d = FileManager.default.contents(atPath: cache), let cached = try? JSONDecoder().decode(PackageTests.self, from: d) {
                return cached
            }
            guard let out = try? dumpPackage(dir),
                  let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                  let targets = json["targets"] as? [[String: Any]] else { return nil }
            let tests = PackageTests(package: json["name"] as? String ?? (rel as NSString).lastPathComponent, dir: dir,
                                     targets: targets.filter { $0["type"] as? String == "test" }.compactMap { $0["name"] as? String })
            try? mkdirp(ws.work)
            try? JSONEncoder().encode(tests).write(to: URL(fileURLWithPath: cache))
            return tests
        }
    }

    /// Builds the given test targets of a package for iOS devices. Returns the
    /// products directory, which holds `<target>.xctest` and resource bundles.
    ///
    /// They build in the app's own build folder, for the same destination and
    /// with the same settings, so the package's modules the app build already
    /// compiled are reused instead of compiled a second time.
    static func buildTests(_ p: PackageTests, targets: [String], ws: Workspace) throws -> String {
        let dd = stampDir(p, ws: ws)
        try mkdirp(dd)
        let log = "\(ws.work)/package-tests-\(p.package).log"
        let products = ws.productsIphoneos
        // Nothing changed in the package (or the local packages it uses) since
        // these targets were last built: a no-op xcodebuild still costs ~10 s.
        // A stamp per built target set: "<newest source time>\n<targets>". Any
        // build of a superset of these targets that's still current will do.
        // The build settings' version is part of the name: new flags mean a new build.
        let stamp = "\(dd)/.simless-built-\(shortHash("3|" + targets.sorted().joined(separator: ",")))"
        let newest = newestSource(p.dir)
        let stamps = ((try? FileManager.default.contentsOfDirectory(atPath: dd)) ?? []).filter { $0.hasPrefix(".simless-built-") }
        for file in stamps {
            // Stamps from older build settings: remove, and build again.
            guard (try? String(contentsOfFile: "\(dd)/\(file)", encoding: .utf8))?.hasPrefix("v3 ") == true else {
                try? FileManager.default.removeItem(atPath: "\(dd)/\(file)"); continue
            }
            guard let text = try? String(contentsOfFile: "\(dd)/\(file)", encoding: .utf8) else { continue }
            let lines = text.dropFirst(3).split(separator: "\n", omittingEmptySubsequences: false)
            guard let built = lines.first.flatMap({ Double($0) }), built >= newest else { continue }
            let covered = Set(lines.dropFirst().first.map { $0.split(separator: ",").map(String.init) } ?? [])
            if Set(targets).isSubset(of: covered), targets.allSatisfy({ exists("\(products)/\($0).xctest") }) { return products }
        }
        // Xcode names a package's all-targets scheme "<name>-Package" when it
        // has several products, and after the package when it has one.
        let listing = try withDefaultDerivedDataGuard(projectNames: [p.package]) {
            try Shell.run(["xcodebuild", "-list", "-json"], cwd: p.dir, stdoutOnly: true).out
        }
        let schemes = listing.firstIndex(of: "{").flatMap { start in
            (try? JSONSerialization.jsonObject(with: Data(listing[start...].utf8)) as? [String: Any])
                .flatMap { ($0["workspace"] as? [String: Any])?["schemes"] as? [String] }
        } ?? []
        let scheme = schemes.first { $0 == "\(p.package)-Package" } ?? schemes.first { $0 == p.package } ?? schemes.first ?? p.package
        try ws.withBuildFolder {
          try withBuildToken(count: ws.config.buildConcurrency ?? max(1, ProcessInfo.processInfo.activeProcessorCount / 5)) {
            let t = now()
            Log.step("building \(targets.joined(separator: ", ")) for iOS (log: \(log))")
            let r = try Cleanup.retryingPoisonedCache { try Shell.run(["xcodebuild", "build-for-testing", "-scheme", scheme, "-configuration", "Debug",
                                   "-destination", ws.destination, "-derivedDataPath", ws.derivedData]
                                  + Workspace.buildSettings + targets.map { "-only-testing:\($0)" }, cwd: p.dir, logPath: log) }
            guard r.code == 0 else {
                throw SimlessError("building \(p.package)'s tests failed (log: \(log)):\n" + Patch.compilerErrors(r.out))
            }
            Log.step("built in \(secs(t))")
          }
        }
        try? "v3 \(newest)\n\(targets.sorted().joined(separator: ","))".write(toFile: stamp, atomically: true, encoding: .utf8)
        return products
    }

    /// Where a package's build stamps live.
    static func stampDir(_ p: PackageTests, ws: Workspace) -> String { "\(ws.work)/PackageTests/\(p.package)" }

    /// The app's build (the scheme's build-for-testing) already made these
    /// test bundles from sources as of `newest`: no package build needed.
    static func markBuilt(_ p: PackageTests, newest: Double, ws: Workspace) -> [String] {
        let built = p.targets.filter { exists("\(ws.productsIphoneos)/\($0).xctest") }
        guard !built.isEmpty else { return [] }
        let dir = stampDir(p, ws: ws)
        try? mkdirp(dir)
        let stamp = "\(dir)/.simless-built-\(shortHash("3|" + built.sorted().joined(separator: ",")))"
        try? "v3 \(newest)\n\(built.sorted().joined(separator: ","))".write(toFile: stamp, atomically: true, encoding: .utf8)
        return built
    }

    /// The newest modification time of the package's own files and of the
    /// local packages it depends on by path (build folders left out).
    static func newestSource(_ dir: String) -> Double {
        var newest = 0.0
        var seen = Set<String>()
        func scan(_ root: String) {
            let root = (root as NSString).standardizingPath
            guard seen.insert(root).inserted else { return }
            let fm = FileManager.default
            guard let e = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                        options: [.skipsHiddenFiles]) else { return }
            for case let url as URL in e {
                let name = url.lastPathComponent
                if name == ".build" || name == "DerivedData" || name.hasSuffix(".xcodeproj") { e.skipDescendants(); continue }
                if let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    newest = max(newest, d.timeIntervalSince1970)
                }
            }
            // Local packages it uses: .package(path: "...").
            if let manifest = try? String(contentsOfFile: "\(root)/Package.swift", encoding: .utf8),
               let re = try? NSRegularExpression(pattern: #"\.package\(\s*(?:name:\s*"[^"]*",\s*)?path:\s*"([^"]+)""#) {
                for m in re.matches(in: manifest, range: NSRange(manifest.startIndex..., in: manifest)) {
                    if let r = Range(m.range(at: 1), in: manifest) { scan("\(root)/\(manifest[r])") }
                }
            }
        }
        scan(dir)
        return newest
    }
}
