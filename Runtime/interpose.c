// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

// Loaded into every simless host with DYLD_INSERT_LIBRARIES.
//
// Dynamic Type: an iOS app on the Mac gets CoreText's "iOS app on Mac" text
// style table, where every size category resolves to the default size. The
// iOS table is in CoreText too. These interposers ask for it, so UIFont,
// UIFontMetrics and SwiftUI text styles scale like on an iPhone. dyld applies
// interposing to callers in the shared cache, which is where UIKit and
// SwiftUI call from.
#include <CoreFoundation/CoreFoundation.h>

typedef const struct __CTFontDescriptor *CTFontDescriptorRef;
extern CTFontDescriptorRef CTFontDescriptorCreateWithTextStyleAndAttributes(CFStringRef style, CFStringRef size, CFDictionaryRef attributes);
extern double CTFontDescriptorGetTextStyleSize(CFStringRef style, CFStringRef size, int platform, void *out);
extern const CFStringRef kCTFontTextStylePlatformAttribute;

static int scaling = 1;   // SIMLESS_DYNAMIC_TYPE=0 turns it off

static CTFontDescriptorRef simless_create_with_text_style(CFStringRef style, CFStringRef size, CFDictionaryRef attributes) {
    if (!scaling) return CTFontDescriptorCreateWithTextStyleAndAttributes(style, size, attributes);
    CFMutableDictionaryRef m = attributes
        ? CFDictionaryCreateMutableCopy(NULL, 0, attributes)
        : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    // 3 is the "iOS app on Mac" environment, whose table doesn't scale.
    CFDictionaryRemoveValue(m, CFSTR("NSCTFontTargetEnvironmentAttribute"));
    if (!CFDictionaryContainsKey(m, kCTFontTextStylePlatformAttribute)) {
        int ios = 0;
        CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &ios);
        CFDictionarySetValue(m, kCTFontTextStylePlatformAttribute, n);
        CFRelease(n);
    }
    CTFontDescriptorRef d = CTFontDescriptorCreateWithTextStyleAndAttributes(style, size, m);
    CFRelease(m);
    return d;
}

// UIFontMetrics asks for a style's size with the default platform (-1).
static double simless_text_style_size(CFStringRef style, CFStringRef size, int platform, void *out) {
    return CTFontDescriptorGetTextStyleSize(style, size, (scaling && platform == -1) ? 0 : platform, out);
}

typedef struct { const void *replacement; const void *replacee; } simless_interpose_t;
__attribute__((used)) static const simless_interpose_t simless_interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)simless_create_with_text_style, (const void *)CTFontDescriptorCreateWithTextStyleAndAttributes },
    { (const void *)simless_text_style_size, (const void *)CTFontDescriptorGetTextStyleSize },
};

extern void simless_runtime_start(void);

__attribute__((constructor)) static void simless_runtime_init(void) {
    const char *dt = getenv("SIMLESS_DYNAMIC_TYPE");
    if (dt && dt[0] == '0') scaling = 0;
    simless_runtime_start();
}
