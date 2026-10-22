// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation
import ObjectiveC

/// No network from a render host unless the project allows it. A render host
/// runs the app's real startup, and on a shared build machine that meant real
/// production calls (user info, analytics events) from every host.
///
/// Every http(s) and ws(s) request through URL Loading (`URLSession`, shared or
/// with its own configuration, and `NSURLConnection`) fails as if the Mac were
/// offline (`URLError.notConnectedToInternet`), except loopback, hosts and URLs
/// the project allows, and URLs it stubs with a file. Each blocked request is
/// one `simless-network: blocked <METHOD> <URL>` line on stderr (the host's
/// log), which `simless render` sums up per host.
///
/// Config (from `.simless.json` "network"): SIMLESS_NETWORK is JSON,
/// `{"allow": ["api.example.com", "*.example.com", "https://x.com/v1/*"],
///   "stub": {"https://x.com/config*": "/abs/path/config.json"}}`.
/// Patterns are globs, matched against the host and against the whole URL.
enum NetworkGuard {
    static var allow: [String] = []
    static var stubs: [(pattern: String, file: String)] = []

    static func install(_ json: String) {
        if let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            allow = o["allow"] as? [String] ?? []
            stubs = ((o["stub"] as? [String: String]) ?? [:]).sorted { $0.key.count > $1.key.count }.map { ($0.key, $0.value) }
        }
        URLProtocol.registerClass(BlockingURLProtocol.self)
        // Sessions with their own configuration only use the protocols in it:
        // every new default or ephemeral configuration gets this one first.
        for name in ["defaultSessionConfiguration", "ephemeralSessionConfiguration"] {
            let sel = NSSelectorFromString(name)
            guard let cls = object_getClass(URLSessionConfiguration.self),
                  let method = class_getClassMethod(URLSessionConfiguration.self, sel) else { continue }
            typealias Make = @convention(c) (AnyClass, Selector) -> URLSessionConfiguration
            let original = unsafeBitCast(method_getImplementation(method), to: Make.self)
            let block: @convention(block) (AnyClass) -> URLSessionConfiguration = { me in
                let config = original(me, sel)
                config.protocolClasses = [BlockingURLProtocol.self] + (config.protocolClasses ?? []).filter { $0 != BlockingURLProtocol.self }
                return config
            }
            class_replaceMethod(cls, sel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
    }

    static func matches(_ pattern: String, _ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return fnmatch(pattern.lowercased(), host, 0) == 0 || fnmatch(pattern, url.absoluteString, 0) == 0
    }

    static func stub(for url: URL) -> String? { stubs.first { matches($0.pattern, url) }?.file }

    /// Whether a request is left to the real network.
    static func passes(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "ws", "wss"].contains(scheme) else { return true }
        let host = url.host?.lowercased() ?? ""
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost") { return true }
        return stub(for: url) == nil && allow.contains { matches($0, url) }
    }
}

final class BlockingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return !NetworkGuard.passes(url)
    }

    override class func canInit(with task: URLSessionTask) -> Bool {
        guard let url = task.currentRequest?.url ?? task.originalRequest?.url else { return false }
        return !NetworkGuard.passes(url)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if let file = NetworkGuard.stub(for: url), let data = FileManager.default.contents(atPath: file) {
            let type = ["json": "application/json", "html": "text/html", "txt": "text/plain", "png": "image/png",
                        "jpg": "image/jpeg", "jpeg": "image/jpeg", "svg": "image/svg+xml"][(file as NSString).pathExtension.lowercased()]
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": type ?? "application/octet-stream", "Content-Length": "\(data.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        FileHandle.standardError.write(Data("simless-network: blocked \(request.httpMethod ?? "GET") \(url.absoluteString)\n".utf8))
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet, userInfo: [
            NSURLErrorFailingURLErrorKey: url,
            NSLocalizedDescriptionKey: "simless blocks the network in render hosts; allow this host in .simless.json \"network.allow\"",
        ]))
    }

    override func stopLoading() {}
}
