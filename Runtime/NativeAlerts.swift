// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation
import UIKit
import ObjectiveC

/// An iOS app on the Mac shows alerts (UIAlertController, SwiftUI .alert) as
/// native AppKit alert panels: real windows, outside the app's UIKit tree. In a
/// UI test host the runtime intercepts them instead: nothing is shown, the
/// alert appears in the accessibility tree as an iPhone-style alert, and
/// tapping one of its buttons ends it with that button, as a person would.
enum NativeAlerts {
    final class Pending {
        let alert: NSObject
        let completion: ((Int) -> Void)?
        init(alert: NSObject, completion: ((Int) -> Void)?) { self.alert = alert; self.completion = completion }
        var title: String { alert.value(forKey: "messageText") as? String ?? "" }
        var message: String { alert.value(forKey: "informativeText") as? String ?? "" }
        var buttons: [String] { ((alert.value(forKey: "buttons") as? [NSObject]) ?? []).map { $0.value(forKey: "title") as? String ?? "" } }
    }

    /// A button of an intercepted alert, as an element the tree can point at.
    final class Button: NSObject {
        let pending: Pending, index: Int
        init(_ pending: Pending, _ index: Int) { self.pending = pending; self.index = index }
        func press() { NativeAlerts.finish(pending, button: index) }
    }

    static var pending: [Pending] = []

    static func install() {
        guard let cls = NSClassFromString("NSAlert") else { return }
        let sheetSel = NSSelectorFromString("beginSheetModalForWindow:completionHandler:")
        if let m = class_getInstanceMethod(cls, sheetSel) {
            // Typed as a block so Swift copies it: AppKit can pass a stack block.
            let block: @convention(block) (NSObject, AnyObject?, (@convention(block) (Int) -> Void)?) -> Void = { alert, _, handler in
                pending.append(Pending(alert: alert, completion: handler.map { done in { done($0) } }))
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        // A modal alert would block the app; answer it with its first button.
        let modalSel = NSSelectorFromString("runModal")
        if let m = class_getInstanceMethod(cls, modalSel) {
            let block: @convention(block) (NSObject) -> Int = { _ in 1000 }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }

    /// A button ends the alert with its tag, which is what AppKit returns for
    /// a pressed button (UIKit tags them with the index of their action).
    static func finish(_ p: Pending, button index: Int) {
        pending.removeAll { $0 === p }
        let buttons = (p.alert.value(forKey: "buttons") as? [NSObject]) ?? []
        p.completion?(index < buttons.count ? (buttons[index].value(forKey: "tag") as? Int ?? 1000 + index) : 1000 + index)
        // UIKit dismisses the alert controller after this; until it's gone a new
        // presentation (the next alert) would be dropped.
        let end = Date().addingTimeInterval(1)
        while alertPresented() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private static func alertPresented() -> Bool {
        for w in UIAutomation.appWindows {
            var vc = w.rootViewController
            while let cur = vc {
                if cur is UIAlertController { return true }
                vc = cur.presentedViewController
            }
        }
        return false
    }

    /// Nodes for the snapshot: an alert with its texts and buttons, centered like on an iPhone.
    static func nodes(addRef: (NSObject) -> Int) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let c = Session.canvas
        for p in pending {
            let buttons = p.buttons
            let width = 270.0
            let textHeight = 44.0 + (p.message.isEmpty ? 0 : 40)
            let height = textHeight + Double(buttons.count) * 44
            let x = (c.w - width) / 2, y = (c.h - height) / 2
            let alertIndex = out.count
            out.append(["ref": addRef(p.alert), "parent": -1, "type": 7, "label": p.title, "id": p.title,
                        "frame": [x, y, width, height], "enabled": true, "hittable": true])
            out.append(["ref": addRef(p.alert), "parent": alertIndex, "type": 48, "label": p.title,
                        "frame": [x + 16, y + 12, width - 32, 22], "enabled": true, "hittable": true])
            if !p.message.isEmpty {
                out.append(["ref": addRef(p.alert), "parent": alertIndex, "type": 48, "label": p.message,
                            "frame": [x + 16, y + 40, width - 32, 36], "enabled": true, "hittable": true])
            }
            for (i, title) in buttons.enumerated() {
                out.append(["ref": addRef(Button(p, i)), "parent": alertIndex, "type": 9, "label": title, "id": title,
                            "frame": [x, y + textHeight + Double(i) * 44, width, 44], "enabled": true, "hittable": true])
            }
        }
        return out
    }

    /// A tap at a point on an intercepted alert's button presses it.
    static func button(at point: CGPoint) -> Button? {
        var refs: [NSObject] = []
        let nodes = self.nodes { refs.append($0); return refs.count - 1 }
        for n in nodes where n["type"] as? Int == 9 {
            let f = n["frame"] as? [Double] ?? [0, 0, 0, 0]
            if CGRect(x: f[0], y: f[1], width: f[2], height: f[3]).contains(point), let b = refs[n["ref"] as? Int ?? 0] as? Button { return b }
        }
        return nil
    }
}
