// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// Signing without touching the developer account: slots are signed with an
/// existing team *wildcard* development profile ("iOS Team Provisioning Profile: *")
/// that already lists this Mac, using the team's Apple Development identity.
enum Signing {
    struct Material {
        let identity: String      // codesign identity (SHA-1 of the certificate)
        let identityName: String
        let profilePath: String
    }

    static func material(team: String) throws -> Material {
        let (hash, name) = try identity(team: team)
        return Material(identity: hash, identityName: name, profilePath: try wildcardProfile(team: team))
    }

    /// The Apple Development identity whose certificate belongs to `team`.
    /// Cached per team (hot reload signs every patch); revalidated against the
    /// keychain's valid identities, which is cheap.
    static func identity(team: String) throws -> (String, String) {
        let cache = "\(Paths.cache)/identity-\(team).txt"
        let out = try Shell.check(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
        if let cached = try? String(contentsOfFile: cache, encoding: .utf8) {
            let parts = cached.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2, out.contains(parts[0]) { return (parts[0], parts[1]) }
        }
        let found = try lookupIdentity(team: team, validIdentities: out)
        try? mkdirp(Paths.cache)
        try? "\(found.0)\t\(found.1)".write(toFile: cache, atomically: true, encoding: .utf8)
        return found
    }

    /// Teams of the valid Apple Development identities in the keychain.
    static func developmentTeams() throws -> Set<String> {
        let out = try Shell.check(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
        var teams = Set<String>()
        for line in out.split(separator: "\n") where line.contains("Apple Development") {
            let parts = line.split(separator: "\"")
            if parts.count >= 2, let team = try certificateTeam(name: String(parts[1])) { teams.insert(team) }
        }
        return teams
    }

    private static func lookupIdentity(team: String, validIdentities out: String) throws -> (String, String) {
        // `  1) <SHA1> "Apple Development: Name (XXXXXXXXXX)"`
        for line in out.split(separator: "\n") where line.contains("Apple Development") {
            let parts = line.split(separator: "\"")
            guard parts.count >= 2,
                  let hash = line.split(separator: " ").first(where: { $0.count == 40 }) else { continue }
            let name = String(parts[1])
            if try certificateTeam(name: name) == team { return (String(hash), name) }
        }
        throw SimlessError("no valid 'Apple Development' signing identity for team \(team) in the keychain")
    }

    private static func certificateTeam(name: String) throws -> String? {
        let pem = try Shell.run(["/usr/bin/security", "find-certificate", "-c", name, "-p"]).out
        let tmp = NSTemporaryDirectory() + "simless-cert-\(UUID().uuidString).pem"
        try pem.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let subject = try Shell.run(["/usr/bin/openssl", "x509", "-in", tmp, "-noout", "-subject"]).out
        // subject=UID=..., CN=..., OU=<TEAM>, O=..., C=..
        return subject.range(of: #"OU ?= ?([A-Z0-9]{10})"#, options: .regularExpression)
            .map { String(subject[$0].suffix(10)) }
    }

    /// This Mac's provisioning UDID, as listed in development profiles.
    static func macUDID() throws -> String {
        let out = try Shell.check(["/usr/sbin/system_profiler", "SPHardwareDataType"])
        guard let line = out.split(separator: "\n").first(where: { $0.contains("Provisioning UDID") }),
              let udid = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else {
            throw SimlessError("could not read this Mac's provisioning UDID")
        }
        return udid
    }

    static func wildcardProfile(team: String) throws -> String {
        let udid = try macUDID()
        let dirs = ["\(Paths.home)/Library/Developer/Xcode/UserData/Provisioning Profiles",
                    "\(Paths.home)/Library/MobileDevice/Provisioning Profiles"]
        var best: (path: String, expires: Date)?
        for dir in dirs {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".mobileprovision") {
                let path = "\(dir)/\(file)"
                guard let plist = try? decodeProfile(path),
                      let ent = plist["Entitlements"] as? [String: Any],
                      ent["application-identifier"] as? String == "\(team).*",
                      let devices = plist["ProvisionedDevices"] as? [String], devices.contains(udid),
                      let expires = plist["ExpirationDate"] as? Date, expires > Date() else { continue }
                if best == nil || expires > best!.expires { best = (path, expires) }
            }
        }
        guard let best else {
            throw SimlessError("""
                no team wildcard development profile (\(team).*) that includes this Mac (\(udid)).
                Xcode creates one when you run any app from Xcode on "My Mac (Designed for iPad)" with automatic signing.
                """)
        }
        return best.path
    }

    static func decodeProfile(_ path: String) throws -> [String: Any] {
        let xml = try Shell.check(["/usr/bin/security", "cms", "-D", "-i", path])
        return try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any] ?? [:]
    }

    /// Signs `path` (a bundle or Mach-O). Entitlements only for the app itself.
    static func sign(_ path: String, identity: String, entitlements: String? = nil) throws {
        var args = ["/usr/bin/codesign", "-f", "-s", identity, "--timestamp=none"]
        if let entitlements { args += ["--entitlements", entitlements, "--generate-entitlement-der"] }
        try Shell.check(args + [path], what: "codesign \((path as NSString).lastPathComponent)")
    }
}
