// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation
import UIKit

/// Compact date pickers, as on an iPhone. On the Mac a compact UIDatePicker is
/// a row of AppKit-like text fields. In a UI test host it shows the way an
/// iPhone does: a button carrying the date or time as its value, and for a
/// time, a tap opens hour and minute wheels (and AM/PM on a 12 hour clock)
/// that adjust(toPickerWheelValue:) turns. A tap anywhere else closes them.
enum DatePickers {
    enum Part { case date, time }

    final class Button: NSObject {
        weak var picker: UIDatePicker?
        let part: Part
        init(_ picker: UIDatePicker, _ part: Part) { self.picker = picker; self.part = part }
    }

    enum Component { case hour, minute, period }

    final class Wheel: NSObject {
        weak var picker: UIDatePicker?
        let component: Component
        init(_ picker: UIDatePicker, _ component: Component) { self.picker = picker; self.component = component }
    }

    private static var buttons: [ObjectIdentifier: [Button]] = [:]
    static var open: (picker: UIDatePicker, wheels: [Wheel])?

    static func isCompact(_ picker: UIDatePicker) -> Bool {
        picker.datePickerStyle != .wheels && picker.datePickerStyle != .inline && picker.datePickerMode != .countDownTimer
    }

    /// The buttons a compact picker shows: a date, a time, or both.
    static func buttons(for picker: UIDatePicker) -> [Button] {
        let id = ObjectIdentifier(picker)
        if let b = buttons[id], b.first?.picker === picker { return b }
        let parts: [Part] = switch picker.datePickerMode {
        case .time: [.time]
        case .date, .yearAndMonth: [.date]
        default: [.date, .time]
        }
        let b = parts.map { Button(picker, $0) }
        buttons[id] = b
        return b
    }

    private static func locale(_ p: UIDatePicker) -> Locale { p.locale ?? .current }

    static func uses12Hours(_ p: UIDatePicker) -> Bool {
        (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale(p)) ?? "").contains("a")
    }

    static func text(_ b: Button) -> String {
        guard let p = b.picker else { return "" }
        let f = DateFormatter()
        f.locale = locale(p)
        f.calendar = p.calendar
        f.timeZone = p.timeZone ?? .current
        f.dateStyle = b.part == .date ? .medium : .none
        f.timeStyle = b.part == .time ? .short : .none
        return f.string(from: p.date)
    }

    // MARK: Wheels

    static func titles(_ w: Wheel) -> [String] {
        guard let p = w.picker else { return [] }
        switch w.component {
        case .hour: return uses12Hours(p) ? (1...12).map(String.init) : (0...23).map { String(format: "%02d", $0) }
        case .minute: return stride(from: 0, to: 60, by: max(1, p.minuteInterval)).map { String(format: "%02d", $0) }
        case .period:
            let f = DateFormatter()
            f.locale = locale(p)
            return [f.amSymbol, f.pmSymbol]
        }
    }

    static func value(_ w: Wheel) -> String {
        guard let p = w.picker else { return "" }
        let c = p.calendar.dateComponents(in: p.timeZone ?? .current, from: p.date)
        let hour = c.hour ?? 0, minute = c.minute ?? 0
        let t = titles(w)
        switch w.component {
        case .hour: return uses12Hours(p) ? t[(hour + 11) % 12] : t[hour]
        case .minute: return String(format: "%02d", minute)
        case .period: return t[hour < 12 ? 0 : 1]
        }
    }

    /// Turns a wheel to the row titled `value`, as a person would, and tells the app.
    static func select(_ value: String, in w: Wheel) -> String? {
        guard let p = w.picker else { return "the picker is gone" }
        let t = titles(w)
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let row = t.firstIndex(of: trimmed) ?? t.firstIndex(where: { Int($0) != nil && Int($0) == Int(trimmed) }) else {
            return "no row \"\(value)\" in that wheel (\(t.prefix(3).joined(separator: ", ")), ...)"
        }
        var c = p.calendar.dateComponents(in: p.timeZone ?? .current, from: p.date)
        let hour = c.hour ?? 0
        switch w.component {
        case .hour: c.hour = uses12Hours(p) ? (row + 1) % 12 + (hour >= 12 ? 12 : 0) : row
        case .minute: c.minute = Int(t[row]) ?? 0
        case .period: c.hour = hour % 12 + (row == 1 ? 12 : 0)
        }
        guard let date = p.calendar.date(from: c) else { return "not a valid time" }
        p.setDate(date, animated: false)
        p.sendActions(for: .valueChanged)
        return nil
    }

    // MARK: Opening and closing

    static func tap(_ b: Button) {
        guard let p = b.picker, b.part == .time else { return }
        var wheels = [Wheel(p, .hour), Wheel(p, .minute)]
        if uses12Hours(p) { wheels.append(Wheel(p, .period)) }
        open = (p, wheels)
    }

    /// A tap while the wheels are open closes them (and goes no further).
    static func tapOutside(at point: CGPoint) -> Bool {
        guard open != nil, let f = frames(), !f.popover.contains(point) else { return false }
        open = nil
        return true
    }

    private static func frames() -> (popover: CGRect, wheels: [CGRect])? {
        guard let open, let p = Optional(open.picker), p.window != nil else { return nil }
        let anchor = p.convert(p.bounds, to: nil)
        let c = Session.canvas
        // CGFloat throughout: Xcode 26's Swift finds mixed Double and CGFloat arithmetic ambiguous.
        let width: CGFloat = 320, height: CGFloat = 216
        let x: CGFloat = min(max(8, anchor.midX - width / 2), CGFloat(c.w) - width - 8)
        var y: CGFloat = anchor.maxY + 8
        if y + height > CGFloat(c.h - c.bottom) { y = max(CGFloat(c.top), anchor.minY - 8 - height) }
        let w: CGFloat = width / CGFloat(open.wheels.count)
        let wheelY: CGFloat = y + height / 2 - 17
        return (CGRect(x: x, y: y, width: width, height: height),
                open.wheels.indices.map { CGRect(x: x + CGFloat($0) * w, y: wheelY, width: w, height: 34) })
    }

    static func nodes(addRef: (NSObject) -> Int) -> [[String: Any]] {
        guard let open, let f = frames() else { return [] }
        var out: [[String: Any]] = [["ref": addRef(NSObject()), "parent": -1, "type": 18,
                                     "frame": [f.popover.minX, f.popover.minY, f.popover.width, f.popover.height], "enabled": true, "hittable": true]]
        let picker: [String: Any] = ["ref": addRef(open.picker), "parent": 0, "type": 51,
                                     "frame": [f.popover.minX, f.popover.minY, f.popover.width, f.popover.height], "enabled": true, "hittable": true]
        out.append(picker)
        for (i, w) in open.wheels.enumerated() {
            let r = f.wheels[i]
            out.append(["ref": addRef(w), "parent": 1, "type": 39, "value": value(w),
                        "frame": [r.minX, r.minY, r.width, r.height], "enabled": true, "hittable": true])
        }
        return out
    }
}
