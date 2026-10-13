// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation
import UIKit
import ObjectiveC

/// `performAccessibilityAudit` for simless UI tests. Xcode's audit runs in a
/// system service simless can't reach, so these are simless's own checks with
/// the same audit types:
/// - hitRegion: interactive elements smaller than 24×24 pt;
/// - sufficientElementDescription: interactive elements and images without a label;
/// - dynamicType: text whose frame doesn't grow between the default text size
///   and the current accessibility size (the screen is laid out at both);
/// - textClipped: text that needs more lines than its frame holds, measured
///   with the text-style font whose line height fits the frame;
/// - contrast: the two dominant colors inside a text element's frame, below
///   4.5:1 (3:1 for large text).
/// elementDetection and trait aren't checked.
enum Audit {
    static let contrast: UInt64 = 1 << 0, hitRegion: UInt64 = 1 << 2, description: UInt64 = 1 << 3
    static let dynamicType: UInt64 = 1 << 16, textClipped: UInt64 = 1 << 17

    static func run(types: UInt64) -> [[String: Any]] {
        let (nodes, _) = Snapshotter.take()
        var issues: [[String: Any]] = []
        func issue(_ type: UInt64, _ index: Int, _ compact: String, _ detailed: String) {
            issues.append(["type": Int(truncatingIfNeeded: type), "node": index, "compact": compact, "detailed": detailed])
        }
        let interactive: Set<Int> = [9, 40, 42, 33, 45, 49, 50, 79]   // button, switch, link, slider, search, text fields, stepper
        let textTypes: Set<Int> = [48, 9, 42]
        let window = UIAutomation.keyWindow?.bounds ?? .zero

        func frame(_ n: [String: Any]) -> CGRect {
            let f = n["frame"] as? [Double] ?? [0, 0, 0, 0]
            return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
        }
        func visible(_ n: [String: Any]) -> Bool { frame(n).intersects(window) && (n["hittable"] as? Bool ?? false || (n["type"] as? Int) == 48) }

        // UIKit's own pieces (a sheet's grabber, a navigation bar's back chevron)
        // are the system's, Xcode's audit doesn't report them either.
        func system(_ n: [String: Any]) -> Bool {
            guard let o = (n["ref"] as? Int).flatMap(Snapshotter.object(ref:)) else { return false }
            return NSStringFromClass(type(of: o)).hasPrefix("_UI")
        }
        for (i, n) in nodes.enumerated() where visible(n) && !system(n) {
            let type = n["type"] as? Int ?? 1
            let label = (n["label"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let f = frame(n)
            if types & hitRegion != 0, interactive.contains(type), f.width < 24 || f.height < 24 {
                issue(hitRegion, i, "Hit region is too small", "The element's hit region is \(Int(f.width))×\(Int(f.height)) pt, smaller than 24×24 pt.")
            }
            if types & description != 0, (interactive.contains(type) || type == 43), label.isEmpty, (n["id"] as? String ?? "").isEmpty || type != 43 {
                if type != 49 && type != 50 {
                    issue(description, i, "Element has no description", "The element has no accessibility label.")
                }
            }
        }

        if types & textClipped != 0 {
            TextFit.image = contrastImage(scale: 2)
            defer { TextFit.image = nil }
            for (i, n) in nodes.enumerated() where visible(n) && textTypes.contains(n["type"] as? Int ?? 0) {
                let label = n["label"] as? String ?? ""
                if !label.isEmpty, TextFit.isClipped(label, in: frame(n)) {
                    issue(textClipped, i, "Text clipped", "\"\(label)\" doesn't fit its frame (\(Int(frame(n).width))×\(Int(frame(n).height)) pt).")
                }
            }
        }

        if types & dynamicType != 0, let current = ContentSize.category ?? UIAutomation.keyWindow?.traitCollection.preferredContentSizeCategory,
           current.isAccessibilityCategory {
            for i in DynamicTypeCheck.unscaled(nodes: nodes, current: current) where visible(nodes[i]) {
                issue(dynamicType, i, "Dynamic Type font sizes are unsupported",
                      "\"\(nodes[i]["label"] as? String ?? "")\" stays the same size at \(current.rawValue) as at the default size.")
            }
        }

        if types & contrast != 0, let image = contrastImage() {
            for (i, n) in nodes.enumerated() where visible(n) && (n["type"] as? Int) == 48 {
                if let ratio = Contrast.ratio(in: image, rect: frame(n)), ratio < (frame(n).height >= 30 ? 3 : 4.5) {
                    issue(contrast, i, "Contrast failed", String(format: "Text contrast %.1f:1 is below the minimum.", ratio))
                }
            }
        }
        return issues
    }

    private static func contrastImage(scale: CGFloat = 1) -> CGImage? {
        guard let w = UIAutomation.keyWindow else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(bounds: w.bounds, format: format).image { _ in
            w.drawHierarchy(in: w.bounds, afterScreenUpdates: false)
        }.cgImage
    }
}

/// Whether text was truncated: SwiftUI and UIKit end truncated text with an
/// ellipsis, so the element's drawn pixels are read (Vision) and checked for
/// one. Text that obviously fits is skipped without reading it.
enum TextFit {
    static var image: CGImage?

    static func isClipped(_ text: String, in frame: CGRect) -> Bool {
        guard frame.width > 8, frame.height > 8, text.count > 3, let image else { return false }
        // Room for the text at a generous glyph width: clearly fits, skip the read.
        let lineHeight = min(frame.height, 30)
        let lines = max(1, (frame.height / max(lineHeight, 12)).rounded(.down))
        let capacity = (frame.width / (lineHeight * 0.6)) * lines
        if CGFloat(text.count) < capacity * 0.6 { return false }
        let scale = CGFloat(image.width) / max(1, UIAutomation.keyWindow?.bounds.width ?? CGFloat(image.width))
        let r = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
            .insetBy(dx: -2 * scale, dy: -1 * scale).integral
        guard let crop = image.cropping(to: r) else { return false }
        let read = OCR.text(crop)
        let trimmed = read.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("…") || trimmed.hasSuffix("...") || trimmed.hasSuffix("..")
            && !text.trimmingCharacters(in: .whitespaces).hasSuffix("..")
    }
}

/// Vision text recognition, loaded on first use.
enum OCR {
    static func text(_ image: CGImage) -> String {
        guard let requestClass = NSClassFromString("VNRecognizeTextRequest") as? NSObject.Type
                ?? (dlopen("/System/Library/Frameworks/Vision.framework/Vision", RTLD_NOW) != nil
                    ? NSClassFromString("VNRecognizeTextRequest") as? NSObject.Type : nil),
              let handlerClass = NSClassFromString("VNImageRequestHandler") as? NSObject.Type else { return "" }
        let request = requestClass.init()
        request.setValue(1, forKey: "recognitionLevel")        // fast
        request.setValue(false, forKey: "usesLanguageCorrection")
        typealias InitHandler = @convention(c) (AnyObject, Selector, CGImage, NSDictionary) -> AnyObject
        let sel = NSSelectorFromString("initWithCGImage:options:")
        guard let alloc = handlerClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let m = class_getInstanceMethod(handlerClass, sel) else { return "" }
        let handler = unsafeBitCast(method_getImplementation(m), to: InitHandler.self)(alloc, sel, image, [:]) as! NSObject
        typealias Perform = @convention(c) (AnyObject, Selector, NSArray, UnsafeMutablePointer<NSError?>?) -> Bool
        let psel = NSSelectorFromString("performRequests:error:")
        guard let pm = class_getInstanceMethod(handlerClass, psel) else { return "" }
        _ = unsafeBitCast(method_getImplementation(pm), to: Perform.self)(handler, psel, [request], nil)
        let results = (request.value(forKey: "results") as? [NSObject]) ?? []
        return results.compactMap { obs -> String? in
            guard let candidates = obs.perform(NSSelectorFromString("topCandidates:"), with: 1)?.takeUnretainedValue() as? [NSObject] else { return nil }
            return candidates.first?.value(forKey: "string") as? String
        }.joined(separator: " ")
    }
}

/// Text that doesn't grow at accessibility sizes: the screen is laid out at
/// the default size, and text elements whose height doesn't change are flagged.
enum DynamicTypeCheck {
    static func unscaled(nodes: [[String: Any]], current: UIContentSizeCategory) -> [Int] {
        guard let scene = UIAutomation.keyWindow?.windowScene else { return [] }
        let key: ([String: Any]) -> String = { "\($0["label"] as? String ?? "")|\($0["id"] as? String ?? "")" }
        // Width and height together: text in an element with a fixed height
        // (beside a sticker, say) still grows sideways.
        func extent(_ n: [String: Any]) -> Double? { (n["frame"] as? [Double]).map { $0[2] * 10_000 + $0[3] } }
        var heights: [String: Double] = [:]
        for n in nodes where (n["type"] as? Int) == 48 { heights[key(n)] = extent(n) }
        func layout(_ size: UIContentSizeCategory) -> [String: Double] {
            scene.traitOverrides.preferredContentSizeCategory = size
            for w in scene.windows { w.layoutIfNeeded() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            var out: [String: Double] = [:]
            for n in Snapshotter.take().0 where (n["type"] as? Int) == 48 { out[key(n)] = extent(n) }
            return out
        }
        // Text that's the same height at the default size and the current one
        // may only be clamped at the top (dynamicTypeSize(...)): it's flagged
        // only if it doesn't change at the smallest size either.
        let atDefault = layout(.large)
        let atSmallest = layout(.extraSmall)
        scene.traitOverrides.preferredContentSizeCategory = current
        for w in scene.windows { w.layoutIfNeeded() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        // Nothing on screen moved: the new size didn't reach this screen (a
        // presentation that keeps its own traits), so there's nothing to judge.
        if !atDefault.contains(where: { k, h in heights[k].map { abs($0 - h) >= 0.5 } ?? false }) { return [] }
        var unchanged = Set<String>()
        for (k, h) in atDefault where h > 0 {
            if let big = heights[k], abs(big - h) < 0.5, let s = atSmallest[k], abs(s - h) < 0.5 { unchanged.insert(k) }
        }
        // Indices refer to a fresh snapshot taken by the caller afterwards (same layout as before).
        _ = Snapshotter.take()
        return nodes.indices.filter { (nodes[$0]["type"] as? Int) == 48 && unchanged.contains(key(nodes[$0])) }
    }
}

/// WCAG contrast between the two most common colors in a rect.
enum Contrast {
    static func ratio(in image: CGImage, rect: CGRect) -> Double? {
        let r = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard r.width >= 4, r.height >= 4, let crop = image.cropping(to: r),
              let data = crop.dataProvider?.data as Data?, crop.bitsPerPixel == 32 else { return nil }
        var counts: [UInt32: Int] = [:]
        let bpr = crop.bytesPerRow
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for y in stride(from: 0, to: crop.height, by: 1) {
                for x in stride(from: 0, to: crop.width, by: 1) {
                    let o = y * bpr + x * 4
                    // Quantize a little so anti-aliasing doesn't split one color into many.
                    let key = (UInt32(p[o] >> 3) << 16) | (UInt32(p[o + 1] >> 3) << 8) | UInt32(p[o + 2] >> 3)
                    counts[key, default: 0] += 1
                }
            }
        }
        let top = counts.sorted { $0.value > $1.value }
        guard top.count >= 2, top[1].value > (Int(r.width * r.height) / 50) else { return nil }
        func lum(_ k: UInt32) -> Double {
            let c = [(k >> 16) & 0xff, (k >> 8) & 0xff, k & 0xff].map { Double($0 << 3) / 255 }
            let l = c.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * l[2] + 0.7152 * l[1] + 0.0722 * l[0]   // BGRA
        }
        let a = lum(top[0].key), b = lum(top[1].key)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
