--- === hs._mylo.sloppyfocus ===
---
--- Focus a window without raising it (X11-style sloppy focus on macOS).
---
--- Uses SkyLight private APIs via the bundled native bridge. Works on Chromium
--- PWAs, which AutoRaise mis-handles. The Z-order of windows is not changed;
--- only the keyboard focus / "key window" assignment is updated.

local module = require("hs._mylo.sloppyfocus.internal")

--- hs._mylo.sloppyfocus.focusWithoutRaise(win [, currentlyFocused]) -> boolean
--- Function
--- Gives keyboard focus to `win` without changing its position in the Z-order.
---
--- Parameters:
---  * win - an hs.window object to receive focus
---  * currentlyFocused - optional hs.window currently holding focus. Required
---    only when switching between windows of the same app (e.g. two iTerm
---    windows), so the call can perform the extra deactivate/activate dance
---    SkyLight needs in that case. If omitted, same-app focus changes may
---    appear to no-op.
---
--- Returns:
---  * true on success, false if the call could not be made (missing window,
---    SkyLight symbols unavailable, or SLPS returned an error)
function module.focusWithoutRaise(win, currentlyFocused)
    if not win then return false end
    local pid = win:pid()
    local wid = win:id()
    if not pid or not wid then return false end

    local fpid, fwid = 0, 0
    if currentlyFocused then
        fpid = currentlyFocused:pid() or 0
        fwid = currentlyFocused:id() or 0
    end

    return module._focusByPidAndWindowID(pid, wid, fpid, fwid)
end

return module
