--- === ClickThrough ===
---
--- Click-through (focus-on-click) for macOS: a single click both focuses the
--- window or accessibility element under the cursor *and* activates it,
--- instead of requiring the usual two clicks for unfocused windows.
---
--- Detects the click target with hs.window first, falling back to
--- hs.axuielement.systemElementAtPosition for non-window UI (panels, popovers,
--- toolbar items, status-bar widgets). Dialogs and menus are deliberately
--- passed through untouched so they keep their normal interaction model.
---
--- A watchdog restarts the event tap if macOS silently disables it, which
--- happens when any single tap callback blocks for too long.

local ax = require("hs.axuielement")

local obj = {}
obj.__index = obj

-- Metadata
obj.name     = "ClickThrough"
obj.version  = "0.1"
obj.author   = ""
obj.homepage = ""
obj.license  = "MIT - https://opensource.org/licenses/MIT"

--- ClickThrough.logger
--- Variable
--- Logger object used within the Spoon. Set its log level to control verbosity.
obj.logger = hs.logger.new("ClickThrough")

--- ClickThrough.clickDebounce
--- Variable
--- Seconds; clicks within this window of the previous one are ignored
--- (double/triple clicks and OS auto-repeat). Default 0.05.
obj.clickDebounce = 0.05

--- ClickThrough.watchdogInterval
--- Variable
--- Seconds between event-tap health checks; if the tap was disabled by
--- macOS it is restarted. Set to 0 to disable. Default 5.
obj.watchdogInterval = 5

--- ClickThrough.healthCheckInterval
--- Variable
--- Seconds between debug-level "tap is alive" log entries. 0 disables.
--- Default 0.
obj.healthCheckInterval = 0

--- ClickThrough.logToFile
--- Variable
--- If true, also write a rotating file log in addition to hs.logger output.
--- Default false.
obj.logToFile = false

--- ClickThrough.logFilePath
--- Variable
--- Path for the optional file log. Default ~/hammerspoon_clickthrough.log.
obj.logFilePath = os.getenv("HOME") .. "/hammerspoon_clickthrough.log"

--- ClickThrough.maxLogSize
--- Variable
--- Rotate the file log when it grows past this many bytes. Default 5 MiB.
obj.maxLogSize = 5 * 1024 * 1024

-- ============================================================================
-- AX HELPERS
-- ============================================================================

local function getAxAttribute(elem, attrName, defaultValue)
    if not elem then return defaultValue end
    local ok, value = pcall(function() return elem:attributeValue(attrName) end)
    return ok and value or defaultValue
end

local function setAxAttribute(elem, attrName, value)
    if not elem then return false end
    local ok = pcall(function() elem:setAttributeValue(attrName, value) end)
    return ok
end

local function rectContains(mousePos, frame)
    if not frame or not mousePos then return false end
    return mousePos.x >= frame.x
       and mousePos.x <= frame.x + frame.w
       and mousePos.y >= frame.y
       and mousePos.y <= frame.y + frame.h
end

local AX_ANCESTOR_DEPTH_LIMIT = 20

-- Walk up to the enclosing AXWindow. Depth-limited to avoid stack overflow
-- on cyclic or pathologically deep trees.
local function findAxWindowAncestor(elem)
    local current = elem
    for _ = 1, AX_ANCESTOR_DEPTH_LIMIT do
        if not current then break end
        if getAxAttribute(current, "AXRole") == "AXWindow" then
            return current
        end
        current = getAxAttribute(current, "AXParent")
    end
    return nil
end

-- Match an AXWindow back to its hs.window by frame (2 px tolerance for
-- sub-pixel rendering differences).
local function hsWindowFromAxWindow(axWin)
    if not axWin then return nil end
    local pos  = getAxAttribute(axWin, "AXPosition")
    local size = getAxAttribute(axWin, "AXSize")
    if not pos or not size then return nil end

    for _, win in ipairs(hs.window.orderedWindows()) do
        local ok, frame = pcall(function() return win:frame() end)
        if ok and frame then
            if math.abs(frame.x - pos.x) <= 2
            and math.abs(frame.y - pos.y) <= 2
            and math.abs(frame.w - size.w) <= 2
            and math.abs(frame.h - size.h) <= 2 then
                return win
            end
        end
    end
    return nil
end

-- Returns a tagged result so callers never duck-type the return value:
--   { kind = "window", win  = <hs.window>  }   normal application window
--   { kind = "ax",     elem = <AX element> }   panel, popover, toolbar item, ...
--   nil                                         nothing found
local function findTarget(mousePos)
    for _, win in ipairs(hs.window.orderedWindows()) do
        local ok, vis = pcall(function() return win:isVisible() end)
        if ok and vis then
            local frame = win:frame()
            if frame and rectContains(mousePos, frame) then
                return { kind = "window", win = win }
            end
        end
    end

    local ok, elem = pcall(function()
        return ax.systemElementAtPosition(mousePos)
    end)
    if ok and elem then
        return { kind = "ax", elem = elem }
    end

    return nil
end

-- ============================================================================
-- FILE LOG (optional)
-- ============================================================================

function obj:_rotateLogIfNeeded()
    local f = io.open(self.logFilePath, "r")
    if not f then return end
    local size = f:seek("end")
    f:close()
    if size > self.maxLogSize then
        local backupPath = self.logFilePath .. "." .. os.date("%Y%m%d_%H%M%S")
        os.rename(self.logFilePath, backupPath)
    end
end

function obj:_openLogFile()
    if self._logfile then pcall(function() self._logfile:close() end) end
    self:_rotateLogIfNeeded()
    self._logfile = io.open(self.logFilePath, "a")
end

function obj:_closeLogFile()
    if self._logfile then
        pcall(function() self._logfile:close() end)
        self._logfile = nil
    end
end

function obj:_log(message, level)
    level = level or "INFO"
    if level == "WARN" then
        self.logger.w(message)
    elseif level == "DEBUG" then
        self.logger.d(message)
    else
        self.logger.i(message)
    end

    if not self.logToFile then return end

    if not self._logfile then pcall(function() self:_openLogFile() end) end
    if not self._logfile then return end

    local line = string.format("%s [%s] %s\n",
        os.date("%Y-%m-%d %H:%M:%S"), level, message)

    local ok = pcall(function()
        self._logfile:write(line)
        self._logfile:flush()
    end)
    if not ok then
        pcall(function() self:_openLogFile() end)
        if self._logfile then
            pcall(function()
                self._logfile:write(line)
                self._logfile:flush()
            end)
        end
    end
end

-- ============================================================================
-- CLICK HANDLER
-- ============================================================================

local MENU_ROLES = {
    AXMenu        = true,
    AXMenuItem    = true,
    AXMenuBar     = true,
    AXMenuBarItem = true,
}

function obj:_onClick()
    local now = hs.timer.secondsSinceEpoch()
    if (now - (self._lastClickTime or 0)) < self.clickDebounce then
        return false
    end
    self._lastClickTime = now

    local mousePos = hs.mouse.absolutePosition()
    local target   = findTarget(mousePos)

    if not target then
        self:_log("No window or AX element under mouse")
        return false
    end

    if target.kind == "window" then
        local win = target.win

        local ok, subrole = pcall(function() return win:subrole() end)
        if ok and subrole == "AXDialog" then
            self:_log("Skip: target window is a dialog (" .. (win:title() or "?") .. ")")
            return false
        end

        local frontmost = hs.window.frontmostWindow()
        if win:id() ~= (frontmost and frontmost:id()) then
            win:focus()
            self:_log("Focused window: " .. (win:title() or "Untitled"))
        else
            self:_log("Clicked already-focused window: " .. (win:title() or "Untitled"))
        end
    else
        local elem  = target.elem
        local role  = getAxAttribute(elem, "AXRole")  or "AXUIElement"
        local title = getAxAttribute(elem, "AXTitle") or role

        if MENU_ROLES[role] then
            self:_log("Skip: clicked menu element (" .. role .. ")")
            return false
        end

        local axWin = findAxWindowAncestor(elem)
        if axWin then
            local subrole = getAxAttribute(axWin, "AXSubrole")
            if subrole == "AXDialog" then
                self:_log("Skip: AX element is inside a dialog (" .. title .. ")")
                return false
            end

            local parentWin = hsWindowFromAxWindow(axWin)
            if parentWin then
                local frontmost = hs.window.frontmostWindow()
                if parentWin:id() ~= (frontmost and frontmost:id()) then
                    parentWin:focus()
                    self:_log("Raised parent window: " .. (parentWin:title() or "Untitled"))
                end
            end
        end

        local isFocused = getAxAttribute(elem, "AXFocused")
        if isFocused ~= true then
            setAxAttribute(elem, "AXFocused", true)
            self:_log("Focused AX element: " .. title .. " (" .. role .. ")")
        else
            self:_log("Clicked already-focused AX element: " .. title .. " (" .. role .. ")")
        end
    end

    return false -- always pass the original click through to the application
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

--- ClickThrough:configure(configuration)
--- Method
--- Merges a table of configuration values into the spoon. Accepts any of the
--- public variables (clickDebounce, watchdogInterval, healthCheckInterval,
--- logToFile, logFilePath, maxLogSize).
function obj:configure(configuration)
    for k, v in pairs(configuration or {}) do
        self[k] = v
    end
end

--- ClickThrough:start()
--- Method
--- Starts the click-through event tap (and watchdog / health-check timers
--- if configured).
function obj:start()
    if self.logToFile then pcall(function() self:_openLogFile() end) end

    self._eventtap = hs.eventtap.new(
        { hs.eventtap.event.types.leftMouseDown },
        function() return self:_onClick() end
    )
    self._eventtap:start()
    self:_log("Click-through event tap started")

    if self.watchdogInterval and self.watchdogInterval > 0 then
        self._watchdog = hs.timer.new(self.watchdogInterval, function()
            if self._eventtap and not self._eventtap:isEnabled() then
                self:_log("Event tap was disabled by macOS watchdog — restarting", "WARN")
                self._eventtap:start()
            end
        end)
        self._watchdog:start()
    end

    if self.healthCheckInterval and self.healthCheckInterval > 0 then
        self._healthcheck = hs.timer.new(self.healthCheckInterval, function()
            local enabled = self._eventtap and self._eventtap:isEnabled()
            self:_log(string.format("Event tap health check — isEnabled: %s",
                tostring(enabled)), "DEBUG")
        end)
        self._healthcheck:start()
    end

    return self
end

--- ClickThrough:stop()
--- Method
--- Stops the event tap and any timers, and closes the file log if open.
function obj:stop()
    if self._healthcheck then self._healthcheck:stop(); self._healthcheck = nil end
    if self._watchdog    then self._watchdog:stop();    self._watchdog    = nil end
    if self._eventtap    then self._eventtap:stop();    self._eventtap    = nil end
    self:_closeLogFile()
    return self
end

return obj
