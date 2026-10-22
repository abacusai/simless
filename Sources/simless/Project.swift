// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation
import CryptoKit

/// .simless.json at the repository root, written by `simless init`.
struct Config: Codable {
    var project: String           // App.xcodeproj or ios/App.xcodeproj (relative to the repo root)
    var scheme: String
    var appTarget: String
    var testTarget: String        // an app-hosted unit-test bundle ("" for none; the dfi mode installs slots through it)
    var kitDir: String            // where SimlessKit.swift + SimlessFixtures.swift live
    var sourceDirs: [String]      // scanned for edited files on `simless reload`
    var device: String = "iphone" // default canvas: iphone | ipad
    var buildConcurrency: Int?    // max simultaneous full builds across all agents
    var hostIdleMinutes: Int?     // hosts exit after this long without requests (default 30; SIMLESS_HOST_IDLE_MINUTES wins)
    var standbyIdleMinutes: Int?  // a standby test host exits after this long unused (default 10; SIMLESS_STANDBY_IDLE_MINUTES wins)
    var diskLimitGB: Double?      // everything simless keeps on this Mac (default 25; SIMLESS_DISK_LIMIT_GB wins)
    var packages: [String]?       // local Swift packages whose views hot reload can patch (relative to root)
    var team: String?             // signing team when the project sets no DEVELOPMENT_TEAM (e.g. a shared sample)
    var idiom: String?            // "phone": phone canvases also get the phone idiom (default: the Mac's iPad idiom)
    var checks: Checks?
    var tests: Tests?
    var calibrate: Calibration?
    var embeddedBundles: Bool?    // keep app extensions and the watch app in the slot (default true)
    var mode: String?             // "native" (default): hosts run unsigned; "dfi": signed Designed-for-iPad installs
    var settle: Double?           // default --settle: ms each render gives the screen's async work (default 0)
    var isolate: Bool?            // native hosts get a sandbox of their own: write only their slot, read only their worktree
    var previews: Bool?           // fixtures from #Preview blocks and the App's root view (default true)
    var network: Network?

    struct Network: Codable {
        var block: Bool?              // render hosts get no network (default true)
        var allow: [String]?          // hosts or URLs (globs) render hosts may reach
        var stub: [String: String]?   // URL glob -> file (relative to the repo) served instead
        var tests: Bool?              // block in unit and UI test hosts too (default false)
    }

    struct Checks: Codable {
        var minTapTarget: Double?     // points (default 44)
        var ignore: [String]?         // issues containing any of these strings aren't reported
    }
    struct Tests: Codable {
        var timeout: Double?          // seconds one test may run before simless stops the run (default 600)
        var skip: [String]?           // always skipped, like --skip
        var simulatorOnly: [String: String]?  // "Target/Suite/test()": why it needs a simulator
        var jobs: Int?                // Swift Testing tests running at once per host
        var hosts: Int?               // test hosts running side by side (default: up to 4 for 4+ targets)
        var uiJobs: Int?              // UI test hosts running side by side (default: up to 4)
        var uiTimeout: Double?        // seconds one UI test may run (default 600)
        var uiSources: [String: String]?  // UI test target -> source folder, when it isn't a synchronized folder
        var uiDevices: [String: [String]]?  // more devices for UI tests and what runs on each,
                                            // e.g. {"ipad": ["AppUITests/IPadUITests"]} ([] for everything)
    }
    struct Calibration: Codable {
        var runtime: String?          // iOS version of the simulator, e.g. "26.5" (default: newest installed)
        var device: String?           // simulator device type (default "iPhone 17 Pro")
    }

    var kitFile: String { "\(kitDir)/SimlessKit.swift" }
    var fixturesFile: String { "\(kitDir)/SimlessFixtures.swift" }
}

/// One checkout (repository or git worktree) of an app.
struct Workspace {
    let root: String
    let config: Config

    static let configName = ".simless.json"
    /// Settings every build of the app and its packages' tests shares, so
    /// they reuse each other's work in one build folder.
    static let buildSettings = [
        "-skipMacroValidation", "-skipPackagePluginValidation",
        "CODE_SIGNING_ALLOWED=NO", "COMPILATION_CACHE_ENABLE_CACHING=YES",
        // One content-addressed cache for every worktree: a new
        // worktree's first build reuses what the others compiled.
        "COMPILATION_CACHE_CAS_PATH=\(Paths.cache)/CompilationCache",
        // Nothing searches the index of these builds, and nothing reads their
        // debug info: failures name their file and line from the source,
        // crashes their functions from the symbol table. Without it builds are
        // faster and test bundles a fraction of the size.
        "COMPILER_INDEX_STORE_ENABLE=NO", "GCC_GENERATE_DEBUGGING_SYMBOLS=NO",
        // Code can tell a simless build apart at compile time, the way it tells
        // a simulator's: `#if targetEnvironment(simulator) || SIMLESS` (a mock
        // store, say). `targetEnvironment(simulator)` is false here, a device build.
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) \(Self.condition)",
    ]
    static let condition = "SIMLESS"

    /// One xcodebuild at a time in this worktree's build folder.
    func withBuildFolder<T>(_ body: () throws -> T) throws -> T {
        try withLock("build-\(shortHash(root))", body)
    }

    static let dfiDestination = "platform=macOS,arch=arm64,variant=Designed for iPad"
    /// The native mode builds the plain iOS device slice: it needs no Mac
    /// destination (none exists in a VM), and no project variant.
    static let iosDestination = "generic/platform=iOS"
    var native: Bool { Native.enabled(self) }
    var destination: String { native ? Self.iosDestination : Self.dfiDestination }

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
        let ws = try load(at: root)
        // When this worktree last used simless, for evicting caches nobody uses.
        if exists(ws.work) { FileManager.default.createFile(atPath: "\(ws.work)/last-used", contents: nil) }
        return ws
    }

    static func load(at root: String) throws -> Workspace {
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(root)/\(configName)"))
        return Workspace(root: root, config: try JSONDecoder().decode(Config.self, from: data))
    }

    /// Local packages (relative to root): from the config, else the ones the
    /// project references now (a package added after `simless init` counts).
    var packages: [String] { config.packages ?? Self.localPackages(root: root, project: config.project) }

    static func localPackages(root: String, project: String) -> [String] {
        let projectDir = (project as NSString).deletingLastPathComponent
        let pbx = (try? String(contentsOfFile: "\(root)/\(project)/project.pbxproj", encoding: .utf8)) ?? ""
        // `relativePath` of XCLocalSwiftPackageReference entries, relative to the project's directory.
        guard let re = try? NSRegularExpression(pattern: #"isa = XCLocalSwiftPackageReference;\s*relativePath = "?([^";]+)"?;"#) else { return [] }
        return re.matches(in: pbx, range: NSRange(pbx.startIndex..., in: pbx)).compactMap {
            Range($0.range(at: 1), in: pbx).map { String(pbx[$0]) }
        }
        .map { projectDir.isEmpty ? $0 : "\(projectDir)/\($0)" }
        // Standardize both sides: it also drops /private from /private/tmp paths.
        .map { URL(fileURLWithPath: "\(root)/\($0)").standardizedFileURL.path
            .replacingOccurrences(of: URL(fileURLWithPath: root).standardizedFileURL.path + "/", with: "") }
        .filter { exists("\(root)/\($0)/Package.swift") }
    }

    var work: String { Paths.workDir(forWorktree: root) }
    var idleMinutes: Int { ProcessInfo.processInfo.environment["SIMLESS_HOST_IDLE_MINUTES"].flatMap(Int.init) ?? config.hostIdleMinutes ?? 30 }
    var standbyIdleMinutes: Int {
        ProcessInfo.processInfo.environment["SIMLESS_STANDBY_IDLE_MINUTES"].flatMap(Int.init) ?? config.standbyIdleMinutes ?? min(idleMinutes, 10)
    }
    var derivedData: String { "\(work)/DerivedData" }
    var products: String { "\(derivedData)/Build/Products" }
    var productsIphoneos: String { "\(products)/Debug-iphoneos" }

    /// The app scheme's .xctestrun in the build folder. Package test builds
    /// write their own next to it, so it's picked by the scheme it's for
    /// (Xcode names it `<Scheme>_<TestPlan>_<platform>.xctestrun`), or else by
    /// holding the app's unit-test target, never by which sorts first.
    var appXCTestRun: String? {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: products)) ?? []).filter { $0.hasSuffix(".xctestrun") }
        if let named = files.filter({ $0.hasPrefix("\(config.scheme)_") }).max(by: { mtime("\(products)/\($0)") < mtime("\(products)/\($1)") }) {
            return "\(products)/\(named)"
        }
        return files.map { "\(products)/\($0)" }.first { path in
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
            let entries = (plist["TestConfigurations"] as? [[String: Any]])?.flatMap { $0["TestTargets"] as? [[String: Any]] ?? [] }
                ?? plist.filter { !$0.key.hasPrefix("__") }.compactMap { $0.value as? [String: Any] }
            return entries.contains { $0["BlueprintName"] as? String == config.testTarget }
        }
    }
    var buildLog: String { "\(work)/build.log" }
    var settingsPath: String { "\(work)/settings.json" }

    // MARK: - Designed-for-iPad project variant

    /// Xcode hides the "Designed for iPad" destination for targets that also
    /// ship native macOS. simless builds from a sibling copy of the project with
    /// macOS dropped from SUPPORTED_PLATFORMS and DfI enabled. The original
    /// project is never modified. The copy must sit next to the original
    /// because the project's file references are relative to its directory.
    /// The directory containing the .xcodeproj. Scheme containers and test-plan
    /// references are relative to it, not to the repository root.
    var projectDir: String {
        let dir = (config.project as NSString).deletingLastPathComponent
        return dir.isEmpty ? root : "\(root)/\(dir)"
    }
    var projectBase: String { ((config.project as NSString).lastPathComponent as NSString).deletingPathExtension }

    func buildProject() throws -> String {
        let original = "\(root)/\(config.project)"
        if native { return original }
        let name = projectBase
        let variant = "\(projectDir)/\(name).simless.xcodeproj"
        let pbx = try String(contentsOfFile: "\(original)/project.pbxproj", encoding: .utf8)
        let needsVariant = pbx.contains("macosx") || pbx.contains("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO")
        guard needsVariant else { return original }

        let stamp = "\(variant)/.simless-source-mtime"
        // Regenerate when the project or its schemes change, or simless itself
        // changes (a variant made by an older version may be wrong).
        let sourceMtime = "\(version) \(max(mtime("\(original)/project.pbxproj"), newestSchemeMtime(original)))"
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

        // Shared schemes and test plans reference targets by project file name,
        // relative to the project's directory; point them at the variant, or the
        // scheme builds the original project and the plan resolves no test targets.
        let originalContainer = "container:\(name).xcodeproj"
        let variantContainer = "container:\(name).simless.xcodeproj"
        let schemes = "\(variant)/xcshareddata/xcschemes"
        for file in (try? FileManager.default.contentsOfDirectory(atPath: schemes)) ?? [] where file.hasSuffix(".xcscheme") {
            let path = "\(schemes)/\(file)"
            var s = try String(contentsOfFile: path, encoding: .utf8)
                .replacingOccurrences(of: originalContainer + "\"", with: variantContainer + "\"")
            guard s.contains(variantContainer) || !s.contains(originalContainer) else {
                throw SimlessError("could not retarget scheme \(file) to the build variant")
            }
            for plan in Self.testPlanReferences(in: s) {
                let planPath = "\(projectDir)/\(plan)"
                guard exists(planPath) else { continue }
                let variantPlan = (plan as NSString).deletingPathExtension + ".simless.xctestplan"
                let body = try String(contentsOfFile: planPath, encoding: .utf8)
                    .replacingOccurrences(of: originalContainer + "\"", with: variantContainer + "\"")
                try body.write(toFile: "\(projectDir)/\(variantPlan)", atomically: true, encoding: .utf8)
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

    /// Full build of the app + unit-test bundle, unsigned (slots are signed by
    /// simless: ad hoc in the native mode, with the team wildcard profile in dfi).
    func build() throws {
        let project = try buildProject()
        try mkdirp(work)
        // Lets garbage collection find build caches whose worktree is gone.
        try root.write(toFile: "\(work)/worktree.txt", atomically: true, encoding: .utf8)
        let tokens = config.buildConcurrency ?? max(1, ProcessInfo.processInfo.activeProcessorCount / 5)
        try withBuildFolder { try withBuildToken(count: tokens) {
            let t = now()
            Log.step("building \(config.scheme) for \(native ? "iOS" : "Designed-for-iPad") (log: \(buildLog))")
            func run(_ action: String) throws -> Shell.Result {
                try Cleanup.retryingPoisonedCache {
                    try Shell.run(["xcodebuild", action,
                                 "-project", project, "-scheme", config.scheme, "-configuration", "Debug",
                                 "-destination", destination, "-derivedDataPath", derivedData] + Self.buildSettings,
                                cwd: root, logPath: buildLog)
                }
            }
            var r = try run("build-for-testing")
            // A scheme without tests (a generated project's, say) has no test action
            // to build for: build the app alone.
            if r.code != 0, r.out.contains("is not currently configured for the test action") { r = try run("build") }
            guard r.code == 0 else {
                throw SimlessError("build failed (log: \(buildLog)):\n" + Patch.compilerErrors(r.out))
            }
            Log.step("built in \(secs(t))")
        } }
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
        var deviceFamily: String? = nil   // TARGETED_DEVICE_FAMILY: "1" is iPhone only
    }

    /// The idiom phone canvases render with: `--idiom`, then `"idiom"`, then
    /// the phone's for an iPhone-only app (what it gets on an iPhone), else the
    /// Mac's iPad idiom. nil means the iPad idiom.
    func phoneIdiom(_ flag: String?) -> String? {
        let chosen = flag ?? config.idiom ?? ((try? settings().deviceFamily)?.trimmingCharacters(in: .whitespaces) == "1" ? "phone" : nil)
        return chosen == "phone" ? "phone" : nil
    }

    private func captureSettings(project: String) throws {
        // By scheme with the build's own destination and derived-data path (so it
        // never touches the default DerivedData). Some schemes resolve no
        // destination this way ("Found no destinations"); then query the target
        // directly, which can't take -derivedDataPath, and clean up after it.
        let attempts: [[String]] = [
            ["-scheme", config.scheme, "-destination", destination, "-derivedDataPath", derivedData],
            ["-target", config.appTarget, "-sdk", "iphoneos"],
        ]
        var bs: [String: String]?
        var lastError = ""
        for extra in attempts where bs == nil {
            let r = try withDefaultDerivedDataGuard(projectNames: [projectBase, "\(projectBase).simless"]) {
                try Shell.run(["xcodebuild", "-showBuildSettings", "-json", "-project", project,
                               "-configuration", "Debug"] + extra, cwd: root, stdoutOnly: true)
            }
            guard r.code == 0, let start = r.out.firstIndex(of: "["),
                  let arr = try? JSONSerialization.jsonObject(with: Data(r.out[start...].utf8)) as? [[String: Any]] else {
                lastError = "xcodebuild -showBuildSettings \(extra.joined(separator: " ")) failed (exit \(r.code))"
                continue
            }
            bs = arr.first { $0["target"] as? String == config.appTarget }?["buildSettings"] as? [String: String]
            if bs == nil { lastError = "no build settings for target \(config.appTarget)" }
        }
        guard let bs else { throw SimlessError("could not read build settings for \(config.appTarget): \(lastError)") }
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
            // As the build has them: patches must see the same `#if`s.
            conditions: Array(Set((bs["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] ?? "DEBUG").split(separator: " ").map(String.init) + [Self.condition])).sorted(),
            bundleID: bs["PRODUCT_BUNDLE_IDENTIFIER"] ?? "",
            // The native mode signs ad hoc: a team is only recorded when one is set,
            // never looked for in the keychain (that took 8.5 s of every `up`).
            team: native ? explicitTeam(fromBuildSettings: bs["DEVELOPMENT_TEAM"] ?? "") ?? ""
                : try teamForSigning(fromBuildSettings: bs["DEVELOPMENT_TEAM"] ?? ""),
            wrapperName: bs["WRAPPER_NAME"] ?? "\(config.appTarget).app",
            deviceFamily: bs["TARGETED_DEVICE_FAMILY"])
        guard !s.bundleID.isEmpty else {
            throw SimlessError("\(config.appTarget) needs a PRODUCT_BUNDLE_IDENTIFIER")
        }
        try JSONEncoder().encode(s).write(to: URL(fileURLWithPath: settingsPath))
    }

    /// $SIMLESS_TEAM; else `team` from .simless.json; else the project's team;
    /// else the team of the only Apple Development identity in the keychain.
    /// The explicit choices come first: a build machine signs with its own team
    /// whatever team the project names.
    private func explicitTeam(fromBuildSettings team: String) -> String? {
        if let t = ProcessInfo.processInfo.environment["SIMLESS_TEAM"], !t.isEmpty { return t }
        if let t = config.team, !t.isEmpty { return t }
        return team.isEmpty ? nil : team
    }

    private func teamForSigning(fromBuildSettings team: String) throws -> String {
        if let t = explicitTeam(fromBuildSettings: team) { return t }
        var teams = try Signing.developmentTeams()
        // Several teams: only one may have the wildcard profile simless signs with.
        let usable = teams.filter { (try? Signing.wildcardProfile(team: $0)) != nil }
        if usable.count == 1 { teams = usable }
        guard teams.count == 1, let only = teams.first else {
            throw SimlessError(teams.isEmpty
                ? "\(config.appTarget) sets no DEVELOPMENT_TEAM and the keychain has no Apple Development identity"
                : "\(config.appTarget) sets no DEVELOPMENT_TEAM; set SIMLESS_TEAM=<one of \(teams.sorted().joined(separator: ", "))>, or add \"team\" to \(Self.configName)")
        }
        return only
    }

    func settings() throws -> Settings {
        guard let d = FileManager.default.contents(atPath: settingsPath) else {
            throw SimlessError("not built yet; run `simless up`")
        }
        return try JSONDecoder().decode(Settings.self, from: d)
    }

    var snapshotPath: String { "\(work)/sources.json" }

    /// The app's sources plus every local package module's: edits anywhere in
    /// them are detected, and the patch-scope graph spans all of them.
    func swiftSources() -> [String] {
        var out: [String] = []
        let dirs = config.sourceDirs.map { $0 == "." ? root : "\(root)/\($0)" } + Packages.modules(ws: self).map(\.dir)
        for base in Array(Set(dirs)) {
            guard let e = FileManager.default.enumerator(atPath: base) else { continue }
            while let rel = e.nextObject() as? String {
                if rel.hasSuffix(".swift") { out.append("\(base)/\(rel)") }
            }
        }
        return Array(Set(out)).sorted()
    }

    static func digest(_ path: String) -> String? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// Records source contents as of a build. Taken before the build starts, so
    /// edits made while it runs still count as changed afterwards. Returns the
    /// sources' id (see `sourcesID`). A failed build puts the previous record
    /// back (`restoreSnapshot`), and only a build that worked drops the copies
    /// the previous record used (`pruneSnapshotCopies`).
    @discardableResult
    func snapshotSources() throws -> String {
        var hashes: [String: String] = [:]
        for f in swiftSources() { hashes[f] = Self.digest(f) }
        try mkdirp(work)
        try JSONEncoder().encode(hashes).write(to: URL(fileURLWithPath: snapshotPath))
        // A copy of each file as built (APFS clones, by content), so hot reload
        // can tell which declarations an edit changed.
        let dir = "\(work)/snapshot"
        try mkdirp(dir)
        for (f, h) in hashes where !exists("\(dir)/\(h).swift") { try? FileManager.default.copyItem(atPath: f, toPath: "\(dir)/\(h).swift") }
        return sourcesID(hashes)
    }

    /// After a failed build: the record (and so the copies) of the build the host still runs.
    func restoreSnapshot(_ previous: Data?) {
        if let previous { try? previous.write(to: URL(fileURLWithPath: snapshotPath)) }
        else { try? FileManager.default.removeItem(atPath: snapshotPath) }
    }

    /// After a build that worked: copies no file of it has any more.
    func pruneSnapshotCopies() {
        let keep = Set(snapshot().values.map { "\($0).swift" })
        let dir = "\(work)/snapshot", fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !keep.contains(name) { try? fm.removeItem(atPath: "\(dir)/\(name)") }
    }

    /// The sources as of the last full build: path -> digest.
    func snapshot() -> [String: String] {
        FileManager.default.contents(atPath: snapshotPath).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// An id for a set of Swift sources (paths relative to the worktree, and
    /// contents): the same sources give the same id, wherever they're synced to.
    func sourcesID(_ hashes: [String: String]) -> String {
        let lines = hashes.map { (path, digest) in
            (path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path) + " " + digest
        }.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(lines.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The id of the Swift sources as they are now.
    func currentSourcesID() -> String {
        sourcesID(Dictionary(uniqueKeysWithValues: swiftSources().map { ($0, Self.digest($0) ?? "") }))
    }

    /// The file's text as of the last full build, when there's a copy of it.
    func snapshotText(of path: String) -> String? {
        guard let h = snapshot()[path] else { return nil }
        return try? String(contentsOfFile: "\(work)/snapshot/\(h).swift", encoding: .utf8)
    }

    /// Swift files whose contents differ from the last full build. Content, not
    /// mtime: git checkouts and stashes touch files without changing them.
    func changedSources() -> [String] {
        let snap = (FileManager.default.contents(atPath: snapshotPath))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        return swiftSources().filter { snap[$0] == nil || snap[$0] != Self.digest($0) }
    }
}
