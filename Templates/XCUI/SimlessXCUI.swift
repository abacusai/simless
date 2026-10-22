// SPDX-License-Identifier: MIT-0
// Copyright 2026 Abacus.AI, Inc. MIT No Attribution: you may use, copy, modify
// and distribute this file without restriction or attribution. Provided "as is",
// without warranty of any kind.

// simless's XCUITest API, compiled into your UI test target's module by
// `simless test` (it's never added to your project). Types declared in a
// module take precedence over the ones it imports, so your tests use these
// instead of XCTest's: the same names and calls, driving a headless simless
// host of your app (no simulator, no window, no mouse) through the
// accessibility tree and real touch events in the app's process.

import Foundation
import XCTest
import AppKit
import CoreGraphics

// MARK: - Host connection

/// The simless host the tests drive: one installed copy of the app, launched
/// with SimlessRuntime. Set up by `simless test` through the environment.
final class SimlessUIHost: @unchecked Sendable {
    nonisolated(unsafe) static let shared = SimlessUIHost()

    let env = ProcessInfo.processInfo.environment
    var port: Int { Int(env["SIMLESS_UI_PORT"] ?? "") ?? 0 }
    var appPath: String { env["SIMLESS_UI_APP"] ?? "" }
    var slotID: String { env["SIMLESS_UI_SLOT"] ?? "" }
    var canvas: [Double] { (env["SIMLESS_UI_CANVAS"] ?? "402,874,62,34").split(separator: ",").compactMap { Double($0) } }
    var idiom: String { env["SIMLESS_UI_IDIOM"] ?? "phone" }
    var timeScale: Double { Double(env["SIMLESS_UI_TIMEOUT_SCALE"] ?? "") ?? 1 }

    private var fd: Int32 = -1
    private var pending = Data()
    var orientation: UIDeviceOrientation = .portrait
    var appearance: XCUIDevice.Appearance = .unspecified

    // MARK: Socket

    private func connect() -> Bool {
        if fd >= 0 { return true }
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { close(s); return false }
        var tv = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        fd = s
        pending = Data()
        return true
    }

    func disconnect() { if fd >= 0 { close(fd) }; fd = -1 }

    /// One request, one reply. Nil when the app isn't running.
    @discardableResult
    func call(_ request: [String: Any]) -> [String: Any]? {
        guard env["SIMLESS_UI_TRACE"] != nil else { return send(request) }
        let start = Date()
        let r = send(request)
        FileHandle.standardError.write(Data("simless-trace \(request["cmd"] ?? "") \(Int(Date().timeIntervalSince(start) * 1000)) \(r == nil ? "NOREPLY \(lastFailure)" : "")\(r?["busy"] ?? "")\(r?["how"] ?? "")\((r?["error"] as? String).map { " error: \($0)" } ?? "")\n".utf8))
        return r
    }

    /// Why the last request got no answer (for SIMLESS_UI_TRACE).
    private var lastFailure = ""
    private var requests = 0
    /// The app answered since it was launched: a refused connection now means its
    /// socket was closed under it, and it listens again in a moment.
    private var answered = false

    /// Every request has an id. If its connection drops before the answer, it's
    /// sent again with the same id, and SimlessRuntime answers it once (a tap
    /// is never done twice); answers to other ids are left behind.
    private func send(_ request: [String: Any]) -> [String: Any]? {
        requests += 1
        let rid = "\(getpid())-\(requests)"
        var request = request
        request["rid"] = rid
        guard var data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        data.append(0x0A)
        for _ in 0..<4 {
            if !connect() {
                lastFailure = "connect errno \(errno)"
                guard answered else { return nil }
                let deadline = Date().addingTimeInterval(2)
                while !connect() && Date() < deadline && isRunning { Thread.sleep(forTimeInterval: 0.05) }
                guard fd >= 0 else { return nil }
            }
            let wrote = data.withUnsafeBytes { raw -> Bool in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n <= 0 { return false }
                    off += n
                }
                return true
            }
            if !wrote { lastFailure = "write errno \(errno)"; disconnect(); continue }
            var buf = [UInt8](repeating: 0, count: 1 << 16)
            reading: while true {
                if let nl = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<nl]
                    pending.removeSubrange(pending.startIndex...nl)
                    guard let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    if let id = reply["rid"] as? String, id != rid { continue }
                    answered = true
                    return reply
                }
                let n = read(fd, &buf, buf.count)
                if n <= 0 {
                    lastFailure = n == 0 ? "closed by the host" : "read errno \(errno)"
                    disconnect()
                    break reading
                }
                pending.append(contentsOf: buf[0..<n])
            }
        }
        return nil
    }

    // MARK: App lifecycle

    /// The app's executable when simless runs it directly (its native mode)
    /// instead of opening the installed app.
    var executable: String { env["SIMLESS_UI_EXEC"] ?? "" }
    private var child: Process?

    var isRunning: Bool {
        (child?.isRunning ?? false) || !NSRunningApplication.runningApplications(withBundleIdentifier: slotID).isEmpty
    }

    func terminate() {
        if isRunning { _ = call(["cmd": "ui.flush"]) }
        disconnect()
        answered = false
        child?.terminate()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: slotID) { app.forceTerminate() }
        let deadline = Date().addingTimeInterval(5)
        while isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if let c = child, c.isRunning { kill(c.processIdentifier, SIGKILL) }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: slotID) { kill(app.processIdentifier, SIGKILL) }
        child = nil
    }

    /// Launches the app headless with these arguments and environment, waits
    /// until its first screen is up.
    func launch(arguments: [String], environment: [String: String]) -> String? {
        terminate()
        var launchEnv: [String: String] = [:]
        for (k, v) in env where k.hasPrefix("SIMLESS_HOST_ENV_") { launchEnv[String(k.dropFirst("SIMLESS_HOST_ENV_".count))] = v }
        for (k, v) in environment { launchEnv[k] = v }
        launchEnv["SIMLESS_RUNTIME_PORT"] = String(port)
        launchEnv["SIMLESS_UI"] = "1"
        launchEnv["SIMLESS_UI_CANVAS"] = env["SIMLESS_UI_CANVAS"] ?? "402,874,62,34"
        launchEnv["SIMLESS_UI_ORIENTATION"] = orientation.isLandscape ? "landscape" : "portrait"
        if appearance != .unspecified { launchEnv["SIMLESS_UI_APPEARANCE"] = String(appearance.rawValue) }
        var cmd = ["-g", "-j"]
        if let log = env["SIMLESS_UI_LOG"] {
            // `open` fails with "No such file or directory" when the log's folder is gone.
            try? FileManager.default.createDirectory(atPath: (log as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            cmd += ["--stderr", log, "--stdout", log]
        }
        for (k, v) in launchEnv.sorted(by: { $0.key < $1.key }) { cmd += ["--env", "\(k)=\(v)"] }
        cmd.append(appPath)
        if !arguments.isEmpty { cmd += ["--args"] + arguments }
        func exec() -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            // A login-like environment, as `open` gives an app, plus the launch's.
            var base: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            for key in ["USER", "LOGNAME", "SHELL", "LANG", "SIMLESS_PERMISSIONS", "SIMLESS_DYNAMIC_TYPE"] { base[key] = env[key] }
            p.environment = base.merging(launchEnv) { $1 }
            p.currentDirectoryURL = URL(fileURLWithPath: "/")
            p.standardInput = FileHandle.nullDevice
            if let log = env["SIMLESS_UI_LOG"] {
                FileManager.default.createFile(atPath: log, contents: nil)
                if let h = FileHandle(forWritingAtPath: log) { h.seekToEndOfFile(); p.standardOutput = h; p.standardError = h }
            } else {
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
            }
            do { try p.run() } catch { return "\(error)" }
            child = p
            return nil
        }
        func open() -> String? {
            if !executable.isEmpty { return exec() }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = cmd
            let errPipe = Pipe()
            p.standardError = errPipe
            p.standardOutput = errPipe
            do { try p.run() } catch { return "\(error)" }
            p.waitUntilExit()
            return p.terminationStatus == 0 ? nil : String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        // simless checks every slot's install before a run, so a failure here is rare.
        let failure = open()
        if let failure { return "could not launch the app: \(failure)" }
        let deadline = Date().addingTimeInterval(60 * timeScale)
        while Date() < deadline {
            if let r = call(["cmd": "ui.ready"]), r["ready"] as? Bool == true { return nil }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return "the app didn't show its first screen within \(Int(60 * timeScale)) s"
    }

    // MARK: Snapshots

    private(set) var snapshot: [Node] = []
    private(set) var generation = 0
    private var snapshotAt = Date.distantPast
    var dirty = true

    /// The accessibility tree, fetched again after any action (or when stale).
    func tree(fresh: Bool = false) -> [Node] {
        if fresh || dirty || Date().timeIntervalSince(snapshotAt) > 0.05 {
            if let r = call(["cmd": "ui.snapshot"]), let nodes = r["nodes"] as? [[String: Any]] {
                generation = r["generation"] as? Int ?? 0
                snapshot = nodes.enumerated().map { Node($0.offset, $0.element) }
            } else {
                snapshot = []
            }
            snapshotAt = Date()
            dirty = false
        }
        return snapshot
    }

    /// Runs an action in the app, then waits for it to settle.
    @discardableResult
    func act(_ request: [String: Any]) -> [String: Any]? {
        let r = call(request)
        dirty = true
        _ = call(["cmd": "ui.idle", "timeout": 2.0 * timeScale])
        return r
    }
}

/// One element of the app's accessibility tree, as the runtime reports it.
struct Node {
    let index: Int
    let ref: Int
    let parent: Int
    let type: XCUIElement.ElementType
    let identifier: String
    let label: String
    let value: Any?
    let title: String
    let placeholder: String
    let frame: CGRect
    let enabled: Bool
    let selected: Bool
    let focused: Bool
    let hittable: Bool

    init(_ index: Int, _ d: [String: Any]) {
        self.index = index
        ref = d["ref"] as? Int ?? index
        parent = d["parent"] as? Int ?? -1
        type = XCUIElement.ElementType(rawValue: UInt(d["type"] as? Int ?? 1)) ?? .other
        identifier = d["id"] as? String ?? ""
        label = d["label"] as? String ?? ""
        value = d["value"]
        title = d["title"] as? String ?? ""
        placeholder = d["placeholder"] as? String ?? ""
        let f = d["frame"] as? [Double] ?? [0, 0, 0, 0]
        frame = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
        enabled = d["enabled"] as? Bool ?? true
        selected = d["selected"] as? Bool ?? false
        focused = d["focused"] as? Bool ?? false
        hittable = d["hittable"] as? Bool ?? false
    }
}

// MARK: - Device

enum UIDeviceOrientation: Int, Sendable {
    case unknown, portrait, portraitUpsideDown, landscapeLeft, landscapeRight, faceUp, faceDown
    var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }
    var isPortrait: Bool { self == .portrait || self == .portraitUpsideDown }
}

enum UIUserInterfaceIdiom: Int, Sendable {
    case unspecified = -1, phone = 0, pad = 1, tv = 2, carPlay = 3, mac = 5, vision = 6
}

/// The device the tests run on, as UIKit would describe it in an iOS test runner.
final class UIDevice: @unchecked Sendable {
    nonisolated(unsafe) static let current = UIDevice()
    var userInterfaceIdiom: UIUserInterfaceIdiom { SimlessUIHost.shared.idiom == "pad" ? .pad : .phone }
    var orientation: UIDeviceOrientation { SimlessUIHost.shared.orientation }
    var systemName: String { "iOS" }
}

final class XCUIDevice: @unchecked Sendable {
    nonisolated(unsafe) static let shared = XCUIDevice()

    enum Button: Int, Sendable { case home = 1, volumeUp, volumeDown, action, camera }

    var orientation: UIDeviceOrientation {
        get { SimlessUIHost.shared.orientation }
        set {
            SimlessUIHost.shared.orientation = newValue
            SimlessUIHost.shared.act(["cmd": "ui.orientation", "landscape": newValue.isLandscape])
        }
    }

    enum Appearance: Int, Sendable { case unspecified = 0, light = 1, dark = 2 }

    /// The system's light or dark mode: the app now and every launch after.
    var appearance: Appearance {
        get { SimlessUIHost.shared.appearance }
        set {
            SimlessUIHost.shared.appearance = newValue
            if SimlessUIHost.shared.isRunning { SimlessUIHost.shared.act(["cmd": "ui.appearance", "style": newValue.rawValue]) }
        }
    }

    func press(_ button: Button) {
        if button == .home { SimlessUIHost.shared.act(["cmd": "ui.background"]) }
    }

    func rotateDigitalCrown(delta: CGFloat, velocity: XCUIGestureVelocity = .default) {
        XCTFail("simless can't run watchOS apps; this test needs the watch simulator")
    }
}

struct XCUIGestureVelocity: RawRepresentable, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, Sendable {
    var rawValue: CGFloat
    init(rawValue: CGFloat) { self.rawValue = rawValue }
    init(_ value: CGFloat) { rawValue = value }
    init(floatLiteral value: Double) { rawValue = CGFloat(value) }
    init(integerLiteral value: Int) { rawValue = CGFloat(value) }
    static let slow = XCUIGestureVelocity(rawValue: 300)
    static let `default` = XCUIGestureVelocity(rawValue: 1200)
    static let fast = XCUIGestureVelocity(rawValue: 3000)
}

struct XCUIKeyboardKey: RawRepresentable, Sendable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let delete = XCUIKeyboardKey(rawValue: "\u{8}")
    static let `return` = XCUIKeyboardKey(rawValue: "\r")
    static let enter = XCUIKeyboardKey(rawValue: "\r")
    static let tab = XCUIKeyboardKey(rawValue: "\t")
    static let space = XCUIKeyboardKey(rawValue: " ")
    static let escape = XCUIKeyboardKey(rawValue: "\u{1b}")
}

// MARK: - Screenshots

final class XCUIScreenshot: NSObject, @unchecked Sendable {
    let pngRepresentation: Data
    init(png: Data) { pngRepresentation = png }
    var image: NSImage { NSImage(data: pngRepresentation) ?? NSImage() }
}

extension XCTAttachment {
    convenience init(screenshot: XCUIScreenshot) {
        self.init(data: screenshot.pngRepresentation, uniformTypeIdentifier: "public.png")
    }
    convenience init(screenshot: XCUIScreenshot, quality: XCTAttachment.ImageQuality) {
        self.init(data: screenshot.pngRepresentation, uniformTypeIdentifier: "public.png")
    }
}

// MARK: - Elements

class XCUIElement: NSObject, @unchecked Sendable {
    enum ElementType: UInt, Sendable {
        case any = 0, other, application, group, window, sheet, drawer, alert, dialog, button, radioButton, radioGroup,
             checkBox, disclosureTriangle, popUpButton, comboBox, menuButton, toolbarButton, popover, keyboard, key,
             navigationBar, tabBar, tabGroup, toolbar, statusBar, table, tableRow, tableColumn, outline, outlineRow,
             browser, collectionView, slider, pageIndicator, progressIndicator, activityIndicator, segmentedControl,
             picker, pickerWheel, `switch`, toggle, link, image, icon, searchField, scrollView, scrollBar, staticText,
             textField, secureTextField, datePicker, textView, menu, menuItem, menuBar, menuBarItem, map, webView,
             incrementArrow, decrementArrow, timeline, ratingIndicator, valueIndicator, splitGroup, splitter,
             relevanceIndicator, colorWell, helpTag, matte, dockItem, ruler, rulerMarker, grid, levelIndicator, cell,
             layoutArea, layoutItem, handle, stepper, tab, touchBar, statusItem
    }

    enum SizeClass: Int, Sendable { case unspecified, compact, regular }

    /// How this element is found: a query and which of its matches.
    let query: XCUIElementQuery?
    let position: Int?       // nil: first match
    var host: SimlessUIHost { .shared }

    init(query: XCUIElementQuery?, position: Int?) {
        self.query = query
        self.position = position
    }

    /// The node this element currently resolves to, if any.
    func resolve() -> Node? {
        guard let query else { return nil }
        let matches = query.matches()
        guard let position else { return matches.first }
        return position < matches.count ? matches[position] : nil
    }

    // MARK: Attributes

    @objc var exists: Bool { resolve() != nil }
    var isHittable: Bool { resolve()?.hittable ?? false }
    @objc var label: String { resolve()?.label ?? "" }
    @objc var identifier: String { resolve()?.identifier ?? "" }
    @objc var title: String { resolve()?.title ?? "" }
    @objc var value: Any? { resolve()?.value }
    @objc var placeholderValue: String? { resolve()?.placeholder }
    var frame: CGRect { resolve()?.frame ?? .zero }
    var isSelected: Bool { resolve()?.selected ?? false }
    var isEnabled: Bool { resolve()?.enabled ?? false }
    var hasFocus: Bool { resolve()?.focused ?? false }
    var elementType: ElementType { resolve()?.type ?? .any }
    var horizontalSizeClass: SizeClass { host.canvas.first.map { $0 < 600 ? .compact : .regular } ?? .unspecified }
    var verticalSizeClass: SizeClass { .regular }
    // Predicate keys (NSPredicate reads these through KVC).
    @objc var enabled: Bool { isEnabled }
    @objc var selected: Bool { isSelected }
    @objc var hittable: Bool { isHittable }
    @objc var elementTypeRaw: UInt { elementType.rawValue }

    override func value(forKey key: String) -> Any? {
        switch key {
        case "elementType": return NSNumber(value: elementType.rawValue)
        case "isEnabled": return isEnabled
        case "isSelected": return isSelected
        case "isHittable": return isHittable
        default: return super.value(forKey: key)
        }
    }

    override var debugDescription: String {
        guard let n = resolve() else { return "\(String(describing: query)) (no match)" }
        return XCUIElementQuery.describe(n, in: host.tree())
    }

    // MARK: Waiting

    func waitForExistence(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout * host.timeScale)
        repeat {
            if resolve() != nil { return true }
            Thread.sleep(forTimeInterval: 0.05)
            host.dirty = true
        } while Date() < deadline
        return resolve() != nil
    }

    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout * host.timeScale)
        repeat {
            if resolve() == nil { return true }
            Thread.sleep(forTimeInterval: 0.05)
            host.dirty = true
        } while Date() < deadline
        return resolve() == nil
    }

    // MARK: Actions

    private func target(_ what: String) -> Node? {
        // XCUITest waits for the app to settle before it acts; presentations
        // (alerts, sheets) can take a moment to arrive.
        if resolve() == nil { _ = waitForExistence(timeout: 3) }
        guard let n = resolve() else {
            if !host.isRunning {
                XCTFail("\(what): the app isn't running, it quit or crashed (its log: \(host.env["SIMLESS_UI_LOG"] ?? "the host log"))")
                return nil
            }
            XCTFail("\(what): no element matches \(query.map { "\($0)" } ?? "the query")\(position.map { " at index \($0)" } ?? "")")
            return nil
        }
        // A first match with no size (a menu Picker's options, kept for
        // queries) can't take a touch; an open menu's row of the same name can.
        if (position ?? 0) == 0, n.frame.isEmpty, let shown = query?.matches().first(where: { $0.hittable && !$0.frame.isEmpty }) {
            return shown
        }
        return n
    }

    /// Scrolls the element into view if it's in a scroll view and not
    /// hittable, like XCUITest does before a tap.
    private func hitPoint(_ what: String) -> CGPoint? {
        guard var n = target(what) else { return nil }
        if !n.hittable {
            host.act(["cmd": "ui.scrollToVisible", "ref": n.ref, "generation": host.generation])
            if let again = resolve() { n = again }
        }
        return CGPoint(x: n.frame.midX, y: n.frame.midY)
    }

    func tap() {
        guard let p = hitPoint("tap") else { return }
        var req: [String: Any] = ["cmd": "ui.tap", "x": p.x, "y": p.y]
        if let n = resolve() { req["ref"] = n.ref; req["generation"] = host.generation }
        host.act(req)
    }

    func doubleTap() {
        guard let p = hitPoint("doubleTap") else { return }
        host.act(["cmd": "ui.tap", "x": p.x, "y": p.y, "count": 2])
    }

    func twoFingerTap() { tap() }

    func press(forDuration duration: TimeInterval) {
        guard let p = hitPoint("press") else { return }
        var req: [String: Any] = ["cmd": "ui.tap", "x": p.x, "y": p.y, "duration": duration]
        if let n = resolve() { req["ref"] = n.ref; req["generation"] = host.generation }
        host.act(req)
    }

    func press(forDuration duration: TimeInterval, thenDragTo other: XCUIElement) {
        guard let p = hitPoint("press"), let o = other.target("drag target") else { return }
        host.act(["cmd": "ui.drag", "from": [p.x, p.y], "to": [o.frame.midX, o.frame.midY], "press": duration, "velocity": 1000])
    }

    func typeText(_ text: String) {
        if let n = resolve(), !n.focused, n.type == .textField || n.type == .secureTextField || n.type == .textView || n.type == .searchField {
            tap()
        }
        host.act(["cmd": "ui.type", "text": text])
    }

    private func swipe(_ dx: CGFloat, _ dy: CGFloat, _ velocity: XCUIGestureVelocity) {
        guard let n = target("swipe") else { return }
        host.act(["cmd": "ui.swipe", "x": n.frame.midX, "y": n.frame.midY, "dx": dx, "dy": dy,
                  "width": n.frame.width, "height": n.frame.height, "velocity": velocity.rawValue])
    }

    func swipeUp() { swipe(0, -1, .default) }
    func swipeDown() { swipe(0, 1, .default) }
    func swipeLeft() { swipe(-1, 0, .default) }
    func swipeRight() { swipe(1, 0, .default) }
    func swipeUp(velocity: XCUIGestureVelocity) { swipe(0, -1, velocity) }
    func swipeDown(velocity: XCUIGestureVelocity) { swipe(0, 1, velocity) }
    func swipeLeft(velocity: XCUIGestureVelocity) { swipe(-1, 0, velocity) }
    func swipeRight(velocity: XCUIGestureVelocity) { swipe(1, 0, velocity) }

    func pinch(withScale scale: CGFloat, velocity: CGFloat) {}
    func rotate(_ rotation: CGFloat, withVelocity velocity: CGFloat) {}

    func adjust(toPickerWheelValue value: String) {
        guard let n = target("adjust") else { return }
        let r = host.act(["cmd": "ui.pickerWheel", "ref": n.ref, "generation": host.generation, "value": value])
        if r?["ok"] as? Bool != true { XCTFail("adjust(toPickerWheelValue: \(value)): \(r?["error"] as? String ?? "no such value")") }
    }

    func adjust(toNormalizedSliderPosition position: CGFloat) {
        guard let n = target("adjust") else { return }
        host.act(["cmd": "ui.slider", "ref": n.ref, "generation": host.generation, "position": position])
    }

    var normalizedSliderPosition: CGFloat { (value as? String).flatMap { Double($0.replacingOccurrences(of: "%", with: "")) }.map { CGFloat($0 / 100) } ?? 0 }

    func coordinate(withNormalizedOffset offset: CGVector) -> XCUICoordinate {
        XCUICoordinate(element: self, normalized: offset, offset: .zero)
    }

    func screenshot() -> XCUIScreenshot {
        let n = resolve()
        let r = host.call(["cmd": "ui.screenshot", "rect": n.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } as Any])
        return XCUIScreenshot(png: (r?["png"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data())
    }

    // MARK: Queries

    /// An element is its own first match.
    var firstMatch: XCUIElement { self }

    func descendants(matching type: ElementType) -> XCUIElementQuery {
        XCUIElementQuery(parent: self, step: .descendants(type))
    }

    func children(matching type: ElementType) -> XCUIElementQuery {
        XCUIElementQuery(parent: self, step: .children(type))
    }

    var buttons: XCUIElementQuery { descendants(matching: .button) }
    var staticTexts: XCUIElementQuery { descendants(matching: .staticText) }
    var otherElements: XCUIElementQuery { descendants(matching: .other) }
    var images: XCUIElementQuery { descendants(matching: .image) }
    var switches: XCUIElementQuery { descendants(matching: .switch) }
    var toggles: XCUIElementQuery { descendants(matching: .toggle) }
    var textFields: XCUIElementQuery { descendants(matching: .textField) }
    var secureTextFields: XCUIElementQuery { descendants(matching: .secureTextField) }
    var textViews: XCUIElementQuery { descendants(matching: .textView) }
    var searchFields: XCUIElementQuery { descendants(matching: .searchField) }
    var cells: XCUIElementQuery { descendants(matching: .cell) }
    var tables: XCUIElementQuery { descendants(matching: .table) }
    var collectionViews: XCUIElementQuery { descendants(matching: .collectionView) }
    var scrollViews: XCUIElementQuery { descendants(matching: .scrollView) }
    var navigationBars: XCUIElementQuery { descendants(matching: .navigationBar) }
    var tabBars: XCUIElementQuery { descendants(matching: .tabBar) }
    var toolbars: XCUIElementQuery { descendants(matching: .toolbar) }
    var alerts: XCUIElementQuery { descendants(matching: .alert) }
    var sheets: XCUIElementQuery { descendants(matching: .sheet) }
    var popovers: XCUIElementQuery { descendants(matching: .popover) }
    var windows: XCUIElementQuery { descendants(matching: .window) }
    var keyboards: XCUIElementQuery { descendants(matching: .keyboard) }
    var keys: XCUIElementQuery { descendants(matching: .key) }
    var sliders: XCUIElementQuery { descendants(matching: .slider) }
    var steppers: XCUIElementQuery { descendants(matching: .stepper) }
    var pickers: XCUIElementQuery { descendants(matching: .picker) }
    var pickerWheels: XCUIElementQuery { descendants(matching: .pickerWheel) }
    var datePickers: XCUIElementQuery { descendants(matching: .datePicker) }
    var segmentedControls: XCUIElementQuery { descendants(matching: .segmentedControl) }
    var links: XCUIElementQuery { descendants(matching: .link) }
    var progressIndicators: XCUIElementQuery { descendants(matching: .progressIndicator) }
    var activityIndicators: XCUIElementQuery { descendants(matching: .activityIndicator) }
    var pageIndicators: XCUIElementQuery { descendants(matching: .pageIndicator) }
    var statusBars: XCUIElementQuery { descendants(matching: .statusBar) }
    var webViews: XCUIElementQuery { descendants(matching: .webView) }
    var maps: XCUIElementQuery { descendants(matching: .map) }
    var menus: XCUIElementQuery { descendants(matching: .menu) }
    var menuItems: XCUIElementQuery { descendants(matching: .menuItem) }
    var groups: XCUIElementQuery { descendants(matching: .group) }
    var icons: XCUIElementQuery { descendants(matching: .icon) }
    var dialogs: XCUIElementQuery { descendants(matching: .dialog) }
}

// MARK: - Coordinates

final class XCUICoordinate: NSObject, @unchecked Sendable {
    let element: XCUIElement
    let normalized: CGVector
    let offset: CGVector

    init(element: XCUIElement, normalized: CGVector, offset: CGVector) {
        self.element = element
        self.normalized = normalized
        self.offset = offset
    }

    var screenPoint: CGPoint {
        let f = element.frame
        return CGPoint(x: f.minX + f.width * normalized.dx + offset.dx, y: f.minY + f.height * normalized.dy + offset.dy)
    }

    func withOffset(_ vector: CGVector) -> XCUICoordinate {
        XCUICoordinate(element: element, normalized: normalized, offset: CGVector(dx: offset.dx + vector.dx, dy: offset.dy + vector.dy))
    }

    func tap() {
        let p = screenPoint
        SimlessUIHost.shared.act(["cmd": "ui.tap", "x": p.x, "y": p.y])
    }

    func doubleTap() {
        let p = screenPoint
        SimlessUIHost.shared.act(["cmd": "ui.tap", "x": p.x, "y": p.y, "count": 2])
    }

    func press(forDuration duration: TimeInterval) {
        let p = screenPoint
        SimlessUIHost.shared.act(["cmd": "ui.tap", "x": p.x, "y": p.y, "duration": duration])
    }

    func press(forDuration duration: TimeInterval, thenDragTo other: XCUICoordinate) {
        press(forDuration: duration, thenDragTo: other, withVelocity: .default, thenHoldForDuration: 0)
    }

    func press(forDuration duration: TimeInterval, thenDragTo other: XCUICoordinate,
               withVelocity velocity: XCUIGestureVelocity, thenHoldForDuration hold: TimeInterval) {
        let a = screenPoint, b = other.screenPoint
        SimlessUIHost.shared.act(["cmd": "ui.drag", "from": [a.x, a.y], "to": [b.x, b.y], "press": duration,
                                  "velocity": velocity.rawValue, "hold": hold])
    }
}

// MARK: - Queries

class XCUIElementQuery: NSObject, @unchecked Sendable {
    enum Step {
        case descendants(XCUIElement.ElementType)
        case children(XCUIElement.ElementType)
        case identifier(String)
        case predicate(NSPredicate)
        case containing(NSPredicate)
        case containingType(XCUIElement.ElementType, String?)
        case subscriptKey(String)
    }

    let parent: XCUIElement?
    let base: XCUIElementQuery?
    let step: Step

    init(parent: XCUIElement?, step: Step) {
        self.parent = parent
        self.base = nil
        self.step = step
    }

    init(base: XCUIElementQuery, step: Step) {
        self.parent = nil
        self.base = base
        self.step = step
    }

    /// Matching nodes, in document order.
    func matches() -> [Node] {
        let tree = SimlessUIHost.shared.tree()
        return evaluate(in: tree)
    }

    func evaluate(in tree: [Node]) -> [Node] {
        switch step {
        case .descendants(let type), .children(let type):
            let roots: [Int]
            if let parent {
                if parent is XCUIApplication {
                    roots = [-1]
                } else if let n = parent.resolve() {
                    roots = [n.index]
                } else {
                    return []
                }
            } else if let base {
                roots = base.evaluate(in: tree).map(\.index)
            } else {
                roots = [-1]
            }
            var out: [Node] = []
            var seen = Set<Int>()
            var childrenOnly = false
            if case .children = step { childrenOnly = true }
            for root in roots {
                for n in tree where n.index != root && !seen.contains(n.index) {
                    let isChild = n.parent == root
                    let inside = isChild || (root == -1 ? true : Self.isDescendant(n, of: root, in: tree))
                    guard childrenOnly ? isChild : inside else { continue }
                    if type == .any || n.type == type { out.append(n); seen.insert(n.index) }
                }
            }
            return out
        case .identifier(let id):
            return (base?.evaluate(in: tree) ?? []).filter { $0.identifier == id }
        case .subscriptKey(let key):
            return (base?.evaluate(in: tree) ?? []).filter { $0.identifier == key || $0.label == key || $0.title == key }
        case .predicate(let p):
            return (base?.evaluate(in: tree) ?? []).filter { p.evaluate(with: Snapshot($0)) }
        case .containing(let p):
            // The element itself counts, as in XCUITest (buttons.containing(label CONTAINS "x")).
            return (base?.evaluate(in: tree) ?? []).filter { n in
                p.evaluate(with: Snapshot(n)) || tree.contains { Self.isDescendant($0, of: n.index, in: tree) && p.evaluate(with: Snapshot($0)) }
            }
        case .containingType(let type, let id):
            return (base?.evaluate(in: tree) ?? []).filter { n in
                tree.contains { m in Self.isDescendant(m, of: n.index, in: tree) && (type == .any || m.type == type) && (id.map { m.identifier == $0 } ?? true) }
            }
        }
    }

    static func isDescendant(_ n: Node, of root: Int, in tree: [Node]) -> Bool {
        var p = n.parent
        var hops = 0
        while p >= 0 && hops < 200 {
            if p == root { return true }
            p = tree[p].parent
            hops += 1
        }
        return false
    }

    // MARK: API

    @objc var count: Int { matches().count }
    var element: XCUIElement { XCUIElement(query: self, position: nil) }
    var firstMatch: XCUIElement { XCUIElement(query: self, position: nil) }
    func element(boundBy index: Int) -> XCUIElement { XCUIElement(query: self, position: index) }
    var allElementsBoundByIndex: [XCUIElement] { (0..<count).map { element(boundBy: $0) } }
    var allElementsBoundByAccessibilityElement: [XCUIElement] { allElementsBoundByIndex }

    subscript(key: String) -> XCUIElement { XCUIElement(query: XCUIElementQuery(base: self, step: .subscriptKey(key)), position: nil) }

    func matching(identifier: String) -> XCUIElementQuery { XCUIElementQuery(base: self, step: .identifier(identifier)) }
    func matching(_ predicate: NSPredicate) -> XCUIElementQuery { XCUIElementQuery(base: self, step: .predicate(predicate)) }
    func matching(_ type: XCUIElement.ElementType, identifier: String?) -> XCUIElementQuery {
        XCUIElementQuery(base: XCUIElementQuery(base: self, step: .predicate(NSPredicate(format: "elementType == %d OR %d == 0", type.rawValue, type.rawValue))),
                         step: identifier.map { .identifier($0) } ?? .predicate(NSPredicate(value: true)))
    }
    func containing(_ predicate: NSPredicate) -> XCUIElementQuery { XCUIElementQuery(base: self, step: .containing(predicate)) }
    func containing(_ type: XCUIElement.ElementType, identifier: String?) -> XCUIElementQuery {
        XCUIElementQuery(base: self, step: .containingType(type, identifier))
    }

    func descendants(matching type: XCUIElement.ElementType) -> XCUIElementQuery { XCUIElementQuery(base: self, step: .descendants(type)) }
    func children(matching type: XCUIElement.ElementType) -> XCUIElementQuery { XCUIElementQuery(base: self, step: .children(type)) }

    var buttons: XCUIElementQuery { descendants(matching: .button) }
    var staticTexts: XCUIElementQuery { descendants(matching: .staticText) }
    var otherElements: XCUIElementQuery { descendants(matching: .other) }
    var images: XCUIElementQuery { descendants(matching: .image) }
    var switches: XCUIElementQuery { descendants(matching: .switch) }
    var textFields: XCUIElementQuery { descendants(matching: .textField) }
    var cells: XCUIElementQuery { descendants(matching: .cell) }
    var navigationBars: XCUIElementQuery { descendants(matching: .navigationBar) }
    var scrollViews: XCUIElementQuery { descendants(matching: .scrollView) }
    var collectionViews: XCUIElementQuery { descendants(matching: .collectionView) }
    var tabBars: XCUIElementQuery { descendants(matching: .tabBar) }
    var toolbars: XCUIElementQuery { descendants(matching: .toolbar) }
    var pickerWheels: XCUIElementQuery { descendants(matching: .pickerWheel) }
    var links: XCUIElementQuery { descendants(matching: .link) }

    override var debugDescription: String {
        let tree = SimlessUIHost.shared.tree()
        return evaluate(in: tree).map { Self.describe($0, in: tree) }.joined(separator: "\n")
    }

    override var description: String {
        let root = parent.map { $0 is XCUIApplication ? "app" : "(\($0.query.map { "\($0)" } ?? "element"))" } ?? ""
        switch step {
        case .descendants(let t): return "\(base.map { "\($0) " } ?? root + " ")\(t == .any ? "descendants" : "\(t)s")"
        case .children(let t): return "\(base.map { "\($0) " } ?? root + " ")children of type \(t)"
        case .identifier(let i): return "\(base.map { "\($0)" } ?? "") with identifier \"\(i)\""
        case .subscriptKey(let k): return "\(base.map { "\($0)" } ?? "")[\"\(k)\"]"
        case .predicate(let p): return "\(base.map { "\($0)" } ?? "") matching \(p.predicateFormat)"
        case .containing(let p): return "\(base.map { "\($0)" } ?? "") containing \(p.predicateFormat)"
        case .containingType(let t, let i): return "\(base.map { "\($0)" } ?? "") containing \(t)\(i.map { " \"\($0)\"" } ?? "")"
        }
    }

    static func describe(_ n: Node, in tree: [Node]) -> String {
        var depth = 0, p = n.parent
        while p >= 0 && depth < 60 { depth += 1; p = tree[p].parent }
        var s = "\(String(repeating: "  ", count: depth))\(n.type), {{\(Int(n.frame.minX)), \(Int(n.frame.minY))}, {\(Int(n.frame.width)), \(Int(n.frame.height))}}"
        if !n.identifier.isEmpty { s += ", identifier: '\(n.identifier)'" }
        if !n.label.isEmpty { s += ", label: '\(n.label)'" }
        if let v = n.value as? String, !v.isEmpty { s += ", value: \(v)" }
        if n.selected { s += ", Selected" }
        if !n.enabled { s += ", Disabled" }
        return s
    }
}

/// What NSPredicates see for one node (identifier, label, value, title,
/// elementType, enabled, selected, hittable, placeholderValue).
final class Snapshot: NSObject {
    let node: Node
    init(_ node: Node) { self.node = node }
    @objc var identifier: String { node.identifier }
    @objc var label: String { node.label }
    @objc var title: String { node.title }
    @objc var value: Any? { node.value }
    @objc var placeholderValue: String { node.placeholder }
    @objc var elementType: UInt { node.type.rawValue }
    @objc var enabled: Bool { node.enabled }
    @objc var isEnabled: Bool { node.enabled }
    @objc var selected: Bool { node.selected }
    @objc var isSelected: Bool { node.selected }
    @objc var hittable: Bool { node.hittable }
    @objc var exists: Bool { true }
    @objc var frame: CGRect { node.frame }
}

// MARK: - Application

final class XCUIApplication: XCUIElement {
    enum State: UInt, Sendable { case unknown = 0, notRunning, runningBackgroundSuspended, runningBackground, runningForeground }

    var launchArguments: [String] = []
    var launchEnvironment: [String: String] = [:]
    let bundleIdentifier: String?

    override init(query: XCUIElementQuery? = nil, position: Int? = nil) {
        bundleIdentifier = nil
        super.init(query: nil, position: nil)
    }

    /// Another app: only Springboard's status bar and "did Safari open" are
    /// available on a Mac host.
    init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
        super.init(query: nil, position: nil)
    }

    private var isOther: Bool { bundleIdentifier != nil }

    override func resolve() -> Node? {
        // The application itself: a node standing for the whole window.
        let c = host.canvas
        return Node(-1, ["type": Int(ElementType.application.rawValue), "frame": [0, 0, c.first ?? 402, c.count > 1 ? c[1] : 874],
                         "label": "", "hittable": true])
    }

    override var frame: CGRect { resolve()?.frame ?? .zero }

    func launch() {
        guard !isOther else { return }
        if let error = host.launch(arguments: launchArguments, environment: launchEnvironment) {
            XCTFail(error)
        }
        host.dirty = true
    }

    func terminate() {
        guard !isOther else { return }
        host.terminate()
        host.dirty = true
    }

    func activate() {
        guard !isOther else { return }
        if host.isRunning {
            host.act(["cmd": "ui.foreground"])
        } else {
            launch()
        }
    }

    func open(_ url: URL) {
        let r = host.act(["cmd": "ui.openURL", "url": url.absoluteString])
        if r?["ok"] as? Bool != true { XCTFail("open(\(url)): \(r?["error"] as? String ?? "the app isn't running")") }
    }

    var state: State {
        if bundleIdentifier == "com.apple.mobilesafari" {
            return (host.call(["cmd": "ui.externalURLs"])?["urls"] as? [String] ?? []).isEmpty ? .notRunning : .runningForeground
        }
        if isOther { return .runningForeground }
        guard host.isRunning else { return .notRunning }
        return (host.call(["cmd": "ui.state"])?["foreground"] as? Bool ?? true) ? .runningForeground : .runningBackground
    }

    func wait(for state: State, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout * host.timeScale)
        repeat {
            if self.state == state { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    override var debugDescription: String {
        let tree = host.tree(fresh: true)
        return "Application, pid: \(NSRunningApplication.runningApplications(withBundleIdentifier: host.slotID).first?.processIdentifier ?? 0)\n"
            + tree.map { XCUIElementQuery.describe($0, in: tree) }.joined(separator: "\n")
    }

    override func screenshot() -> XCUIScreenshot {
        let r = host.call(["cmd": "ui.screenshot"])
        return XCUIScreenshot(png: (r?["png"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data())
    }

    // Springboard: the status bar sits in the top safe area.
    override func descendants(matching type: ElementType) -> XCUIElementQuery {
        if bundleIdentifier == "com.apple.springboard", type == .statusBar {
            return StatusBarQuery(parent: self, step: .descendants(.statusBar))
        }
        return super.descendants(matching: type)
    }

    // MARK: Accessibility audit

    func performAccessibilityAudit(for auditTypes: XCUIAccessibilityAuditType = .all,
                                   _ issueHandler: ((XCUIAccessibilityAuditIssue) throws -> Bool)? = nil) throws {
        let r = host.act(["cmd": "ui.audit", "types": auditTypes.rawValue])
        let tree = host.tree(fresh: true)
        var unhandled: [XCUIAccessibilityAuditIssue] = []
        for issue in (r?["issues"] as? [[String: Any]]) ?? [] {
            let node = (issue["node"] as? Int).flatMap { i in tree.first { $0.index == i } }
            let element = node.map { n in XCUIElement(query: NodeQuery(index: n.index), position: nil) }
            let i = XCUIAccessibilityAuditIssue(auditType: XCUIAccessibilityAuditType(rawValue: UInt64(issue["type"] as? Int ?? 0)),
                                                element: element,
                                                compactDescription: issue["compact"] as? String ?? "",
                                                detailedDescription: issue["detailed"] as? String ?? "")
            if try issueHandler?(i) != true { unhandled.append(i) }
        }
        if !unhandled.isEmpty {
            throw AuditError(issues: unhandled)
        }
    }

    struct AuditError: Error, CustomStringConvertible {
        let issues: [XCUIAccessibilityAuditIssue]
        var description: String {
            "\(issues.count) accessibility audit issue(s):\n" + issues.map { "  \($0.auditType): \($0.compactDescription)" }.joined(separator: "\n")
        }
    }
}

/// One node by its position in the snapshot (audit issue elements).
final class NodeQuery: XCUIElementQuery {
    let index: Int
    init(index: Int) {
        self.index = index
        super.init(parent: nil, step: .descendants(.any))
    }
    override func evaluate(in tree: [Node]) -> [Node] { tree.filter { $0.index == index } }
}

final class StatusBarQuery: XCUIElementQuery {
    override func evaluate(in tree: [Node]) -> [Node] {
        let c = SimlessUIHost.shared.canvas
        return [Node(-2, ["type": Int(XCUIElement.ElementType.statusBar.rawValue),
                          "frame": [0, 0, c.first ?? 402, c.count > 2 ? c[2] : 62], "hittable": true])]
    }
}

struct XCUIAccessibilityAuditType: OptionSet, Sendable, CustomStringConvertible {
    let rawValue: UInt64
    init(rawValue: UInt64) { self.rawValue = rawValue }
    static let contrast = XCUIAccessibilityAuditType(rawValue: 1 << 0)
    static let elementDetection = XCUIAccessibilityAuditType(rawValue: 1 << 1)
    static let hitRegion = XCUIAccessibilityAuditType(rawValue: 1 << 2)
    static let sufficientElementDescription = XCUIAccessibilityAuditType(rawValue: 1 << 3)
    static let dynamicType = XCUIAccessibilityAuditType(rawValue: 1 << 16)
    static let textClipped = XCUIAccessibilityAuditType(rawValue: 1 << 17)
    static let trait = XCUIAccessibilityAuditType(rawValue: 1 << 18)
    static let all = XCUIAccessibilityAuditType(rawValue: ~0)
    var description: String {
        switch self {
        case .contrast: return "contrast"
        case .elementDetection: return "elementDetection"
        case .hitRegion: return "hitRegion"
        case .sufficientElementDescription: return "sufficientElementDescription"
        case .dynamicType: return "dynamicType"
        case .textClipped: return "textClipped"
        case .trait: return "trait"
        default: return "audit(\(rawValue))"
        }
    }
}

final class XCUIAccessibilityAuditIssue: NSObject, @unchecked Sendable {
    let auditType: XCUIAccessibilityAuditType
    let element: XCUIElement?
    let compactDescription: String
    let detailedDescription: String
    init(auditType: XCUIAccessibilityAuditType, element: XCUIElement?, compactDescription: String, detailedDescription: String) {
        self.auditType = auditType
        self.element = element
        self.compactDescription = compactDescription
        self.detailedDescription = detailedDescription
    }
}

// MARK: - Run artifacts

/// The bundle's principal class: on each failed test it saves a screenshot of
/// the app and its accessibility tree next to the run's logs.
@objc(SimlessXCUIObserver)
final class SimlessXCUIObserver: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
        guard let dir = ProcessInfo.processInfo.environment["SIMLESS_UI_ARTIFACTS"], SimlessUIHost.shared.isRunning else { return }
        let name = testCase.name.trimmingCharacters(in: CharacterSet(charactersIn: "-[]")).replacingOccurrences(of: " ", with: ".")
        let host = SimlessUIHost.shared
        if let r = host.call(["cmd": "ui.screenshot"]), let png = (r["png"] as? String).flatMap({ Data(base64Encoded: $0) }) {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        let tree = host.tree(fresh: true)
        let text = tree.map { XCUIElementQuery.describe($0, in: tree) }.joined(separator: "\n")
        try? text.write(toFile: "\(dir)/\(name).tree.txt", atomically: true, encoding: .utf8)
    }
}
