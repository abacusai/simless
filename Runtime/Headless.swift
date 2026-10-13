// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation
import ObjectiveC
import MachO

/// Keeps a UI test host invisible without SIMLESS_HEADLESS: that variable tells
/// the app it's a render host (apps skip analytics and sync on it), while a UI
/// test needs the app's real launch, as XCUITest gives it. Window ordering is
/// made a no-op as soon as AppKit loads, before the first window exists.
enum Headless {
    private static var done = false

    static func install() {
        _dyld_register_func_for_add_image { _, _ in Headless.tryInstall() }
        DispatchQueue.main.async { tryInstall(); hide() }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("UIWindowDidBecomeVisibleNotification"), object: nil, queue: .main) { _ in hide() }
    }

    static func tryInstall() {
        guard !done, NSClassFromString("NSWindow") != nil else { return }
        done = true
        let noOp1: @convention(block) (AnyObject) -> Void = { _ in }
        let noOpSender: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in }
        let noOpOrder: @convention(block) (AnyObject, Int, Int) -> Void = { _, _, _ in }
        let replacements: [(String, AnyObject)] = [
            ("orderWindow:relativeTo:", unsafeBitCast(noOpOrder, to: AnyObject.self)),
            ("orderFront:", unsafeBitCast(noOpSender, to: AnyObject.self)),
            ("makeKeyAndOrderFront:", unsafeBitCast(noOpSender, to: AnyObject.self)),
            ("orderFrontRegardless", unsafeBitCast(noOp1, to: AnyObject.self)),
        ]
        for name in ["NSWindow", "UINSWindow"] {
            guard let cls = NSClassFromString(name) else { continue }
            for (sel, block) in replacements {
                if let m = class_getInstanceMethod(cls, NSSelectorFromString(sel)) {
                    method_setImplementation(m, imp_implementationWithBlock(block))
                }
            }
        }
    }

    /// No Dock icon, never active, windows transparent and click-through.
    static func hide() {
        guard let cls = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = cls.value(forKey: "sharedApplication") as? NSObject else { return }
        let setPolicy = NSSelectorFromString("setActivationPolicy:")
        typealias PolicyFn = @convention(c) (AnyObject, Selector, Int) -> Bool
        _ = unsafeBitCast(app.method(for: setPolicy), to: PolicyFn.self)(app, setPolicy, 2)
        app.perform(NSSelectorFromString("hide:"), with: nil)
        typealias FloatFn = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        typealias BoolFn = @convention(c) (AnyObject, Selector, Bool) -> Void
        let alpha = NSSelectorFromString("setAlphaValue:"), ignore = NSSelectorFromString("setIgnoresMouseEvents:")
        for w in (app.value(forKey: "windows") as? [NSObject]) ?? [] {
            unsafeBitCast(w.method(for: alpha), to: FloatFn.self)(w, alpha, 0)
            unsafeBitCast(w.method(for: ignore), to: BoolFn.self)(w, ignore, true)
        }
    }
}

/// The slot can't hold app-group entitlements: group containers resolve to a
/// private folder per group inside the slot's own container (as SimlessKit
/// does for render and unit-test hosts).
enum AppGroups {
    static func redirect() {
        let sel = NSSelectorFromString("containerURLForSecurityApplicationGroupIdentifier:")
        guard let m = class_getInstanceMethod(FileManager.self, sel) else { return }
        let block: @convention(block) (AnyObject, NSString) -> NSURL? = { _, group in
            let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/SimlessAppGroups/\(group)")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url as NSURL
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }
}

/// UIDevice's model as the device being stood in for ("iPhone" on a phone
/// canvas): an iOS app on the Mac reports "iPad".
enum DeviceModel {
    static func apply(_ model: String) {
        for name in ["model", "localizedModel"] {
            guard let m = class_getInstanceMethod(NSClassFromString("UIDevice"), NSSelectorFromString(name)) else { continue }
            let block: @convention(block) (AnyObject) -> NSString = { _ in model as NSString }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        // The device's idiom too (apps word things by it). The trait collection's
        // idiom is left alone: SwiftUI picks control styles from it.
        // Only in UI test hosts: under the phone idiom SwiftUI's Stepper and form
        // controls can overflow the stack on the Mac, which a render host or a
        // unit test host shouldn't risk for a screen that doesn't need it.
        if model == "iPhone", ProcessInfo.processInfo.environment["SIMLESS_UI"] == "1",
           let m = class_getInstanceMethod(NSClassFromString("UIDevice"), NSSelectorFromString("userInterfaceIdiom")) {
            let block: @convention(block) (AnyObject) -> Int = { _ in 0 }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }

    /// An iPhone (and its simulator) supports a watch session, the Mac
    /// doesn't: in a UI test host, apps that show watch features only where a
    /// watch can pair see what they see on an iPhone. Nothing pairs, so
    /// isPaired stays false. (Not in test hosts: a session there never
    /// finishes activating, and tests waiting on it would hang.)
    static func watchSupported() {
        guard let cls = NSClassFromString("WCSession"), let m = class_getClassMethod(cls, NSSelectorFromString("isSupported")) else { return }
        let block: @convention(block) (AnyObject) -> Bool = { _ in true }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }
}
