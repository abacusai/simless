// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

// SimlessRuntime: loaded into every simless host with DYLD_INSERT_LIBRARIES.
// It needs nothing from the app (no SimlessKit changes), so new simless
// versions bring new runtime features without `simless init`.
//
// - Dynamic Type that scales (interpose.c).
// - Original bundle ids for app extensions and the watch app, which the slot
//   renames under its own id.
// - A test runner: test bundles are loaded into this warm process and run
//   in-process (Swift Testing through its ABI entry point, XCTest through its
//   runtime), streaming events to `simless test`. No xcodebuild launch per run.
// - UI automation for `simless test` UI tests (UIAutomation.swift).
//
// Protocol: newline-delimited JSON on 127.0.0.1:$SIMLESS_RUNTIME_PORT.

import Foundation
import Darwin
import UIKit

let runtimeVersion = 1

@_silgen_name("simless_install_crash_handler") func simless_install_crash_handler()
@_silgen_name("simless_touch") func simless_touch(_ window: UIWindow, _ point: CGPoint, _ phase: Int32) -> Bool
@_silgen_name("simless_touch_error") func simless_touch_error() -> UnsafePointer<CChar>?
@_silgen_name("simless_catch") func simless_catch(_ body: @convention(c) (UnsafeMutableRawPointer?) -> Void, _ context: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?

func runtimeLog(_ s: String) {
    FileHandle.standardError.write(Data(("simless-runtime: " + s + "\n").utf8))
}

@_cdecl("simless_runtime_start")
public func simlessRuntimeStart() {
    let env = ProcessInfo.processInfo.environment
    // simless removing a slot: the app empties its own data container (macOS
    // lets nothing else touch it) and quits before anything else runs.
    // A native host on a shared machine: its own sandbox first, before any of the app's code.
    if env["SIMLESS_NATIVE"] == "1", env["SIMLESS_ISOLATE_SLOT"] != nil { Isolation.apply(env: env) }
    // A native host (unsandboxed, its home redirected into the slot) before anything reads its data.
    if env["SIMLESS_NATIVE"] == "1" { NativeHost.install() }
    if env["SIMLESS_WIPE"] == "1" {
        // Only ever the app's own container or slot home, never a real home folder.
        guard Housekeeping.isAppData(NSHomeDirectory()) else { exit(1) }
        // Preferences go through cfprefsd: deleting its files behind its back
        // made the next launch's settings vanish.
        Housekeeping.resetDefaults()
        Housekeeping.empty(NSHomeDirectory(), keepFolders: 2, keeping: ["Preferences"])
        exit(0)
    }
    // A test run starts with an empty tmp, so what tests leave there doesn't pile up.
    if env["SIMLESS_CLEAN_TMP"] == "1", Housekeeping.isAppData(NSTemporaryDirectory()) { Housekeeping.empty(NSTemporaryDirectory()) }
    raiseOpenFileLimit()
    // No macOS permission or review dialogs from a host (SIMLESS_PERMISSIONS=ask lets them through).
    if env["SIMLESS_PERMISSIONS"] != "ask" { Permissions.install() }
    consumeSandboxTokens(env["SIMLESS_SANDBOX_TOKENS"])
    if let slot = env["SIMLESS_SLOT_ID"], let original = env["SIMLESS_ORIGINAL_BUNDLE_ID"] {
        BundleIDs.restore(slot: slot, original: original)
    }
    AppGroups.redirect()
    TabSidebar.install()
    if let model = env["SIMLESS_DEVICE_MODEL"], !model.isEmpty { DeviceModel.apply(model) }
    // Unit test hosts: windows tests make get the device's size and safe areas.
    if env["SIMLESS_UI"] != "1", let canvas = env["SIMLESS_UNIT_CANVAS"] { UnitCanvas.install(canvas) }
    if env["SIMLESS_UI"] == "1" {
        Headless.install()
        // An iPhone supports a watch session; asked at startup, so set it now.
        if (env["SIMLESS_UI_CANVAS"] ?? "").split(separator: ",").first.flatMap({ Double($0) }).map({ $0 < 600 }) ?? true {
            DeviceModel.watchSupported()
        }
    }
    if let port = env["SIMLESS_RUNTIME_PORT"].flatMap({ UInt16($0) }) {
        // A host is a hidden background app, which macOS naps: timers slow
        // down and work drops to background priority. Tests run it at full speed.
        appNapOff = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "simless host")
        // Names the test on a crash, for when macOS writes no crash report.
        simless_install_crash_handler()
        Server.start(port: port)
    }
}

private var appNapOff: NSObjectProtocol?

/// An app started with `open` may keep 256 files open, and a test run with
/// hundreds of tests in parallel (each with its own store) needs more.
func raiseOpenFileLimit() {
    var limit = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
    let wanted = min(limit.rlim_max, rlim_t(OPEN_MAX), 10_240)
    if limit.rlim_cur < wanted {
        limit.rlim_cur = wanted
        setrlimit(RLIMIT_NOFILE, &limit)
    }
}

/// Read-only sandbox extensions issued by simless (the repository, test bundles).
func consumeSandboxTokens(_ joined: String?) {
    guard let joined, !joined.isEmpty,
          let h = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW),
          let sym = dlsym(h, "sandbox_extension_consume") else { return }
    typealias Consume = @convention(c) (UnsafePointer<CChar>) -> Int64
    for t in joined.split(separator: "\n") { _ = unsafeBitCast(sym, to: Consume.self)(String(t)) }
}

// MARK: - Bundle ids

/// The slot renames the app, its extensions and the watch app under its own
/// id (installd requires that prefix). Tests that read their ids get the
/// original ones back: from `bundleIdentifier`, and in Info.plist values
/// (a watch app's companion id). In the render host the app keeps the slot's id.
enum BundleIDs {
    static var slot = ""
    static var original = ""
    /// Whether the app's own bundle reports its original id too (test and UI hosts).
    static var includeMain = ProcessInfo.processInfo.environment["SIMLESS_RUNTIME_PORT"] != nil

    /// The original id for one of the slot's ids, or nil for any other id.
    static func originalID(_ id: String) -> String? {
        if id == slot { return includeMain ? original : nil }
        guard id.hasPrefix(slot + ".") else { return nil }
        return original + id.dropFirst(slot.count)
    }

    /// The slot's id for an original one.
    static func slotID(_ id: String) -> String? {
        if id == original { return includeMain ? slot : nil }
        guard id.hasPrefix(original + ".") else { return nil }
        return slot + id.dropFirst(original.count)
    }

    static func restore(slot: String, original: String) {
        self.slot = slot
        self.original = original
        // bundleIdentifier
        let sel = NSSelectorFromString("bundleIdentifier")
        if let m = class_getInstanceMethod(Bundle.self, sel) {
            typealias Getter = @convention(c) (AnyObject, Selector) -> NSString?
            let call = unsafeBitCast(method_getImplementation(m), to: Getter.self)
            let block: @convention(block) (AnyObject) -> NSString? = { bundle in
                guard let id = call(bundle, sel) as String? else { return nil }
                return (originalID(id) ?? id) as NSString
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        // Bundle(identifier:) with an id the app now reports (asset catalogs look bundles up that way).
        let find = NSSelectorFromString("bundleWithIdentifier:")
        if let m = class_getClassMethod(Bundle.self, find) {
            typealias Find = @convention(c) (AnyObject, Selector, NSString) -> AnyObject?
            let call = unsafeBitCast(method_getImplementation(m), to: Find.self)
            let block: @convention(block) (AnyObject, NSString) -> AnyObject? = { cls, id in
                call(cls, find, id) ?? slotID(id as String).flatMap { call(cls, find, $0 as NSString) }
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        // Info.plist values: the plists were rewritten with the slot's ids.
        let info = NSSelectorFromString("infoDictionary")
        if let m = class_getInstanceMethod(Bundle.self, info) {
            typealias Info = @convention(c) (AnyObject, Selector) -> NSDictionary?
            let call = unsafeBitCast(method_getImplementation(m), to: Info.self)
            // Foundation writes into the dictionary it gets back (since macOS 27,
            // `_NSBundleGetPrincipalClassFromInfoDict` caches the principal class in
            // it, which Metal reaches when the first window opens), so this hands back
            // the bundle's own dictionary when no id changes, and a mutable copy when
            // one does. An immutable copy crashed every host at launch.
            let block: @convention(block) (AnyObject) -> NSDictionary? = { bundle in
                guard let d = call(bundle, info) else { return nil }
                var changes: [(key: Any, id: String)] = []
                for (k, v) in d { if let s = v as? String, let o = originalID(s) { changes.append((k, o)) } }
                guard !changes.isEmpty else { return d }
                let out = NSMutableDictionary(dictionary: d)
                for change in changes { out[change.key] = change.id }
                return out
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        let object = NSSelectorFromString("objectForInfoDictionaryKey:")
        if let m = class_getInstanceMethod(Bundle.self, object) {
            typealias Object = @convention(c) (AnyObject, Selector, NSString) -> AnyObject?
            let call = unsafeBitCast(method_getImplementation(m), to: Object.self)
            let block: @convention(block) (AnyObject, NSString) -> AnyObject? = { bundle, key in
                let v = call(bundle, object, key)
                if let s = v as? String, let o = originalID(s) { return o as NSString }
                return v
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }
}

// MARK: - Server

/// One thread per connection; work that touches UIKit or XCTest hops to the main thread.
enum Server {
    static func start(port: UInt16) {
        guard var fd = listenSocket(port) else { runtimeLog("port \(port) unavailable"); return }
        Thread.detachNewThread {
            while true {
                let c = accept(fd, nil, nil)
                if c >= 0 { let conn = highNumbered(c); Thread.detachNewThread { Connection(fd: conn).serve() }; continue }
                if errno == EINTR { continue }
                runtimeLog("listener on \(port) lost (\(String(cString: strerror(errno)))); listening again")
                // An app launched directly (a native host) closes, while it starts,
                // descriptors it didn't open, this listener's among them: listen
                // again. Its number may be another file's by now, so it's closed
                // only while it's still this socket.
                if isListener(fd, port: port) { close(fd) }
                var again: Int32?
                for _ in 0..<100 {
                    again = listenSocket(port)
                    if again != nil { break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                guard let again else { runtimeLog("port \(port) unavailable"); return }
                fd = again
            }
        }
        // A host nobody talks to exits, so a standby host never lingers.
        let idle = ProcessInfo.processInfo.environment["SIMLESS_IDLE"].flatMap(Double.init) ?? 1800
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 15)
                activity.lock()
                let quiet = Date().timeIntervalSince(lastActivity) > idle && active == 0
                activity.unlock()
                if quiet { exit(0) }
            }
        }
    }

    private static func listenSocket(_ port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port.bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return nil }
        return highNumbered(fd)
    }

    /// Moves a descriptor to a number above the ones that get reused. While an
    /// app started directly (a native host) launches, something closes a
    /// descriptor number a second time after it was given out again: a socket
    /// that got that number died with EBADF. Numbers this high are never handed out by then.
    static func highNumbered(_ fd: Int32) -> Int32 {
        let high = fcntl(fd, F_DUPFD_CLOEXEC, 1000)
        guard high >= 0 else { return fd }
        close(fd)
        return high
    }

    /// Whether `fd` is a listening socket on `port`.
    private static func isListener(_ fd: Int32, port: UInt16) -> Bool {
        var accepting: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ACCEPTCONN, &accepting, &len) == 0, accepting != 0 else { return false }
        var addr = sockaddr_in()
        var alen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &alen) }
        }
        return ok == 0 && UInt16(bigEndian: addr.sin_port) == port
    }

    static let activity = NSLock()
    static var lastActivity = Date()
    static var active = 0
    static func touch(_ delta: Int = 0) {
        activity.lock(); lastActivity = Date(); active += delta; activity.unlock()
    }
}

final class Connection {
    let fd: Int32
    private let lock = NSLock()
    init(fd: Int32) { self.fd = fd }

    /// Writes one JSON line; safe from any thread.
    static func finite(_ value: Any) -> Any {
        switch value {
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return n
        case let d as Double: return d.isFinite ? d : 0
        case let f as CGFloat: return f.isFinite ? Double(f) : 0
        case let a as [Any]: return a.map(finite)
        case let o as [String: Any]: return o.mapValues(finite)
        default: return value
        }
    }

    func send(_ object: [String: Any]) {
        // JSONSerialization throws (an Objective-C exception, fatal) on NaN and
        // infinity, which odd layouts do produce in frames.
        guard var data = try? JSONSerialization.data(withJSONObject: Self.finite(object)) else { return }
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    func serve() {
        Server.touch(1)
        defer { Server.touch(-1) }
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            pending.append(contentsOf: buf[0..<n])
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                Server.touch()
                guard let req = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let cmd = req["cmd"] as? String else {
                    send(["ok": false, "error": "bad request"]); continue
                }
                handle(cmd, req)
            }
        }
        close(fd)
    }

    private func handle(_ cmd: String, _ req: [String: Any]) {
        switch cmd {
        case "usage":
            send(["ok": true, "containerBytes": Housekeeping.containerBytes()])
        case "hello":
            send(["ok": true, "pid": Int(getpid()), "runtime": runtimeVersion, "loaded": TestBundles.loaded,
                  "token": ProcessInfo.processInfo.environment["SIMLESS_HOST_TOKEN"] ?? ""])
        case "load":
            let errors = TestBundles.load(req["bundles"] as? [String] ?? [])
            send(["ok": errors.isEmpty, "errors": errors, "loaded": TestBundles.loaded])
        case "list":
            TestRunner(connection: self, request: req).list()
        case "run":
            TestRunner(connection: self, request: req).run()
        case "exit":
            send(["ok": true])
            exit(0)
        default:
            if UIAutomation.handles(cmd) {
                UIAutomation.handle(cmd, req, self)
            } else {
                send(["ok": false, "error": "unknown cmd \(cmd)"])
            }
        }
    }
}

// MARK: - Test bundles

enum TestBundles {
    static var loaded: [String] = []

    /// dlopen each bundle's executable. Code can't be unloaded, so a host
    /// loads each build of a bundle once; simless starts a fresh host per run.
    static func load(_ paths: [String]) -> [String] {
        var errors: [String] = []
        for path in paths where !loaded.contains(path) {
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let exe = (Bundle(path: path)?.executablePath) ?? "\(path)/\(name)"
            if dlopen(exe, RTLD_NOW) == nil {
                errors.append("\(name): \(String(cString: dlerror()))")
            } else {
                loaded.append(path)
            }
        }
        return errors
    }
}

/// The host's own files, which only the app itself may touch.
enum Housekeeping {
    /// Whether a folder belongs to this app alone: inside its sandbox container,
    /// or inside its simless slot (a native host's home).
    static func isAppData(_ dir: String) -> Bool {
        let path = URL(fileURLWithPath: dir).standardizedFileURL.path
        return path.contains("/Library/Containers/") || path.contains("/Library/Caches/simless/slots/")
    }

    /// Removes everything inside `dir`, keeping `dir`. With `keepFolders`,
    /// folders down to that depth stay, empty: an app container's skeleton
    /// (Library, Library/Caches, tmp, ...) has to be there for macOS to
    /// launch the app again.
    static func empty(_ dir: String, keepFolders depth: Int = 0, keeping kept: Set<String> = []) {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !kept.contains(item) {
            let path = (dir as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            let isLink = (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
            if depth > 0, !isLink, fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                empty(path, keepFolders: depth - 1, keeping: kept)
            } else {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    /// Clears every preferences domain the app saved (its own, and suites):
    /// cfprefsd keeps them in memory, so deleting the plist files alone would
    /// hand the next launch its old values.
    static func resetDefaults() {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: NSHomeDirectory()) else { return }
        var domains: Set<String> = []
        for case let path as String in e where path.hasSuffix(".plist") && (path as NSString).deletingLastPathComponent.hasSuffix("Preferences") {
            domains.insert(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        }
        if let own = Bundle.main.bundleIdentifier { domains.insert(own) }
        for domain in domains {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        UserDefaults.standard.synchronize()
    }

    /// Bytes under the app's data container.
    static func containerBytes() -> Int {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total = 0
        for case let f as URL in e { total += (try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0 }
        return total
    }
}

// MARK: - Device canvas in unit test hosts

/// A test that puts a view in a window of its own (to read its layout or
/// accessibility) gets an iPhone's window there: its size and its safe areas,
/// such as the Dynamic Island's 62 pt, not the Mac window's 20 pt.
enum UnitCanvas {
    static var width = 402.0, height = 874.0, top = 62.0, bottom = 34.0

    static func install(_ spec: String) {
        let c = spec.split(separator: ",").compactMap { Double($0) }
        guard c.count == 4 else { return }
        (width, height, top, bottom) = (c[0], c[1], c[2], c[3])
        // A window on the canvas reports the device's insets.
        let sel = #selector(getter: UIView.safeAreaInsets)
        if let m = class_getInstanceMethod(UIWindow.self, sel) {
            typealias Getter = @convention(c) (AnyObject, Selector) -> UIEdgeInsets
            let original = unsafeBitCast(method_getImplementation(m), to: Getter.self)
            let block: @convention(block) (UIWindow) -> UIEdgeInsets = { w in
                guard w.bounds.width == CGFloat(width), w.bounds.height == CGFloat(height) else { return original(w, sel) }
                return UIEdgeInsets(top: CGFloat(top), left: 0, bottom: CGFloat(bottom), right: 0)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? UIWindow else { return }
            apply(w)
        }
    }

    /// Sizes the window to the canvas and lays its content out within the
    /// device's safe areas (the root's own safe area counts what the Mac adds).
    static func apply(_ w: UIWindow) {
        let size = CGSize(width: width, height: height)
        if w.frame.size != size { w.frame = CGRect(origin: .zero, size: size) }
        if let root = w.rootViewController {
            root.view.layoutIfNeeded()
            let base = root.view.safeAreaInsets, current = root.additionalSafeAreaInsets
            let wanted = UIEdgeInsets(top: max(0, CGFloat(top) - (base.top - current.top)), left: 0,
                                      bottom: max(0, CGFloat(bottom) - (base.bottom - current.bottom)), right: 0)
            if wanted != current { root.additionalSafeAreaInsets = wanted }
        }
        w.layoutIfNeeded()
    }
}

// MARK: - Tab sidebar

/// A tab view that adapts to a sidebar (`.sidebarAdaptable`) starts with the
/// sidebar open on the Mac, as in Mac Catalyst. iPadOS starts it closed, with
/// the floating tab bar, and opens it on request: so do the hosts.
enum TabSidebar {
    private static var started = Set<ObjectIdentifier>()

    static func install() {
        guard let cls = NSClassFromString("UITabBarController") else { return }
        let sel = NSSelectorFromString("viewWillAppear:")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
        let original = unsafeBitCast(method_getImplementation(m), to: F.self)
        let block: @convention(block) (AnyObject, Bool) -> Void = { controller, animated in
            if started.insert(ObjectIdentifier(controller)).inserted, controller.responds(to: NSSelectorFromString("sidebar")),
               let sidebar = controller.value(forKey: "sidebar") as? NSObject, sidebar.responds(to: NSSelectorFromString("setHidden:")) {
                sidebar.setValue(true, forKey: "hidden")
            }
            original(controller, sel, animated)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }
}
