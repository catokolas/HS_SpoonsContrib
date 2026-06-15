--- === MouseCopyPasteSelection ===
---
--- X11-style copy-on-select for macOS: when you release the mouse after
--- dragging across text, or double-click a word, the selection is sent to
--- the clipboard automatically (synthesised Cmd+C). Optionally, middle-
--- clicking inside a text field pastes the clipboard at the click point
--- (synthesised Cmd+V).
---
--- The "is the cursor over text" gate uses `hs.mouse.currentCursorType()`,
--- which returns `"IBeamCursor"` (or `"IBeamCursorForVerticalLayout"`)
--- when the system cursor is the text I-beam — the same NSCursor hot-spot
--- check the original C implementation performs.
---
--- Reimplemented from the standalone myPaste.app (Cato Kolås), itself
--- derived from `lodestone/macpaste`. The Obj-C `CGEventTap` + NSCursor
--- comparison becomes `hs.eventtap` + `hs.mouse.currentCursorType()`; the
--- behaviour is otherwise unchanged.

local obj = {}
obj.__index = obj

-- Metadata
obj.name     = "MouseCopyPasteSelection"
obj.version  = "0.1"
obj.author   = "Cato Kolås <cato.kolas@gmail.com>"
obj.credits  = "Based on https://github.com/lodestone/macpaste"
obj.homepage = "https://github.com/catokolas/HS_SpoonsContrib"
obj.license  = "Unlicense - https://unlicense.org"

--- MouseCopyPasteSelection.doubleClickMs
--- Variable
--- Maximum milliseconds between two leftMouseDown events for the pair to
--- count as a double-click. Defaults to 400, matching myPaste's
--- `DOUBLE_CLICK_MILLIS`.
obj.doubleClickMs = 400

--- MouseCopyPasteSelection.enableMiddleClickPaste
--- Variable
--- If true (default), middle-clicking (mouse button 2) pastes the
--- clipboard at the click location — X11-style. The handler gates on
--- `hs.mouse.currentCursorType()` returning an I-beam, so the
--- synthesised focus-click can only ever land on a text-editable
--- region the OS itself reports as such; it positions the caret and
--- nothing else. Set false to ignore middle-click events entirely.
obj.enableMiddleClickPaste = true

--- MouseCopyPasteSelection.pasteClickDelayUs
--- Variable
--- Microseconds to wait after the synthesised focus-click before the
--- paste keystroke. Defaults to 15000 (15ms), matching myPaste's
--- `usleep(15000)` after the click pair.
obj.pasteClickDelayUs = 15000

--- MouseCopyPasteSelection.pasteTypeDelayUs
--- Variable
--- Additional microseconds slept before the Cmd+V keystroke is issued.
--- Defaults to 1000 (1ms), matching myPaste's second `usleep(1000)`.
obj.pasteTypeDelayUs = 1000

--- MouseCopyPasteSelection.useSeparateSelectionBuffer
--- Variable
--- When `true` (default), copy-on-select fills a private in-memory
--- selection buffer instead of clobbering the system clipboard — the
--- X11 PRIMARY/CLIPBOARD model. The system clipboard is snapshot before
--- the synthesised Cmd+C and restored afterward, so Cmd+V always pastes
--- what the user explicitly Cmd+C'd. Middle-click paste reads from the
--- private buffer.
---
--- Set to `false` to use the legacy shared-clipboard model where
--- copy-on-select writes directly to the system clipboard.
obj.useSeparateSelectionBuffer = true

--- MouseCopyPasteSelection.dragThresholdPx
--- Variable
--- Minimum cursor movement (in pixels, max of |dx|/|dy|) before a drag
--- arms the copy-on-release. Defaults to 5; prevents a tiny accidental
--- 1-2px drag from triggering a copy. Adopted from lodestone/macpaste
--- PR #7.
obj.dragThresholdPx = 5

--- MouseCopyPasteSelection.restoreDelayMs
--- Variable
--- Milliseconds to wait after a synthesised Cmd+V before restoring the
--- user's "real" clipboard. The target app needs time to read the
--- pasteboard during its paste handler; too short and the restore wins
--- the race. Too long and Cmd+V the user types in this window would
--- paste the selection. Defaults to 200. Only used when
--- `useSeparateSelectionBuffer` is `true`.
obj.restoreDelayMs = 200

--- MouseCopyPasteSelection.logger
--- Variable
--- Logger object used within the Spoon. Set its level to control verbosity.
obj.logger = hs.logger.new("MouseCopyPasteSelection")

-- Cursor-type strings that mean "the cursor is over editable text". Both
-- horizontal and vertical-layout I-beams should arm the copy-on-release.
local IBEAM_TYPES = {
  IBeamCursor                  = true,
  IBeamCursorForVerticalLayout = true,
}

-- Sentinel stamped on synthetic events posted by this Spoon (the
-- focus-click pair fired by _synthPaste before Cmd+V).
--
-- Convention shared across this Spoon family: every sibling Spoon that
-- posts synthetic events stamps `eventSourceUserData` with a value in
-- the range `0xC0DE5C00 .. 0xC0DE5CFF`. Low-byte assignments:
--   0x01 = MouseScrollTweaks
--   0x02 = MouseTrackpadTweaks
--   0x03 = MouseCopyPasteSelection (this Spoon)
-- isSiblingSyntheticEvent() below treats anything in that range as
-- "already handled by another tap in the chain, pass through" — so a
-- middle-click that another Spoon synthesised won't re-trigger our
-- paste cycle, and our own focus-click pair won't be misread by our
-- double-click detector as a real user double-click.
local SENTINEL              = 0xC0DE5C03
local SENTINEL_PREFIX_MASK  = 0xFFFFFF00
local SENTINEL_PREFIX_VALUE = 0xC0DE5C00

local function isSiblingSyntheticEvent(usd)
  if not usd then return false end
  return (usd & SENTINEL_PREFIX_MASK) == SENTINEL_PREFIX_VALUE
end

local function isOverText()
  return IBEAM_TYPES[hs.mouse.currentCursorType()] == true
end

--- MouseCopyPasteSelection:configure(configuration)
--- Method
--- Configures the spoon. Accepts any of the public variables
--- (doubleClickMs, enableMiddleClickPaste, pasteClickDelayUs,
--- pasteTypeDelayUs).
---
--- Parameters:
---  * configuration - a table of configuration values to merge into the spoon
---
--- Returns:
---  * self
function obj:configure(configuration)
  for k, v in pairs(configuration or {}) do
    self[k] = v
  end
  return self
end

-- Synthesise Cmd+C. In separate-buffer mode (the default), snapshot the
-- user's real clipboard before the keystroke, wait for the focused app to
-- write the selection out (detected via changeCount), capture the new
-- contents into self._selectionBuffer, then restore the original. In
-- legacy/shared mode just fire Cmd+C and let the selection sit on the
-- system clipboard.
function obj:_synthCopy()
  if not self.useSeparateSelectionBuffer then
    hs.eventtap.keyStroke({"cmd"}, "c", 0)
    return
  end

  local saveBuffer = hs.pasteboard.readAllData()
  local saveCount  = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({"cmd"}, "c", 0)

  -- The captured-and-completed flag protects the safety-timeout from
  -- restoring twice if waitUntil ran first.
  local done = false

  hs.timer.waitUntil(
    function() return done or hs.pasteboard.changeCount() ~= saveCount end,
    function()
      if done then return end
      done = true
      self._selectionBuffer = hs.pasteboard.readAllData()
      hs.pasteboard.writeAllData(saveBuffer)
      self.logger.d("synth Cmd+C: captured selection, restored clipboard")
    end,
    0.01
  )

  -- Safety timeout: if the focused app never wrote to the pasteboard
  -- (nothing selected, app swallowed the shortcut, etc.) abandon the
  -- watcher rather than letting it poll forever.
  hs.timer.doAfter(0.2, function()
    if done then return end
    done = true
    self.logger.d("synth Cmd+C: no pasteboard change within 200ms; giving up")
  end)
end

-- Mirrors myPaste/main.m paste(): click at the cursor to focus and place
-- the caret, then a Cmd+V keystroke. The two usleeps reproduce the same
-- timing the C version uses to let WindowServer settle.
--
-- In separate-buffer mode we additionally swap the private selection
-- buffer onto the general pasteboard before the keystroke and schedule a
-- restore of the user's real clipboard restoreDelayMs after — so a Cmd+V
-- the user types later still pastes their real clipboard, not the
-- selection.
function obj:_synthPaste(ev)
  local loc = ev:location()
  local T   = hs.eventtap.event.types

  local saveBuffer, postPasteCount
  if self.useSeparateSelectionBuffer then
    if not self._selectionBuffer then
      self.logger.d("middle-click paste: empty selection buffer; using system clipboard")
    else
      saveBuffer = hs.pasteboard.readAllData()
      hs.pasteboard.writeAllData(self._selectionBuffer)
    end
  end

  -- Stamp the synthetic focus-click pair so siblings (and our own
  -- _handle below) can recognise these as "not a real user click".
  local P = hs.eventtap.event.properties
  local down = hs.eventtap.event.newMouseEvent(T.leftMouseDown, loc)
  local up   = hs.eventtap.event.newMouseEvent(T.leftMouseUp,   loc)
  down:setProperty(P.eventSourceUserData, SENTINEL)
  up  :setProperty(P.eventSourceUserData, SENTINEL)
  down:post()
  up:post()
  hs.timer.usleep(self.pasteClickDelayUs)
  hs.timer.usleep(self.pasteTypeDelayUs)
  hs.eventtap.keyStroke({"cmd"}, "v", 0)

  if saveBuffer then
    -- Note the count right after we wrote the selection. If something
    -- else bumps it before our restore fires (e.g. user Cmd+Cs new
    -- content), skip the restore rather than clobbering the new value.
    postPasteCount = hs.pasteboard.changeCount()
    hs.timer.doAfter(self.restoreDelayMs / 1000, function()
      if hs.pasteboard.changeCount() ~= postPasteCount then
        self.logger.d("middle-click paste: clipboard changed externally; skip restore")
        return
      end
      hs.pasteboard.writeAllData(saveBuffer)
      self.logger.d("middle-click paste: restored real clipboard")
    end)
  end
end

function obj:_handle(ev)
  local T = hs.eventtap.event.types
  local etype = ev:getType()

  -- WindowServer can drop the tap if a callback misbehaves or a long-
  -- running operation blocks the runloop. Re-arm in place rather than
  -- losing the feature for the rest of the session.
  if etype == T.tapDisabledByTimeout or etype == T.tapDisabledByUserInput then
    self.logger.w("eventtap was disabled; re-enabling")
    if self._tap then self._tap:start() end
    return false, {}
  end

  -- The leftMouse* paths feed the double-click detector and the
  -- copy-on-drag arm. They must ignore synthetic clicks (ours or any
  -- sibling Spoon's) so the focus-click pair _synthPaste emits doesn't
  -- get misread as a real user gesture. The otherMouseDown branch
  -- below is NOT gated — a middle-click that MouseTrackpadTweaks
  -- synthesised (1-finger top-center, 3-finger tap, …) should still
  -- trigger a paste, exactly like a hardware middle-click does.
  local P = hs.eventtap.event.properties
  local isSibling = isSiblingSyntheticEvent(ev:getProperty(P.eventSourceUserData))

  if etype == T.leftMouseDown then
    if isSibling then return false, {} end
    self._prevClickMs  = self._curClickMs
    self._curClickMs   = hs.timer.absoluteTime() / 1e6   -- ns -> ms
    self._dragStartLoc = ev:location()

  elseif etype == T.leftMouseUp then
    if isSibling then return false, {} end
    local isDouble = (self._curClickMs - self._prevClickMs) < self.doubleClickMs
    if isDouble then
      self.logger.d("copy - doubleclick")
      self:_synthCopy()
    elseif self._isDragging then
      self.logger.d("copy - was dragging")
      self:_synthCopy()
      self._isDragging = false
    end

  elseif etype == T.leftMouseDragged then
    if isSibling then return false, {} end
    if not self._isDragging and isOverText() and self._dragStartLoc then
      local loc = ev:location()
      local dx  = math.abs(loc.x - self._dragStartLoc.x)
      local dy  = math.abs(loc.y - self._dragStartLoc.y)
      if math.max(dx, dy) > self.dragThresholdPx then
        self.logger.d("start dragging")
        self._isDragging = true
      end
    end

  elseif etype == T.otherMouseDown then
    local btn = ev:getProperty(hs.eventtap.event.properties.mouseEventButtonNumber)
    local overText = isOverText()
    self.logger.d(string.format(
      "otherMouseDown received: btn=%s overText=%s sibling=%s",
      tostring(btn), tostring(overText), tostring(isSibling)))
    if btn == 2 and overText then
      self.logger.d("middle-click paste fired")
      self:_synthPaste(ev)
    end
  end

  return false, {}
end

--- MouseCopyPasteSelection:start()
--- Method
--- Starts the event tap. Drag-to-select and double-click in text fields
--- will now copy automatically. Middle-click paste is also active if
--- `enableMiddleClickPaste` is true.
---
--- Errors loudly if Hammerspoon doesn't have Accessibility permission,
--- since `hs.eventtap` silently fails without it.
---
--- Returns:
---  * self
function obj:start()
  if not hs.accessibilityState() then
    error("MouseCopyPasteSelection requires Accessibility permission for "
          .. "Hammerspoon (System Settings -> Privacy & Security -> "
          .. "Accessibility).", 2)
  end

  self._prevClickMs  = 0
  self._curClickMs   = 0
  self._isDragging   = false
  self._dragStartLoc = nil
  -- _selectionBuffer intentionally NOT cleared on (re)start so toggling
  -- the tap off and on doesn't lose the most-recent selection.

  local T = hs.eventtap.event.types
  local mask = { T.leftMouseDown, T.leftMouseUp, T.leftMouseDragged }
  if self.enableMiddleClickPaste then
    table.insert(mask, T.otherMouseDown)
  end

  self._tap = hs.eventtap.new(mask, function(ev) return self:_handle(ev) end)
  self._tap:start()
  self.logger.i("started; middleClickPaste=" .. tostring(self.enableMiddleClickPaste))
  return self
end

--- MouseCopyPasteSelection:stop()
--- Method
--- Stops the event tap. Copy-on-select and middle-click-paste both stop.
---
--- Returns:
---  * self
function obj:stop()
  if self._tap then self._tap:stop(); self._tap = nil end
  self.logger.i("stopped")
  return self
end

--- MouseCopyPasteSelection:toggle()
--- Method
--- Toggles the event tap on/off and shows a brief `hs.alert` banner so
--- the user can tell which state they're in without checking the
--- console. Useful as a hotkey binding when typing in apps where the
--- middle-click paste or the copy-on-release would get in the way.
function obj:toggle()
  if self._tap and self._tap:isEnabled() then
    self:stop()
    hs.alert.show("MouseCopyPasteSelection: off")
  else
    self:start()
    hs.alert.show("MouseCopyPasteSelection: on")
  end
end

--- MouseCopyPasteSelection:getSelection()
--- Method
--- Returns the most recent copy-on-select text from the private
--- selection buffer, or `nil` if the buffer is empty (no selection has
--- happened yet, or `useSeparateSelectionBuffer` is `false`).
---
--- Returns:
---  * string or nil
function obj:getSelection()
  if not self._selectionBuffer then return nil end
  return self._selectionBuffer["public.utf8-plain-text"]
      or self._selectionBuffer["public.plain-text"]
end

--- MouseCopyPasteSelection:bindHotkeys(mapping)
--- Method
--- Binds (or rebinds) keyboard shortcuts. The mapping table accepts a
--- `toggle` key with a `{mods, key}` pair compatible with
--- `hs.hotkey.bindSpec`. Calling `bindHotkeys` again clears prior
--- bindings first.
---
--- Parameters:
---  * mapping - table like `{ toggle = {{"cmd","alt"}, "p"} }`
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
