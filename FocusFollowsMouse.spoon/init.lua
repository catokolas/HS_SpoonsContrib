--- === FocusFollowsMouse ===
---
--- Focus the window under the mouse pointer ("sloppy focus" / X11-style
--- focus-follows-mouse). When the pointer comes to rest over a window that
--- isn't already focused, that window is focused.
---
--- A short debounce delay means focus only changes once the cursor settles,
--- so quickly sweeping the pointer across windows does not thrash focus.
--- Focus changes are suppressed while a mouse button is held, so dragging
--- never steals focus.
---
--- Note: on macOS, focusing a window also raises it; there is no public system
--- primitive for focus-without-raise. If the optional `hs._ckol.sloppyfocus`
--- native helper is installed, this spoon uses it instead to focus without
--- raising; otherwise it falls back to `hs.window:focus()`.
---
--- Derived from the MouseFollowsFocus spoon by Jason Felice
--- <jason.m.felice@gmail.com>; the event-tap and focus-management logic is a
--- ground-up rewrite for the opposite direction (focus follows mouse rather
--- than mouse follows focus).

local obj={}
obj.__index = obj

-- Metadata
obj.name = "FocusFollowsMouse"
obj.version = "0.1"
obj.author = "Cato Kolås <cato.kolas@gmail.com>"
obj.credits = "Inspired by MouseFollowsFocus by Jason Felice <jason.m.felice@gmail.com>"
obj.homepage = "https://github.com/Hammerspoon/Spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- FocusFollowsMouse.delay
--- Variable
--- Seconds the pointer must rest over a window before focus is changed. Defaults to 0.1.
obj.delay = 0.1

--- FocusFollowsMouse.excludedApps
--- Variable
--- List of app names or bundle IDs whose windows should never be auto-focused.
obj.excludedApps = {}

--- FocusFollowsMouse.logger
--- Variable
--- Logger object used within the Spoon. Can be accessed to set the default log level for the messages coming from the Spoon.
obj.logger = hs.logger.new('FocusFollowsMouse')

--- FocusFollowsMouse:configure(configuration)
--- Method
--- Configures the spoon. Accepts any of the public variables (delay, excludedApps).
---
--- Parameters:
---  * configuration - a table of configuration values to merge into the spoon
function obj:configure(configuration)
  for k, v in pairs(configuration or {}) do
    self[k] = v
  end
end

local function isExcluded(self, win)
  local app = win:application()
  if not app then return false end
  local name, bid = app:name(), app:bundleID()
  for _, ex in ipairs(self.excludedApps) do
    if ex == name or ex == bid then return true end
  end
  return false
end

--- FocusFollowsMouse:windowUnderPoint(point)
--- Method
--- Returns the topmost standard window whose frame contains the given point, or nil.
---
--- Parameters:
---  * point - a table with x and y fields (e.g. from hs.mouse.absolutePosition())
-- True iff the cursor `point` falls inside this window's frame and the
-- window is currently a viable focus target.
local function frameContains(win, point)
  if not win or not win:isVisible() or win:isMinimized() then return false end
  local f = win:frame()
  return point.x >= f.x and point.x < f.x + f.w
     and point.y >= f.y and point.y < f.y + f.h
end

function obj:windowUnderPoint(point)
  -- Hammerspoon's own windows (Console, alerts) don't show up in
  -- hs.window.orderedWindows() because of how AX enumeration works
  -- inside the HS process itself. We can't just "always pick the HS
  -- window when its frame contains the point" — that breaks the
  -- reverse case where the Console is visually behind a front window
  -- but its frame still spans across the overlap region.
  --
  -- Use hs.axuielement.systemElementAtPosition() to ask the system
  -- which element is actually visually topmost. If that element
  -- belongs to Hammerspoon, the matching HS window wins. Otherwise
  -- fall through to the normal orderedWindows() iteration, which
  -- handles the rest correctly.
  local axOk, ax = pcall(require, "hs.axuielement")
  if axOk and ax then
    local el = ax.systemElementAtPosition(point.x, point.y)
    if el then
      local pid = el:pid()
      local app = pid and hs.application.applicationForPID(pid)
      if app and app:bundleID() == "org.hammerspoon.Hammerspoon" then
        for _, win in ipairs(app:allWindows()) do
          if frameContains(win, point) then return win end
        end
      end
    end
  end

  -- Normal path: topmost visible window in z-order covering the point.
  -- Iterating in z-order means we never walk past a dialog/sheet to the
  -- parent window behind it (which would steal focus while the user is
  -- interacting with the dialog).
  for _, win in ipairs(hs.window.orderedWindows()) do
    if frameContains(win, point) then return win end
  end
  return nil
end

-- Optional native module that focuses without raising. If it's installed
-- (~/.hammerspoon/hs/_ckol/sloppyfocus/) we use it; otherwise we fall back
-- to win:focus(), which raises.
local _sloppy = (function()
  local ok, m = pcall(require, "hs._ckol.sloppyfocus")
  return ok and m or nil
end)()

-- AXRoles of open menus. When the cursor is over one of these, focusing
-- the window behind would dismiss the menu, so we bail.
local MENU_ROLES = {
  AXMenu        = true,
  AXMenuItem    = true,
  AXMenuBar     = true,
  AXMenuBarItem = true,
  AXMenuButton  = true,
}

-- When the focused window is itself a modal sheet whose parent is the
-- candidate window, focusing the candidate bounces off WindowServer
-- back to the sheet — visible as a chrome flicker on each cursor
-- settle. Sheets are typically not enumerable via orderedWindows() but
-- ARE returned by focusedWindow(); their frame sits inside the parent's
-- frame in the same process.
local function focusedIsSheetOf(focused, candidate)
  if not focused or not candidate then return false end
  local fa, ca = focused:application(), candidate:application()
  if not fa or not ca or fa:pid() ~= ca:pid() then return false end
  local ff, cf = focused:frame(), candidate:frame()
  local slop = 4
  return ff.x >= cf.x - slop and ff.x + ff.w <= cf.x + cf.w + slop
     and ff.y >= cf.y - slop and ff.y + ff.h <= cf.y + cf.h + slop
end

function obj:_maybeFocus()
  if #hs.mouse.getButtons() ~= 0 then return end
  local point = hs.mouse.absolutePosition()
  -- Skip focus shifts while an open menu is under the cursor; otherwise
  -- the focus call dismisses it.
  local axOk, ax = pcall(require, "hs.axuielement")
  if axOk and ax then
    local el = ax.systemElementAtPosition(point.x, point.y)
    if el then
      local role = el:attributeValue("AXRole")
      if MENU_ROLES[role] then return end
    end
  end
  local win = self:windowUnderPoint(point)
  if not win then return end
  if isExcluded(self, win) then return end
  local focused = hs.window.focusedWindow()
  if focused and focused:id() == win:id() then return end
  if focusedIsSheetOf(focused, win) then return end
  if _sloppy and _sloppy.focusWithoutRaise(win, focused) then return end
  win:focus()
end

--- FocusFollowsMouse:start()
--- Method
--- Starts focusing windows as the mouse moves over them.
---
--- Parameters:
---  * None
function obj:start()
  self.timer = hs.timer.delayed.new(self.delay, function() self:_maybeFocus() end)
  self.eventtap = hs.eventtap.new(
    {hs.eventtap.event.types.mouseMoved},
    function() self.timer:start(); return false end
  )
  self.eventtap:start()
  return self
end

--- FocusFollowsMouse:stop()
--- Method
--- Stops focusing windows as the mouse moves.
---
--- Parameters:
---  * None
function obj:stop()
  if self.eventtap then self.eventtap:stop(); self.eventtap = nil end
  if self.timer then self.timer:stop(); self.timer = nil end
  return self
end

return obj
