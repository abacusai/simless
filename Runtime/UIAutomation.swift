// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation
import UIKit
import ObjectiveC

/// In-process UI automation for UI tests (Templates/XCUI drives it): the app's
/// accessibility tree typed the way XCUITest types it, and input as real
/// touches (touch.m) into the app's hidden window.
enum UIAutomation {
    static let commands: Set<String> = [
        "ui.ready", "ui.snapshot", "ui.idle", "ui.tap", "ui.drag", "ui.swipe", "ui.type", "ui.scrollToVisible",
        "ui.pickerWheel", "ui.slider", "ui.screenshot", "ui.orientation", "ui.background", "ui.foreground",
        "ui.state", "ui.openURL", "ui.externalURLs", "ui.audit", "ui.appearance", "ui.flush",
    ]
    static func handles(_ cmd: String) -> Bool { commands.contains(cmd) }

    static func handle(_ cmd: String, _ req: [String: Any], _ connection: Connection) {
        // A request sent again after its connection went (see Replies) gets the
        // first attempt's answer: a tap or a drag is never done twice.
        let rid = req["rid"] as? String
        if let rid, Replies.answer(rid, on: connection) { return }
        // A run loop block, not the main queue: commands spin the run loop while
        // they wait (idle, touches, dismissals), and inside a main-queue block
        // the main queue couldn't drain, so the app's own async work would stall.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            enableAutomation()
            var reply: [String: Any] = [:]
            if let thrown = catchingExceptions({ reply = perform(cmd, req) }) {
                reply = ["ok": false, "error": "UIKit threw \(thrown) during \(cmd)"]
            }
            if let rid { reply["rid"] = rid; Replies.store(rid, reply) }
            connection.send(reply)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Runs `body`; returns the Objective-C exception it threw, if any (catch.m).
    private static func catchingExceptions(_ body: @escaping () -> Void) -> String? {
        final class Body { let run: () -> Void; init(_ run: @escaping () -> Void) { self.run = run } }
        let box = Unmanaged.passRetained(Body(body))
        defer { box.release() }
        guard let thrown = simless_catch({ Unmanaged<Body>.fromOpaque($0!).takeUnretainedValue().run() }, box.toOpaque()) else { return nil }
        defer { free(thrown) }
        return String(cString: thrown)
    }

    private static func perform(_ cmd: String, _ req: [String: Any]) -> [String: Any] {
        switch cmd {
        case "ui.ready":
            return ["ok": true, "ready": Session.ready()]
        case "ui.snapshot":
            let (nodes, generation) = Snapshotter.take()
            return ["ok": true, "nodes": nodes, "generation": generation]
        case "ui.flush":
            // Before the test quits the app: settings it saved must reach
            // cfprefsd, which on the Mac takes them a moment later.
            UserDefaults.standard.synchronize()
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            return ["ok": true]
        case "ui.idle":
            let settled = Idle.wait(timeout: req["timeout"] as? Double ?? 2)
            return ["ok": true, "settled": settled, "busy": settled ? "" : Idle.lastBusy]
        case "ui.tap":
            let p = point(req)
            let count = req["count"] as? Int ?? 1
            let duration = req["duration"] as? Double ?? 0.02
            // SwiftUI's gestures don't take synthesized touches on the Mac, so a
            // plain tap on a SwiftUI element activates it the way VoiceOver does
            // (a Button's action, a Toggle, a link, an onTapGesture). UIKit views
            // (tab bars, text fields, cells, controls) get a real touch.
            if let b = (Snapshotter.object(req) as? NativeAlerts.Button) ?? NativeAlerts.button(at: p) {
                b.press()
                return ["ok": true, "how": "alert"]
            }
            if Menus.open != nil, Menus.tap(at: p, ref: Snapshotter.object(req)) { return ["ok": true, "how": "menu"] }
            if ShareSheet.tap(at: p, ref: Snapshotter.object(req)) { return ["ok": true, "how": "shareSheet"] }
            if let b = Snapshotter.object(req) as? DatePickers.Button { DatePickers.tap(b); return ["ok": true, "how": "datePicker"] }
            if DatePickers.tapOutside(at: p) { return ["ok": true, "how": "closeDatePicker"] }
            // A long press opens the context menu under the finger.
            if duration >= 0.4, Menus.openEditMenu(at: p) { return ["ok": true, "how": "editMenu"] }
            if duration >= 0.4, Menus.openContextMenu(at: p) { return ["ok": true, "how": "contextMenu"] }
            // A button that shows a menu when tapped.
            if count == 1, duration < 0.3, let target = Snapshotter.object(req) ?? Snapshotter.element(at: p),
               Menus.openButtonMenu(target, at: p) {
                return ["ok": true, "how": "buttonMenu"]
            }
            // A stepper's Increment and Decrement: the Mac's stepper doesn't take
            // touches, so the tap does what VoiceOver's increment would.
            if count == 1, let part = Snapshotter.object(req),
               let stepper = Snapshotter.parentObject(req, type: .stepper) ?? Input.stepper(containing: part, at: p) {
                let id = (part.value(forKey: "accessibilityIdentifier") as? String ?? "") + (part.accessibilityLabel ?? "")
                let increment = id.hasSuffix("Increment") || (!id.hasSuffix("Decrement") && p.x > stepper.accessibilityFrame.midX)
                let before = stepper.accessibilityValue
                if increment { stepper.accessibilityIncrement() } else { stepper.accessibilityDecrement() }
                Input.spin(0.03)
                // A UIStepper that ignores accessibility: change its value as a tap would.
                if stepper.accessibilityValue == before, let control = Input.stepperControl(stepper) {
                    control.value = increment ? min(control.maximumValue, control.value + control.stepValue) : max(control.minimumValue, control.value - control.stepValue)
                    control.sendActions(for: .valueChanged)
                    Input.spin(0.03)
                }
                return ["ok": true, "how": increment ? "increment" : "decrement"]
            }
            // The keyboard toolbar lives in simless's own window: its buttons are
            // activated directly.
            if count == 1, let target = Snapshotter.object(req), Keyboard.contains(target) {
                if let control = Snapshotter.view(of: target) as? UIControl, control.isEnabled {
                    let events = control.allControlEvents
                    control.sendActions(for: events.contains(.primaryActionTriggered) ? .primaryActionTriggered : .touchUpInside)
                    Input.spin(0.03)
                    return ["ok": true, "how": "control"]
                }
                if target.accessibilityActivate() { return ["ok": true, "how": "activate"] }
            }
            // Text inputs take a real touch: that's what gives them focus.
            let field = Input.textInput(at: p)
            if field == nil, count == 1, duration < 0.3, let target = Snapshotter.object(req) ?? Snapshotter.element(at: p),
               Input.activates(target) {
                if target.accessibilityActivate() { return ["ok": true, "how": "activate"] }
                // An element that merges its children (children: .ignore or .combine)
                // can lose a Button's action; the Button is still one of the
                // elements XCUITest sees under it.
                if Snapshotter.activateAutomationChild(of: target) { return ["ok": true, "how": "activateChild"] }
                // No action of its own: a tap gesture on a SwiftUI container
                // around it (onTapGesture) is that container's activation.
                var o = target.value(forKey: "accessibilityContainer") as? NSObject
                var hops = 0
                while let cur = o, !(cur is UIView), Input.activates(cur), hops < 12 {
                    if cur.accessibilityActivate() { return ["ok": true, "how": "activateContainer"] }
                    o = cur.value(forKey: "accessibilityContainer") as? NSObject
                    hops += 1
                }
            }
            for i in 0..<count {
                if let e = Input.tap(at: p, duration: duration) { return ["ok": false, "error": e] }
                if i + 1 < count { Input.spin(0.05) }
            }
            // A text view takes focus once its tap recognizer has waited out a
            // double tap; the next action (typing) needs it focused.
            if count == 1, let field, !field.isFirstResponder {
                let end = Date().addingTimeInterval(0.6)
                while !field.isFirstResponder && Date() < end { Input.spin(0.02) }
                if !field.isFirstResponder { _ = field.becomeFirstResponder() }
            }
            return ["ok": true, "how": "touch"]
        case "ui.drag":
            let from = req["from"] as? [Double] ?? [0, 0], to = req["to"] as? [Double] ?? [0, 0]
            let e = Input.drag(from: CGPoint(x: from[0], y: from[1]), to: CGPoint(x: to[0], y: to[1]),
                               press: req["press"] as? Double ?? 0, velocity: req["velocity"] as? Double ?? 1000,
                               hold: req["hold"] as? Double ?? 0)
            return ["ok": e == nil, "error": e as Any]
        case "ui.swipe":
            let e = Input.swipe(center: point(req), dx: req["dx"] as? Double ?? 0, dy: req["dy"] as? Double ?? 0,
                                size: CGSize(width: req["width"] as? Double ?? 0, height: req["height"] as? Double ?? 0),
                                velocity: req["velocity"] as? Double ?? 1200)
            return ["ok": e == nil, "error": e as Any]
        case "ui.type":
            let e = Keyboard.type(req["text"] as? String ?? "")
            return ["ok": e == nil, "error": e as Any]
        case "ui.scrollToVisible":
            guard let obj = Snapshotter.object(req) else { return ["ok": false, "error": "stale element"] }
            Scrolling.scrollToVisible(obj)
            return ["ok": true]
        case "ui.pickerWheel":
            guard let obj = Snapshotter.object(req) else { return ["ok": false, "error": "stale element"] }
            if let w = obj as? DatePickers.Wheel {
                let e = DatePickers.select(req["value"] as? String ?? "", in: w)
                return ["ok": e == nil, "error": e as Any]
            }
            let e = Pickers.select(req["value"] as? String ?? "", in: obj)
            return ["ok": e == nil, "error": e as Any]
        case "ui.slider":
            guard let obj = Snapshotter.object(req), let slider = Snapshotter.view(of: obj) as? UISlider else { return ["ok": false, "error": "not a slider"] }
            let pos = Float(req["position"] as? Double ?? 0)
            slider.setValue(slider.minimumValue + (slider.maximumValue - slider.minimumValue) * pos, animated: false)
            slider.sendActions(for: .valueChanged)
            return ["ok": true]
        case "ui.screenshot":
            return Screenshots.take(rect: (req["rect"] as? [Double]).map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) })
        case "ui.orientation":
            Session.landscape = req["landscape"] as? Bool ?? false
            Session.applyCanvas()
            return ["ok": true]
        case "ui.background":
            Lifecycle.background()
            return ["ok": true]
        case "ui.foreground":
            Lifecycle.foreground()
            return ["ok": true]
        case "ui.state":
            let states = UIApplication.shared.connectedScenes.map { $0.activationState.rawValue }
            return ["ok": true, "foreground": Lifecycle.foregrounded, "scenes": states,
                    "appState": UIApplication.shared.applicationState.rawValue]
        case "ui.openURL":
            guard let s = req["url"] as? String, let url = URL(string: s) else { return ["ok": false, "error": "bad URL"] }
            let e = Lifecycle.open(url)
            return ["ok": e == nil, "error": e as Any]
        case "ui.appearance":
            Session.applyAppearance(req["style"] as? Int ?? 0)
            Idle.wait(timeout: 1)
            return ["ok": true]
        case "ui.externalURLs":
            return ["ok": true, "urls": ExternalURLs.opened]
        case "ui.audit":
            return ["ok": true, "issues": Audit.run(types: UInt64(truncatingIfNeeded: req["types"] as? Int ?? -1))]
        default:
            return ["ok": false, "error": "unknown \(cmd)"]
        }
    }

    private static func point(_ req: [String: Any]) -> CGPoint {
        CGPoint(x: req["x"] as? Double ?? 0, y: req["y"] as? Double ?? 0)
    }

    private static var automationOn = false
    static func enableAutomation() {
        guard !automationOn, let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let sym = dlsym(h, "_AXSSetAutomationEnabled") else { return }
        typealias Fn = @convention(c) (Bool) -> Void
        unsafeBitCast(sym, to: Fn.self)(true)
        automationOn = true
    }

    /// The app's windows, back to front.
    static var appWindows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !$0.isHidden && $0.bounds.width > 0 && !Keyboard.isEmulatedKeyboard($0)
                // UIKit's text effects window holds nothing a test sees on the Mac.
                && !NSStringFromClass(type(of: $0)).hasSuffix("TextEffectsWindow") }
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
    }

    static var keyWindow: UIWindow? { appWindows.last(where: \.isKeyWindow) ?? appWindows.last }
}

// MARK: - Replies

/// The answers to the last few hundred requests, by the id the UI test shim
/// gives each one. A native host's socket can be closed under it (by something
/// in the app's process while it launches): the shim then sends the request
/// again on a new connection, and gets the answer the first attempt made, or
/// waits for it if that one is still running. Exactly once, whatever the socket did.
enum Replies {
    private static let lock = NSLock()
    private static var done: [String: [String: Any]] = [:]
    private static var order: [String] = []
    private static var running: Set<String> = []

    /// True when the request was answered here (seen before); false when it's
    /// new and the caller runs it, then stores its reply.
    static func answer(_ rid: String, on connection: Connection) -> Bool {
        lock.lock()
        if let reply = done[rid] { lock.unlock(); connection.send(reply); return true }
        guard running.contains(rid) else { running.insert(rid); lock.unlock(); return false }
        lock.unlock()
        // The first attempt still runs on the main thread; this is the connection's own thread.
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            lock.lock(); let reply = done[rid]; lock.unlock()
            if let reply { connection.send(reply); return true }
        }
        connection.send(["ok": false, "error": "request \(rid) didn't finish", "rid": rid])
        return true
    }

    static func store(_ rid: String, _ reply: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        running.remove(rid)
        done[rid] = reply
        order.append(rid)
        if order.count > 512 { for old in order.prefix(order.count - 512) { done[old] = nil }; order.removeFirst(order.count - 512) }
    }
}

// MARK: - Session (launch set-up)

/// What a UI test launch asked for: the device canvas, orientation, text size.
enum Session {
    static var landscape = ProcessInfo.processInfo.environment["SIMLESS_UI_ORIENTATION"] == "landscape"
    private static var applied = false

    static var canvas: (w: Double, h: Double, top: Double, bottom: Double) {
        let c = (ProcessInfo.processInfo.environment["SIMLESS_UI_CANVAS"] ?? "402,874,62,34").split(separator: ",").compactMap { Double($0) }
        let w = c.first ?? 402, h = c.count > 1 ? c[1] : 874
        let top = c.count > 2 ? c[2] : 62, bottom = c.count > 3 ? c[3] : 34
        if landscape { return (h, w, w < 600 ? 0 : top, bottom) }
        return (w, h, top, bottom)
    }

    /// The first screen is up: a key window with content, canvas applied, idle.
    static func ready() -> Bool {
        guard let w = UIAutomation.keyWindow, w.rootViewController?.isViewLoaded == true else { return false }
        if !applied {
            applied = true
            installHooks()
            applyCanvas()
            Idle.wait(timeout: 3)
        }
        return true
    }

    /// Light or dark mode for every window, as XCUIDevice.appearance sets it
    /// for the whole device (0 unspecified, 1 light, 2 dark).
    static func applyAppearance(_ style: Int) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.traitOverrides.userInterfaceStyle = UIUserInterfaceStyle(rawValue: style) ?? .unspecified
        }
    }

    static func installHooks() {
        if let style = ProcessInfo.processInfo.environment["SIMLESS_UI_APPEARANCE"].flatMap(Int.init) { applyAppearance(style) }
        if (ProcessInfo.processInfo.environment["SIMLESS_UI_CANVAS"] ?? "").split(separator: ",").first.flatMap({ Double($0) }).map({ $0 < 600 }) ?? true {
            DeviceModel.watchSupported()
        }
        NativeAlerts.install()
        ContentSize.applyLaunchArgument()
        ExternalURLs.install()
        Keyboard.install()
        NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main) { _ in
            applyCanvas()
        }
    }

    static func applyCanvas() {
        let c = canvas
        let size = CGSize(width: c.w, height: c.h)
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.traitOverrides.horizontalSizeClass = c.w < 600 ? .compact : .regular
            scene.traitOverrides.verticalSizeClass = (c.w > c.h && c.h < 600) ? .compact : .regular
            if let size = ContentSize.category { scene.traitOverrides.preferredContentSizeCategory = size }
            for w in scene.windows where !Keyboard.isEmulatedKeyboard(w) {
                if w.frame.size != size { w.frame = CGRect(origin: .zero, size: size) }
                // The Mac window has a safe area of its own (the title bar); add only the difference.
                if let root = w.rootViewController {
                    let base = root.view.safeAreaInsets, current = root.additionalSafeAreaInsets
                    let wanted = UIEdgeInsets(top: max(0, c.top - (base.top - current.top)), left: 0,
                                              bottom: max(0, c.bottom - (base.bottom - current.bottom)), right: 0)
                    if wanted != current { root.additionalSafeAreaInsets = wanted }
                }
                w.layoutIfNeeded()
            }
        }
    }
}

/// `-UIPreferredContentSizeCategoryName <category>` works on iOS; the Mac
/// ignores it, so the runtime applies it (fonts scale through interpose.c).
enum ContentSize {
    static var category: UIContentSizeCategory? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-UIPreferredContentSizeCategoryName"), i + 1 < args.count else { return nil }
        return UIContentSizeCategory(rawValue: args[i + 1])
    }

    static func applyLaunchArgument() {
        guard let category else { return }
        let sel = NSSelectorFromString("preferredContentSizeCategory")
        if let m = class_getInstanceMethod(UIApplication.self, sel) {
            let block: @convention(block) (AnyObject) -> NSString = { _ in category.rawValue as NSString }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        NotificationCenter.default.post(name: UIContentSizeCategory.didChangeNotification, object: UIApplication.shared,
                                        userInfo: [UIContentSizeCategory.newValueUserInfoKey: category])
    }
}

// MARK: - Snapshots

/// The accessibility tree as XCUITest sees it: elements plus the containers
/// XCUITest exposes (windows, bars, scroll views, cells, alerts, controls),
/// each typed with XCUIElement.ElementType raw values.
enum Snapshotter {
    private static var refs: [NSObject] = []
    static func object(ref: Int) -> NSObject? { refs.indices.contains(ref) ? refs[ref] : nil }
    private static var generation = 0

    static func object(_ req: [String: Any]) -> NSObject? {
        guard let ref = req["ref"] as? Int, ref >= 0, ref < refs.count, req["generation"] as? Int ?? generation == generation else { return nil }
        return refs[ref]
    }

    /// The innermost accessibility element at a point (window coordinates).
    static func element(at point: CGPoint) -> NSObject? {
        let origin = UIAutomation.appWindows.first?.accessibilityFrame.origin ?? .zero
        var best: NSObject?
        var bestArea = CGFloat.greatestFiniteMagnitude
        var seen = Set<ObjectIdentifier>()
        func visit(_ obj: NSObject, _ depth: Int) {
            guard depth < 150, seen.insert(ObjectIdentifier(obj)).inserted else { return }
            if let v = obj as? UIView, v.isHidden || v.alpha < 0.01 { return }
            // A compact date picker's button (see DatePickers).
            if let picker = obj as? UIDatePicker, DatePickers.isCompact(picker) {
                let f = picker.accessibilityFrame.offsetBy(dx: -origin.x, dy: -origin.y)
                let buttons = DatePickers.buttons(for: picker)
                if f.contains(point), f.width * f.height < bestArea {
                    let i = min(buttons.count - 1, Int((point.x - f.minX) / max(1, f.width / CGFloat(buttons.count))))
                    best = buttons[max(0, i)]; bestArea = f.width * f.height
                }
                return
            }
            if obj.isAccessibilityElement {
                let f = obj.accessibilityFrame.offsetBy(dx: -origin.x, dy: -origin.y)
                if f.contains(point), f.width * f.height < bestArea { best = obj; bestArea = f.width * f.height }
                return
            }
            var children = (obj.accessibilityElements as? [NSObject]) ?? []
            if children.isEmpty, let v = obj as? UIView { children = v.subviews }
            for c in children { visit(c, depth + 1) }
        }
        for w in UIAutomation.appWindows.reversed() { visit(w, 0); if best != nil { break } }
        return best
    }

    /// The UIView an element lives in (itself, or its nearest container view).
    static func view(of obj: NSObject) -> UIView? {
        var o: NSObject? = obj
        var hops = 0
        while let cur = o, hops < 50 {
            if let v = cur as? UIView { return v }
            o = cur.value(forKey: "accessibilityContainer") as? NSObject
            hops += 1
        }
        return nil
    }

    enum T: Int {
        case other = 1, application = 2, window = 4, sheet = 5, alert = 7, button = 9, popover = 18, keyboard = 19, key = 20,
             navigationBar = 21, tabBar = 22, toolbar = 24, statusBar = 25, table = 26, collectionView = 32, slider = 33,
             pageIndicator = 34, progressIndicator = 35, activityIndicator = 36, segmentedControl = 37, picker = 38,
             pickerWheel = 39, `switch` = 40, link = 42, image = 43, searchField = 45, scrollView = 46, staticText = 48,
             textField = 49, secureTextField = 50, datePicker = 51, textView = 52, menu = 53, menuItem = 54, webView = 58,
             cell = 75, stepper = 79
    }

    /// Each ref's parent node index and type, from the last snapshot.
    private static var parents: [Int: Int] = [:]
    private static var types: [Int: Int] = [:]

    /// The object of the element containing `req`'s element, when it has `type`.
    static func parentObject(_ req: [String: Any], type: T) -> NSObject? {
        guard object(req) != nil, let ref = req["ref"] as? Int, let p = parents[ref], p >= 0,
              let pref = refs.indices.contains(p) ? p : nil, types[pref] == type.rawValue else { return nil }
        return refs[pref]
    }

    static func take() -> ([[String: Any]], Int) {
        Keyboard.refreshAccessory()
        generation += 1
        refs = []
        var nodes: [[String: Any]] = []
        let origin = UIAutomation.appWindows.first?.accessibilityFrame.origin ?? .zero
        let windowBounds = UIAutomation.keyWindow?.bounds ?? .zero

        func frameOf(_ obj: NSObject) -> CGRect {
            let f = obj.accessibilityFrame
            return CGRect(x: f.minX - origin.x, y: f.minY - origin.y, width: f.width, height: f.height)
        }

        // Inside an element's automationElements: XCUITest sees these, VoiceOver
        // (and so the accessibility audit) doesn't.
        var automationDepth = 0
        func add(_ obj: NSObject, type: T, parent: Int, frame: CGRect? = nil) -> Int {
            let f = frame ?? frameOf(obj)
            let traits = obj.accessibilityTraits
            var n: [String: Any] = ["ref": refs.count, "parent": parent, "type": type.rawValue,
                                    "frame": [f.minX, f.minY, f.width, f.height].map { (Double($0) * 10).rounded() / 10 }]
            let id = (obj as? UIAccessibilityIdentification)?.accessibilityIdentifier
                ?? (obj.responds(to: NSSelectorFromString("accessibilityIdentifier")) ? obj.value(forKey: "accessibilityIdentifier") as? String : nil)
            if let id, !id.isEmpty { n["id"] = id }
            if let l = obj.accessibilityLabel, !l.isEmpty { n["label"] = l }
            // An explicitly empty value is kept: XCUITest reports it as "".
            if let v = obj.accessibilityValue { n["value"] = v }
            if let actions = obj.accessibilityCustomActions, !actions.isEmpty { n["actions"] = actions.map(\.name) }
            if let tf = obj as? UITextField {
                n["value"] = tf.text?.isEmpty == false ? tf.text! : (tf.placeholder ?? "")
                if let p = tf.placeholder { n["placeholder"] = p }
                n["focused"] = tf.isFirstResponder
            }
            if let tv = obj as? UITextView { n["value"] = tv.text ?? ""; n["focused"] = tv.isFirstResponder }
            if let sw = obj as? UISwitch { n["value"] = sw.isOn ? "1" : "0" }
            var enabled = !traits.contains(.notEnabled)
            if let c = obj as? UIControl { enabled = enabled && c.isEnabled }
            n["enabled"] = enabled
            n["selected"] = traits.contains(.selected) || ((obj as? UIControl)?.isSelected ?? false)
            n["hittable"] = Hit.isHittable(obj, frame: f, window: windowBounds)
            if automationDepth > 0 { n["automationOnly"] = true }
            nodes.append(n)
            refs.append(obj)
            return nodes.count - 1
        }

        var seen = Set<ObjectIdentifier>()
        func visit(_ obj: NSObject, parent: Int, depth: Int) {
            guard depth < 150, seen.insert(ObjectIdentifier(obj)).inserted else { return }
            if let v = obj as? UIView, v.isHidden || v.alpha < 0.01 { return }
            // A compact date picker shows as on an iPhone: buttons with the date or time.
            if let picker = obj as? UIDatePicker, DatePickers.isCompact(picker) {
                let me = add(picker, type: .datePicker, parent: parent)
                let buttons = DatePickers.buttons(for: picker)
                let f = frameOf(picker)
                for (i, b) in buttons.enumerated() {
                    // An iPhone's compact picker button is 34 pt tall.
                    let w = f.width / CGFloat(buttons.count)
                    let h = max(f.height, 34)
                    let bf = CGRect(x: f.minX + CGFloat(i) * w, y: f.midY - h / 2, width: w, height: h)
                    let n = add(b, type: .button, parent: me, frame: bf)
                    nodes[n]["label"] = picker.accessibilityLabel.flatMap { $0.isEmpty ? nil : $0 } ?? (b.part == .time ? "Time Picker" : "Date Picker")
                    nodes[n]["value"] = DatePickers.text(b)
                    nodes[n]["enabled"] = picker.isEnabled
                    nodes[n]["hittable"] = true
                }
                return
            }
            if obj.isAccessibilityElement {
                let me = add(obj, type: elementType(obj), parent: parent)
                // XCUITest shows the parts of some controls (a stepper's buttons, a picker's wheels).
                for c in controlParts(obj) { visit(c, parent: me, depth: depth + 1) }
                // What XCUITest sees below an element that VoiceOver reads as one
                // (a combined element's children, with their identifiers).
                automationDepth += 1
                for c in automationChildren(obj) { visit(c, parent: me, depth: depth + 1) }
                automationDepth -= 1
                return
            }
            var me = parent
            if let t = containerType(obj) {
                me = add(obj, type: t, parent: parent)
            } else if let id = obj.value(forKey: "accessibilityIdentifier") as? String, !id.isEmpty, !(obj is UIWindow) {
                me = add(obj, type: .other, parent: parent)
            }
            var children = (obj.accessibilityElements as? [NSObject]) ?? []
            if children.isEmpty {
                let count = obj.accessibilityElementCount()
                if count != NSNotFound && count > 0 && count < 10_000 {
                    for i in 0..<count { if let e = obj.accessibilityElement(at: i) as? NSObject { children.append(e) } }
                }
            }
            // Under an element, a container's parts are what XCUITest sees there.
            if children.isEmpty, automationDepth > 0 { children = automationChildren(obj) }
            if children.isEmpty, let v = obj as? UIView { children = v.subviews }
            for c in children { visit(c, parent: me, depth: depth + 1) }
        }

        for window in UIAutomation.appWindows {
            let w = add(window, type: .window, parent: -1, frame: CGRect(origin: CGPoint(x: window.frame.minX, y: window.frame.minY), size: window.bounds.size))
            visit(window, parent: w, depth: 0)
        }
        // An open menu (UIKit would show it as an AppKit menu).
        let menuBase = nodes.count
        for n in Menus.nodes(addRef: { refs.append($0); return refs.count - 1 }) {
            var m = n
            if let p = m["parent"] as? Int, p >= 0 { m["parent"] = menuBase + p }
            nodes.append(m)
        }
        // A compact date picker's wheels, while open.
        let dateBase = nodes.count
        for n in DatePickers.nodes(addRef: { refs.append($0); return refs.count - 1 }) {
            var m = n
            if let p = m["parent"] as? Int, p >= 0 { m["parent"] = dateBase + p }
            nodes.append(m)
        }
        // A share sheet (AppKit's picker on the Mac).
        let shareBase = nodes.count
        for n in ShareSheet.nodes(addRef: { refs.append($0); return refs.count - 1 }) {
            var m = n
            if let p = m["parent"] as? Int, p >= 0 { m["parent"] = shareBase + p }
            nodes.append(m)
        }
        // Alerts the runtime intercepted (UIKit would show them as AppKit panels).
        let base = nodes.count
        for n in NativeAlerts.nodes(addRef: { refs.append($0); return refs.count - 1 }) {
            var m = n
            if let p = m["parent"] as? Int, p >= 0 { m["parent"] = base + p }
            nodes.append(m)
        }
        // The Mac names a stepper's buttons "<stepper label>, Increment"; an
        // iPhone names them "Increment" and "Decrement".
        for i in nodes.indices where nodes[i]["type"] as? Int == T.button.rawValue {
            guard let p = nodes[i]["parent"] as? Int, p >= 0, p < nodes.count, nodes[p]["type"] as? Int == T.stepper.rawValue,
                  let stepper = nodes[p]["label"] as? String, !stepper.isEmpty,
                  let l = nodes[i]["label"] as? String, l.hasPrefix(stepper + ", ") else { continue }
            nodes[i]["label"] = String(l.dropFirst(stepper.count + 2))
        }
        if let kb = Keyboard.node() {
            nodes.append(kb.merging(["ref": refs.count, "parent": -1]) { $1 })
            refs.append(NSObject())
            if let accessory = Keyboard.accessoryView {
                // A keyboard toolbar is a toolbar to XCUITest, whatever view SwiftUI builds it from.
                if accessory is UIToolbar {
                    visit(accessory, parent: -1, depth: 0)
                } else {
                    let bar = add(accessory, type: .toolbar, parent: -1, frame: accessory.convert(accessory.bounds, to: nil))
                    for child in accessory.subviews { visit(child, parent: bar, depth: 1) }
                }
            }
        }
        parents = Dictionary(nodes.compactMap { n in (n["ref"] as? Int).map { ($0, n["parent"] as? Int ?? -1) } }, uniquingKeysWith: { a, _ in a })
        types = Dictionary(nodes.compactMap { n in (n["ref"] as? Int).map { ($0, n["type"] as? Int ?? 0) } }, uniquingKeysWith: { a, _ in a })
        return (nodes, generation)
    }

    /// Activates the first element under `obj` (depth first, through
    /// automationElements) that takes an activation.
    static func activateAutomationChild(of obj: NSObject, depth: Int = 0) -> Bool {
        guard depth < 6 else { return false }
        for c in automationChildren(obj) {
            if c.accessibilityTraits.contains(.button) || c.accessibilityTraits.contains(.link), c.accessibilityActivate() { return true }
            if activateAutomationChild(of: c, depth: depth + 1) { return true }
        }
        return false
    }

    /// UIAccessibilityContainer's `automationElements`, where it differs from
    /// what VoiceOver gets.
    static func automationChildren(_ obj: NSObject) -> [NSObject] {
        guard obj.responds(to: NSSelectorFromString("automationElements")),
              let list = obj.value(forKey: "automationElements") as? [NSObject] else { return [] }
        return list.filter { $0 !== obj }
    }

    private static func controlParts(_ obj: NSObject) -> [NSObject] {
        guard let v = obj as? UIView else { return [] }
        if v is UIStepper || v is UIPickerView || v is UIDatePicker || v is UISegmentedControl {
            return (v.accessibilityElements as? [NSObject]) ?? v.subviews
        }
        return []
    }

    static func containerType(_ obj: NSObject) -> T? {
        let cls = NSStringFromClass(type(of: obj))
        switch obj {
        case is UINavigationBar: return .navigationBar
        case is UITabBar: return .tabBar
        case is UIToolbar: return .toolbar
        case is UITableView: return .table
        case is UICollectionView:
            // iPadOS shows XCUITest no tab bar around the floating one's tabs.
            if cls.contains("Floating") && Session.canvas.w >= 600 { return nil }
            return cls.contains("TabBar") || cls.contains("Floating") ? .tabBar : .collectionView
        case is UITableViewCell, is UICollectionViewCell: return .cell
        case is UITextView: return .textView
        case is UIScrollView:
            return cls.contains("Picker") ? nil : .scrollView
        case is UIStepper: return .stepper
        case is UIDatePicker: return .datePicker
        case is UIPickerView: return .picker
        case is UISegmentedControl: return .segmentedControl
        default: break
        }
        if cls.contains("AlertControllerView") || cls.contains("_UIAlertControllerInterfaceActionGroupView") {
            return Alerts.isActionSheet(obj) ? .sheet : .alert
        }
        if cls.contains("FloatingTabBar") { return Session.canvas.w >= 600 ? nil : .tabBar }
        if cls.hasSuffix("TabBar") { return .tabBar }
        if cls == "UIKeyboardLayoutStar" || cls == "UIKBKeyplaneView" { return .keyboard }
        return nil
    }

    static func elementType(_ obj: NSObject) -> T {
        if let v = obj as? UIView {
            switch v {
            case let tf as UITextField: return tf.isSecureTextEntry ? .secureTextField : (v.superview is UISearchBar || NSStringFromClass(type(of: v)).contains("Search") ? .searchField : .textField)
            case is UITextView: return .textView
            case is UISwitch: return .switch
            case is UISlider: return .slider
            case is UIStepper: return .stepper
            case is UIPageControl: return .pageIndicator
            case is UIActivityIndicatorView: return .activityIndicator
            case is UIProgressView: return .progressIndicator
            case is UISegmentedControl: return .segmentedControl
            case is UIDatePicker: return .datePicker
            default: break
            }
        }
        let cls = NSStringFromClass(type(of: obj))
        if cls.contains("PickerTableView") || cls.contains("PickerColumn") { return .pickerWheel }
        // An iPad's floating tab bar: XCUITest on iPadOS sees each tab as a button.
        if cls.hasPrefix("_UIFloatingTabBarItem") { return .button }
        let t = obj.accessibilityTraits
        if #available(iOS 17.0, *), t.contains(.toggleButton) { return .switch }
        if t.contains(.keyboardKey) { return .key }
        if t.contains(.searchField) { return .searchField }
        // A button that also reads as a link is a button to XCUITest.
        if t.contains(.button) || t.contains(.tabBar) { return .button }
        if t.contains(.link) { return .link }
        if t.contains(.adjustable) { return .slider }
        if t.contains(.image) { return .image }
        if t.contains(.staticText) || t.contains(.header) { return .staticText }
        return .other
    }
}

/// XCUITest's hittability: the element's hit point is on screen, inside the
/// visible part of its scroll views, and nothing else takes the touch there.
enum Hit {
    static func isHittable(_ obj: NSObject, frame: CGRect, window: CGRect) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        let p = CGPoint(x: frame.midX, y: frame.midY)
        guard window.contains(p) else { return false }
        guard let view = Snapshotter.view(of: obj), let w = view.window else { return false }
        // Inside every enclosing scroll view's visible rect.
        var s: UIView? = view
        while let cur = s {
            if let sv = cur as? UIScrollView, sv !== view {
                let visible = sv.convert(sv.bounds, to: w)
                if !visible.contains(p) { return false }
            }
            s = cur.superview
        }
        guard let hit = w.hitTest(p, with: nil) else { return false }
        return hit === view || hit.isDescendant(of: view) || view.isDescendant(of: hit)
    }
}

// MARK: - Idle

/// XCUITest waits for the app to go idle before acting; so does simless:
/// until no layer animation is running (or the timeout, for endless loops).
enum Idle {
    @discardableResult
    static func wait(timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        // A flung list glides for up to ~3 s, and where it stops decides what
        // the next query sees, so a glide gets longer than other animations.
        let glideDeadline = deadline.addingTimeInterval(4)
        var quiet = 0
        while Date() < deadline || (gliding && Date() < glideDeadline) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.016))
            if animating() { quiet = 0 } else { quiet += 1 }
            if quiet >= 3 { return true }
        }
        return false
    }

    /// Whether the last check found a scroll view still gliding.
    private static var gliding = false
    /// Where each gliding scroll view was at the last check.
    private static var glideOffsets: [ObjectIdentifier: CGPoint] = [:]

    /// When each running animation was first seen, so one that outlives its
    /// own duration (paused, or stuck because nothing renders) stops counting.
    private static var firstSeen: [String: Date] = [:]
    static var lastBusy = ""

    private static func animating() -> Bool {
        var budget = 4000
        let now = Date()
        var current: [String: Date] = [:]
        var root = CALayer()
        var busy = false
        // Every layer is visited (no early exit) so each running animation's
        // first sighting is kept.
        func visit(_ layer: CALayer) {
            budget -= 1
            if budget < 0 { return }
            // Hidden and paused layers don't move on screen.
            if layer.isHidden || layer.opacity == 0 || layer.speed == 0 { return }
            // A refresh control that isn't refreshing only decorates a scroll's bounce.
            if let r = layer.delegate as? UIRefreshControl, !r.isRefreshing { return }
            if check(layer) { busy = true }
            layer.sublayers?.forEach(visit)
        }
        func check(_ layer: CALayer) -> Bool {
            var moving = false
            if let keys = layer.animationKeys(), !keys.isEmpty,
               // Nor do layers outside the window (a refresh control above a scrolled list).
               layer.convert(layer.bounds, to: root).intersects(root.bounds) {
                for k in keys {
                    guard let a = layer.animation(forKey: k) else { continue }
                    // Repeating animations (spinners, idle loops) never end; don't wait for them.
                    guard a.repeatCount < 1e6, a.duration < 10 else { continue }
                    let id = "\(ObjectIdentifier(layer).hashValue)|\(k)|\(a.beginTime)"
                    let seen = firstSeen[id] ?? now
                    current[id] = seen
                    // A spring's duration is when it's fully at rest; it looks settled well before.
                    let length = (a as? CASpringAnimation).map { min($0.duration, $0.settlingDuration, 1) } ?? a.duration
                    if now.timeIntervalSince(seen) < length * Double(max(1, a.repeatCount)) + 0.3 {
                        lastBusy = "\(type(of: (layer.delegate as AnyObject?) ?? layer)) \(k) \(type(of: a)) \(a.duration)"
                        moving = true
                    }
                }
            }
            return moving
        }
        for w in UIAutomation.appWindows { root = w.layer; visit(w.layer) }
        firstSeen = current
        gliding = false
        // A scroll view still gliding after a swipe: a touch now would only stop it.
        // Checked even while layers animate (its scroll indicator fades in).
        do {
            func glides(_ v: UIView, _ depth: Int) -> Bool {
                if let sv = v as? UIScrollView, sv.isDecelerating {
                    // The last points of a glide crawl for a second or more: a
                    // list moving under ~15 pt/s has under 8 pt left to go.
                    let id = ObjectIdentifier(sv), offset = sv.contentOffset
                    defer { glideOffsets[id] = offset }
                    if let last = glideOffsets[id], hypot(offset.x - last.x, offset.y - last.y) < 0.25 {
                        // Stopped where it is, the way a finger landing stops it
                        // (a touch on a scroll view that's still decelerating
                        // would only stop it, and do nothing else).
                        let stop = NSSelectorFromString("_stopScrollingAndZoomingAnimations")
                        if sv.responds(to: stop) { sv.perform(stop) }
                        if !sv.isDecelerating { return false }
                    }
                    lastBusy = "\(type(of: sv)) decelerating"
                    return true
                }
                return depth < 60 && v.subviews.contains { glides($0, depth + 1) }
            }
            if UIAutomation.appWindows.contains(where: { glides($0, 0) }) { Idle.gliding = true; return true }
        }
        // A presentation or dismissal in flight: the next one would be dropped.
        if !busy {
            for w in UIAutomation.appWindows {
                var vc = w.rootViewController
                while let cur = vc {
                    if cur.isBeingPresented || cur.isBeingDismissed || cur.transitionCoordinator != nil {
                        lastBusy = "\(type(of: cur)) transition"
                        return true
                    }
                    vc = cur.presentedViewController
                }
            }
        }
        return busy
    }
}

// MARK: - Input

/// Touches through touch.m, in key-window coordinates.
enum Input {
    /// Lets UIKit run while a touch is down. UIKit tracks touches in
    /// UITrackingRunLoopMode (a scroll view's delayed-touches timer fires there),
    /// so both modes get time.
    static func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        let tracking = RunLoop.Mode("UITrackingRunLoopMode")
        repeat {
            RunLoop.main.run(mode: tracking, before: Date().addingTimeInterval(0.004))
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.004))
        } while Date() < end
    }

    /// Why a touch didn't start: what UIKit threw, or a missing private method.
    static func touchFailure() -> String {
        simless_touch_error().map { "touch injection failed: \(String(cString: $0))" } ?? "touch injection isn't available"
    }

    static func tap(at point: CGPoint, duration: Double) -> String? {
        guard let window = UIAutomation.keyWindow else { return "no window" }
        let target = topWindow(at: point) ?? window
        guard simless_touch(target, point, 0) else { return touchFailure() }
        spin(max(duration, 0.02))
        _ = simless_touch(target, point, 3)
        spin(0.03)
        return nil
    }

    /// The stepper an element is part of (its Increment or Decrement), if any.
    static func stepper(containing part: NSObject, at point: CGPoint) -> NSObject? {
        var o: NSObject? = part.value(forKey: "accessibilityContainer") as? NSObject
        if let v = part as? UIView { o = v.superview }
        var hops = 0
        while let cur = o, hops < 4 {
            if cur is UIStepper || cur.accessibilityTraits.contains(.adjustable) && NSStringFromClass(type(of: cur)).contains("Stepper") { return cur }
            o = (cur as? UIView)?.superview ?? cur.value(forKey: "accessibilityContainer") as? NSObject
            hops += 1
        }
        return nil
    }

    /// The UIStepper behind a stepper element.
    static func stepperControl(_ obj: NSObject) -> UIStepper? {
        if let s = obj as? UIStepper { return s }
        guard let v = Snapshotter.view(of: obj) else { return nil }
        func find(_ v: UIView) -> UIStepper? {
            if let s = v as? UIStepper { return s }
            for c in v.subviews { if let s = find(c) { return s } }
            return nil
        }
        return find(v)
    }

    /// The editable text view or field under a point, if any.
    static func textInput(at point: CGPoint) -> UIView? {
        guard let w = topWindow(at: point) ?? UIAutomation.keyWindow else { return nil }
        var v = w.hitTest(w.convert(point, from: nil), with: nil)
        while let cur = v {
            if let tf = cur as? UITextField { return tf.isEnabled ? tf : nil }
            if let tv = cur as? UITextView { return tv.isEditable ? tv : nil }
            v = cur.superview
        }
        return nil
    }

    /// Elements that a tap activates rather than touches: SwiftUI's (not UIKit
    /// views or the elements UIKit vends for its own controls).
    static func activates(_ obj: NSObject) -> Bool {
        if obj is UIView { return false }
        let cls = NSStringFromClass(type(of: obj))
        if cls.hasPrefix("UI") || cls.hasPrefix("_UI") { return false }
        return true
    }

    /// The window that takes touches at a point: alerts and menus can live in their own windows.
    static func topWindow(at point: CGPoint) -> UIWindow? {
        if let w = Keyboard.accessoryWindow(at: point) { return w }
        return UIAutomation.appWindows.reversed().first { w in w.hitTest(w.convert(point, from: nil), with: nil) != nil && w.windowLevel.rawValue >= 0 }
    }

    /// A finger moving from `a` to `b` at `velocity` points a second, one move
    /// a frame (UIKit measures part of a swipe's speed by the clock). With a
    /// `release` speed the last stretch slows down to it, like a finger easing
    /// off before it lifts: a scroll view glides on from the speed at lift-off.
    static func drag(from a: CGPoint, to b: CGPoint, press: Double, velocity: Double, hold: Double, release: Double? = nil) -> String? {
        guard let window = topWindow(at: a) ?? UIAutomation.keyWindow else { return "no window" }
        let length = Double(hypot(b.x - a.x, b.y - a.y))
        let speed = max(velocity, 1)
        let slow = min(max(release ?? speed, 1), speed)
        let eased = slow < speed ? length * 0.2 : 0
        let fastPart = (length - eased) / speed
        // Where the finger is `t` seconds in.
        func travelled(_ t: Double) -> Double {
            t <= fastPart ? t * speed : min(length, length - eased + (t - fastPart) * slow)
        }
        let total = fastPart + eased / slow
        guard simless_touch(window, a, 0) else { return touchFailure() }
        spin(max(press, 0.016))
        func move(_ t: Double) {
            let f = CGFloat(length > 0 ? travelled(min(t, total)) / length : 1)
            _ = simless_touch(window, CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), 1)
            spin(0.016)
        }
        if release != nil {
            // A swipe goes by the clock: on a busy app UIKit gets one move per
            // frame it draws, like from a real finger, and the speed holds.
            let began = ProcessInfo.processInfo.systemUptime - 0.016
            var t = 0.0
            repeat { t = ProcessInfo.processInfo.systemUptime - began; move(t) } while t < total
        } else {
            // A drag is a fixed list of small moves, each handled before the
            // next. By the clock they came out fewer and larger on a busy app,
            // and a press-and-drag on a chart in a scroll view stopped selecting.
            let steps = max(2, Int(total / 0.016))
            for i in 1...steps { move(total * Double(i) / Double(steps)) }
        }
        if hold > 0 {
            _ = simless_touch(window, b, 2)
            spin(hold)
        }
        _ = simless_touch(window, b, 3)
        spin(0.03)
        return nil
    }

    /// XCUITest's swipe: a quick drag across half the element, in one direction.
    static func swipe(center: CGPoint, dx: Double, dy: Double, size: CGSize, velocity: Double) -> String? {
        let window = UIAutomation.keyWindow?.bounds ?? .zero
        let length = dx != 0 ? min(size.width, window.width) * 0.5 : min(size.height, window.height) * 0.5
        var start = center
        // Start inside the window.
        start.x = min(max(start.x, 10), window.width - 10)
        start.y = min(max(start.y, 10), window.height - 10)
        let end = CGPoint(x: start.x + CGFloat(dx) * length, y: start.y + CGFloat(dy) * length)
        // A swipe down at the top of a sheet dismisses it, like on an iPhone.
        if dy > 0, ShareSheet.swipeDown(at: start) || Presentations.dismissSheet(at: start) { return nil }
        // A finger eases off before it lifts, so the glide after a swipe
        // doesn't carry a list more than about a screen.
        return drag(from: CGPoint(x: start.x - CGFloat(dx) * 4, y: start.y - CGFloat(dy) * 4), to: end, press: 0,
                    velocity: velocity, hold: 0, release: velocity * 0.4)
    }
}

// MARK: - Scrolling, pickers

enum Scrolling {
    static func scrollToVisible(_ obj: NSObject) {
        guard let view = Snapshotter.view(of: obj), let window = view.window else { return }
        let frame = obj.accessibilityFrame
        let inWindow = window.convert(frame, from: nil)
        var s: UIView? = view
        while let cur = s {
            if let sv = cur as? UIScrollView, sv !== view {
                let r = sv.convert(inWindow, from: window).insetBy(dx: 0, dy: -20)
                sv.scrollRectToVisible(r, animated: false)
            }
            s = cur.superview
        }
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

enum Pickers {
    static func select(_ value: String, in obj: NSObject) -> String? {
        var v: UIView? = Snapshotter.view(of: obj)
        while let cur = v, !(cur is UIPickerView) { v = cur.superview }
        guard let picker = v as? UIPickerView, let ds = picker.dataSource else { return "not a picker wheel" }
        // Which wheel: the column containing the element.
        let elementFrame = obj.accessibilityFrame
        var component = 0
        for c in 0..<ds.numberOfComponents(in: picker) {
            if let row = picker.view(forRow: picker.selectedRow(inComponent: c), forComponent: c),
               row.accessibilityFrame.intersects(elementFrame) { component = c; break }
        }
        let rows = ds.pickerView(picker, numberOfRowsInComponent: component)
        for r in 0..<min(rows, 5000) {
            let title = picker.delegate?.pickerView?(picker, titleForRow: r, forComponent: component)
                ?? picker.delegate?.pickerView?(picker, attributedTitleForRow: r, forComponent: component)?.string
                ?? (picker.view(forRow: r, forComponent: component)?.accessibilityLabel)
            if title == value {
                picker.selectRow(r, inComponent: component, animated: false)
                picker.delegate?.pickerView?(picker, didSelectRow: r, inComponent: component)
                return nil
            }
        }
        return "no row \"\(value)\" in that wheel"
    }
}

// MARK: - Presentations

enum Presentations {
    /// Dismisses the topmost sheet if `point` is in its top part, the way a swipe down does on a phone.
    static func dismissSheet(at point: CGPoint) -> Bool {
        guard var top = UIAutomation.keyWindow?.rootViewController else { return false }
        while let p = top.presentedViewController { top = p }
        guard top.presentingViewController != nil, !top.isModalInPresentation,
              top.modalPresentationStyle != .fullScreen, top.modalPresentationStyle != .overFullScreen else { return false }
        let frame = top.view.convert(top.view.bounds, to: nil)
        // Only from the top of the sheet, or when its scroll view is already at the top.
        let scroll = firstScrollView(in: top.view)
        let atTop = scroll.map { $0.contentOffset.y <= -$0.adjustedContentInset.top + 1 } ?? true
        guard frame.contains(point), point.y < frame.minY + 120 || atTop else { return false }
        top.dismiss(animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return true
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let s = view as? UIScrollView { return s }
        for v in view.subviews { if let s = firstScrollView(in: v) { return s } }
        return nil
    }
}

enum Alerts {
    static func isActionSheet(_ obj: NSObject) -> Bool {
        var r: UIResponder? = obj as? UIResponder
        while let cur = r {
            if let a = cur as? UIAlertController { return a.preferredStyle == .actionSheet }
            r = cur.next
        }
        return false
    }
}

// MARK: - Keyboard

/// The Mac has no software keyboard. While a text input has focus, simless
/// shows one's footprint: keyboard notifications with an iPhone keyboard's
/// frame (so layouts move up), a keyboard element in the tree, and the input's
/// accessory view (keyboard toolbars) above it.
enum Keyboard {
    static var visible = false
    static var accessoryView: UIView?
    static var accessoryWindow: UIWindow?

    static func isEmulatedKeyboard(_ w: UIWindow) -> Bool { w === accessoryWindow }

    /// Whether an element belongs to the keyboard toolbar simless shows.
    static func contains(_ obj: NSObject) -> Bool {
        guard let a = accessoryView else { return false }
        var v: UIView? = Snapshotter.view(of: obj)
        while let cur = v { if cur === a { return true }; v = cur.superview }
        return false
    }

    static var height: CGFloat { Session.canvas.w < 600 ? (Session.landscape ? 209 : 336) : 398 }

    static func frame() -> CGRect {
        let c = Session.canvas
        return CGRect(x: 0, y: c.h - Double(height), width: c.w, height: Double(height))
    }

    static func install() {
        NotificationCenter.default.addObserver(forName: UITextField.textDidBeginEditingNotification, object: nil, queue: .main) { n in show(for: n.object as? UIView) }
        NotificationCenter.default.addObserver(forName: UITextView.textDidBeginEditingNotification, object: nil, queue: .main) { n in show(for: n.object as? UIView) }
        NotificationCenter.default.addObserver(forName: UITextField.textDidEndEditingNotification, object: nil, queue: .main) { _ in hideIfNoFocus() }
        NotificationCenter.default.addObserver(forName: UITextView.textDidEndEditingNotification, object: nil, queue: .main) { _ in hideIfNoFocus() }
    }

    static func node() -> [String: Any]? {
        guard visible else { return nil }
        let f = frame()
        return ["type": Snapshotter.T.keyboard.rawValue, "frame": [f.minX, f.minY, f.width, f.height], "enabled": true, "hittable": true]
    }

    private static func show(for input: UIView?) {
        let f = frame()
        let wasVisible = visible
        visible = true
        let info: [AnyHashable: Any] = [
            UIResponder.keyboardFrameBeginUserInfoKey: NSValue(cgRect: wasVisible ? f : f.offsetBy(dx: 0, dy: f.height)),
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: f),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0.25,
            UIResponder.keyboardAnimationCurveUserInfoKey: 7,
            UIResponder.keyboardIsLocalUserInfoKey: true,
        ]
        if !wasVisible { NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil, userInfo: info) }
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil, userInfo: info)
        if !wasVisible { NotificationCenter.default.post(name: UIResponder.keyboardDidShowNotification, object: nil, userInfo: info) }
        NotificationCenter.default.post(name: UIResponder.keyboardDidChangeFrameNotification, object: nil, userInfo: info)
        // Keep the content above the keyboard, as the keyboard layout guide would.
        if let root = UIAutomation.keyWindow?.rootViewController {
            let base = root.view.safeAreaInsets.bottom - root.additionalSafeAreaInsets.bottom
            root.additionalSafeAreaInsets.bottom = max(0, height - base)
        }
        showAccessory(for: input)
    }

    private static func showAccessory(for input: UIView?) {
        accessoryWindow?.isHidden = true
        accessoryWindow = nil
        accessoryView = nil
        // An empty accessory (SwiftUI attaches one to every text view) isn't shown.
        guard let accessory = findAccessory(input), !accessory.subviews.isEmpty else { return }
        accessoryView = accessory
        placeAccessory()
    }

    /// UIKit hosts a keyboard toolbar in its text effects window, at the
    /// bottom of the screen on the Mac (there's no keyboard under it). simless
    /// moves its host up to sit on the emulated keyboard. If UIKit doesn't host
    /// it, simless does, in a window of its own.
    static func placeAccessory() {
        guard visible, let a = accessoryView else { return }
        let h = max(44, a.bounds.height > 0 ? a.bounds.height : a.systemLayoutSizeFitting(CGSize(width: Session.canvas.w, height: 0)).height)
        let top = frame().minY - h
        if let w = a.window, w !== accessoryWindow {
            accessoryWindow?.isHidden = true
            accessoryWindow = nil
            guard let host = a.superview else { return }
            let y = a.convert(a.bounds, to: w).minY
            if abs(y - top) > 0.5 { host.frame.origin.y += top - y }
            return
        }
        if let bar = a.superview, a.window === accessoryWindow {
            // SwiftUI moves it within its superview.
            if a.frame != bar.bounds { a.frame = bar.bounds }
            return
        }
        if a.window == nil, let scene = UIAutomation.keyWindow?.windowScene {
            // No view controller in it: UIKit's input system owns the
            // accessory's controller and would refuse another parent for it.
            let w = PassThroughWindow(windowScene: scene)
            w.windowLevel = .normal + 1
            w.isHidden = false
            // SwiftUI's accessory keeps itself at the bottom of its superview,
            // so it gets one exactly the bar's size.
            let bar = UIView(frame: CGRect(x: 0, y: top, width: Session.canvas.w, height: h))
            w.addSubview(bar)
            bar.addSubview(a)
            a.frame = bar.bounds
            a.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            accessoryWindow = w
        }
    }

    /// The window holding the keyboard toolbar, if `point` is on it.
    static func accessoryWindow(at point: CGPoint) -> UIWindow? {
        guard visible, let a = accessoryView, let w = a.window else { return nil }
        return a.convert(a.bounds, to: nil).contains(point) ? w : nil
    }

    final class PassThroughWindow: UIWindow {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let v = super.hitTest(point, with: event)
            return v === self ? nil : v
        }
    }

    /// SwiftUI attaches a keyboard toolbar a moment after the field takes focus.
    static func refreshAccessory() {
        guard visible else { return }
        if accessoryView != nil { placeAccessory(); return }
        guard let input = firstResponder() as? UIView, findAccessory(input)?.subviews.isEmpty == false else { return }
        showAccessory(for: input)
    }

    private static func findAccessory(_ input: UIView?) -> UIView? {
        var r: UIResponder? = input
        while let cur = r {
            if let a = cur.inputAccessoryView { return a }
            r = cur.next
        }
        return nil
    }

    private static func hideIfNoFocus() {
        DispatchQueue.main.async {
            guard firstResponder() == nil, visible else { return }
            let f = frame()
            visible = false
            let info: [AnyHashable: Any] = [
                UIResponder.keyboardFrameBeginUserInfoKey: NSValue(cgRect: f),
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: f.offsetBy(dx: 0, dy: f.height)),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.25,
            ]
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil, userInfo: info)
            NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil, userInfo: info)
            if let root = UIAutomation.keyWindow?.rootViewController { root.additionalSafeAreaInsets.bottom = 0 }
            Session.applyCanvas()
            accessoryWindow?.isHidden = true
            accessoryWindow = nil
            accessoryView = nil
        }
    }

    static func firstResponder() -> UIResponder? {
        for w in UIAutomation.appWindows {
            if let r = w.value(forKey: "firstResponder") as? UIResponder, r !== w { return r }
        }
        return nil
    }

    /// Types into whatever has keyboard focus: "\n" is the return key, U+0008 delete.
    static func type(_ text: String) -> String? {
        guard let r = firstResponder() as? UIKeyInput else { return "no element has keyboard focus" }
        for ch in text {
            switch ch {
            case "\u{8}": r.deleteBackward()
            case "\n", "\r": r.insertText("\n")
            default: r.insertText(String(ch))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return nil
    }
}

// MARK: - Lifecycle, URLs

enum Lifecycle {
    static var foregrounded = true

    static func background() {
        foregrounded = false
        let nc = NotificationCenter.default
        for scene in UIApplication.shared.connectedScenes {
            nc.post(name: UIScene.willDeactivateNotification, object: scene)
            nc.post(name: UIScene.didEnterBackgroundNotification, object: scene)
        }
        nc.post(name: UIApplication.willResignActiveNotification, object: UIApplication.shared)
        nc.post(name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
    }

    static func foreground() {
        foregrounded = true
        let nc = NotificationCenter.default
        nc.post(name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)
        for scene in UIApplication.shared.connectedScenes {
            nc.post(name: UIScene.willEnterForegroundNotification, object: scene)
            nc.post(name: UIScene.didActivateNotification, object: scene)
        }
        nc.post(name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared)
    }

    /// A URL for this app: handed to its scene the way iOS would (SwiftUI's onOpenURL sees it).
    static func open(_ url: URL) -> String? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let delegate = scene.delegate,
              delegate.responds(to: #selector(UISceneDelegate.scene(_:openURLContexts:))),
              let cls = NSClassFromString("UIOpenURLContext") as? NSObject.Type else {
            return "the app's scene can't open URLs"
        }
        let context = cls.init()
        context.setValue(url, forKey: "URL")
        if let optionsClass = NSClassFromString("UISceneOpenURLOptions") as? NSObject.Type {
            context.setValue(optionsClass.init(), forKey: "options")
        }
        delegate.scene?(scene, openURLContexts: [context as! UIOpenURLContext])
        return nil
    }
}

/// Links to the web don't leave the app (there's no Safari to switch to on a
/// headless host): they're recorded, and tests can ask whether one opened.
enum ExternalURLs {
    static var opened: [String] = []

    static func install() {
        let sel = NSSelectorFromString("openURL:options:completionHandler:")
        guard let m = class_getInstanceMethod(UIApplication.self, sel) else { return }
        let old = method_getImplementation(m)
        typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        let call = unsafeBitCast(old, to: Open.self)
        let block: @convention(block) (AnyObject, NSURL, NSDictionary, AnyObject?) -> Void = { app, url, options, completion in
            let scheme = (url.scheme ?? "").lowercased()
            typealias Done = @convention(block) (Bool) -> Void
            if noHandler.contains(scheme) {
                if let completion { unsafeBitCast(completion, to: Done.self)(false) }
                return
            }
            if scheme == "http" || scheme == "https" || scheme.hasPrefix("x-apple") {
                opened.append(url.absoluteString ?? "")
                if let completion { unsafeBitCast(completion, to: Done.self)(true) }
                return
            }
            call(app, sel, url, options, completion)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))

        // The Mac has Mail, Messages and FaceTime, an iPhone simulator doesn't:
        // the app sees what it sees in the simulator (and shows its fallback).
        let canSel = NSSelectorFromString("canOpenURL:")
        if let cm = class_getInstanceMethod(UIApplication.self, canSel) {
            typealias Can = @convention(c) (AnyObject, Selector, NSURL) -> Bool
            let canCall = unsafeBitCast(method_getImplementation(cm), to: Can.self)
            let canBlock: @convention(block) (AnyObject, NSURL) -> Bool = { app, url in
                noHandler.contains((url.scheme ?? "").lowercased()) ? false : canCall(app, canSel, url)
            }
            method_setImplementation(cm, imp_implementationWithBlock(canBlock))
        }
    }

    private static let noHandler: Set<String> = ["mailto", "tel", "telprompt", "sms", "facetime", "facetime-audio", "message"]
}

// MARK: - Screenshots

enum Screenshots {
    static func take(rect: CGRect?) -> [String: Any] {
        guard let w = UIAutomation.keyWindow else { return ["ok": false, "error": "no window"] }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let full = UIGraphicsImageRenderer(bounds: w.bounds, format: format).image { ctx in
            for window in UIAutomation.appWindows {
                window.drawHierarchy(in: window.frame, afterScreenUpdates: true)
            }
            if Keyboard.visible {
                UIColor(white: 0.82, alpha: 1).setFill()
                ctx.fill(Keyboard.frame())
                if let a = Keyboard.accessoryView, a.window != nil {
                    a.drawHierarchy(in: a.convert(a.bounds, to: nil), afterScreenUpdates: true)
                }
            }
        }
        var image = full
        if let rect, rect.width > 0, rect.height > 0,
           let cg = full.cgImage?.cropping(to: CGRect(x: rect.minX * 2, y: rect.minY * 2, width: rect.width * 2, height: rect.height * 2)) {
            image = UIImage(cgImage: cg, scale: 2, orientation: .up)
        }
        return ["ok": true, "png": image.pngData()?.base64EncodedString() ?? ""]
    }
}
