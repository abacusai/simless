// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

// Objective-C exceptions for Swift, which can't catch them. An exception UIKit
// throws while a UI request runs would otherwise unwind into AppKit's event
// loop, which swallows it, and the request would never get an answer.
#import <Foundation/Foundation.h>

/// Runs body(context). Returns NULL, or the exception it threw (malloc'd).
char *simless_catch(void (*body)(void *), void *context) {
    @try {
        body(context);
        return NULL;
    } @catch (NSException *e) {
        return strdup([NSString stringWithFormat:@"%@: %@", e.name, e.reason].UTF8String ?: "exception");
    } @catch (id e) {
        return strdup([e description].UTF8String ?: "exception");
    }
}
