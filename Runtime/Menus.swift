// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation
import UIKit
import ObjectiveC

/// Context menus (a long press) and button menus (SwiftUI Menu, menu-style
/// Pickers). On the Mac UIKit would show them as native AppKit menus, which
/// track modally. In a UI test host the runtime asks the view for its menu
/// instead, shows its items in the accessibility tree like an iPhone's menu,
/// and runs an item's handler when it's tapped.
enum Menus {
    final class Item: NSObject {
        let element: UIMenuElement
        let title: String
        let identifier: String
        let destructive: Bool
        init(_ element: UIMenuElement) {
            self.element = element
            title = element.title
            identifier = (element as NSObject).value(forKey: "accessibilityIdentifier") as? String ?? ""
            destructive = (element as? UIAction)?.attributes.contains(.destructive) ?? false
        }

        func perform(sender: AnyObject?) {
            if let action = element as? UIAction {
                let sel = NSSelectorFromString("performWithSender:target:")
                if action.responds(to: sel) {
                    typealias Perform = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
                    unsafeBitCast(action.method(for: sel), to: Perform.self)(action, sel, sender, nil)
                } else if let handler = (action as NSObject).value(forKey: "handler") {
                    typealias Handler = @convention(block) (UIAction) -> Void
                    unsafeBitCast(handler as AnyObject, to: Handler.self)(action)
                }
            } else if let command = element as? UICommand {
                UIApplication.shared.sendAction(command.action, to: nil, from: sender, for: nil)
            }
        }
    }

    static var open: (items: [Item], anchor: CGRect, sender: AnyObject?)?

    /// The context menu of the view under `point`, if it has one.
    static func openContextMenu(at point: CGPoint) -> Bool {
        guard let window = UIAutomation.keyWindow, var view = window.hitTest(point, with: nil) as UIView? else { return false }
        while true {
            for case let interaction as UIContextMenuInteraction in view.interactions {
                let location = view.convert(point, from: window)
                guard let delegate = interaction.delegate,
                      let config = delegate.contextMenuInteraction(interaction, configurationForMenuAtLocation: location) else { continue }
                if let menu = menu(from: config) {
                    show(menu, anchor: CGRect(origin: point, size: .zero), sender: view)
                    return true
                }
            }
            guard let next = view.superview else { return false }
            view = next
        }
    }

    /// A button whose tap shows a menu (UIButton.menu shown as its primary action).
    static func openButtonMenu(_ obj: NSObject, at point: CGPoint) -> Bool {
        for start in [UIAutomation.keyWindow?.hitTest(point, with: nil), Snapshotter.view(of: obj)] {
            if let start, openButtonMenu(from: start, at: point) { return true }
        }
        return false
    }

    private static func openButtonMenu(from start: UIView, at point: CGPoint) -> Bool {
        var v: UIView? = start
        while let cur = v {
            if let c = cur as? UIControl, c.showsMenuAsPrimaryAction {
                let interaction = c.interactions.compactMap { $0 as? UIContextMenuInteraction }.first
                let config = interaction.flatMap { i in i.delegate?.contextMenuInteraction(i, configurationForMenuAtLocation: c.convert(point, from: nil)) }
                // SwiftUI fills a Menu's items when UIKit says the menu is about to show.
                if c.allControlEvents.contains(.menuActionTriggered) { c.sendActions(for: .menuActionTriggered) }
                if let interaction, let config { notify(c, "contextMenuInteraction:willDisplayMenuForConfiguration:animator:", interaction, config) }
                if let menu = (c as? UIButton)?.menu.flatMap({ $0.children.isEmpty ? nil : $0 }) ?? config.flatMap(menu(from:)) {
                    show(menu, anchor: c.convert(c.bounds, to: nil), sender: c)
                    if let interaction, let config { ending = (c, interaction, config) }
                    return true
                }
            }
            v = cur.superview
        }
        return false
    }

    /// The control whose menu is open, told when it closes (SwiftUI tracks it).
    private static var ending: (UIControl, UIContextMenuInteraction, UIContextMenuConfiguration)?

    private static func notify(_ target: NSObject, _ selector: String, _ interaction: UIContextMenuInteraction, _ config: UIContextMenuConfiguration) {
        let sel = NSSelectorFromString(selector)
        guard target.responds(to: sel) else { return }
        typealias F = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject?) -> Void
        unsafeBitCast(target.method(for: sel), to: F.self)(target, sel, interaction, config, nil)
    }

    private static func menu(from config: UIContextMenuConfiguration) -> UIMenu? {
        guard let provider = (config as NSObject).value(forKey: "actionProvider") else { return nil }
        typealias Provider = @convention(block) ([UIMenuElement]) -> UIMenu?
        return unsafeBitCast(provider as AnyObject, to: Provider.self)([])
    }

    static func show(_ menu: UIMenu, anchor: CGRect, sender: AnyObject?) {
        var items: [Item] = []
        debug = menu.children.map { "\(type(of: $0)) \($0.title)" }
        func flatten(_ m: UIMenu) {
            for child in m.children {
                if let sub = child as? UIMenu { flatten(sub) } else { items.append(Item(child)) }
            }
        }
        flatten(menu)
        open = (items, anchor, sender)
    }

    static func close() {
        open = nil
        if let (c, i, config) = ending {
            ending = nil
            notify(c, "contextMenuInteraction:willEndForConfiguration:animator:", i, config)
        }
    }
    static var debug: [String] = []

    /// Frames like an iPhone's menu: 250 pt wide, 44 pt rows, under the anchor if it fits.
    static func frames() -> (menu: CGRect, items: [CGRect])? {
        guard let open else { return nil }
        let c = Session.canvas
        let height = Double(open.items.count) * 44
        let x = min(max(16, open.anchor.minX), c.w - 266)
        var y = open.anchor.maxY + 8
        if y + height > c.h - c.bottom { y = max(c.top, open.anchor.minY - 8 - height) }
        return (CGRect(x: x, y: y, width: 250, height: height),
                open.items.indices.map { CGRect(x: x, y: y + Double($0) * 44, width: 250, height: 44) })
    }

    static func nodes(addRef: (NSObject) -> Int) -> [[String: Any]] {
        guard let open, let f = frames() else { return [] }
        var out: [[String: Any]] = [["ref": addRef(NSObject()), "parent": -1, "type": 32,   // a collection view, like iOS menus
                                     "frame": [f.menu.minX, f.menu.minY, f.menu.width, f.menu.height], "enabled": true, "hittable": true]]
        for (i, item) in open.items.enumerated() {
            let r = f.items[i]
            var n: [String: Any] = ["ref": addRef(item), "parent": 0, "type": 9, "label": item.title,
                                    "frame": [r.minX, r.minY, r.width, r.height], "enabled": true, "hittable": true]
            if !item.identifier.isEmpty { n["id"] = item.identifier }
            out.append(n)
        }
        return out
    }

    /// A tap while a menu is open: an item runs and closes it; anywhere else just closes it.
    static func tap(at point: CGPoint, ref: NSObject?) -> Bool {
        guard let open, let f = frames() else { return false }
        if let item = ref as? Item {
            close(); item.perform(sender: open.sender); return true
        }
        if let i = f.items.firstIndex(where: { $0.contains(point) }) {
            close(); open.items[i].perform(sender: open.sender); return true
        }
        close()
        return true
    }
}
