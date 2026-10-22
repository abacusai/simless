// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

// Interposers for native hosts (SIMLESS_NATIVE=1): the app runs outside the
// app sandbox, so what the sandbox scoped to the app is scoped here instead.
//
// - The per-user temp and cache folders (confstr), which NSTemporaryDirectory
//   and FileManager read, point into the slot's home, not the user's shared
//   /var/folders: tests clean their tmp, and patches are placed there.
// - Keychain calls go to a keychain of the slot's own (Runtime/Native.swift):
//   without an application identifier the real one refuses every call
//   (errSecMissingEntitlement), and a shared one would leak between slots.
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *simless_dir(const char *name) {
    const char *v = getenv(name);
    return (v && v[0] == '/') ? v : NULL;
}

static size_t simless_confstr(int name, char *buf, size_t len) {
    const char *dir = NULL;
    if (name == _CS_DARWIN_USER_TEMP_DIR) dir = simless_dir("SIMLESS_TMPDIR");
    else if (name == _CS_DARWIN_USER_CACHE_DIR) dir = simless_dir("SIMLESS_CACHEDIR");
    if (!dir) return confstr(name, buf, len);
    size_t n = strlen(dir) + 1;
    if (buf && len > 0) strlcpy(buf, dir, len);
    return n;
}

// Implemented in Swift; return 1 when they handled the call.
extern int simless_keychain_enabled(void);
extern OSStatus simless_keychain_add(CFDictionaryRef attributes, CFTypeRef *result);
extern OSStatus simless_keychain_copy(CFDictionaryRef query, CFTypeRef *result);
extern OSStatus simless_keychain_update(CFDictionaryRef query, CFDictionaryRef attributes);
extern OSStatus simless_keychain_delete(CFDictionaryRef query);

static OSStatus simless_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    return simless_keychain_enabled() ? simless_keychain_add(attributes, result) : SecItemAdd(attributes, result);
}
static OSStatus simless_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    return simless_keychain_enabled() ? simless_keychain_copy(query, result) : SecItemCopyMatching(query, result);
}
static OSStatus simless_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    return simless_keychain_enabled() ? simless_keychain_update(query, attributes) : SecItemUpdate(query, attributes);
}
static OSStatus simless_SecItemDelete(CFDictionaryRef query) {
    return simless_keychain_enabled() ? simless_keychain_delete(query) : SecItemDelete(query);
}

typedef struct { const void *replacement; const void *replacee; } simless_native_interpose_t;
__attribute__((used)) static const simless_native_interpose_t simless_native_interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)simless_confstr, (const void *)confstr },
    { (const void *)simless_SecItemAdd, (const void *)SecItemAdd },
    { (const void *)simless_SecItemCopyMatching, (const void *)SecItemCopyMatching },
    { (const void *)simless_SecItemUpdate, (const void *)SecItemUpdate },
    { (const void *)simless_SecItemDelete, (const void *)SecItemDelete },
};

// Isolation (Runtime/Isolation.swift builds the profile): the call itself is
// made from C, with C's calling convention.
extern int sandbox_init_with_parameters(const char *profile, uint64_t flags, const char *const parameters[], char **errorbuf);

int simless_sandbox_apply(const char *profile, char **error) {
    const char *none[] = { NULL };
    return sandbox_init_with_parameters(profile, 0, none, error);
}
