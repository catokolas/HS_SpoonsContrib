--- === MouseMoveResizeWindows ===
---
--- Hold a configurable modifier chord and drag anywhere inside a window
--- to move or resize it — no need to aim for the title bar or a corner.
---
--- * Modifier + left-drag → moves the window, tracking the cursor.
--- * Modifier + right-drag → resizes the window by moving the **closest
---   edge** (left, right, top, or bottom — picked once at mouse-down
---   from the four edge-distances and held for the rest of the drag).
---
--- Releasing the modifier mid-drag aborts the gesture cleanly without
--- snapping the window back. Clicks without the modifier are passed
--- through untouched.
---
--- The window targeted by a drag is the topmost one whose frame
--- contains the cursor at mouse-down — i.e. the one you're clicking
--- into. With `firstRaise` on (the default), that window is focused and
--- raised at the start of each drag.
---
--- Requires Hammerspoon's Accessibility permission to install the
--- eventtap and to call `hs.window:setFrame`.
---
--- ## Coexistence with sibling Spoons
---
--- This Spoon is read-only: it inspects mouse events and consumes them
--- while a drag is active, but never posts synthetic events of its own.
--- The shared sibling sentinel range (`0xC0DE5C00..0xC0DE5CFF`) is
--- therefore unused here — there's nothing to stamp. Other Spoons in
--- the family that DO synthesise events use these bytes:
---   0x01 = MouseScrollTweaks
---   0x02 = MouseTrackpadTweaks
---   0x03 = MouseCopyPasteSelection

local obj = {}
obj.__index = obj

-- Metadata
obj.name     = "MouseMoveResizeWindows"
obj.version  = "0.1"
obj.author   = "Cato Kolås <cato.kolas@gmail.com>"
obj.credits  = ""
obj.homepage = "https://github.com/catokolas/HS_SpoonsContrib"
obj.license  = "MIT - https://opensource.org/licenses/MIT"

--- MouseMoveResizeWindows.modifiers
--- Variable
--- Modifier-only chord that arms the drag — a list of modifier names
--- matched exactly against `hs.eventtap.event:getFlags()`. The Spoon
--- is agnostic about which names appear: anything Hammerspoon surfaces
--- as a flag-table key works (today: `ctrl`, `alt`, `shift`, `cmd`,
--- `fn`). Default: `{"alt"}` — Option + drag, picked because it
--- doesn't collide with the Command-key combos most apps own.
--- Match is exact: extra held modifiers disarm the gesture.
obj.modifiers = { "alt" }

--- MouseMoveResizeWindows.firstRaise
--- Variable
--- If true (default), the target window is focused and raised at the
--- start of each drag — handy when you grab a half-occluded background
--- window. Set false to move/resize without changing focus order.
obj.firstRaise = true

--- MouseMoveResizeWindows.logger
--- Variable
--- Logger object used within the Spoon. Set its level (e.g.
--- `spoon.MouseMoveResizeWindows.logger.setLogLevel("debug")`) to trace
--- gesture decisions.
obj.logger = hs.logger.new("MouseMoveResizeWindows")

--- MouseMoveResizeWindows.startupDelay
--- Variable
--- Seconds to defer the accessibility check + `hs.eventtap.new`/
--- `:start()` inside `:start()`. The spoon's `start()` returns
--- immediately and schedules a one-shot timer that performs the
--- real wiring.
---
--- Why: Hammerspoon's reload runs every Spoon's `:start()` in tight
--- succession on the main thread. The simultaneous `CGEventTapCreate`
--- XPC handshakes across multiple Mouse-* spoons contend with other
--- main-thread cold-start work (notably NSURLSession's first-call
--- init) enough to stall one-shot timers in *other* Spoons for
--- tens of seconds — ModelsUsage in particular loses its KIX-request
--- timeout. Pushing this spoon's OS calls a few seconds past the
--- reload storm avoids being part of that contention. Set to 0 for
--- the pre-2026-06 synchronous behaviour.
---
--- Default 3.6 is staggered against the other Mouse-* spoons
--- (3.0 / 3.3 / 3.9) so their deferred OS calls don't all land in
--- the same run-loop tick.
obj.startupDelay = 3.6

-- Internal state — not part of the public API.
obj._tap      = nil   -- eventtap handle
obj._hotkeys  = {}    -- bindHotkeys-installed hotkeys
obj._drag     = nil   -- active drag context (see _startDrag)

local function setFromList(list)
  local s = {}
  for _, v in ipairs(list or {}) do s[v] = true end
  return s
end

-- Exact-match required-vs-held check. Every entry in `required` must
-- appear truthy in `flags`, and no other alphabetic-name key in
-- `flags` may be truthy. No modifier set is hardcoded — whatever
-- `hs.eventtap.event:getFlags()` surfaces is what we compare against,
-- so if a manifest writes `{"hyper"}` or a future macOS adds a new
-- modifier the matcher honours it without code change. Names follow
-- Hammerspoon's own table-key convention (`cmd`, `alt`, `ctrl`,
-- `shift`, `fn`, …).
--
-- Quirks handled:
--   * `getFlags()` is dense (every known modifier with `true`/`false`)
--     in some Hammerspoon versions, sparse in others — `if v and …`
--     handles both.
--   * `checkKeyboardModifiers()` (and at least some `getFlags()`
--     implementations) also include glyph aliases (`⌥` next to `alt`,
--     `⌘` next to `cmd`, …). The alphabetic-key filter
--     (`k:match("^%a+$")`) ignores those convenience duplicates so the
--     "no extras" rule doesn't trip on the Spoon's own canonical name.
local function modifiersMatch(flags, required)
  local want = setFromList(required)
  for k in pairs(want) do
    if not flags[k] then return false end
  end
  for k, v in pairs(flags) do
    if v and k:match("^%a+$") and not want[k] then
      return false
    end
  end
  return true
end

--- MouseMoveResizeWindows:configure(configuration)
--- Method
--- Shallow-merge configuration values into the Spoon. Accepts any of
--- the public variables. Returns self.
function obj:configure(configuration)
  if configuration then
    for k, v in pairs(configuration) do self[k] = v end
  end
  return self
end

-- ============================================================
-- Window targeting
-- ============================================================

local function pointInRect(pt, r)
  return pt.x >= r.x and pt.x <= r.x + r.w
     and pt.y >= r.y and pt.y <= r.y + r.h
end

-- Topmost window whose frame contains the pointer, or nil. Skips
-- windows without a frame (`r.w == 0` is what hs.window returns for
-- non-standard windows — menu extras, sheets, etc.).
local function windowAtPoint(pt)
  for _, w in ipairs(hs.window.orderedWindows()) do
    local ok, r = pcall(function() return w:frame() end)
    if ok and r and r.w > 0 and r.h > 0 and pointInRect(pt, r) then
      return w
    end
  end
  return nil
end

-- Pick the closest of the four window edges to the pointer at
-- mouse-down. Used to decide which edge a right-drag-resize moves.
-- Returns one of "left" | "right" | "top" | "bottom".
local function closestEdge(pt, r)
  local dLeft   = pt.x - r.x
  local dRight  = (r.x + r.w) - pt.x
  local dTop    = pt.y - r.y
  local dBottom = (r.y + r.h) - pt.y
  local best, bestD = "left", dLeft
  if dRight  < bestD then best, bestD = "right",  dRight  end
  if dTop    < bestD then best, bestD = "top",    dTop    end
  if dBottom < bestD then best, bestD = "bottom", dBottom end
  return best
end

-- ============================================================
-- Drag math
-- ============================================================

local function translatedFrame(start, dx, dy)
  return { x = start.x + dx, y = start.y + dy, w = start.w, h = start.h }
end

-- Single-edge resize. dx/dy are pointer deltas from drag start;
-- whichever component matters for `edge` is applied, the other is
-- ignored. Sizes clamp to 1px so we don't generate negative-size frames
-- (which AppKit interprets as flipped windows).
local function resizedFrame(start, edge, dx, dy)
  local x, y, w, h = start.x, start.y, start.w, start.h
  if edge == "left" then
    local newW = math.max(1, w - dx)
    x = x + (w - newW)
    w = newW
  elseif edge == "right" then
    w = math.max(1, w + dx)
  elseif edge == "top" then
    local newH = math.max(1, h - dy)
    y = y + (h - newH)
    h = newH
  elseif edge == "bottom" then
    h = math.max(1, h + dy)
  end
  return { x = x, y = y, w = w, h = h }
end

-- ============================================================
-- Gesture state machine
-- ============================================================

function obj:_startDrag(mode, ev)
  -- Use the event's own location, not `hs.mouse.absolutePosition()`.
  -- Inside an eventtap callback the latter returns the cursor as of
  -- event delivery (i.e. the click point) and stays frozen across
  -- subsequent dragged events, producing zero deltas. `ev:location()`
  -- reflects the actual cursor position carried by each event.
  local pt = ev:location()
  local target = windowAtPoint(pt)
  if not target then
    self.logger.d("no window under pointer at mouse-down; ignoring")
    return false
  end
  local startFrame = target:frame()
  local edge = (mode == "resize") and closestEdge(pt, startFrame) or nil
  if self.firstRaise then
    pcall(function() target:focus() end)
  end
  self._drag = {
    mode       = mode,
    window     = target,
    startPt    = { x = pt.x, y = pt.y },
    startFrame = startFrame,
    edge       = edge,
  }
  self.logger.d(string.format(
    "drag started: mode=%s edge=%s frame=(%.0f,%.0f %.0fx%.0f)",
    mode, tostring(edge),
    startFrame.x, startFrame.y, startFrame.w, startFrame.h))
  return true
end

-- Minimum interval between setFrame calls during a resize gesture.
-- Resize is slow in apps that reflow content per setSize (iTerm with
-- tmux is the worst offender — terminal grid recompute per call). At
-- 60Hz drag events the AX queue backlogs and the window visibly lags
-- the cursor. Throttling to ~30Hz keeps responsiveness without losing
-- precision because we always store the latest pointer position and
-- flush it on mouse-up. Move gestures are fast in every app I've
-- tested, so they bypass the throttle.
local RESIZE_THROTTLE_S = 0.033

function obj:_applyDrag(ev)
  local d = self._drag
  if not d then return end
  -- See note in _startDrag: ev:location() carries the current cursor
  -- position; hs.mouse.absolutePosition() freezes at the click point
  -- inside the eventtap callback.
  d.latestPt = ev:location()

  if d.mode == "resize" then
    local now = hs.timer.secondsSinceEpoch()
    if d.lastApplyAt and (now - d.lastApplyAt) < RESIZE_THROTTLE_S then
      return  -- skip; latestPt stored, flushed by mouse-up or next event
    end
    d.lastApplyAt = now
  end

  self:_commit(d.latestPt)
end

local function roundPx(v) return math.floor(v + 0.5) end

function obj:_commit(pt)
  local d = self._drag
  if not d then return end
  local dx, dy = pt.x - d.startPt.x, pt.y - d.startPt.y
  local newFrame
  if d.mode == "move" then
    newFrame = translatedFrame(d.startFrame, dx, dy)
  else
    newFrame = resizedFrame(d.startFrame, d.edge, dx, dy)
  end
  -- Don't ask macOS to put the window's top above the cursor's
  -- current screen's visible area. The WindowServer interprets that
  -- as the "drag to throw the window to the next display" gesture
  -- and teleports the window to that display's centre, ignoring
  -- subsequent setFrame calls. Clamping keeps us in bounds; the user
  -- can still drag a window to another display by moving their
  -- cursor onto that display — `getCurrentScreen()` follows the
  -- cursor, so the clamp follows the new screen's top edge.
  if d.mode == "move" then
    local cursorScreen = hs.mouse.getCurrentScreen()
    if cursorScreen then
      local sf = cursorScreen:frame()
      if newFrame.y < sf.y then newFrame.y = sf.y end
    end
  end
  -- Integer-pixel rounding avoids sub-pixel jitter.
  newFrame.x = roundPx(newFrame.x)
  newFrame.y = roundPx(newFrame.y)
  newFrame.w = roundPx(newFrame.w)
  newFrame.h = roundPx(newFrame.h)
  -- Pass `0` as the duration arg to skip the 0.2s default animation —
  -- without it every drag event schedules an animation that the next
  -- drag event interrupts, backlogging at 60Hz and producing visible
  -- lag.
  local ok, err = pcall(function() d.window:setFrame(newFrame, 0) end)
  if not ok then
    self.logger.w("setFrame failed: " .. tostring(err))
  end
end

function obj:_endDrag()
  local d = self._drag
  if not d then return end
  -- Flush the final cursor position so a resize that was skipped by
  -- the throttle still lands at its intended size.
  if d.mode == "resize" and d.latestPt then
    self:_commit(d.latestPt)
  end
  self.logger.d("drag ended")
  self._drag = nil
end

-- ============================================================
-- Event handler
-- ============================================================

function obj:_handle(ev)
  local T = hs.eventtap.event.types
  local etype = ev:getType()

  if etype == T.tapDisabledByTimeout or etype == T.tapDisabledByUserInput then
    self.logger.w("eventtap was disabled; re-enabling")
    if self._tap then self._tap:start() end
    return false
  end

  -- Releasing modifiers mid-drag aborts cleanly. Releasing them while
  -- not dragging is a no-op (the normal case after every chord).
  if etype == T.flagsChanged then
    if self._drag and not modifiersMatch(ev:getFlags(), self.modifiers) then
      self:_endDrag()
    end
    return false
  end

  -- Mouse-down: arm a new gesture if modifiers match.
  if etype == T.leftMouseDown or etype == T.rightMouseDown then
    if self._drag then
      -- A second button pressed mid-drag is just ignored; the first
      -- gesture wins until its own mouse-up.
      return false
    end
    if not modifiersMatch(ev:getFlags(), self.modifiers) then
      return false
    end
    local mode = (etype == T.leftMouseDown) and "move" or "resize"
    if self:_startDrag(mode, ev) then
      return true  -- consume; we own the drag now
    end
    return false
  end

  -- Drag: only respond to the same-button drags we started.
  if etype == T.leftMouseDragged then
    if self._drag and self._drag.mode == "move" then
      self:_applyDrag(ev)
      return true
    end
    return false
  end
  if etype == T.rightMouseDragged then
    if self._drag and self._drag.mode == "resize" then
      self:_applyDrag(ev)
      return true
    end
    return false
  end

  -- Mouse-up: end whichever gesture we own.
  if etype == T.leftMouseUp then
    if self._drag and self._drag.mode == "move" then
      self:_endDrag()
      return true
    end
    return false
  end
  if etype == T.rightMouseUp then
    if self._drag and self._drag.mode == "resize" then
      self:_endDrag()
      return true
    end
    return false
  end

  return false
end

-- ============================================================
-- Lifecycle
-- ============================================================

--- MouseMoveResizeWindows:start()
--- Method
--- Installs the eventtap. Errors if Hammerspoon does not have
--- Accessibility permission. Idempotent.
---
--- Returns:
---  * self
function obj:start()
  -- Pure-Lua only here. All OS-touching work is deferred — see
  -- `obj.startupDelay` for the cold-start contention rationale.
  if self._startupTimer then self._startupTimer:stop(); self._startupTimer = nil end
  if self._tap then self._tap:stop(); self._tap = nil end

  self._startupTimer = hs.timer.doAfter(self.startupDelay or 3, function()
    self._startupTimer = nil

    if not hs.accessibilityState() then
      self.logger.e("MouseMoveResizeWindows requires Accessibility permission for "
                    .. "Hammerspoon (System Settings -> Privacy & Security -> "
                    .. "Accessibility); spoon not started.")
      return
    end

    local T = hs.eventtap.event.types
    self._tap = hs.eventtap.new({
      T.leftMouseDown, T.leftMouseDragged, T.leftMouseUp,
      T.rightMouseDown, T.rightMouseDragged, T.rightMouseUp,
      T.flagsChanged,
    }, function(ev) return self:_handle(ev) end)
    self._tap:start()

    self.logger.i(string.format(
      "started; modifiers={%s} firstRaise=%s",
      table.concat(self.modifiers or {}, ","),
      tostring(self.firstRaise)))
  end)

  return self
end

--- MouseMoveResizeWindows:stop()
--- Method
--- Stops the eventtap and clears any in-progress drag.
---
--- Returns:
---  * self
function obj:stop()
  if self._startupTimer then self._startupTimer:stop(); self._startupTimer = nil end
  if self._tap then self._tap:stop(); self._tap = nil end
  self._drag = nil
  self.logger.i("stopped")
  return self
end

--- MouseMoveResizeWindows:toggle()
--- Method
--- Toggles the Spoon on/off and shows a brief `hs.alert` banner.
function obj:toggle()
  if self._tap and self._tap:isEnabled() then
    self:stop()
    hs.alert.show("MouseMoveResizeWindows: off")
  else
    self:start()
    hs.alert.show("MouseMoveResizeWindows: on")
  end
end

--- MouseMoveResizeWindows:bindHotkeys(mapping)
--- Method
--- Binds (or rebinds) keyboard shortcuts. Supported action: `toggle`.
--- Calling `bindHotkeys` again clears prior bindings first.
---
--- Parameters:
---  * mapping - table like `{ toggle = {{"shift","ctrl","cmd"}, "w"} }`
---
--- Returns:
---  * self
function obj:bindHotkeys(mapping)
  if self._hotkeys then
    for _, hk in ipairs(self._hotkeys) do hk:delete() end
  end
  self._hotkeys = {}
  local actions = {
    toggle = function() self:toggle() end,
  }
  for name, fn in pairs(actions) do
    if mapping and mapping[name] then
      table.insert(self._hotkeys, hs.hotkey.bindSpec(mapping[name], fn))
    end
  end
  self.logger.i("bindHotkeys: bound " .. #self._hotkeys .. " hotkey(s)")
  return self
end

return obj
