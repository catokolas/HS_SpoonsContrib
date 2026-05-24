// focus_test.m — Phase 1.5: full AutoRaise-style focus-without-raise ritual.
//
// Build: make focus_test
// Usage: ./focus_test <pid>
//
// What the test does (steps 1-3 mirror AutoRaise.mm:187-221):
//   1. Resolve PSN for the target pid.
//   2. Resolve the target window's CGWindowID via the AX tree
//      (first window of the app — fine for single-window PWAs).
//   3. _SLPSSetFrontProcessWithOptions(psn, WID, kCPSUserGenerated)
//      ← we previously passed wid=0 here which caused a raise.
//   4. Post two synthetic SLPS events (yabai's "make_key_window" trick)
//      to mark the window as key without changing Z-order.
//
// What to watch:
//   - SLPS return 0
//   - target becomes frontmost in the printed output
//   - VISUALLY: window stays in place in the Z-stack (no raise)
//   - Keystrokes go to the target if you then type (test by hand)

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <unistd.h>

extern OSStatus GetProcessForPID(pid_t pid, ProcessSerialNumber *psn) __attribute__((weak_import));

// _AXUIElementGetWindow lives in HIServices (part of ApplicationServices)
// but is not in the public headers. Declare it weakly so we degrade gracefully
// if Apple ever pulls it.
extern AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *out) __attribute__((weak_import));

#define kCPSUserGenerated 0x200

typedef OSStatus (*SLPSSetFrontFn) (ProcessSerialNumber *, uint32_t, uint32_t);
typedef OSStatus (*SLPSPostEventFn)(ProcessSerialNumber *, uint8_t *);

static SLPSSetFrontFn  slpsSetFront  = NULL;
static SLPSPostEventFn slpsPostEvent = NULL;

static int loadSkyLight(void) {
    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (!sky) {
        fprintf(stderr, "dlopen SkyLight failed: %s\n", dlerror());
        return -1;
    }
    slpsSetFront  = (SLPSSetFrontFn) dlsym(sky, "_SLPSSetFrontProcessWithOptions");
    slpsPostEvent = (SLPSPostEventFn)dlsym(sky, "SLPSPostEventRecordTo");
    if (!slpsSetFront || !slpsPostEvent) {
        fprintf(stderr, "missing SLPS symbols\n");
        return -1;
    }
    return 0;
}

// AutoRaise.mm:169-185 — verbatim byte layout. The magic offsets came from
// yabai (https://github.com/koekeishiya/yabai). Don't touch.
static void makeKeyWindow(ProcessSerialNumber *psn, uint32_t window_id) {
    uint8_t bytes[0xf8] = {0};
    bytes[0x04] = 0xf8;
    bytes[0x3a] = 0x10;
    memcpy(bytes + 0x3c, &window_id, sizeof(uint32_t));
    memset(bytes + 0x20, 0xFF, 0x10);

    bytes[0x08] = 0x01;
    slpsPostEvent(psn, bytes);

    bytes[0x08] = 0x02;
    slpsPostEvent(psn, bytes);
}

// Returns the first AXWindow's CGWindowID for the given pid.
// Adequate for single-window PWAs; for multi-window apps a real impl
// would target a specific window (e.g. the one under the mouse).
static int firstWindowID(pid_t pid, CGWindowID *out_wid) {
    AXUIElementRef axApp = AXUIElementCreateApplication(pid);
    if (!axApp) return -1;

    int result = -1;
    CFTypeRef windows = NULL;
    if (AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute, &windows) == kAXErrorSuccess
        && windows
        && CFGetTypeID(windows) == CFArrayGetTypeID()
        && CFArrayGetCount((CFArrayRef)windows) > 0) {
        AXUIElementRef firstWin = (AXUIElementRef)CFArrayGetValueAtIndex((CFArrayRef)windows, 0);
        if (_AXUIElementGetWindow && _AXUIElementGetWindow(firstWin, out_wid) == kAXErrorSuccess) {
            result = 0;
        }
    }
    if (windows) CFRelease(windows);
    CFRelease(axApp);
    return result;
}

static void printFrontmost(const char *label) {
    NSRunningApplication *front = [NSWorkspace sharedWorkspace].frontmostApplication;
    if (front) {
        printf("%-22s %s (pid %d)\n", label,
               front.localizedName.UTF8String ?: "?",
               front.processIdentifier);
    } else {
        printf("%-22s <none>\n", label);
    }
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <pid>\n", argv[0]);
        return 1;
    }
    pid_t pid = (pid_t)atoi(argv[1]);
    if (pid <= 0) { fprintf(stderr, "Bad pid: %s\n", argv[1]); return 1; }

    if (loadSkyLight() != 0) return 1;
    if (!_AXUIElementGetWindow) {
        fprintf(stderr, "_AXUIElementGetWindow unavailable\n");
        return 1;
    }

    @autoreleasepool {
        NSRunningApplication *target =
            [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (!target) { fprintf(stderr, "No NSRunningApplication for pid %d\n", pid); return 1; }

        printf("target:                %s (bundle %s)\n",
               target.localizedName.UTF8String    ?: "?",
               target.bundleIdentifier.UTF8String ?: "?");
        printFrontmost("frontmost BEFORE:");

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        ProcessSerialNumber psn = {0, 0};
        OSStatus status = GetProcessForPID(pid, &psn);
        if (status != noErr) {
            fprintf(stderr, "GetProcessForPID failed: %d\n", (int)status);
            return 1;
        }
        printf("PSN:                   high=%u low=%u\n",
               (unsigned)psn.highLongOfPSN, (unsigned)psn.lowLongOfPSN);
#pragma clang diagnostic pop

        CGWindowID wid = 0;
        if (firstWindowID(pid, &wid) != 0) {
            fprintf(stderr, "Could not resolve window id (no AX windows?)\n");
            return 1;
        }
        printf("window id:             0x%x (%u)\n", wid, wid);

        OSStatus rc = slpsSetFront(&psn, wid, kCPSUserGenerated);
        printf("SLPS return:           %d (%s)\n", (int)rc, rc == 0 ? "noErr" : "ERROR");

        makeKeyWindow(&psn, wid);
        printf("make_key_window:       posted\n");

        usleep(250 * 1000);
        printFrontmost("frontmost +250ms:");
        printf("target.isActive +250:  %s\n",
               [NSRunningApplication runningApplicationWithProcessIdentifier:pid].isActive
               ? "YES" : "NO");

        usleep(500 * 1000);
        printFrontmost("frontmost +750ms:");
        printf("target.isActive +750:  %s\n",
               [NSRunningApplication runningApplicationWithProcessIdentifier:pid].isActive
               ? "YES" : "NO");
    }
    return 0;
}
