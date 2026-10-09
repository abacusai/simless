// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation
import CryptoKit

/// .simless.json at the repository root, written by `simless init`.
struct Config: Codable {
    var project: String           // App.xcodeproj (relative to root)
    var scheme: String
    var appTarget: String
    var testTarget: String        // an app-hosted unit-test bundle; used to install slots
    var kitDir: String            // where SimlessKit.swift + SimlessFixtures.swift live
    var sourceDirs: [String]      // scanned for edited files on `simless reload`
    var device: String = "iphone" // default canvas: iphone | ipad
    var buildConcurrency: Int?    // max simultaneous full builds across all agents
    var hostIdleMinutes: Int?     // hosts exit after this long without requests (default 30)

    var kitFile: String { "\(kitDir)/SimlessKit.swift" }
    var fixturesFile: String { "\(kitDir)/SimlessFixtures.swift" }
}

/// One checkout (repository or git worktree) of an app.
struct Workspace {
    let root: String
    let config: Config

    static let configName = ".simless.json"
    static let dfiDestination = "platform=macOS,arch=arm64,variant=Designed for iPad"

    static func findRoot(from start: String = FileManager.default.currentDirectoryPath) -> String? {
        var url = URL(fileURLWithPath: start)
        while url.path != "/" {
            if exists(url.appendingPathComponent(configName).path) { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static func load() throws -> Workspace {
        guard let root = findRoot() else { throw SimlessError("no \(configName) found; run `simless init` in your app's repository") }
        return try load(at: root)
    }

    static func load(at root: String) throws -> Workspace {
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(root)/\(configName)"))
        return Workspace(root: root, config: try JSONDecoder().decode(Config.self, from: data))
    }

    var work: String { Paths.workDir(forWorktree: root) }
    var idleMinutes: Int { config.hostIdleMinutes ?? 30 }
    var derivedData: String { "\(work)/DerivedData" }
    var products: String { "\(derivedData)/Build/Products" }
    var productsIphoneos: String { "\(products)/Debug-iphoneos" }
    var buildLog: String { "\(work)/build.log" }
    var settingsPath: String { "\(work)/settings.json" }

    // MARK: - Designed-for-iPad project variant

    /// Xcode hides the "Designed for iPad" destination for targets that also
    /// ship native macOS. simless builds from a sibling copy of the project with
    /// macOS dropped from SUPPORTED_PLATFORMS and DfI enabled. The original
    /// project is never modified. The copy must sit next to the original
    /// because the project's file references are relative to its directory.
    func buildProject() throws -> String {
        let original = "\(root)/\(config.project)"
        let name = (config.project as NSString).deletingPathExtension
        let variant = "\(root)/\(name).simless.xcodeproj"
        let pbx = try String(contentsOfFile: "\(original)/project.pbxproj", encoding: .utf8)
        let needsVariant = pbx.contains("macosx") || pbx.contains("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO")
        guard needsVariant else { return original }

        let stamp = "\(variant)/.simless-source-mtime"
        let sourceMtime = String(max(mtime("\(original)/project.pbxproj"), newestSchemeMtime(original)))
        if exists(variant), (try? String(contentsOfFile: stamp, encoding: .utf8)) == sourceMtime { return variant }

        Log.step("generating \((variant as NSString).lastPathComponent) (Designed-for-iPad build variant)")
        try? FileManager.default.removeItem(atPath: variant)
        try Shell.check(["/usr/bin/rsync", "-a", "--exclude", "xcuserdata", original + "/", variant + "/"],
                        what: "copy project")
        // Only iOS-capable targets change; macOS-only targets (e.g. a Mac share
        // extension) keep their platforms and are platform-filtered out of the build.
        var patched = pbx.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let l = String(line)
            guard l.contains("SUPPORTED_PLATFORMS = "), l.contains("iphoneos") else { return l }
            let platforms = l.replacingOccurrences(of: " macosx", with: "").replacingOccurrences(of: "macosx ", with: "")
            return platforms.replacingOccurrences(of: "\";", with: "\"; SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = YES;")
        }.joined(separator: "\n")
        patched = patched.replacingOccurrences(of: "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO", with: "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = YES")
        try patched.write(toFile: "\(variant)/project.pbxproj", atomically: true, encoding: .utf8)

        // Shared schemes and test plans reference targets by project name; point
        // them at the variant, or the plan resolves no test targets.
        let variantContainer = "container:\(name).simless.xcodeproj"
        let schemes = "\(variant)/xcshareddata/xcschemes"
        for file in (try? FileManager.default.contentsOfDirectory(atPath: schemes)) ?? [] where file.hasSuffix(".xcscheme") {
            let path = "\(schemes)/\(file)"
            var s = try String(contentsOfFile: path, encoding: .utf8)
                .replacingOccurrences(of: "container:\(config.project)", with: variantContainer)
            for plan in Self.testPlanReferences(in: s) {
                let planPath = "\(root)/\(plan)"
                guard exists(planPath) else { continue }
                let variantPlan = (plan as NSString).deletingPathExtension + ".simless.xctestplan"
                let body = try String(contentsOfFile: planPath, encoding: .utf8)
                    .replacingOccurrences(of: "container:\(config.project)", with: variantContainer)
                try body.write(toFile: "\(root)/\(variantPlan)", atomically: true, encoding: .utf8)
                s = s.replacingOccurrences(of: "container:\(plan)\"", with: "container:\(variantPlan)\"")
            }
            try s.write(toFile: path, atomically: true, encoding: .utf8)
        }
        try sourceMtime.write(toFile: stamp, atomically: true, encoding: .utf8)
        return variant
    }

    /// `<TestPlanReference reference = "container:Foo.xctestplan">` paths.
    static func testPlanReferences(in scheme: String) -> [String] {
        let pattern = #"reference = "container:([^"]+\.xctestplan)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: scheme, range: NSRange(scheme.startIndex..., in: scheme)).compactMap {
            Range($0.range(at: 1), in: scheme).map { String(scheme[$0]) }
        }.filter { !$0.hasSuffix(".simless.xctestplan") }
    }

    private func newestSchemeMtime(_ project: String) -> Double {
        let dir = "\(project)/xcshareddata/xcschemes"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map { mtime("\(dir)/\($0)") }.max() ?? 0
    }

    // MARK: - Build

    /// Full DfI build of the app + unit-test bundle, unsigned (simless signs slots
    /// itself with the team wildcard profile, so builds never need provisioning).
    func build() throws {
        let project = try buildProject()
        try mkdirp(work)
        // Lets garbage collection find build caches whose worktree is gone.
        try root.write(toFile: "\(work)/worktree.txt", atomically: true, encoding: .utf8)
        let tokens = config.buildConcurrency ?? max(1, ProcessInfo.processInfo.activeProcessorCount / 5)
        try withBuildToken(count: tokens) {
            let t = now()
            Log.step("building \(config.scheme) for Designed-for-iPad (log: \(buildLog))")
            let r = try Shell.run(["xcodebuild", "build-for-testing",
                             "-project", project, "-scheme", config.scheme, "-configuration", "Debug",
                             "-destination", Self.dfiDestination, "-derivedDataPath", derivedData,
                             "-skipMacroValidation", "-skipPackagePluginValidation",
                             "CODE_SIGNING_ALLOWED=NO", "COMPILATION_CACHE_ENABLE_CACHING=YES",
                             // One content-addressed cache for every worktree: a new
                             // worktree's first build reuses what the others compiled.
                             "COMPILATION_CACHE_CAS_PATH=\(Paths.cache)/CompilationCache"],
                            cwd: root, logPath: buildLog)
            guard r.code == 0 else {
                throw SimlessError("build failed (log: \(buildLog)):\n" + Patch.compilerErrors(r.out))
            }
            Log.step("built in \(secs(t))")
        }
        try captureSettings(project: project)
    }

    // MARK: - Build settings needed to compile patches

    struct Settings: Codable {
        var moduleName: String
        var deploymentTarget: String
        var swiftVersion: String
        var defaultIsolation: String?
        var upcomingFeatures: [String]
        var conditions: [String]
        var bundleID: String
        var team: String
        var wrapperName: String
    }

    private func captureSettings(project: String) throws {
        // Without -derivedDataPath this resolves packages into the default DerivedData.
        let out = try Shell.check(["xcodebuild", "-showBuildSettings", "-json", "-project", project,
                                   "-scheme", config.scheme, "-derivedDataPath", derivedData,
                                   "-configuration", "Debug", "-sdk", "iphoneos"],
                                  cwd: root, what: "xcodebuild -showBuildSettings", stdoutOnly: true)
        guard let start = out.firstIndex(of: "["),
              let arr = try JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [[String: Any]],
              let bs = (arr.first { $0["target"] as? String == config.appTarget } ?? arr.first)?["buildSettings"] as? [String: String] else {
            throw SimlessError("could not read build settings for \(config.appTarget)")
        }
        var features: [String] = []
        for (k, v) in bs where k.hasPrefix("SWIFT_UPCOMING_FEATURE_") && v == "YES" {
            // SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY -> MemberImportVisibility
            features.append(k.dropFirst("SWIFT_UPCOMING_FEATURE_".count).split(separator: "_")
                .map { $0.prefix(1) + $0.dropFirst().lowercased() }.joined())
        }
        if bs["SWIFT_APPROACHABLE_CONCURRENCY"] == "YES" {
            features += ["NonisolatedNonsendingByDefault", "InferIsolatedConformances"]
        }
        let s = Settings(
            moduleName: bs["PRODUCT_MODULE_NAME"] ?? config.appTarget,
            deploymentTarget: bs["IPHONEOS_DEPLOYMENT_TARGET"] ?? "17.0",
            swiftVersion: (bs["SWIFT_VERSION"] ?? "5").split(separator: ".").first.map(String.init) ?? "5",
            defaultIsolation: bs["SWIFT_DEFAULT_ACTOR_ISOLATION"],
            upcomingFeatures: Array(Set(features)).sorted(),
            conditions: (bs["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] ?? "DEBUG").split(separator: " ").map(String.init),
            bundleID: bs["PRODUCT_BUNDLE_IDENTIFIER"] ?? "",
            team: bs["DEVELOPMENT_TEAM"] ?? "",
            wrapperName: bs["WRAPPER_NAME"] ?? "\(config.appTarget).app")
        guard !s.bundleID.isEmpty, !s.team.isEmpty else {
            throw SimlessError("\(config.appTarget) needs PRODUCT_BUNDLE_IDENTIFIER and DEVELOPMENT_TEAM")
        }
        try JSONEncoder().encode(s).write(to: URL(fileURLWithPath: settingsPath))
    }

    func settings() throws -> Settings {
        guard let d = FileManager.default.contents(atPath: settingsPath) else {
            throw SimlessError("not built yet; run `simless up`")
        }
        return try JSONDecoder().decode(Settings.self, from: d)
    }

    var snapshotPath: String { "\(work)/sources.json" }

    func swiftSources() -> [String] {
        var out: [String] = []
        for dir in config.sourceDirs {
            let base = "\(root)/\(dir)"
            guard let e = FileManager.default.enumerator(atPath: base) else { continue }
            while let rel = e.nextObject() as? String {
                if rel.hasSuffix(".swift") { out.append("\(base)/\(rel)") }
            }
        }
        return out.sorted()
    }

    private static func digest(_ path: String) -> String? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// Records source contents as of a build. Taken before the build starts, so
    /// edits made while it runs still count as changed afterwards.
    func snapshotSources() throws {
        var hashes: [String: String] = [:]
        for f in swiftSources() { hashes[f] = Self.digest(f) }
        try mkdirp(work)
        try JSONEncoder().encode(hashes).write(to: URL(fileURLWithPath: snapshotPath))
    }

    /// Swift files whose contents differ from the last full build. Content, not
    /// mtime: git checkouts and stashes touch files without changing them.
    func changedSources() -> [String] {
        let snap = (FileManager.default.contents(atPath: snapshotPath))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        return swiftSources().filter { snap[$0] == nil || snap[$0] != Self.digest($0) }
    }
}
