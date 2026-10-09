// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import AppKit

/// A slot is one installed copy of the app under its own bundle id
/// (<bundle id>.simless<N>), so several agents can each run a render host of the
/// same app at once (macOS runs one instance per bundle id).
enum Slots {

    /// Clones the fresh build into the slot and re-signs it as <id>.simlessN:
    /// no app extensions, no capabilities, LSUIElement (never a Dock icon).
    static func prepare(_ slot: SlotRecord, ws: Workspace, settings: Workspace.Settings) throws {
        let t = now()
        let signing = try Signing.material(team: settings.team)
        let products = "\(slot.dir)/Debug-iphoneos"
        let app = "\(products)/\(settings.wrapperName)"
        try? FileManager.default.removeItem(atPath: products)
        try mkdirp(products)
        // APFS clone: near-free copy of a multi-hundred-MB app.
        try Shell.check(["/bin/cp", "-c", "-R", "\(ws.productsIphoneos)/\(settings.wrapperName)", app], what: "clone app")

        let fm = FileManager.default
        for plugin in (try? fm.contentsOfDirectory(atPath: "\(app)/PlugIns")) ?? [] where plugin.hasSuffix(".appex") {
            try fm.removeItem(atPath: "\(app)/PlugIns/\(plugin)")   // ids would fail the .simlessN prefix check
        }
        try? fm.removeItem(atPath: "\(app)/Watch")
        try? fm.removeItem(atPath: "\(app)/SimlessPatches")

        let info = "\(app)/Info.plist"
        try Shell.check(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleIdentifier \(slot.slotID)", info])
        _ = try? Shell.run(["/usr/libexec/PlistBuddy", "-c", "Delete :LSUIElement", info])
        try Shell.check(["/usr/libexec/PlistBuddy", "-c", "Add :LSUIElement bool true", info])
        try fm.copyItem(atPath: signing.profilePath, toPath: "\(app)/embedded.mobileprovision")

        let entitlements = "\(slot.dir)/entitlements.plist"
        try """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>application-identifier</key><string>\(settings.team).\(slot.slotID)</string>
              <key>com.apple.developer.team-identifier</key><string>\(settings.team)</string>
              <key>get-task-allow</key><true/>
            </dict></plist>
            """.write(toFile: entitlements, atomically: true, encoding: .utf8)

        // Built unsigned: sign nested code inside-out, then the app.
        for path in nestedCode(in: app) { try Signing.sign(path, identity: signing.identity) }
        try Signing.sign(app, identity: signing.identity, entitlements: entitlements)

        // xctestrun for installing: same as the build's, host bundle id swapped.
        guard let src = (try? fm.contentsOfDirectory(atPath: ws.products))?.first(where: { $0.hasSuffix(".xctestrun") }) else {
            throw SimlessError("build produced no .xctestrun (is \(ws.config.testTarget) an app-hosted unit-test target?)")
        }
        let xctestrun = "\(slot.dir)/slot.xctestrun"
        try? fm.removeItem(atPath: xctestrun)
        try fm.copyItem(atPath: "\(ws.products)/\(src)", toPath: xctestrun)
        let n = Int(try Shell.check(["/usr/bin/plutil", "-extract", "TestConfigurations.0.TestTargets", "raw", xctestrun])
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        for i in 0..<n {
            let key = "TestConfigurations.0.TestTargets.\(i).TestHostBundleIdentifier"
            if (try? Shell.check(["/usr/bin/plutil", "-extract", key, "raw", xctestrun]))?
                .trimmingCharacters(in: .whitespacesAndNewlines) == settings.bundleID {
                try Shell.check(["/usr/bin/plutil", "-replace", key, "-string", slot.slotID, xctestrun])
            }
        }
        Log.step("slot \(slot.slotID) prepared in \(secs(t))")
    }

    /// Frameworks, dylibs and test bundles inside the app, deepest first.
    private static func nestedCode(in app: String) -> [String] {
        var found: [String] = []
        guard let e = FileManager.default.enumerator(atPath: app) else { return [] }
        while let rel = e.nextObject() as? String {
            let ext = (rel as NSString).pathExtension
            if ["framework", "xctest", "dylib"].contains(ext) { found.append("\(app)/\(rel)") }
        }
        return found.sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
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
            Log.step("installed \(slot.slotID) in \(secs(t))")
        }
    }

    /// Launches the host headless and waits until it answers.
    static func launch(_ slot: SlotRecord, idleMinutes: Int = 30) throws {
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
        while now() < startDeadline {
            let instances = NSRunningApplication.runningApplications(withBundleIdentifier: slot.slotID)
            // An instance that predates our open is not the host we asked for.
            let launchedAt = Date(timeIntervalSinceReferenceDate: opened - 1)
            if opened > 0, instances.contains(where: { ($0.launchDate ?? .distantPast) < launchedAt }) {
                terminateAll(slot)
                opened = 0
            }
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: slot.slotID).isEmpty
            if !running && now() - opened > 3 {
                // Timestamp before `open`: on a busy machine it can take seconds to
                // return, and the new instance must not look older than the launch.
                opened = now()
                _ = try? Shell.run(["/usr/bin/open", "-g", "-j", "\(installed)/\(wrapper)", "--args",
                                    "--simless-port", String(slot.port),
                                    "--simless-idle", String(idleMinutes * 60)])
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
