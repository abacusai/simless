// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

// Which test crashed the host. macOS writes a crash report for the first few
// crashes of an app and then stops, so a test host can't count on one. When
// the host crashes, this walks the crashed thread's stack and prints the
// frames that belong to a loaded test bundle (the test's own function among
// them) to the host's log, then lets the crash go on as before.
#include <signal.h>
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/ucontext.h>

static void write_str(const char *s) { (void)write(2, s, strlen(s)); }

static void simless_crash_handler(int sig, siginfo_t *info, void *context) {
    ucontext_t *uc = (ucontext_t *)context;
    uintptr_t fp = 0, pc = 0;
#if defined(__arm64__)
    if (uc && uc->uc_mcontext) { fp = uc->uc_mcontext->__ss.__fp; pc = uc->uc_mcontext->__ss.__pc; }
#endif
    pthread_t self = pthread_self();
    uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(self);
    uintptr_t bottom = top - pthread_get_stacksize_np(self);
    const char *last = NULL;
    int printed = 0;
    // The top of the stack, for a description when macOS writes no report.
    uintptr_t top_fp = fp;
    int shown = 0;
    if (pc) {
        Dl_info d;
        if (dladdr((void *)pc, &d) && d.dli_sname) { write_str("simless-crash-frame: "); write_str(d.dli_sname); write_str("\n"); shown++; }
    }
    for (int i = 0; i < 64 && top_fp >= bottom && top_fp < top && shown < 8; i++) {
        uintptr_t ret = ((uintptr_t *)top_fp)[1];
        Dl_info d;
        if (ret && dladdr((void *)ret, &d) && d.dli_sname) {
            if (!last || strcmp(last, d.dli_sname) != 0) {
                write_str("simless-crash-frame: "); write_str(d.dli_sname); write_str("\n");
                last = d.dli_sname; shown++;
            }
        }
        uintptr_t next = ((uintptr_t *)top_fp)[0];
        if (next <= top_fp) break;
        top_fp = next;
    }
    last = NULL;
    write_str("simless-crash: test frames on the crashed thread:\n");
    for (long i = 0; i < 2000000 && fp >= bottom && fp < top && printed < 12; i++) {
        uintptr_t ret = ((uintptr_t *)fp)[1];
        uintptr_t next = ((uintptr_t *)fp)[0];
        Dl_info d;
        if (ret && dladdr((void *)ret, &d) && d.dli_fname && d.dli_sname && strstr(d.dli_fname, ".xctest/")) {
            if (!last || strcmp(last, d.dli_sname) != 0) {
                write_str("simless-test-frame: ");
                write_str(d.dli_sname);
                write_str("\n");
                last = d.dli_sname;
                printed++;
            }
        }
        if (next <= fp) break;
        fp = next;
    }
    (void)info;
    signal(sig, SIG_DFL);
    raise(sig);
}

/// Installs the handler, with an alternate stack for the main thread so a
/// stack overflow there can still run it.
void simless_install_crash_handler(void) {
    static char altstack[256 * 1024];
    stack_t ss = { .ss_sp = altstack, .ss_size = sizeof altstack, .ss_flags = 0 };
    sigaltstack(&ss, NULL);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = simless_crash_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    int signals[] = { SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE };
    for (unsigned i = 0; i < sizeof signals / sizeof signals[0]; i++) sigaction(signals[i], &sa, NULL);
}
