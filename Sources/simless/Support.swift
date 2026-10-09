// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation

struct SimlessError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

// MARK: - Output

enum Log {
    static var verbose = false
    static func info(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    static func step(_ s: String) { info("▸ " + s) }
    static func debug(_ s: String) { if verbose { info("  " + s) } }
}

func now() -> Double { CFAbsoluteTimeGetCurrent() }
func secs(_ since: Double) -> String { String(format: "%.1fs", now() - since) }

// MARK: - Paths

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// Everything simless builds or caches. The agent only accepts patches from here.
    static let cache = "\(home)/Library/Caches/simless"
    static let support = "\(home)/Library/Application Support/Simless"
    static let slots = "\(cache)/slots"
    static let locks = "\(cache)/locks"
    static let statePath = "\(cache)/state.json"
    static let agentApp = "\(support)/SimlessAgent.app"
    static let agentSocket = "\(support)/agent.sock"

    /// The simless source checkout (templates, agent source). Resolved at compile time.
    static let toolRoot: String = {
        var url = URL(fileURLWithPath: #filePath)   // <root>/Sources/simless/Support.swift
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.path
    }()

    static func workDir(forWorktree worktree: String) -> String {
        "\(cache)/work/\(shortHash(worktree))-\((worktree as NSString).lastPathComponent)"
    }
}

func shortHash(_ s: String) -> String {
    // FNV-1a, enough to key cache directories.
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return String(h, radix: 16).prefix(10).description
}

func mkdirp(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

func mtime(_ path: String) -> Double {
    ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?
        .timeIntervalSinceReferenceDate ?? 0
}

// MARK: - Processes

struct Shell {
    /// DEVELOPER_DIR pointing at full Xcode when xcode-select points at CommandLineTools.
    static let developerDir: String? = {
        if let d = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] { return d }
        let selected = (try? run(["/usr/bin/xcode-select", "-p"], useXcode: false).out)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if selected.contains("CommandLineTools"), exists("/Applications/Xcode.app") {
            return "/Applications/Xcode.app/Contents/Developer"
        }
        return nil
    }()

    struct Result { let code: Int32; let out: String }

    /// Runs a command, capturing stdout+stderr (into `logPath` too, if given).
    @discardableResult
    /// `stdoutOnly`: discard stderr (for commands whose stdout is JSON).
    static func run(_ args: [String], cwd: String? = nil, env: [String: String] = [:],
                    logPath: String? = nil, useXcode: Bool = true, stdoutOnly: Bool = false) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0].hasPrefix("/") ? args[0] : "/usr/bin/env")
        p.arguments = args[0].hasPrefix("/") ? Array(args.dropFirst()) : args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var environment = ProcessInfo.processInfo.environment
        if useXcode, let dev = developerDir { environment["DEVELOPER_DIR"] = dev }
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        // Through a file, not a pipe: xcodebuild output can exceed pipe buffers.
        let out = logPath ?? NSTemporaryDirectory() + "simless-\(UUID().uuidString).log"
        FileManager.default.createFile(atPath: out, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: out))
        p.standardOutput = handle
        p.standardError = stdoutOnly ? FileHandle.nullDevice : handle
        try p.run()
        p.waitUntilExit()
        try handle.close()
        let text = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
        if logPath == nil { try? FileManager.default.removeItem(atPath: out) }
        Log.debug("$ \(args.joined(separator: " ")) -> \(p.terminationStatus)")
        return Result(code: p.terminationStatus, out: text)
    }

    @discardableResult
    static func check(_ args: [String], cwd: String? = nil, logPath: String? = nil,
                      what: String? = nil, stdoutOnly: Bool = false) throws -> String {
        let r = try run(args, cwd: cwd, logPath: logPath, stdoutOnly: stdoutOnly)
        guard r.code == 0 else {
            let tail = r.out.split(separator: "\n").suffix(15).joined(separator: "\n")
            throw SimlessError("\(what ?? args.first ?? "command") failed (exit \(r.code))"
                          + (logPath.map { "; log: \($0)" } ?? "") + "\n" + tail)
        }
        return r.out
    }
}

// MARK: - Locks

/// flock-based mutual exclusion across every simless process (all agents, all projects).
func withLock<T>(_ name: String, _ body: () throws -> T) throws -> T {
    try mkdirp(Paths.locks)
    let fd = open("\(Paths.locks)/\(name).lock", O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { throw SimlessError("cannot open lock \(name)") }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        Log.debug("waiting for lock \(name)")
        flock(fd, LOCK_EX)
    }
    defer { flock(fd, LOCK_UN) }
    return try body()
}

/// Takes one of `count` build tokens so concurrent agents don't all compile at once.
func withBuildToken<T>(count: Int, _ body: () throws -> T) throws -> T {
    try mkdirp(Paths.locks)
    while true {
        for i in 0..<count {
            let fd = open("\(Paths.locks)/build-\(i).lock", O_CREAT | O_RDWR, 0o644)
            if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 {
                defer { flock(fd, LOCK_UN); close(fd) }
                return try body()
            }
            if fd >= 0 { close(fd) }
        }
        Log.debug("all \(count) build slots busy; waiting")
        Thread.sleep(forTimeInterval: 0.5)
    }
}

// MARK: - Global state (slot assignments), guarded by the "state" lock

struct SlotRecord: Codable {
    var bundleBase: String      // e.g. com.example.app
    var n: Int                  // slot number -> <bundleBase>.simless<n>
    var worktree: String
    var port: Int
    var builtAt: Double = 0     // reference-date seconds of the last full build
    var patch: Int = 0          // patches applied since that build
    var lastPatch: String?      // newest patch dylib; re-applied whenever the host relaunches
    var slotID: String { "\(bundleBase).simless\(n)" }
    var dir: String { "\(Paths.slots)/\(slotID)" }
}

struct GlobalState: Codable {
    var slots: [SlotRecord] = []

    static func load() -> GlobalState {
        guard let d = FileManager.default.contents(atPath: Paths.statePath),
              let s = try? JSONDecoder().decode(GlobalState.self, from: d) else { return GlobalState() }
        return s
    }

    func save() throws {
        try mkdirp(Paths.cache)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: URL(fileURLWithPath: Paths.statePath), options: .atomic)
    }

    /// Returns this worktree's slot, assigning the lowest free slot number and port.
    static func slot(bundleBase: String, worktree: String) throws -> SlotRecord {
        try withLock("state") {
            var s = load()
            if let r = s.slots.first(where: { $0.bundleBase == bundleBase && $0.worktree == worktree }) { return r }
            let usedN = Set(s.slots.filter { $0.bundleBase == bundleBase }.map(\.n))
            let usedPorts = Set(s.slots.map(\.port))
            let n = (1...).first { !usedN.contains($0) }!
            let port = (47800...).first { !usedPorts.contains($0) }!
            let r = SlotRecord(bundleBase: bundleBase, n: n, worktree: worktree, port: port)
            s.slots.append(r)
            try s.save()
            return r
        }
    }

    static func update(_ record: SlotRecord) throws {
        try withLock("state") {
            var s = load()
            s.slots.removeAll { $0.slotID == record.slotID }
            s.slots.append(record)
            try s.save()
        }
    }

    static func release(_ record: SlotRecord) throws {
        try withLock("state") {
            var s = load()
            s.slots.removeAll { $0.slotID == record.slotID }
            try s.save()
        }
    }
}
