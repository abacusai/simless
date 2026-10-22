// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// Startup work a real app does: fetch its remote config, through a session of
/// its own (which only uses the URL protocols its configuration lists). A render
/// host must not reach the network: simless blocks the request and says so in
/// the render, and CI checks that.
enum RemoteConfig {
    static func fetch() {
        let session = URLSession(configuration: .default)
        session.dataTask(with: URL(string: "https://example.com/simless-demo/config.json")!) { _, _, _ in }.resume()
    }
}
