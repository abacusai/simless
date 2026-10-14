// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// SimlessRuntime.dylib, injected into every host (see Runtime/Runtime.swift).
/// Built from the simless source folder for this Xcode, signed with the team's
/// identity, and cached until simless or Xcode changes.
enum RuntimeBuild {
    static func dylib(team: String) throws -> String {
        let unsigned = try compiled()
        let dir = (unsigned as NSString).deletingLastPathComponent
        let out = "\(dir)/signed-\(shortHash(team))/SimlessRuntime.dylib"
        if exists(out) { return out }
        return try withLock("runtime-build") {
            if exists(out) { return out }
            try mkdirp((out as NSString).deletingLastPathComponent)
            try? FileManager.default.removeItem(atPath: out + ".tmp")
            try FileManager.default.copyItem(atPath: unsigned, toPath: out + ".tmp")
            try Signing.sign(out + ".tmp", identity: try Signing.identity(team: team).0)
            try FileManager.default.moveItem(atPath: out + ".tmp", toPath: out)
            return out
        }
    }

    /// Compiles the runtime ahead of time (`simless up` does it next to the
    /// app's build, since it needs nothing from it).
    static func prebuild() { _ = try? compiled() }

    /// The runtime compiled for this simless and Xcode, not yet signed.
    static func compiled() throws -> String {
        let sources = ((try? FileManager.default.contentsOfDirectory(atPath: "\(Paths.toolRoot)/Runtime")) ?? [])
            .filter { $0.hasSuffix(".swift") || $0.hasSuffix(".c") || $0.hasSuffix(".m") }.sorted().map { "\(Paths.toolRoot)/Runtime/\($0)" }
        let xcode = (try? Shell.run(["xcodebuild", "-version"]).out) ?? ""
        let stamp = shortHash(([version, xcode] + sources.map { "\($0) \(mtime($0))" }).joined(separator: "|"))
        let dir = "\(Paths.cache)/runtime/\(stamp)"
        let out = "\(dir)/SimlessRuntime.dylib"
        if exists(out) { return out }
        return try withLock("runtime-build") {
            if exists(out) { return out }
            let t = now()
            try mkdirp(dir)
            let sdk = try Shell.check(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
            var objects: [String] = []
            for c in sources where c.hasSuffix(".c") || c.hasSuffix(".m") {
                let o = "\(dir)/\(((c as NSString).lastPathComponent as NSString).deletingPathExtension).o"
                try Shell.check(["xcrun", "clang", "-c", "-O2", "-fobjc-arc", "-target", "arm64-apple-ios17.0", "-isysroot", sdk, c, "-o", o],
                                what: "compile \((c as NSString).lastPathComponent)")
                objects.append(o)
            }
            try Shell.check(["xcrun", "swiftc", "-emit-library", "-O", "-module-name", "SimlessRuntime",
                             "-target", "arm64-apple-ios17.0", "-sdk", sdk, "-swift-version", "5",
                             "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup", "-framework", "IOKit", "-o", out + ".tmp"]
                            + sources.filter { $0.hasSuffix(".swift") } + objects, what: "build SimlessRuntime")
            try FileManager.default.moveItem(atPath: out + ".tmp", toPath: out)
            Log.step("built SimlessRuntime in \(secs(t))")
            // Older builds of the runtime are no use once this one exists.
            for old in (try? FileManager.default.contentsOfDirectory(atPath: "\(Paths.cache)/runtime")) ?? [] where old != stamp {
                try? FileManager.default.removeItem(atPath: "\(Paths.cache)/runtime/\(old)")
            }
            return out
        }
    }

    /// Xcode's test frameworks for an iOS app on the Mac (what xcodebuild puts
    /// on DYLD_FRAMEWORK_PATH for "Designed for iPad" test runs).
    static var developerDir: String {
        Shell.developerDir ?? (try? Shell.run(["/usr/bin/xcode-select", "-p"], useXcode: false).out
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "/Applications/Xcode.app/Contents/Developer"
    }

    static var testFrameworkEnv: [String: String] {
        let p = "\(developerDir)/Platforms/MacOSX.platform/Developer"
        return ["DYLD_FRAMEWORK_PATH": "\(p)/Library/Frameworks:\(p)/Library/PrivateFrameworks",
                "DYLD_LIBRARY_PATH": "\(p)/usr/lib"]
    }
}
