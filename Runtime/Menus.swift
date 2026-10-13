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
        /// A submenu: on an iPhone it's a row that opens its own items.
        var submenu: UIMenu? { element as? UIMenu }
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
    /// What the open menu's rows are to XCUITest: buttons, or an edit menu's menu items.
    private static var itemType = 9

    /// A long press in a text field shows the edit menu (Select, Select All,
    /// Paste), like on an iPhone. AppKit would only show its own context menu.
    static func openEditMenu(at point: CGPoint) -> Bool {
        guard let window = UIAutomation.keyWindow, var view = window.hitTest(point, with: nil) as UIView? else { return false }
        while !(view is UITextField || view is UITextView) {
            guard let next = view.superview else { return false }
            view = next
        }
        if let tv = view as? UITextView, !tv.isEditable { return false }
        if !view.isFirstResponder { view.becomeFirstResponder() }
        guard let input = view as? (UIView & UITextInput) else { return false }
        var actions: [UIAction] = []
        let hasText = !(input.text(in: input.textRange(from: input.beginningOfDocument, to: input.endOfDocument) ?? UITextRange()) ?? "").isEmpty
        if hasText {
            actions.append(UIAction(title: "Select") { _ in
                if let range = input.tokenizer.rangeEnclosingPosition(input.selectedTextRange?.start ?? input.endOfDocument, with: .word, inDirection: .storage(.backward)) {
                    input.selectedTextRange = range
                }
            })
            actions.append(UIAction(title: "Select All") { _ in input.selectAll(nil) })
        }
        if UIPasteboard.general.hasStrings {
            actions.append(UIAction(title: "Paste") { _ in input.paste(nil) })
        }
        guard !actions.isEmpty else { return false }
        show(UIMenu(children: actions), anchor: view.convert(view.bounds, to: nil), sender: view)
        itemType = 54   // menuItem
        return true
    }

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
        unsafeBitCast(target.method(for: sel), to: F.self)(target, sel, interaction, config, Animator())
    }

    /// The menu's show or hide animation, already done: SwiftUI waits for its
    /// completion before it acts on a choice (a dialog the choice raises, say).
    final class Animator: NSObject, UIContextMenuInteractionAnimating {
        var previewViewController: UIViewController? { nil }
        func addAnimations(_ animations: @escaping () -> Void) { animations() }
        func addCompletion(_ completion: @escaping () -> Void) {
            RunLoop.main.perform(inModes: [.common], block: completion)
        }
    }

    private static func menu(from config: UIContextMenuConfiguration) -> UIMenu? {
        guard let provider = (config as NSObject).value(forKey: "actionProvider") else { return nil }
        typealias Provider = @convention(block) ([UIMenuElement]) -> UIMenu?
        return unsafeBitCast(provider as AnyObject, to: Provider.self)([])
    }

    static func show(_ menu: UIMenu, anchor: CGRect, sender: AnyObject?) {
        var items: [Item] = []
        func flatten(_ m: UIMenu) {
            for child in m.children {
                // Inline menus are sections of this one; the rest are rows that open.
                if let sub = child as? UIMenu, sub.options.contains(.displayInline) || sub.title.isEmpty { flatten(sub) } else { items.append(Item(child)) }
            }
        }
        flatten(menu)
        open = (items, anchor, sender)
        itemType = 9
    }

    static func close() {
        open = nil
        if let (c, i, config) = ending {
            ending = nil
            notify(c, "contextMenuInteraction:willEndForConfiguration:animator:", i, config)
        }
    }

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
            var n: [String: Any] = ["ref": addRef(item), "parent": 0, "type": itemType, "label": item.title,
                                    "frame": [r.minX, r.minY, r.width, r.height], "enabled": true, "hittable": true]
            if !item.identifier.isEmpty { n["id"] = item.identifier }
            out.append(n)
        }
        return out
    }

    /// A tap while a menu is open: an item runs and closes it, a submenu opens
    /// in its place, anywhere else just closes it.
    static func tap(at point: CGPoint, ref: NSObject?) -> Bool {
        guard let open, let f = frames() else { return false }
        guard let item = (ref as? Item) ?? f.items.firstIndex(where: { $0.contains(point) }).map({ open.items[$0] }) else {
            close()
            return true
        }
        if let submenu = item.submenu {
            show(submenu, anchor: open.anchor, sender: open.sender)
        } else {
            close()
            item.perform(sender: open.sender)
        }
        return true
    }
}
