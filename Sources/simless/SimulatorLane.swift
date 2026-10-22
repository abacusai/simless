// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// The command that runs the simulator-only tests in a simulator: each test
/// target with the scheme that tests it, and a destination for its platform
/// on an installed runtime.
enum SimulatorLane {
    /// Test target name -> the shared scheme whose test action (or test plan) has it.
    /// The configured scheme wins when several have the target.
    static func schemes(_ ws: Workspace) -> [String: String] {
        let projectDir = "\(ws.root)/\(ws.config.project)"
        let dir = "\(projectDir)/xcshareddata/xcschemes"
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".xcscheme") }
            .sorted { a, _ in a == "\(ws.config.scheme).xcscheme" }
        var out: [String: String] = [:]
        for file in files {
            let scheme = String(file.dropLast(".xcscheme".count))
            guard let xml = try? String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8),
                  let test = xml.range(of: "<TestAction").map({ String(xml[$0.lowerBound...]) }),
                  let end = test.range(of: "</TestAction>").map({ String(test[..<$0.lowerBound]) }) else { continue }
            var targets = matches(end, #"BlueprintName = "([^"]+)""#)
            // Test plans the scheme uses, next to the project.
            for plan in matches(end, #"reference = "container:([^"]+\.xctestplan)""#) {
                let path = ((projectDir as NSString).deletingLastPathComponent as NSString).appendingPathComponent(plan)
                if let data = FileManager.default.contents(atPath: path),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let list = json["testTargets"] as? [[String: Any]] {
                    targets += list.compactMap { ($0["target"] as? [String: Any])?["name"] as? String }
                }
            }
            for t in targets where out[t] == nil { out[t] = scheme }
        }
        return out
    }

    /// A target's platform from its SDKROOT in the project (iOS when it isn't a
    /// project target, like a local package's tests).
    static func platform(_ target: String, ws: Workspace) -> String {
        guard let pbx = try? String(contentsOfFile: "\(ws.root)/\(ws.config.project)/project.pbxproj", encoding: .utf8),
              let list = firstMatch(pbx, #"/\* \#(NSRegularExpression.escapedPattern(for: target)) \*/ = \{\s*isa = PBXNativeTarget;\s*buildConfigurationList = ([0-9A-F]+)"#),
              let configs = firstMatch(pbx, #"\#(list)[^=]*= \{\s*isa = XCConfigurationList;\s*buildConfigurations = \(([^)]*)\)"#),
              let config = matches(configs, #"([0-9A-F]{24})"#).first,
              let settings = firstMatch(pbx, #"\#(config)[^=]*= \{\s*isa = XCBuildConfiguration;\s*buildSettings = \{([\s\S]*?)\};\s*name"#) else { return "iOS" }
        let sdk = firstMatch(settings, #"SDKROOT = ([a-z]+);"#) ?? "iphoneos"
        switch sdk {
        case "watchos": return "watchOS"
        case "appletvos": return "tvOS"
        case "xros": return "visionOS"
        default: return "iOS"
        }
    }

    /// `platform=<X> Simulator,name=<device>,OS=<version>` on the newest
    /// runtime installed for the platform (or `calibrate.runtime` for iOS).
    /// Where a platform's simulator-only tests run, or what's missing for it.
    enum Destination {
        case ready(String)
        case missing(String)
    }

    /// The configured device type (`calibrate.device`, or an Apple Watch for
    /// watchOS) on the configured runtime (`calibrate.runtime`, else the newest
    /// installed one). Only a simulator named exactly like the device type
    /// counts: another session's simulator, booted or renamed, never stands in.
    static func destination(_ platform: String, ws: Workspace) -> Destination {
        let deviceType = platform == "watchOS" ? "Apple Watch Series 11 (46mm)" : (ws.config.calibrate?.device ?? Calibrate.simDeviceType)
        guard let out = try? Shell.run(["xcrun", "simctl", "list", "-j", "devices", "available"], stdoutOnly: true).out,
              let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else {
            return .missing("`xcrun simctl list` didn't answer, so there's no simulator to check")
        }
        // Runtime keys look like com.apple.CoreSimulator.SimRuntime.iOS-26-5.
        let prefix = "com.apple.CoreSimulator.SimRuntime.\(platform)-"
        func version(_ key: String) -> [Int] { key.dropFirst(prefix.count).split(separator: "-").compactMap { Int($0) } }
        let installed = devices.keys.filter { $0.hasPrefix(prefix) }.sorted { version($0).lexicographicallyPrecedes(version($1)) }
        let wanted = ws.config.calibrate?.runtime
        let runtime: String
        if let wanted {
            let w = wanted.split(separator: ".").compactMap { Int($0) }
            guard let r = installed.last(where: { Array(version($0).prefix(w.count)) == w }) else {
                return .missing("no \(platform) \(wanted) simulator runtime is installed (calibrate.runtime). Install it with "
                    + "`xcodebuild -downloadPlatform \(platform) -buildVersion \(wanted)`, or set calibrate.runtime to an installed one: "
                    + (installed.isEmpty ? "none installed" : installed.map { version($0).map(String.init).joined(separator: ".") }.joined(separator: ", ")))
            }
            runtime = r
        } else {
            guard let r = installed.last else {
                return .missing("no \(platform) simulator runtime is installed. Install one with `xcodebuild -downloadPlatform \(platform)`")
            }
            runtime = r
        }
        let os = version(runtime).map(String.init).joined(separator: ".")
        guard (devices[runtime] ?? []).contains(where: { ($0["name"] as? String) == deviceType }) else {
            let type = deviceTypeID(deviceType) ?? "com.apple.CoreSimulator.SimDeviceType.\(deviceType.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: ""))"
            return .missing("no simulator named \"\(deviceType)\" on \(platform) \(os). Create it with "
                + "`xcrun simctl create \"\(deviceType)\" \(type) \(runtime)`")
        }
        return .ready("platform=\(platform) Simulator,name=\(deviceType),OS=\(os)")
    }

    /// The simctl identifier of a device type by its name.
    static func deviceTypeID(_ name: String) -> String? {
        guard let out = try? Shell.run(["xcrun", "simctl", "list", "-j", "devicetypes"], stdoutOnly: true).out,
              let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let types = json["devicetypes"] as? [[String: Any]] else { return nil }
        return types.first { ($0["name"] as? String) == name }?["identifier"] as? String
    }

    private static func matches(_ text: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }

    private static func firstMatch(_ text: String, _ pattern: String) -> String? { matches(text, pattern).first }
}

/// App code that checks `targetEnvironment(simulator)`. simless builds the app
/// for a device, so that code takes its device branch, and a test written
/// against the simulator branch fails here for that reason alone.
enum SimulatorBranches {
    /// A note for a run with failures, or nil when the app has no such check.
    static func note(_ ws: Workspace) -> String? {
        guard let r = try? Shell.run(["git", "-C", ws.root, "grep", "-l", "-F", "targetEnvironment(simulator)", "--", "*.swift"],
                                     useXcode: false, stdoutOnly: true), r.code == 0 else { return nil }
        let files = r.out.split(separator: "\n").map(String.init).filter { !$0.contains("Tests") }
        guard let first = files.first else { return nil }
        let more = files.count > 1 ? " and \(files.count - 1) more" : ""
        return "note: the app checks targetEnvironment(simulator) in \(first)\(more). simless builds for a device, "
            + "so that code runs its device branch here. Code that should take the simulator's branch under simless too "
            + "(a mock store, say) can check `targetEnvironment(simulator) || SIMLESS`. A test that counts on the "
            + "simulator itself needs one: add it to tests.simulatorOnly in \(Workspace.configName)"
    }
}
