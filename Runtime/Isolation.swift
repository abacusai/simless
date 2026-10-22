// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

// Isolation for native hosts on shared machines (SIMLESS_ISOLATE=1, or
// "isolate": true in .simless.json). A native host runs outside the app
// sandbox, so the app's code could read and write anything its user can: on
// a build machine serving many projects as one user, other projects' files.
// Before the app's own code runs, the runtime puts the process in a sandbox
// of its own (the mechanism behind sandbox-exec, no entitlement needed):
// - it writes only into its slot (home, tmp) and the system's temporary folders;
// - in the user's home folder it reads only its slot, its worktree, its build
//   folder, and simless's runtime;
// - it can't connect to other simless hosts on this machine.
// Everything else (frameworks, Xcode, the network) works as before.

import Foundation

@_silgen_name("simless_sandbox_apply")
private func simless_sandbox_apply(_ profile: UnsafePointer<CChar>, _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

enum Isolation {
    static func apply(env: [String: String]) {
        guard let slot = env["SIMLESS_ISOLATE_SLOT"], let home = env["SIMLESS_ISOLATE_USER_HOME"] else { return }
        let readable = (env["SIMLESS_ISOLATE_READ"] ?? "").split(separator: "\n").map(String.init)
        let port = env["SIMLESS_ISOLATE_PORT"] ?? "0"
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let profile = """
            (version 1)
            (allow default)
            (deny file-write* (subpath \(q(home))) (subpath "/private/tmp") (subpath "/Volumes"))
            (allow file-write* (subpath \(q(slot))))
            (deny file-read* (subpath \(q(home))))
            (allow file-read* (literal \(q(home))) (subpath \(q(slot))) \(readable.map { "(subpath \(q($0)))" }.joined(separator: " ")))
            (deny network-outbound (remote ip "localhost:*"))
            (allow network-outbound (remote ip \(q("localhost:" + port))))
            """
        if env["SIMLESS_ISOLATE_DEBUG"] == "1" { runtimeLog("isolation profile:\n" + profile) }
        var error: UnsafeMutablePointer<CChar>?
        let rc = simless_sandbox_apply(profile, &error)
        if rc != 0 {
            runtimeLog("isolation failed: \(error.map { String(cString: $0) } ?? "?")")
            exit(70)   // never run unisolated when isolation was asked for
        }
    }
}
