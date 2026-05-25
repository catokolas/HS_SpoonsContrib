--- === MoveSpaces ===
---
--- Move the currently-focused window to the macOS Space immediately to the
--- left or right of the current Space, on the same screen.
---
--- Uses Hammerspoon's official `hs.spaces` API. The window move itself is
--- silent — no Mission Control flicker. Setting `followWindow = true` makes
--- the viewer follow the window to its new Space (at the cost of one Mission
--- Control transition).
---
--- Inspired by an earlier `MoveSpaces.spoon` by Tyler Thrailkill
--- <tyler.b.thrailkill@gmail.com>, itself based on code by Szymon Kaliski
--- <hi@szymonkaliski.com>. That implementation simulated a title-bar drag
--- against the now-deprecated `hs._asm.undocumented.spaces`; this is a
--- clean rewrite against `hs.spaces`.

local obj = {}
obj.__index = obj

-- Metadata
obj.name    = "MoveSpaces"
obj.version = "0.1"
obj.author  = "Cato Kolås <cato.kolas@gmail.com>"
obj.credits = "Inspired by MoveSpaces.spoon by Tyler Thrailkill, based on "
            .. "code by Szymon Kaliski. Reimplemented against hs.spaces."
obj.homepage = "https://github.com/catokolas/HS_SpoonsContrib"
obj.license  = "MIT - https://opensource.org/licenses/MIT"

--- MoveSpaces.followWindow
--- Variable
--- If true (default), the viewer follows the window to its new Space — same
--- behaviour as moving a window between workspaces on Linux desktops. If
--- false, the view snaps back to the originating Space after the move
--- (costs an extra Mission Control transition).
obj.followWindow = true

--- MoveSpaces.wrap
--- Variable
--- If true, moving past the leftmost/rightmost Space wraps around to the
--- opposite end of the same screen's Space list. Default `false` (silent
--- no-op at edges).
obj.wrap = false

--- MoveSpaces.skipFullScreenSpaces
--- Variable
--- If true, fullscreen-app Spaces are stepped over when looking for the
--- destination Space (a window can't be moved into a fullscreen Space
--- anyway). Default `true`.
obj.skipFullScreenSpaces = true

--- MoveSpaces.logger
--- Variable
--- Logger object used within the Spoon. Set its level to control verbosity.
obj.logger = hs.logger.new("MoveSpaces")

-- Optional native helper. On macOS 26+ the public `hs.spaces.moveWindowToSpace`
-- silently no-ops; the native helper calls SkyLight's `SLSMoveWindowsToManagedSpace`
-- directly and actually moves the window. If the helper isn't installed we
-- fall back to a drag-simulation that may or may not work on this OS.
local _movetospace = (function()
  local ok, m = pcall(require, "hs._ckol.movetospace")
  return ok and m or nil
end)()

function obj:_moveWindow(direction)
  local log = self.logger
  log.i("_moveWindow called, direction=" .. tostring(direction))

  local win = hs.window.focusedWindow()
  if not win then log.i("no focused window"); return end
  log.i(string.format("focused window: id=%s title=%q app=%s",
    tostring(win:id()), win:title() or "", win:application():name()))

  local screen = win:screen()
  if not screen then log.d("focused window has no screen"); return end
  local screenUUID = screen:getUUID()

  local spaces = hs.spaces.spacesForScreen(screenUUID)
  log.i("spacesForScreen returned: " .. hs.inspect(spaces))
  if not spaces or #spaces == 0 then
    log.w("no spaces returned for screen " .. tostring(screenUUID))
    return
  end

  local currentSpace = hs.spaces.activeSpaceOnScreen(screenUUID)
  log.i("activeSpaceOnScreen=" .. tostring(currentSpace))
  local idx
  for i, sid in ipairs(spaces) do
    if sid == currentSpace then idx = i; break end
  end
  if not idx then
    log.w("active space not found in screen's space list")
    return
  end
  log.i("current space index=" .. tostring(idx) .. " of " .. tostring(#spaces))

  if hs.spaces.spaceType(currentSpace) == "fullscreen" then
    log.i("focused window is in a fullscreen Space; not moving")
    return
  end

  local n, target, steps = #spaces, idx, 0
  while true do
    target = target + direction
    if target < 1 or target > n then
      if self.wrap then
        target = ((target - 1) % n) + 1
      else
        log.d("no neighbor Space in that direction")
        return
      end
    end
    if target == idx then
      log.d("only one eligible Space (the current one)")
      return
    end

    local candidate = spaces[target]
    if self.skipFullScreenSpaces and hs.spaces.spaceType(candidate) == "fullscreen" then
      steps = steps + 1
      if steps >= n then
        log.d("no non-fullscreen Spaces available in that direction")
        return
      end
      -- continue loop to step again
    else
      local dirStr = direction == 1 and "right" or "left"

      -- Path 1: SkyLight API move (silent, no view shift). Works for
      -- standard Cocoa windows.
      if _movetospace and _movetospace.move(win, candidate) then
        log.i(string.format("native move: window %s -> space %s",
          tostring(win:id()), tostring(candidate)))
        if self.followWindow then
          log.i("followWindow: gotoSpace(" .. tostring(candidate) .. ")")
          hs.spaces.gotoSpace(candidate)
        end
        return
      end

      -- Path 2: HID-level drag-with-Ctrl+arrow. May work for windows the
      -- API path can't shift (Electron, Chromium, some terminal apps on
      -- macOS 26+). Always shifts the view as a side effect.
      if _movetospace and _movetospace.dragMoveWindow then
        log.i("API move failed; trying HID-level drag-sim")
        _movetospace.dragMoveWindow(win, dirStr)
        -- Verify
        local after = hs.spaces.windowSpaces(win:id()) or {}
        local moved = false
        for _, s in ipairs(after) do
          if s == candidate then moved = true; break end
        end
        if moved then
          log.i("HID drag-sim succeeded")
          if not self.followWindow then
            local origin = spaces[idx]
            hs.timer.doAfter(0.05, function()
              log.i("snap-back: gotoSpace(" .. tostring(origin) .. ")")
              hs.spaces.gotoSpace(origin)
            end)
          end
          return
        end
        log.w("HID drag-sim did not move the window")
      end

      -- Out of options.
      log.w("no remaining path; this window appears unmovable on this macOS")
      return
    end
  end
end

-- Drag-simulation move. The hs.spaces.moveWindowToSpace API silently no-ops
-- on macOS 26+; simulating a title-bar drag while sending the system's
-- Cmd+Ctrl+arrow Space-switch shortcut is the proven workaround. Side
-- effect: the view follows the window because Cmd+Ctrl+arrow switches the
-- viewer too. If followWindow is false, we snap the view back afterwards.
function obj:_dragMove(win, screen, direction, targetSpace)
  local log = self.logger
  local screenUUID = screen:getUUID()
  local originSpace = hs.spaces.activeSpaceOnScreen(screenUUID)

  local zb = win:zoomButtonRect()
  if not zb then
    log.w("zoomButtonRect returned nil; cannot drag-move")
    return
  end
  local clickPoint = { x = zb.x + zb.w + 5, y = zb.y + zb.h / 2 }

  -- Chromium-based browsers have a tab strip where a regular title bar
  -- would be; the drag handle sits one row higher than the zoom button.
  local appName = win:application():name() or ""
  if appName == "Google Chrome" or appName == "Brave Browser"
     or appName == "Chromium" or appName == "Microsoft Edge"
     or appName == "Arc" or appName == "Vivaldi" then
    clickPoint.y = clickPoint.y - zb.h
  end

  log.i(string.format("drag-move: click at (%.0f, %.0f), target space=%s",
    clickPoint.x, clickPoint.y, tostring(targetSpace)))

  local savedMousePos = hs.mouse.absolutePosition()

  hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseDown, clickPoint):post()
  hs.timer.usleep(50000)  -- 50ms for macOS to register the click

  -- Send several leftMouseDragged events so macOS recognises an actual drag
  -- in progress (a bare leftMouseDown is treated as a click, not a drag, and
  -- the window won't follow when the Space switches).
  for i = 1, 4 do
    local dragPoint = { x = clickPoint.x + i * 2, y = clickPoint.y }
    hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseDragged, dragPoint):post()
    hs.timer.usleep(15000)
  end
  log.i("drag events posted; switching space")

  hs.spaces.gotoSpace(targetSpace)
  log.i("gotoSpace returned; entering waitUntil")

  -- Release-once-and-cleanup. Called by waitUntil success OR safety timeout.
  local released = false
  local waitTimer
  local function release(reason)
    if released then return end
    released = true
    if waitTimer and waitTimer.stop then waitTimer:stop() end
    hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseUp, clickPoint):post()
    hs.mouse.absolutePosition(savedMousePos)
    log.i("drag-move released (" .. reason .. ")")
    if not self.followWindow then
      hs.timer.doAfter(0.05, function()
        log.i("snap-back: gotoSpace(" .. tostring(originSpace) .. ")")
        hs.spaces.gotoSpace(originSpace)
      end)
    end
  end

  waitTimer = hs.timer.waitUntil(
    function() return hs.spaces.activeSpaceOnScreen(screenUUID) == targetSpace end,
    function() release("space switched") end,
    0.01
  )

  -- Safety: if the Space never switches (e.g., system shortcut disabled),
  -- release the drag within 1.5s to avoid a stuck mouse-down.
  hs.timer.doAfter(1.5, function() release("safety timeout") end)
end

--- MoveSpaces:moveFocusedWindowLeft()
--- Method
--- Moves the currently-focused window to the Space immediately to the left
--- of the current Space, on the same screen.
function obj:moveFocusedWindowLeft()
  self:_moveWindow(-1)
end

--- MoveSpaces:moveFocusedWindowRight()
--- Method
--- Moves the currently-focused window to the Space immediately to the right
--- of the current Space, on the same screen.
function obj:moveFocusedWindowRight()
  self:_moveWindow(1)
end

--- MoveSpaces:bindHotkeys(mapping)
--- Method
--- Binds (or rebinds) keyboard shortcuts. The mapping table accepts
--- `space_left` and `space_right` keys, each a `{mods, key}` pair
--- compatible with `hs.hotkey.bindSpec`. Either may be omitted to leave
--- that direction unbound. Calling `bindHotkeys` again clears prior
--- bindings first.
---
--- Parameters:
---  * mapping - table like
---    `{ space_left  = {{"shift","ctrl"}, "left"},
---       space_right = {{"shift","ctrl"}, "right"} }`
---
--- Returns:
---  * self
function obj:bindHotkeys(mapping)
  if self._hotkeys then
    for _, hk in ipairs(self._hotkeys) do hk:delete() end
  end
  self._hotkeys = {}

  if mapping and mapping.space_left then
    table.insert(self._hotkeys, hs.hotkey.bindSpec(mapping.space_left, function()
      self:moveFocusedWindowLeft()
    end))
  end
  if mapping and mapping.space_right then
    table.insert(self._hotkeys, hs.hotkey.bindSpec(mapping.space_right, function()
      self:moveFocusedWindowRight()
    end))
  end
  self.logger.i("bindHotkeys: bound " .. #self._hotkeys .. " hotkey(s)")
  return self
end

return obj
