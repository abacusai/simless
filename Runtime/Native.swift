// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

// Native hosts (SIMLESS_NATIVE=1): the app's iOS build, retagged for Mac
// Catalyst and started directly by simless, outside the app sandbox. This
// gives the app what a "Designed for iPad" install had, so it behaves the same:
// - it reports itself as an iOS app on a Mac (apps and SimlessKit branch on it);
// - preference suites stay under the slot's id, like the standard domain does,
//   so slots of one app never share them (they'd live in ~/Library/Preferences);
// - a keychain of its own, kept in its home (native.c routes SecItem calls here).
// The home folder itself is CFFIXED_USER_HOME, and tmp and caches native.c.

import Foundation
import Security
import ObjectiveC

enum NativeHost {
    static var enabled = false

    static func install() {
        enabled = true
        reportiOSAppOnMac()
        scopePreferenceSuites()
        Keychain.shared.load()
        suppressMacMenus()
    }

    /// A Mac Catalyst app shows UIKit's edit and context menus as AppKit menus,
    /// whose tracking loop holds the main thread until someone clicks (a
    /// "Designed for iPad" app shows them in its own window). A headless host
    /// has nobody to click: a UI test stalled 60 s in one. The runtime shows
    /// iPhone menus itself (Menus.swift), so AppKit's never pop up.
    private static func suppressMacMenus() {
        func replace(_ cls: AnyClass?, _ name: String, classMethod: Bool = false, _ block: Any) {
            guard let cls else { return }
            let sel = NSSelectorFromString(name)
            guard let m = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel) else { return }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        let uikitMenus: @convention(block) (AnyObject, AnyObject?, AnyObject?, CGPoint, AnyObject?) -> Void = { _, _, _, _, _ in }
        replace(NSClassFromString("UINSMenuController"), "showContextMenu:inWindow:atLocationInWindow:activityItemsConfiguration:", uikitMenus)
        let positioned: @convention(block) (AnyObject, AnyObject?, CGPoint, AnyObject?) -> Bool = { _, _, _, _ in false }
        replace(NSClassFromString("NSMenu"), "popUpMenuPositioningItem:atLocation:inView:", positioned)
        let context: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Void = { _, _, _, _ in }
        replace(NSClassFromString("NSMenu"), "popUpContextMenu:withEvent:forView:", classMethod: true, context)
        let contextFont: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Void = { _, _, _, _, _ in }
        replace(NSClassFromString("NSMenu"), "popUpContextMenu:withEvent:forView:withFont:", classMethod: true, contextFont)
    }

    /// `ProcessInfo.isiOSAppOnMac` is true for a "Designed for iPad" app and
    /// false for Mac Catalyst. The app was built as an iOS app; it keeps
    /// seeing itself as one.
    private static func reportiOSAppOnMac() {
        // The shared instance is a private subclass with its own implementation:
        // replace it in every class from that one up.
        let sel = NSSelectorFromString("isiOSAppOnMac")
        let block: @convention(block) (AnyObject) -> Bool = { _ in true }
        let imp = imp_implementationWithBlock(block)
        var cls: AnyClass? = object_getClass(ProcessInfo.processInfo)
        while let c = cls {
            if let m = class_getInstanceMethod(c, sel), class_getMethodImplementation(c, sel) != imp {
                if !class_addMethod(c, sel, imp, method_getTypeEncoding(m)) { method_setImplementation(m, imp) }
            }
            cls = class_getSuperclass(c)
        }
    }

    /// `UserDefaults(suiteName:)` names a domain in ~/Library/Preferences, shared
    /// by every slot (and the user's own apps). Suites become the slot's:
    /// "group.app" -> "<slot id>.suite.group.app"; the app's original id is its
    /// standard domain, which already is the slot's id.
    private static func scopePreferenceSuites() {
        guard let slot = ProcessInfo.processInfo.environment["SIMLESS_SLOT_ID"], !slot.isEmpty else { return }
        let original = ProcessInfo.processInfo.environment["SIMLESS_ORIGINAL_BUNDLE_ID"] ?? ""
        let sel = NSSelectorFromString("initWithSuiteName:")
        guard let m = class_getInstanceMethod(UserDefaults.self, sel) else { return }
        typealias Init = @convention(c) (AnyObject, Selector, NSString?) -> AnyObject?
        let call = unsafeBitCast(method_getImplementation(m), to: Init.self)
        let block: @convention(block) (AnyObject, NSString?) -> AnyObject? = { obj, name in
            guard let name = name as String?, !name.isEmpty, name != slot, !name.hasPrefix(slot + "."),
                  name != "NSGlobalDomain" else { return call(obj, sel, name as NSString?) }
            let scoped = name == original ? slot : "\(slot).suite.\(name)"
            return call(obj, sel, scoped as NSString)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }
}

// MARK: - Keychain

@_cdecl("simless_keychain_enabled")
func simlessKeychainEnabled() -> Int32 { NativeHost.enabled ? 1 : 0 }

@_cdecl("simless_keychain_add")
func simlessKeychainAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> OSStatus {
    Keychain.shared.add(attributes as NSDictionary as? [String: Any] ?? [:], result)
}

@_cdecl("simless_keychain_copy")
func simlessKeychainCopy(_ query: CFDictionary, _ result: UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> OSStatus {
    Keychain.shared.copy(query as NSDictionary as? [String: Any] ?? [:], result)
}

@_cdecl("simless_keychain_update")
func simlessKeychainUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    Keychain.shared.update(query as NSDictionary as? [String: Any] ?? [:], attributes as NSDictionary as? [String: Any] ?? [:])
}

@_cdecl("simless_keychain_delete")
func simlessKeychainDelete(_ query: CFDictionary) -> OSStatus {
    Keychain.shared.delete(query as NSDictionary as? [String: Any] ?? [:])
}

/// Generic and internet passwords (what apps keep tokens in), with the
/// SecItem semantics apps rely on: duplicates by primary key, match limits,
/// returning data, attributes or both. Kept in the slot's home, so a wiped
/// slot starts with an empty keychain like a fresh install.
final class Keychain: @unchecked Sendable {
    static let shared = Keychain()
    private let lock = NSLock()
    private var items: [[String: Any]] = []
    private var path: String { NSHomeDirectory() + "/Library/Keychains/simless-keychain.plist" }

    private static let valueData = kSecValueData as String
    private static let itemClass = kSecClass as String
    /// The attributes that make two items the same item, per class.
    private static let primaryKeys: [String: [String]] = [
        kSecClassGenericPassword as String: [kSecAttrAccount, kSecAttrService].map { $0 as String },
        kSecClassInternetPassword as String: [kSecAttrAccount, kSecAttrServer, kSecAttrProtocol, kSecAttrPort,
                                              kSecAttrPath, kSecAttrSecurityDomain, kSecAttrAuthenticationType].map { $0 as String },
    ]

    func load() {
        lock.lock(); defer { lock.unlock() }
        guard let d = FileManager.default.contents(atPath: path),
              let list = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [[String: Any]] else { return }
        items = list
    }

    private func save() {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let d = try? PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0) {
            try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// Query keys that steer a call rather than name an attribute to match.
    private static func isControl(_ key: String) -> Bool {
        key.hasPrefix("r_") || key.hasPrefix("m_") || key.hasPrefix("u_") || key.hasPrefix("v_")
            || key == kSecAttrSynchronizable as String || key == kSecAttrAccessible as String
            || key == kSecAttrAccessGroup as String || key == kSecAttrAccessControl as String
            || key == kSecUseDataProtectionKeychain as String
    }

    private static func storable(_ v: Any) -> Bool {
        v is NSString || v is NSData || v is NSNumber || v is NSDate
    }

    private static func matches(_ item: [String: Any], _ query: [String: Any]) -> Bool {
        for (k, v) in query where !isControl(k) {
            guard let mine = item[k] as? NSObject, let wanted = v as? NSObject, mine.isEqual(wanted) else { return false }
        }
        return true
    }

    private func supported(_ query: [String: Any]) -> Bool {
        guard let cls = query[Self.itemClass] as? String else { return false }
        return Self.primaryKeys[cls] != nil
    }

    func add(_ attributes: [String: Any], _ result: UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> OSStatus {
        guard supported(attributes) else { return errSecUnimplemented }
        lock.lock(); defer { lock.unlock() }
        let cls = attributes[Self.itemClass] as! String
        var item: [String: Any] = [:]
        for (k, v) in attributes where (!Self.isControl(k) || k == Self.valueData) && Self.storable(v) { item[k] = v }
        let key = Self.primaryKeys[cls] ?? []
        let duplicate = items.contains { other in
            other[Self.itemClass] as? String == cls && key.allSatisfy { k in
                (other[k] as? NSObject)?.isEqual(item[k] as? NSObject) ?? (item[k] == nil)
            }
        }
        if duplicate { return errSecDuplicateItem }
        item[kSecAttrCreationDate as String] = Date()
        item[kSecAttrModificationDate as String] = Date()
        items.append(item)
        save()
        if let result { result.pointee = Self.output([item], attributes).map { Unmanaged.passRetained($0) } }
        return errSecSuccess
    }

    func copy(_ query: [String: Any], _ result: UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> OSStatus {
        guard supported(query) else { return errSecUnimplemented }
        if query[kSecReturnRef as String] as? Bool == true || query[kSecReturnPersistentRef as String] as? Bool == true {
            return errSecUnimplemented
        }
        lock.lock(); defer { lock.unlock() }
        var found = items.filter { Self.matches($0, query) }
        guard !found.isEmpty else { return errSecItemNotFound }
        let limit = query[kSecMatchLimit as String]
        let all = (limit as? String) == (kSecMatchLimitAll as String) || ((limit as? Int) ?? 1) > 1
        if let n = limit as? Int, n > 1 { found = Array(found.prefix(n)) }
        else if !all { found = Array(found.prefix(1)) }
        if let result {
            result.pointee = Self.output(found, query, array: all).map { Unmanaged.passRetained($0) }
        }
        return errSecSuccess
    }

    func update(_ query: [String: Any], _ changes: [String: Any]) -> OSStatus {
        guard supported(query) else { return errSecUnimplemented }
        lock.lock(); defer { lock.unlock() }
        var hit = false
        for i in items.indices where Self.matches(items[i], query) {
            for (k, v) in changes where (!Self.isControl(k) || k == Self.valueData) && Self.storable(v) { items[i][k] = v }
            items[i][kSecAttrModificationDate as String] = Date()
            hit = true
        }
        guard hit else { return errSecItemNotFound }
        save()
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        guard supported(query) else { return errSecUnimplemented }
        lock.lock(); defer { lock.unlock() }
        let before = items.count
        items.removeAll { Self.matches($0, query) }
        guard items.count < before else { return errSecItemNotFound }
        save()
        return errSecSuccess
    }

    /// What a call returns, as its kSecReturn* keys ask: data, attributes
    /// (with the data when both are asked for), one item or an array.
    private static func output(_ found: [[String: Any]], _ query: [String: Any], array: Bool = false) -> CFTypeRef? {
        let wantsData = query[kSecReturnData as String] as? Bool == true
        let wantsAttributes = query[kSecReturnAttributes as String] as? Bool == true
        guard wantsData || wantsAttributes else { return nil }
        let values: [Any] = found.map { item in
            if wantsAttributes {
                var d = item.filter { $0.key != valueData }
                if wantsData { d[valueData] = item[valueData] ?? Data() }
                return d as NSDictionary
            }
            return (item[valueData] as? Data ?? Data()) as NSData
        }
        if array || values.count > 1 { return values as NSArray }
        return values.first as CFTypeRef?
    }
}
