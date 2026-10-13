// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation
import UIKit

/// The share sheet. On the Mac UIActivityViewController hands off to AppKit's
/// sharing picker, which a UI test host never shows. While one is presented,
/// simless shows an iPhone-like sheet in the tree (ActivityListView, with a
/// Close button). Close or a swipe down dismisses it as a cancel: the
/// controller's completion handler gets (nil, false). Sharing to a target
/// isn't emulated.
enum ShareSheet {
    final class Close: NSObject {}
    private static let close = Close()

    static func presented() -> UIActivityViewController? {
        func find(_ vc: UIViewController?) -> UIActivityViewController? {
            guard let vc else { return nil }
            if let a = vc as? UIActivityViewController, !a.isBeingDismissed { return a }
            for child in vc.children { if let a = find(child) { return a } }
            return find(vc.presentedViewController)
        }
        for w in UIAutomation.appWindows { if let a = find(w.rootViewController) { return a } }
        return nil
    }

    private static func frame() -> CGRect {
        let c = Session.canvas
        return CGRect(x: 0, y: c.h * 0.45, width: c.w, height: c.h * 0.55)
    }

    private static func closeFrame() -> CGRect {
        let f = frame()
        return CGRect(x: f.maxX - 16 - 30, y: f.minY + 16, width: 30, height: 30)
    }

    static func nodes(addRef: (NSObject) -> Int) -> [[String: Any]] {
        guard presented() != nil else { return [] }
        let f = frame(), b = closeFrame()
        return [
            ["ref": addRef(NSObject()), "parent": -1, "type": 1, "id": "ActivityListView",
             "frame": [f.minX, f.minY, f.width, f.height], "enabled": true, "hittable": true],
            ["ref": addRef(close), "parent": 0, "type": 9, "id": "header.closeButton", "label": "Close",
             "frame": [b.minX, b.minY, b.width, b.height], "enabled": true, "hittable": true],
        ]
    }

    /// A tap on Close, or a swipe down from inside the sheet.
    static func tap(at point: CGPoint, ref: NSObject?) -> Bool {
        guard presented() != nil, ref === close || closeFrame().insetBy(dx: -8, dy: -8).contains(point) else { return false }
        dismiss()
        return true
    }

    static func swipeDown(at point: CGPoint) -> Bool {
        guard presented() != nil, frame().contains(point) else { return false }
        dismiss()
        return true
    }

    private static func dismiss() {
        guard let a = presented() else { return }
        let handler = a.completionWithItemsHandler
        // The sheet holding it (SwiftUI wraps it in one) goes with it.
        var top: UIViewController = a
        while let parent = top.parent { top = parent }
        (top.presentingViewController ?? top).dismiss(animated: true) {
            handler?(nil, false, nil, nil)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }
}
