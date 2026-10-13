// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import AppKit

/// A slot is one installed copy of the app under its own bundle id
/// (<bundle id>.simless<N>), so several agents can each run a render host of the
/// same app at once (macOS runs one instance per bundle id).
enum Slots {

    /// Clones the fresh build into the slot and re-signs it as <id>.simlessN:
    /// no capabilities, LSUIElement (never a Dock icon). App extensions and the
    /// watch app stay (tests look for them) under ids within the slot's, unless
    /// `embedded` is false.
    static func prepare(_ slot: SlotRecord, ws: Workspace, settings: Workspace.Settings, embedded: Bool = true) throws {
        let t = now()
        let signing = try Signing.material(team: settings.team)
        let products = "\(slot.dir)/Debug-iphoneos"
        let app = "\(products)/\(settings.wrapperName)"
        try? FileManager.default.removeItem(atPath: products)
        try mkdirp(products)
        // APFS clone: near-free copy of a multi-hundred-MB app.
        try Shell.check(["/bin/cp", "-c", "-R", "\(ws.productsIphoneos)/\(settings.wrapperName)", app], what: "clone app")

        let fm = FileManager.default
        let nested = embeddedBundles(in: app)
        if embedded {
            // Their ids must start with the app's, which is now the slot's.
            for bundle in nested { try reidentify("\(bundle)/Info.plist", from: settings.bundleID, to: slot.slotID) }
        } else {
            for bundle in nested { try? fm.removeItem(atPath: bundle) }
            try? fm.removeItem(atPath: "\(app)/Watch")
        }
        try? fm.removeItem(atPath: "\(app)/SimlessPatches")

        let info = "\(app)/Info.plist"
        try Shell.check(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleIdentifier \(slot.slotID)", info])
        _ = try? Shell.run(["/usr/libexec/PlistBuddy", "-c", "Delete :LSUIElement", info])
        try Shell.check(["/usr/libexec/PlistBuddy", "-c", "Add :LSUIElement bool true", info])
        // Background-only: macOS never shows its windows, including in the install
        // and unit-test runs that launch the app without simless's arguments.
        _ = try? Shell.run(["/usr/libexec/PlistBuddy", "-c", "Delete :LSBackgroundOnly", info])
        try Shell.check(["/usr/libexec/PlistBuddy", "-c", "Add :LSBackgroundOnly bool true", info])
        try fm.copyItem(atPath: signing.profilePath, toPath: "\(app)/embedded.mobileprovision")

        let entitlements = "\(slot.dir)/entitlements.plist"
        try entitlementsPlist(team: settings.team, id: slot.slotID).write(toFile: entitlements, atomically: true, encoding: .utf8)

        // Built unsigned: sign nested code inside-out, then the app.
        for path in nestedCode(in: app) {
            if path.hasSuffix(".appex"), let id = bundleID(path) {
                // An extension needs a profile and its own application-identifier to install.
                try? fm.removeItem(atPath: "\(path)/embedded.mobileprovision")
                try fm.copyItem(atPath: signing.profilePath, toPath: "\(path)/embedded.mobileprovision")
                let ent = "\(slot.dir)/entitlements-\(id).plist"
                try entitlementsPlist(team: settings.team, id: id).write(toFile: ent, atomically: true, encoding: .utf8)
                try Signing.sign(path, identity: signing.identity, entitlements: ent)
            } else {
                try Signing.sign(path, identity: signing.identity)
            }
        }
        try Signing.sign(app, identity: signing.identity, entitlements: entitlements)

        // xctestrun for installing: same as the build's, host bundle id swapped.
        guard let src = (try? fm.contentsOfDirectory(atPath: ws.products))?.first(where: { $0.hasSuffix(".xctestrun") }) else {
            throw SimlessError("build produced no .xctestrun (is \(ws.config.testTarget) an app-hosted unit-test target?)")
        }
        let xctestrun = "\(slot.dir)/slot.xctestrun"
        try? fm.removeItem(atPath: xctestrun)
        try retargetXCTestRun(from: "\(ws.products)/\(src)", to: xctestrun,
                              hostBundleID: settings.bundleID, slotID: slot.slotID)
        Log.step("slot \(slot.slotID) prepared in \(secs(t))")
    }

    /// Copies the build's .xctestrun with the test host's bundle id swapped for
    /// the slot's, and SIMLESS_HEADLESS set so install and test runs never show a
    /// window. Handles both formats: v2 (`TestConfigurations[].TestTargets[]`,
    /// schemes with a test plan) and v1 (test targets as top-level keys).
    private static func retargetXCTestRun(from src: String, to dst: String, hostBundleID: String, slotID: String) throws {
        guard let data = FileManager.default.contents(atPath: src),
              var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SimlessError("could not read \(src)")
        }
        func retarget(_ target: [String: Any]) -> [String: Any] {
            var t = target
            var env = t["EnvironmentVariables"] as? [String: Any] ?? [:]
            env["SIMLESS_HEADLESS"] = "1"
            t["EnvironmentVariables"] = env
            if t["TestHostBundleIdentifier"] as? String == hostBundleID { t["TestHostBundleIdentifier"] = slotID }
            return t
        }
        if let configs = plist["TestConfigurations"] as? [[String: Any]] {
            plist["TestConfigurations"] = configs.map { config in
                var c = config
                c["TestTargets"] = (config["TestTargets"] as? [[String: Any]] ?? []).map(retarget)
                return c
            }
        } else {
            for (key, value) in plist where !key.hasPrefix("__") {
                if let target = value as? [String: Any] { plist[key] = retarget(target) }
            }
        }
        let out = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try out.write(to: URL(fileURLWithPath: dst))
    }

    /// The minimum a slot (or one of its extensions) is signed with: the
    /// wildcard profile allows nothing more.
    private static func entitlementsPlist(team: String, id: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>application-identifier</key><string>\(team).\(id)</string>
          <key>com.apple.developer.team-identifier</key><string>\(team)</string>
          <key>get-task-allow</key><true/>
        </dict></plist>
        """
    }

    /// Frameworks, dylibs, test bundles, extensions and watch apps inside the
    /// app, deepest first.
    private static func nestedCode(in app: String) -> [String] {
        var found: [String] = []
        guard let e = FileManager.default.enumerator(atPath: app) else { return [] }
        while let rel = e.nextObject() as? String {
            let ext = (rel as NSString).pathExtension
            if ["framework", "xctest", "dylib", "appex", "app"].contains(ext) { found.append("\(app)/\(rel)") }
        }
        return found.sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
    }

    /// App extensions and watch apps (with their own extensions).
    private static func embeddedBundles(in app: String) -> [String] {
        nestedCode(in: app).filter { $0.hasSuffix(".appex") || $0.hasSuffix(".app") }
    }

    private static func bundleID(_ bundle: String) -> String? {
        guard let d = FileManager.default.contents(atPath: "\(bundle)/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    /// Rewrites every id in a nested bundle's Info.plist that is the app's id or
    /// within it (CFBundleIdentifier, WKCompanionAppBundleIdentifier, ...).
    private static func reidentify(_ infoPlist: String, from old: String, to new: String) throws {
        guard let d = FileManager.default.contents(atPath: infoPlist),
              let plist = try PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return }
        func map(_ v: Any) -> Any {
            if let s = v as? String, s == old || s.hasPrefix(old + ".") { return new + s.dropFirst(old.count) }
            if let a = v as? [Any] { return a.map(map) }
            if let dict = v as? [String: Any] { return dict.mapValues(map) }
            return v
        }
        let out = try PropertyListSerialization.data(fromPropertyList: map(plist), format: .binary, options: 0)
        try out.write(to: URL(fileURLWithPath: infoPlist))
    }

    /// macOS registers an installed app's extensions; a slot's widgets must not
    /// show up in the widget gallery, so each is set to "ignore".
    private static func hideExtensions(_ slot: SlotRecord) {
        let installed = "\(slot.dir)/Debug-iphoneos/.XCInstall"
        for app in (try? FileManager.default.contentsOfDirectory(atPath: installed)) ?? [] where app.hasSuffix(".app") {
            for appex in embeddedBundles(in: "\(installed)/\(app)") where appex.hasSuffix(".appex") {
                if let id = bundleID(appex) { _ = try? Shell.run(["/usr/bin/pluginkit", "-e", "ignore", "-i", id]) }
            }
        }
    }

    // MARK: - Test runs

    /// Copies package test bundles into the slot app and re-signs it. The next
    /// test run installs them, and the app hosts them like its own tests.
    static func injectTests(_ slot: SlotRecord, ws: Workspace, bundles: [(target: String, products: String)]) throws {
        let settings = try ws.settings()
        let signing = try Signing.material(team: settings.team)
        let app = "\(slot.dir)/Debug-iphoneos/\(settings.wrapperName)"
        let fm = FileManager.default
        try mkdirp("\(app)/PlugIns")
        for b in bundles {
            let dst = "\(app)/PlugIns/\(b.target).xctest"
            try? fm.removeItem(atPath: dst)
            try Shell.check(["/bin/cp", "-c", "-R", "\(b.products)/\(b.target).xctest", dst], what: "copy \(b.target)")
            // SwiftPM resource bundles: Bundle.module looks for them next to its code.
            for r in (try? fm.contentsOfDirectory(atPath: b.products)) ?? [] where r.hasSuffix(".bundle") {
                try Shell.check(["/bin/cp", "-c", "-R", "\(b.products)/\(r)", "\(dst)/\(r)"], what: "copy \(r)")
            }
            for path in nestedCode(in: dst) { try Signing.sign(path, identity: signing.identity) }
            try Signing.sign(dst, identity: signing.identity)
        }
        try Signing.sign(app, identity: signing.identity, entitlements: "\(slot.dir)/entitlements.plist")
    }

    /// The xctestrun for one test run: the slot's, plus an entry per injected
    /// package test bundle (hosted like the app's own tests), the sandbox
    /// tokens that let tests read the repository, and the per-test time limit.
    /// `merged` package targets run in one launch: the first one's entry loads
    /// the others (SimlessKit dlopens them), and they get no entries of their own.
    static func testRun(_ slot: SlotRecord, ws: Workspace, packageTargets: [String], merged: [String] = [],
                        timeout: Double) throws -> String {
        let src = "\(slot.dir)/slot.xctestrun"
        guard let data = FileManager.default.contents(atPath: src),
              var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SimlessError("\(slot.slotID) is not installed; run `simless up`")
        }
        var dirs = [ws.root]
        for p in ws.packages {
            let dir = URL(fileURLWithPath: "\(ws.root)/\(p)").standardizedFileURL.path
            if !dir.hasPrefix(URL(fileURLWithPath: ws.root).standardizedFileURL.path + "/") { dirs.append(dir) }
        }
        let tokens = dirs.compactMap(Sandbox.readToken).joined(separator: "\n")
        func configure(_ target: [String: Any]) -> [String: Any] {
            var t = target
            var env = t["EnvironmentVariables"] as? [String: Any] ?? [:]
            env["SIMLESS_SANDBOX_TOKENS"] = tokens
            t["EnvironmentVariables"] = env
            t["TestTimeoutsEnabled"] = true
            t["DefaultTestExecutionTimeAllowance"] = Int(timeout)
            t["MaximumTestExecutionTimeAllowance"] = Int(timeout)
            return t
        }
        func hosted(_ template: [String: Any], _ name: String) -> [String: Any] {
            var t = template
            if name == merged.first {
                var env = t["EnvironmentVariables"] as? [String: Any] ?? [:]
                env["SIMLESS_TEST_BUNDLES"] = merged.dropFirst().joined(separator: "\n")
                t["EnvironmentVariables"] = env
            }
            t["BlueprintName"] = name
            t["ProductModuleName"] = name.replacingOccurrences(of: "-", with: "_")
            t["TestBundlePath"] = "__TESTHOST__/PlugIns/\(name).xctest"
            if let host = t["TestHostPath"] as? String { t["DependentProductPaths"] = [host, "\(host)/PlugIns/\(name).xctest"] }
            t.removeValue(forKey: "BlueprintProviderName")
            t.removeValue(forKey: "BlueprintProviderRelativePath")
            return t
        }
        let main = ws.config.testTarget
        let entries = packageTargets.filter { !merged.dropFirst().contains($0) }
        if var configs = plist["TestConfigurations"] as? [[String: Any]] {
            for i in configs.indices {
                var targets = (configs[i]["TestTargets"] as? [[String: Any]] ?? []).map(configure)
                if let template = targets.first(where: { $0["BlueprintName"] as? String == main }) ?? targets.first {
                    targets += entries.map { hosted(template, $0) }
                }
                configs[i]["TestTargets"] = targets
            }
            plist["TestConfigurations"] = configs
        } else {
            for (key, value) in plist where !key.hasPrefix("__") {
                if let target = value as? [String: Any] { plist[key] = configure(target) }
            }
            if let template = plist[main] as? [String: Any] {
                for name in entries { plist[name] = hosted(template, name) }
            }
        }
        let dst = "\(slot.dir)/test.xctestrun"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: dst))
        return dst
    }

    /// Installs the slot via a zero-test run (xcodebuild is the only supported
    /// installer for DfI apps). Installs are serialized machine-wide.
    static func install(_ slot: SlotRecord, ws: Workspace) throws {
        try withLock("install") {
            let t = now()
            stop(slot)
            let log = "\(slot.dir)/install.log"
            // -derivedDataPath keeps xcodebuild's logs out of ~/Library/Developer/Xcode/DerivedData.
            let r = try Shell.run(["xcodebuild", "test-without-building", "-xctestrun", "\(slot.dir)/slot.xctestrun",
                                   "-derivedDataPath", ws.derivedData,
                                   "-destination", Workspace.dfiDestination,
                                   "-only-testing:\(ws.config.testTarget)/SimlessInstallOnly"],
                                  cwd: ws.root, logPath: log)
            // The zero-test run only exists to install. Under heavy load the app can
            // be slower to start than xcodebuild's test-bootstrap timeout, which then
            // kills it ("never finished bootstrapping"); the install itself succeeded.
            let installed = (try? FileManager.default.contentsOfDirectory(atPath: "\(slot.dir)/Debug-iphoneos/.XCInstall"))?
                .contains { $0.hasSuffix(".app") } ?? false
            guard r.code == 0 || (installed && r.out.contains("never finished bootstrapping")) else {
                throw SimlessError("install \(slot.slotID) failed (exit \(r.code)); log: \(log)\n"
                                   + r.out.split(separator: "\n").suffix(8).joined(separator: "\n"))
            }
            terminateAll(slot)
            hideExtensions(slot)
            Log.step("installed \(slot.slotID) in \(secs(t))")
        }
    }

    /// Launches the host headless and waits until it answers. `locale` (e.g.
    /// "hr" or "pt-BR") sets the app's language and region for the whole process.
    static func launch(_ slot: SlotRecord, idleMinutes: Int = 30, locale: String? = nil) throws {
        var extra: [String] = []
        if let locale {
            extra += ["--simless-locale", locale, "-AppleLanguages", "(\(locale))",
                      "-AppleLocale", locale.replacingOccurrences(of: "-", with: "_")]
        }
        // Fixtures can read files in the repository (read-only), like tests can.
        if let token = Sandbox.readToken(slot.worktree) { extra += ["--simless-sandbox", token] }
        let t = now()
        // By path, not bundle id: LaunchServices can hold several registrations
        // for one id (older installs) and `open -b` may pick a stale one.
        let installed = "\(slot.dir)/Debug-iphoneos/.XCInstall"
        guard let wrapper = (try? FileManager.default.contentsOfDirectory(atPath: installed))?.first(where: { $0.hasSuffix(".app") }) else {
            throw SimlessError("\(slot.slotID) is not installed; run `simless up`")
        }
        // Any instance not started by this launch (the install or test run's app,
        // which isn't a host) would swallow `open`: macOS runs one instance per
        // bundle id.
        if slot.stats() == nil { terminateAll(slot) }
        // The app's own startup can take a while on a busy machine: wait as long
        // as the process is alive, and reopen only when it isn't running.
        let startDeadline = now() + 60
        var opened = 0.0
        var restarts = 0
        let patience: [Double] = [10, 20, 30]
        while now() < startDeadline {
            let instances = NSRunningApplication.runningApplications(withBundleIdentifier: slot.slotID)
            // An instance that predates our open is not the host we asked for.
            let launchedAt = Date(timeIntervalSinceReferenceDate: opened - 1)
            if opened > 0, instances.contains(where: { ($0.launchDate ?? .distantPast) < launchedAt }) {
                Log.debug("stale instance: launchDates \(instances.map { $0.launchDate.map { "\($0.timeIntervalSinceReferenceDate - opened)" } ?? "nil" })")
                terminateAll(slot)
                opened = 0
            }
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: slot.slotID).isEmpty
            // Running but not serving: occasionally a launch never finishes starting
            // (seen right after test runs). Restart it, with growing patience so a
            // slow start on a loaded machine still gets time.
            if running, opened > 0, now() - opened > patience[min(restarts, patience.count - 1)] {
                Log.debug("host process not serving after \(Int(now() - opened))s; restarting it")
                terminateAll(slot)
                restarts += 1
                opened = 0
            }
            if !running && now() - opened > 3 {
                Log.debug("not running; opening (\(String(format: "%.1f", now() - t))s)")
                // Timestamp before `open`: on a busy machine it can take seconds to
                // return, and the new instance must not look older than the launch.
                opened = now()
                // The host's stderr names a trap (`Fatal error: ...`) when macOS
                // writes no crash report (it limits repeated ones).
                try? FileManager.default.removeItem(atPath: "\(slot.dir)/host.log")
                _ = try? Shell.run(["/usr/bin/open", "-g", "-j", "--stderr", "\(slot.dir)/host.log",
                                    "\(installed)/\(wrapper)", "--args",
                                    "--simless-port", String(slot.port),
                                    "--simless-idle", String(idleMinutes * 60)] + extra)
            }
            if let stats = slot.stats() {
                Log.step("host \(slot.slotID) up on :\(slot.port) in \(secs(t))")
                try reapplyPatch(slot, hostPatch: stats["patch"] as? Int ?? 0)
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw SimlessError("host \(slot.slotID) did not start; see \(slot.dir)/install.log")
    }

    /// A relaunched host starts from the installed build (plus any bundled warm
    /// patch). If live patches were applied since, load the newest one again.
    private static func reapplyPatch(_ slot: SlotRecord, hostPatch: Int) throws {
        guard hostPatch == 0, slot.patch > 0, let dylib = slot.lastPatch, exists(dylib) else { return }
        if let why = try Patch.live(dylib: dylib, slot: slot) {
            Log.info("  warning: could not re-apply the latest patch (\(why)); host shows the last full build. Run `simless reload`.")
        } else {
            Log.step("re-applied patch \(slot.patch)")
        }
    }

    /// Terminates every instance of the slot's bundle id, escalating to SIGKILL.
    static func terminateAll(_ slot: SlotRecord) {
        var apps = NSRunningApplication.runningApplications(withBundleIdentifier: slot.slotID)
        guard !apps.isEmpty else { return }
        apps.forEach { $0.forceTerminate() }
        let deadline = now() + 5
        while now() < deadline {
            apps = NSRunningApplication.runningApplications(withBundleIdentifier: slot.slotID)
            if apps.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        apps.forEach { kill($0.processIdentifier, SIGKILL) }
        Thread.sleep(forTimeInterval: 0.5)
    }

    static func stop(_ slot: SlotRecord) {
        guard let stats = slot.stats() else { return }
        _ = try? slot.client(timeout: 2).call(["cmd": "stop"])
        if let pid = stats["pid"] as? Int {
            for _ in 0..<30 where kill(pid_t(pid), 0) == 0 { Thread.sleep(forTimeInterval: 0.1) }
            if kill(pid_t(pid), 0) == 0 { kill(pid_t(pid), SIGKILL) }
        }
    }
}
