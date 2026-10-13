// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import Foundation
import ObjectiveC
import MachO

/// A host is a real Mac app, so a permission request (calendar, camera,
/// microphone, speech, notifications, photos, contacts, location, tracking)
/// or a review request would put macOS's own dialog on the user's screen.
/// In every simless host the runtime answers instead: permission requests are
/// denied at once, without asking macOS, and review requests do nothing.
/// (Granting isn't possible: the app's next access would make macOS ask.)
enum Permissions {
    private static var done = Set<String>()

    static func install() {
        _dyld_register_func_for_add_image { _, _ in Permissions.tryInstall() }
        tryInstall()
    }

    /// Frameworks load late, so this runs again as images are added.
    static func tryInstall() {
        typealias BoolError = @convention(block) (Bool, NSError?) -> Void
        typealias BoolOnly = @convention(block) (Bool) -> Void
        typealias Status = @convention(block) (Int) -> Void
        let later = DispatchQueue.global()

        // Instance methods whose completion takes (granted, error).
        for (cls, sel) in [("EKEventStore", "requestFullAccessToEventsWithCompletion:"),
                           ("EKEventStore", "requestWriteOnlyAccessToEventsWithCompletion:"),
                           ("EKEventStore", "requestFullAccessToRemindersWithCompletion:"),
                           ("UNUserNotificationCenter", "requestAuthorizationWithOptions:completionHandler:"),
                           ("CNContactStore", "requestAccessForEntityType:completionHandler:"),
                           ("EKEventStore", "requestAccessToEntityType:completion:")] {
            // Options and entity types are integers, not objects.
            let argument: Argument = sel.hasPrefix("requestAuthorizationWithOptions") || sel.hasPrefix("requestAccessFor") || sel.hasPrefix("requestAccessTo") ? .integer : .none
            replace(cls, sel, classMethod: false, argument: argument) { completion in
                guard let completion else { return }
                let done = unsafeBitCast(completion, to: BoolError.self)
                later.async { done(false, nil) }
            }
        }
        // Class methods whose completion takes (granted).
        for (cls, sel) in [("AVCaptureDevice", "requestAccessForMediaType:completionHandler:"),
                           ("AVAudioApplication", "requestRecordPermissionWithCompletionHandler:")] {
            replace(cls, sel, classMethod: true, argument: sel.contains("MediaType") ? .object : .none) { completion in
                guard let completion else { return }
                let done = unsafeBitCast(completion, to: BoolOnly.self)
                later.async { done(false) }
            }
        }
        replace("AVAudioSession", "requestRecordPermission:", classMethod: false, argument: .none) { completion in
            guard let completion else { return }
            let done = unsafeBitCast(completion, to: BoolOnly.self)
            later.async { done(false) }
        }
        // Class methods whose completion takes a status: denied.
        for (cls, sel, denied) in [("SFSpeechRecognizer", "requestAuthorization:", 1),
                                   ("PHPhotoLibrary", "requestAuthorization:", 2),
                                   ("PHPhotoLibrary", "requestAuthorizationForAccessLevel:handler:", 2),
                                   ("ATTrackingManager", "requestTrackingAuthorizationWithCompletionHandler:", 2),
                                   ("MPMediaLibrary", "requestAuthorization:", 1)] {
            replace(cls, sel, classMethod: true, argument: sel.contains("AccessLevel") ? .integer : .none) { completion in
                guard let completion else { return }
                let done = unsafeBitCast(completion, to: Status.self)
                later.async { done(denied) }
            }
        }
        // No completion: nothing happens.
        noOp("CLLocationManager", "requestWhenInUseAuthorization", classMethod: false)
        noOp("CLLocationManager", "requestAlwaysAuthorization", classMethod: false)
        noOp("SKStoreReviewController", "requestReview", classMethod: true)
        noOp("SKStoreReviewController", "requestReviewInScene:", classMethod: true, takesArgument: true)
    }

    /// What comes before the completion block.
    enum Argument { case none, object, integer }

    /// Replaces a method whose last argument is a completion block.
    private static func replace(_ className: String, _ selector: String, classMethod: Bool, argument: Argument,
                                _ answer: @escaping (AnyObject?) -> Void) {
        let key = "\(className).\(selector)"
        guard !done.contains(key), let cls = NSClassFromString(className) else { return }
        let sel = NSSelectorFromString(selector)
        guard let m = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel) else { return }
        done.insert(key)
        switch argument {
        case .none:
            let block: @convention(block) (AnyObject, AnyObject?) -> Void = { _, completion in answer(completion) }
            method_setImplementation(m, imp_implementationWithBlock(block))
        case .object:
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { _, _, completion in answer(completion) }
            method_setImplementation(m, imp_implementationWithBlock(block))
        case .integer:
            let block: @convention(block) (AnyObject, Int, AnyObject?) -> Void = { _, _, completion in answer(completion) }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }

    private static func noOp(_ className: String, _ selector: String, classMethod: Bool, takesArgument: Bool = false) {
        let key = "\(className).\(selector)"
        guard !done.contains(key), let cls = NSClassFromString(className) else { return }
        let sel = NSSelectorFromString(selector)
        guard let m = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel) else { return }
        done.insert(key)
        if takesArgument {
            let block: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in }
            method_setImplementation(m, imp_implementationWithBlock(block))
        } else {
            let block: @convention(block) (AnyObject) -> Void = { _ in }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }
}
