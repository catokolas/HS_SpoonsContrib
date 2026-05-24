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
--- Note: on macOS, focusing a window also raises it; there is no system
--- primitive for focus-without-raise.

local obj={}
obj.__index = obj

-- Metadata
obj.name = "FocusFollowsMouse"
obj.version = "0.1"
obj.author = "Jason Felice <jason.m.felice@gmail.com>"
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
function obj:windowUnderPoint(point)
  for _, win in ipairs(hs.window.orderedWindows()) do
    if win:isStandard() and win:isVisible() and not win:isMinimized() then
      local f = win:frame()
      if point.x >= f.x and point.x < f.x + f.w
         and point.y >= f.y and point.y < f.y + f.h then
        return win
      end
    end
  end
  return nil
end

-- Optional native module that focuses without raising. If it's installed
-- (~/.hammerspoon/hs/_mylo/sloppyfocus/) we use it; otherwise we fall back
-- to win:focus(), which raises.
local _sloppy = (function()
  local ok, m = pcall(require, "hs._mylo.sloppyfocus")
  return ok and m or nil
end)()

function obj:_maybeFocus()
  if #hs.mouse.getButtons() ~= 0 then return end
  local win = self:windowUnderPoint(hs.mouse.absolutePosition())
  if not win then return end
  if isExcluded(self, win) then return end
  local focused = hs.window.focusedWindow()
  if focused and focused:id() == win:id() then return end
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
