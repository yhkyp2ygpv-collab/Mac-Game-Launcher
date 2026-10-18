// Wine 9 starts a game's process without Anvil's settings in its environment when the
// library's constructor runs, and with them later. Run with libanvil inserted and no
// ANVIL_* variables:
//   DYLD_INSERT_LIBRARIES=libanvil.dylib ./lazy_setup_test <log path>
#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#include <pthread.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

static void* nothing(void*) { return nullptr; }

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    const char* log = argv[1];
    remove(log);
    // As at the constructor: no settings, so nothing may have been logged.
    FILE* f = fopen(log, "r");
    int failures = 0;
    printf("%s: nothing logged before the settings exist\n", f ? "FAIL" : "ok"); if (f) { failures++; fclose(f); }
    IMP before = method_getImplementation(class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable)));
    // The settings arrive, as Wine 9's ntdll sets them.
    setenv("ANVIL_LOG", log, 1);
    setenv("ANVIL_HOOK_ENABLED", "1", 1);
    setenv("ANVIL_TARGET_FPS", "80", 1);
    pthread_t t;
    pthread_create(&t, nullptr, nothing, nullptr);
    pthread_join(t, nullptr);
    char text[4096] = {0};
    if ((f = fopen(log, "r"))) { fread(text, 1, sizeof text - 1, f); fclose(f); }
    bool injected = strstr(text, "injected into pid") && strstr(text, "(first thread)");
    printf("%s: set up at the game's first thread once the settings exist\n", injected ? "ok" : "FAIL"); if (!injected) failures++;
    IMP after = method_getImplementation(class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable)));
    Dl_info info; dladdr((void*)after, &info);
    bool hooked = info.dli_fname && strstr(info.dli_fname, "libanvil");
    printf("%s: CAMetalLayer nextDrawable goes through Anvil (%s)\n", hooked ? "ok" : "FAIL", info.dli_fname ? info.dli_fname : "?"); if (!hooked) failures++;
    (void)before;
    // A second thread doesn't set up twice.
    pthread_create(&t, nullptr, nothing, nullptr);
    pthread_join(t, nullptr);
    if ((f = fopen(log, "r"))) { memset(text, 0, sizeof text); fread(text, 1, sizeof text - 1, f); fclose(f); }
    int count = 0; for (const char* p = text; (p = strstr(p, "injected into pid")); p++) count++;
    printf("%s: set up once (%d)\n", count == 1 ? "ok" : "FAIL", count); if (count != 1) failures++;
    printf("%s\n", failures ? "lazy setup: FAILED" : "lazy setup: all checks passed");
    return failures ? 1 : 0;
}
