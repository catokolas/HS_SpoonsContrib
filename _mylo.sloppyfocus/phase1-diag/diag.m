// diag.m — Phase 1 diagnostic for sloppy-focus PWA investigation
//
// Dumps everything we might care about for a given pid: NSRunningApplication
// metadata, parent process, PSN, AX role/title/window count. Run it against a
// native app and a PWA and diff the output to identify the actual difference
// AutoRaise stumbles on.
//
// Build: make
// Usage: ./diag <pid>
//   e.g.  ./diag $(pgrep -f "Google Chrome$" | head -1)
//
// Tip: get the pid of the focused window from the Hammerspoon console:
//   hs.window.focusedWindow():pid()

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <libproc.h>

// GetProcessForPID is deprecated since 10.9 but still functional; declare it
// weak so we degrade cleanly if it ever disappears.
extern OSStatus GetProcessForPID(pid_t pid, ProcessSerialNumber *psn) __attribute__((weak_import));

static pid_t parentPID(pid_t pid) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) > 0) {
        return info.pbi_ppid;
    }
    return -1;
}

static NSString* axStringAttr(AXUIElementRef elem, CFStringRef attr) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(elem, attr, &value) != kAXErrorSuccess || !value) {
        return nil;
    }
    NSString *result = nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        result = [(__bridge NSString*)value copy];
    }
    CFRelease(value);
    return result;
}

static NSInteger axWindowCount(AXUIElementRef app) {
    CFTypeRef windows = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &windows) != kAXErrorSuccess || !windows) {
        return -1;
    }
    NSInteger count = -1;
    if (CFGetTypeID(windows) == CFArrayGetTypeID()) {
        count = CFArrayGetCount((CFArrayRef)windows);
    }
    CFRelease(windows);
    return count;
}

static const char* policyName(NSApplicationActivationPolicy p) {
    switch (p) {
        case NSApplicationActivationPolicyRegular:    return "regular";
        case NSApplicationActivationPolicyAccessory:  return "accessory";
        case NSApplicationActivationPolicyProhibited: return "prohibited";
    }
    return "?";
}

int main(int argc, char** argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <pid>\n", argv[0]);
        return 1;
    }
    pid_t pid = (pid_t)atoi(argv[1]);
    if (pid <= 0) { fprintf(stderr, "Bad pid: %s\n", argv[1]); return 1; }

    @autoreleasepool {
        printf("=== diag for pid %d ===\n", pid);

        // -------- NSRunningApplication --------
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (!app) {
            printf("NSRunningApplication:   <not found>\n");
        } else {
            printf("bundleIdentifier:       %s\n", app.bundleIdentifier.UTF8String  ?: "<nil>");
            printf("bundleURL:              %s\n", app.bundleURL.path.UTF8String     ?: "<nil>");
            printf("executableURL:          %s\n", app.executableURL.path.UTF8String ?: "<nil>");
            printf("localizedName:          %s\n", app.localizedName.UTF8String      ?: "<nil>");
            printf("activationPolicy:       %s\n", policyName(app.activationPolicy));
            printf("active:                 %s\n", app.isActive    ? "YES" : "NO");
            printf("hidden:                 %s\n", app.isHidden    ? "YES" : "NO");
            printf("ownsMenuBar:            %s\n", app.ownsMenuBar ? "YES" : "NO");
        }

        // -------- Parent process --------
        pid_t ppid = parentPID(pid);
        printf("parent pid:             %d\n", ppid);
        if (ppid > 0) {
            NSRunningApplication *parent = [NSRunningApplication runningApplicationWithProcessIdentifier:ppid];
            printf("parent bundleID:        %s\n", parent.bundleIdentifier.UTF8String ?: "<nil>");
            printf("parent localizedName:   %s\n", parent.localizedName.UTF8String    ?: "<nil>");
        }

        // -------- PSN --------
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (GetProcessForPID) {
            ProcessSerialNumber psn = {0, 0};
            OSStatus status = GetProcessForPID(pid, &psn);
            if (status == noErr) {
                printf("PSN:                    high=%u low=%u\n",
                       (unsigned)psn.highLongOfPSN, (unsigned)psn.lowLongOfPSN);
            } else {
                printf("PSN:                    GetProcessForPID failed (status %d)\n", (int)status);
            }
        } else {
            printf("PSN:                    GetProcessForPID unavailable\n");
        }
#pragma clang diagnostic pop

        // -------- AX --------
        AXUIElementRef axApp = AXUIElementCreateApplication(pid);
        if (!axApp) {
            printf("AX:                     AXUIElementCreateApplication returned NULL\n");
        } else {
            NSString *role  = axStringAttr(axApp, kAXRoleAttribute);
            NSString *title = axStringAttr(axApp, kAXTitleAttribute);
            printf("AX role:                %s\n", role.UTF8String  ?: "<nil>");
            printf("AX title:               %s\n", title.UTF8String ?: "<nil>");
            printf("AX window count:        %ld\n", (long)axWindowCount(axApp));

            // Focused window snapshot (helps see whether AX agrees on focus).
            CFTypeRef focused = NULL;
            if (AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute, &focused) == kAXErrorSuccess && focused) {
                NSString *wTitle = axStringAttr((AXUIElementRef)focused, kAXTitleAttribute);
                printf("AX focused window:      %s\n", wTitle.UTF8String ?: "<nil>");
                CFRelease(focused);
            } else {
                printf("AX focused window:      <none>\n");
            }
            CFRelease(axApp);
        }
    }
    return 0;
}
