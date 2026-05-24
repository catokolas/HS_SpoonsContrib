// hs._mylo.sloppyfocus.internal — native bridge to SkyLight's private
// focus-without-raise primitives. The full recipe (SLPS + yabai-style
// make_key_window event posting + same-process deactivate/activate dance)
// was lifted from AutoRaise.mm:169-221.
//
// Exposed to Lua as: _focusByPidAndWindowID(pid, wid, fpid, fwid) -> boolean
// where fpid/fwid identify the currently-focused window (optional; 0 = none).
// The public Lua surface is in init.lua; callers pass hs.window objects.

@import Cocoa;
@import LuaSkin;

#include <dlfcn.h>
#include <string.h>
#include <unistd.h>

extern OSStatus GetProcessForPID(pid_t pid, ProcessSerialNumber *psn) __attribute__((weak_import));

#define kCPSUserGenerated 0x200

typedef OSStatus (*SLPSSetFrontFn) (ProcessSerialNumber *, uint32_t, uint32_t);
typedef OSStatus (*SLPSPostEventFn)(ProcessSerialNumber *, uint8_t *);

static SLPSSetFrontFn  slpsSetFront  = NULL;
static SLPSPostEventFn slpsPostEvent = NULL;

static BOOL ensureSkyLight(void) {
    if (slpsSetFront && slpsPostEvent) return YES;
    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (!sky) return NO;
    slpsSetFront  = (SLPSSetFrontFn) dlsym(sky, "_SLPSSetFrontProcessWithOptions");
    slpsPostEvent = (SLPSPostEventFn)dlsym(sky, "SLPSPostEventRecordTo");
    return (slpsSetFront != NULL) && (slpsPostEvent != NULL);
}

// Magic byte layout from yabai; AutoRaise.mm:169-185. Do not edit.
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

// Same-process focus-switch dance (AutoRaise.mm:192-216). When switching
// between two windows of the same app, SkyLight thinks the process is
// already key and skips the focus change. Posting a synthetic deactivate
// on the old window and activate on the new one forces it through.
static void switchKeyWindowSameProcess(
        ProcessSerialNumber *psn, uint32_t new_wid,
        ProcessSerialNumber *old_psn, uint32_t old_wid) {
    uint8_t bytes[0xf8] = {0};
    bytes[0x04] = 0xf8;
    bytes[0x08] = 0x0d;

    bytes[0x8a] = 0x02;
    memcpy(bytes + 0x3c, &old_wid, sizeof(uint32_t));
    slpsPostEvent(old_psn, bytes);

    usleep(10000); // 10ms — AutoRaise comments this avoids race confusion in some apps.

    bytes[0x8a] = 0x01;
    memcpy(bytes + 0x3c, &new_wid, sizeof(uint32_t));
    slpsPostEvent(psn, bytes);
}

/// hs._mylo.sloppyfocus._focusByPidAndWindowID(pid, wid [, fpid, fwid]) -> boolean
/// Function
/// Internal. Use focusWithoutRaise(win [, currentlyFocused]) from the Lua wrapper.
static int focusByPidAndWindowID(lua_State *L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin checkArgs:LS_TNUMBER, LS_TNUMBER,
                    LS_TNUMBER | LS_TOPTIONAL, LS_TNUMBER | LS_TOPTIONAL,
                    LS_TBREAK];

    pid_t    pid  = (pid_t)   lua_tointeger(L, 1);
    uint32_t wid  = (uint32_t)lua_tointeger(L, 2);
    pid_t    fpid = (lua_gettop(L) >= 3) ? (pid_t)   lua_tointeger(L, 3) : 0;
    uint32_t fwid = (lua_gettop(L) >= 4) ? (uint32_t)lua_tointeger(L, 4) : 0;

    if (pid <= 0 || wid == 0 || !ensureSkyLight()) {
        lua_pushboolean(L, NO);
        return 1;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    ProcessSerialNumber psn = {0, 0};
    if (GetProcessForPID(pid, &psn) != noErr) {
        lua_pushboolean(L, NO);
        return 1;
    }

    if (fpid == pid && fwid != 0 && fwid != wid) {
        ProcessSerialNumber fpsn = {0, 0};
        if (GetProcessForPID(fpid, &fpsn) == noErr) {
            switchKeyWindowSameProcess(&psn, wid, &fpsn, fwid);
        }
    }
#pragma clang diagnostic pop

    OSStatus rc = slpsSetFront(&psn, wid, kCPSUserGenerated);
    if (rc != noErr) {
        lua_pushboolean(L, NO);
        return 1;
    }

    makeKeyWindow(&psn, wid);
    lua_pushboolean(L, YES);
    return 1;
}

static const luaL_Reg moduleLib[] = {
    {"_focusByPidAndWindowID", focusByPidAndWindowID},
    {NULL, NULL}
};

// Lua loader. The name MUST match the require path, dots -> underscores:
//   require("hs._mylo.sloppyfocus.internal") -> luaopen_hs__mylo_sloppyfocus_internal
int luaopen_hs__mylo_sloppyfocus_internal(lua_State *L) {
    [LuaSkin sharedWithState:L];
    luaL_newlib(L, moduleLib);
    return 1;
}
