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

-- Cached list of Hammerspoon-owned window frames, used by `_maybeFocus`
-- to detect "cursor over our own UI" without paying any AX cost on the
-- poll hot path. The cache is refreshed at most once per second; the
-- per-poll cost of `findHsWindowAt` is pure Lua arithmetic against the
-- cached rects. See `_maybeFocus` for the full rationale.
local _hsApp = nil
local _hsFrames = {}
local _hsFramesAt = 0
local HS_FRAMES_TTL_NS = 1e9

local function refreshHsFrames()
  if not _hsApp then
    _hsApp = hs.application.applicationForPID(hs.processInfo.processID)
  end
  if not _hsApp then _hsFrames = {}; return end
  local fresh = {}
  for _, win in ipairs(_hsApp:allWindows()) do
    local f = win:frame()
    if f then fresh[#fresh + 1] = f end
  end
  _hsFrames = fresh
end

local function findHsWindowAt(point)
  local now = hs.timer.absoluteTime()
  if now - _hsFramesAt >= HS_FRAMES_TTL_NS then
    refreshHsFrames()
    _hsFramesAt = now
  end
  for _, f in ipairs(_hsFrames) do
    if point.x >= f.x and point.x < f.x + f.w
       and point.y >= f.y and point.y < f.y + f.h then
      return true
    end
  end
  return false
end

-- AXRoles of open menus. When the cursor is over one of these, focusing
-- the window behind would dismiss the menu, so we bail.
local MENU_ROLES = {
  AXMenu        = true,
  AXMenuItem    = true,
  AXMenuBar     = true,
  AXMenuBarItem = true,
  AXMenuButton  = true,
}

-- Walk an AX element's parent chain looking for a menu-role ancestor.
-- Mozilla apps (Thunderbird/Firefox) nest the element directly under
-- the cursor several levels below the actual AXMenu container, so a
-- single-level role check at the hit point misses the open popup and
-- FFM dismisses it by focusing the window behind.
local function inMenuChain(el)
  local depth = 0
  while el and depth < 8 do
    local role = el:attributeValue("AXRole")
    if role and MENU_ROLES[role] then return true end
    el = el:attributeValue("AXParent")
    depth = depth + 1
  end
  return false
end

-- Walk to the enclosing AXWindow and report whether it's a popup-like
-- surface (autocomplete dropdown, tooltip, HUD, floating panel). Real
-- focusable windows expose AXSubrole == "AXStandardWindow"; popups
-- expose AXFloatingWindow / AXUnknown / etc. or no subrole at all.
-- Used in addition to the menu-role check because popups often expose
-- generic content roles (AXCell, AXStaticText) that we can't add to
-- MENU_ROLES without breaking focus over ordinary tables and labels.
local function inPopupWindow(el)
  local depth = 0
  while el and depth < 12 do
    if el:attributeValue("AXRole") == "AXWindow" then
      return el:attributeValue("AXSubrole") ~= "AXStandardWindow"
    end
    el = el:attributeValue("AXParent")
    depth = depth + 1
  end
  return false
end

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

  -- Bail (no auto-focus, no AX) when the cursor is over a
  -- Hammerspoon-owned window.
  --
  -- Why: every AX-touching path on a WKWebView-backed HS window
  -- (allWindows enumeration, win:frame(), win:focus()) can route
  -- through accessibility surface that synchronously waits on the
  -- WebKit content process. When that process is busy (paint, JS, even
  -- responding to the user's own click), the wait can be **seconds**
  -- — long enough to peg Hammerspoon's main thread, raise the
  -- macOS beachball, and queue every subsequent input event (drags
  -- replay as one motion, clicks land late).
  --
  -- Mitigation strategy:
  --   1. Hit-test against a *cached* list of HS-owned window frames
  --      so the per-poll cost is pure Lua arithmetic. Refresh happens
  --      at most once per second.
  --   2. If the cursor is over any HS window, return — don't attempt
  --      win:focus(). The user focuses HS windows by clicking them
  --      (which already activates them via macOS click-to-activate).
  --      This trades auto-focus-on-hover for HS windows in exchange
  --      for no beachball, which is the right call when one of those
  --      windows is a busy WKWebView dashboard.
  if findHsWindowAt(point) then return end

  -- Other apps' windows: the AX cascade is needed to skip focus shifts
  -- while an open menu / floating popup is involved (otherwise the
  -- focus call dismisses them). Two probes:
  --   1. Element at cursor (catches most apps; menu may be a nested
  --      child so we walk the parent chain).
  --   2. Frontmost app's AXFocusedUIElement (catches popups that
  --      `systemElementAtPosition` doesn't return — e.g. Thunderbird,
  --      where the cursor's hit element is the window content behind
  --      while the menu is the app's focused UI element).
  local axOk, ax = pcall(require, "hs.axuielement")
  if axOk and ax then
    local el = ax.systemElementAtPosition(point.x, point.y)
    if el and (inMenuChain(el) or inPopupWindow(el)) then return end
    local front = hs.application.frontmostApplication()
    if front then
      local appEl = ax.applicationElement(front)
      local focusedEl = appEl and appEl:attributeValue("AXFocusedUIElement")
      if focusedEl and inMenuChain(focusedEl) then return end
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
  -- Poll mouse position instead of tapping mouseMoved events.
  --
  -- An eventtap on mouseMoved fires the Lua callback for every mouse
  -- event (~60 Hz), and that callback has to acquire the Hammerspoon
  -- Lua VM lock. When another spoon is doing main-thread work — most
  -- notably WKWebView IPC for a dashboard webview (e.g. ModelsUsage) —
  -- mouse events block in the kernel queue until the lock frees, then
  -- replay all at once. Visible symptom: dragging a webview window's
  -- title bar gets queued and replayed as one motion, clicks land late.
  --
  -- Polling decouples mouse delivery from Lua entirely. We sample
  -- position at `self.delay` and only invoke `_maybeFocus` when the
  -- cursor has settled at a new spot (one tick of unchanged position
  -- after a tick of motion). That preserves "focus the window after
  -- ~delay of no movement" behaviour without paying per-event lock
  -- contention.
  self._pollLastPoint = nil
  self._pollFiredHere = false
  self.timer = hs.timer.doEvery(self.delay, function()
    local p = hs.mouse.absolutePosition()
    if self._pollLastPoint
       and self._pollLastPoint.x == p.x
       and self._pollLastPoint.y == p.y then
      if not self._pollFiredHere then
        self._pollFiredHere = true
        self:_maybeFocus()
      end
    else
      self._pollLastPoint = p
      self._pollFiredHere = false
    end
  end)
  return self
end

--- FocusFollowsMouse:stop()
--- Method
--- Stops focusing windows as the mouse moves.
---
--- Parameters:
---  * None
function obj:stop()
  if self.timer then self.timer:stop(); self.timer = nil end
  self._pollLastPoint = nil
  self._pollFiredHere = false
  return self
end

--- FocusFollowsMouse:toggle()
--- Method
--- Toggles the Spoon on/off and shows a brief `hs.alert` banner so the
--- user can tell which state they're in without checking the console.
--- Useful as a hotkey binding for apps where focus-follows-mouse would
--- get in the way (full-screen video, games).
function obj:toggle()
  if self.timer then
    self:stop()
    hs.alert.show("FocusFollowsMouse: off")
  else
    self:start()
    hs.alert.show("FocusFollowsMouse: on")
  end
end

--- FocusFollowsMouse:bindHotkeys(mapping)
--- Method
--- Binds (or rebinds) keyboard shortcuts. The mapping table accepts a
--- `toggle` key with a `{mods, key}` pair compatible with
--- `hs.hotkey.bindSpec`. Calling `bindHotkeys` again clears prior
--- bindings first.
---
--- Parameters:
---  * mapping - table like `{ toggle = {{"ctrl","cmd"}, "f"} }`
---
--- Returns:
---  * self
function obj:bindHotkeys(mapping)
  if self._hotkeys then
    for _, hk in ipairs(self._hotkeys) do hk:delete() end
  end
  self._hotkeys = {}

  if mapping and mapping.toggle then
    table.insert(self._hotkeys, hs.hotkey.bindSpec(mapping.toggle, function()
      self:toggle()
    end))
  end
  self.logger.i("bindHotkeys: bound " .. #self._hotkeys .. " hotkey(s)")
  return self
end

return obj
