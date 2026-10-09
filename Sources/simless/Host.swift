// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

/// Newline-delimited JSON over TCP (render hosts) or a Unix socket (the agent).
final class LineClient {
    private let fd: Int32

    init(port: Int, timeout: Double = 15) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SimlessError("socket failed") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { close(fd); throw SimlessError("host not reachable on port \(port)") }
        setTimeout(timeout)
    }

    init(unixPath: String, timeout: Double = 10) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SimlessError("socket failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(unixPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw SimlessError("socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(fd); throw SimlessError("agent not reachable at \(unixPath)") }
        setTimeout(timeout)
    }

    deinit { close(fd) }

    private func setTimeout(_ seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private var pending = Data()

    func call(_ request: [String: Any]) throws -> [String: Any] {
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                guard n > 0 else { throw SimlessError("write failed") }
                off += n
            }
        }
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            if let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw SimlessError("bad response")
                }
                return obj
            }
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { throw SimlessError(n == 0 ? "connection closed" : "timed out waiting for response") }
            pending.append(contentsOf: buf[0..<n])
        }
    }
}

extension SlotRecord {
    func client(timeout: Double = 15) throws -> LineClient { try LineClient(port: port, timeout: timeout) }

    /// stats from the host, or nil when it isn't running.
    func stats() -> [String: Any]? {
        guard let c = try? LineClient(port: port, timeout: 3), let r = try? c.call(["cmd": "stats"]),
              r["ok"] as? Bool == true else { return nil }
        return r
    }
}
