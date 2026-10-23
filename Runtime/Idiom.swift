// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation
import ObjectiveC
import UIKit

/// The idiom on the Mac. An iOS app there takes it from the screen, and simless
/// asks for the phone idiom on a render's hosting controller only (SimlessKit),
/// so two things break that a device never sees:
/// - A window with no scene (the render window) has the screen's idiom, and on
///   some Macs the screen reports none: then every List traps in UIKit
///   ("unknown user interface idiom (UIUserInterfaceIdiom(rawValue: -1))").
///   Windows in render and unit test hosts get the device's idiom outright.
/// - SwiftUI hands a NavigationStack inside a sheet the screen's traits as an
///   override, iPad idiom included, under a phone-idiom parent, and UIKit
///   throws ("Cannot override interface idiom to UIUserInterfaceIdiomPad when
///   original interface idiom is UIUserInterfaceIdiomPhone"). A child keeps its
///   parent's idiom instead.
enum Idiom {
    static func install(windows: Bool) {
        guard ProcessInfo.processInfo.isiOSAppOnMac else { return }
        keepParentIdiom()
        guard windows else { return }
        let device = UIDevice.current.userInterfaceIdiom
        let idiom: UIUserInterfaceIdiom = device == .unspecified ? .pad : device
        NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let w = note.object as? UIWindow, !w.traitOverrides.contains(UITraitUserInterfaceIdiom.self) else { return }
                w.traitOverrides.userInterfaceIdiom = idiom
            }
        }
    }

    private static func keepParentIdiom() {
        let sel = NSSelectorFromString("setOverrideTraitCollection:forChildViewController:")
        guard let m = class_getInstanceMethod(UIViewController.self, sel) else { return }
        typealias Fn = @convention(c) (UIViewController, Selector, UITraitCollection?, UIViewController) -> Void
        let original = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (UIViewController, UITraitCollection?, UIViewController) -> Void = { parent, traits, child in
            var traits = traits
            let wanted = traits?.userInterfaceIdiom ?? .unspecified, own = parent.traitCollection.userInterfaceIdiom
            if wanted != .unspecified, own != .unspecified, wanted != own {
                traits = traits?.modifyingTraits { $0.userInterfaceIdiom = own }
            }
            original(parent, sel, traits, child)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }
}
