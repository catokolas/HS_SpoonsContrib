--- === MouseTrackpadTweaks ===
---
--- Per-device input tweaks for Magic Mouse and the built-in Trackpad
--- that macOS doesn't expose itself:
---
--- 1. **Magic-Mouse-only scroll inversion.** Flips vertical (and
---    optionally horizontal) scroll for the Magic Mouse without
---    touching trackpad scrolling — useful when the trackpad is set to
---    "Natural" and the mouse should scroll the other way.
--- 2. **Middle-click synthesis.** Fires a middle-click on either
---    (a) ≥ N-finger tap or click, or (b) 1-finger tap or click inside
---    a configurable top-center region of the device surface. Both the
---    Magic Mouse and the Trackpad are supported. Each trigger mode's
---    "tap vs. click vs. either" can be configured independently.
---
--- ## Companion native module
---
--- Attribution of scroll events to a specific physical device, and
--- multi-finger touch counting, are not exposed by Hammerspoon's pure
--- Lua API. Both features depend on an optional native module,
--- `hs._ckol.multitouch`, that wraps `MultitouchSupport.framework`.
--- When the module is not installed, the Spoon loads cleanly, logs a
--- warning, and lets all events pass through unmodified.
---
--- ## Coexistence with MouseScrollTweaks
---
--- `MouseScrollTweaks.spoon` taps scrollWheel events but passes
--- continuous-scroll events (trackpad / Magic Mouse) through untouched
--- via `scrollWheelEventIsContinuous`. This Spoon only touches
--- continuous-scroll events on the Magic Mouse and ignores discrete
--- wheel events, so the two Spoons do not interact. Each stamps its
--- own sentinel on synthetic events to prevent self re-entry.

local obj = {}
obj.__index = obj

-- Metadata
obj.name     = "MouseTrackpadTweaks"
obj.version  = "0.1"
obj.author   = "Cato Kolås <cato.kolas@gmail.com>"
obj.credits  = ""
obj.homepage = "https://github.com/catokolas/HS_SpoonsContrib"
obj.license  = "MIT - https://opensource.org/licenses/MIT"

--- MouseTrackpadTweaks.invertVertical
--- Variable
--- If true (default), Magic Mouse vertical scroll direction is flipped.
--- Trackpad scrolling is unaffected.
obj.invertVertical = true

--- MouseTrackpadTweaks.invertHorizontal
--- Variable
--- If true (default), Magic Mouse horizontal scroll direction is flipped
--- — matching the vertical default so the mouse scrolls "Traditional"
--- on both axes regardless of the system's "Natural" trackpad setting.
obj.invertHorizontal = true

--- MouseTrackpadTweaks.middleClick
--- Variable
--- Middle-click synthesis configuration. Two trigger modes, each with
--- an independently-configurable trigger type:
---
--- ```
--- middleClick = {
---   enabled = true,
---
---   multiFinger = {
---     enabled     = true,
---     fingerCount = 3,            -- ≥ this many fingers fires middle-click
---     trigger     = "either",     -- "tap" | "click" | "either"
---   },
---
---   topCenter = {
---     enabled = true,
---     devices = { magicMouse = true, trackpad = true },
---     trigger = "either",         -- "tap" | "click" | "either"
---     xMin = 0.30, xMax = 0.70,   -- normalized fractions of the
---     yMin = 0.00, yMax = 0.30,   -- device surface (0,0 = top-left)
---   },
---
---   tap = {                       -- shared tap-validity thresholds
---     maxDurationMs = 200,
---     maxTravelPx   = 12,         -- cursor travel during the tap
---   },
--- }
--- ```
obj.middleClick = {
  enabled = true,

  multiFinger = {
    enabled     = true,
    fingerCount = 3,
    trigger     = "either",
    -- Only count touches that BEGAN this recently before the click.
    -- Magic Mouse routinely reports 2-3 passive contacts (pointing
    -- finger + hand-rest + thumb) just from how the user grips it; a
    -- naive total-count check fires middle-click on any normal click.
    -- An age gate filters those resting contacts out.
    maxAgeMs    = 1500,
  },

  topCenter = {
    enabled = true,
    devices = { magicMouse = true, trackpad = true },
    trigger = "either",
    xMin = 0.30, xMax = 0.70,
    yMin = 0.00, yMax = 0.30,
    -- An in-region touch only counts as a deliberate middle-click
    -- placement if it BEGAN this recently before the click. Naturally-
    -- resting fingers (Magic Mouse grip) have been on the surface for
    -- seconds and will be filtered out.
    maxAgeMs = 1500,
  },

  tap = {
    maxDurationMs    = 200,
    maxTravelPx      = 12,    -- screen-cursor travel during the touch
    maxSurfaceTravel = 0.05,  -- max normalized surface travel of any
                              -- touch in the session. Catches Magic
                              -- Mouse scrolls (finger slides across
                              -- the surface while cursor stays put).
  },
}

--- MouseTrackpadTweaks.logger
--- Variable
--- Logger object used within the Spoon. Set its level (e.g.
--- `spoon.MouseTrackpadTweaks.logger.setLogLevel("debug")`) to trace
--- touch sessions and middle-click decisions.
obj.logger = hs.logger.new("MouseTrackpadTweaks")

--- MouseTrackpadTweaks.startupDelay
--- Variable
--- Seconds to defer the `hs.eventtap.new`/`:start()` call inside
--- `:start()`. The accessibility probe and the multitouch shim
--- startup intentionally remain synchronous.
---
--- Why defer the eventtap: Hammerspoon's reload runs every Spoon's
--- `:start()` in tight succession on the main thread. The
--- simultaneous `CGEventTapCreate` XPC handshakes across multiple
--- Mouse-* spoons contend with other main-thread cold-start work
--- (notably NSURLSession's first-call init) enough to stall
--- one-shot timers in *other* Spoons for tens of seconds —
--- ModelsUsage in particular loses its KIX-request timeout.
--- Pushing the tap registration a few seconds past the reload
--- storm avoids being part of that contention.
---
--- Why NOT defer the multitouch shim: `hs._ckol.multitouch` has no
--- C-level `__gc` cleanup for its native MultitouchSupport callback,
--- so a stale callback from the previous Lua state survives
--- `hs.reload()` and crashes Hammerspoon on the next touch (LuaSkin
--- `pushLuaRef:ref:` assertion) during the deferral window. Starting
--- the shim synchronously in the new state replaces the stale
--- callback before any touch can arrive. `hs.eventtap` does not have
--- this problem because its C wrapper detaches the tap on teardown.
---
--- Default 3.3 is staggered against the other Mouse-* spoons
--- (3.0 / 3.6 / 3.9) so their deferred OS calls don't all land in
--- the same run-loop tick. Set to 0 to disable the eventtap defer.
obj.startupDelay = 3.3

-- Internal state — not part of the public API.
obj._tap          = nil    -- shared eventtap (scroll + click)
obj._mt           = nil    -- hs._ckol.multitouch module ref, or nil
obj._mtStarted    = false
obj._touches      = {}     -- [deviceId] = { kind, byId, count, session }
obj._lastTouch    = { kind = nil, id = nil, atS = 0 }
obj._clickPending = false  -- intercepted leftMouseDown awaiting its leftMouseUp
obj._scrollStreamIsMagicMouse = false  -- locked at scrollPhase=Began; cleared
                                       -- at momentumPhase=End. Drives whether
                                       -- the current continuous-scroll stream
                                       -- (including its momentum tail) is
                                       -- inverted.
obj._hotkeys      = {}

-- Sentinel stamped on synthetic events to prevent self re-entry on the
-- eventtap.
--
-- Convention shared across this Spoon family: every sibling Spoon that
-- posts synthetic events stamps `eventSourceUserData` with a value in
-- the range `0xC0DE5C00 .. 0xC0DE5CFF`. Low-byte assignments:
--   0x01 = MouseScrollTweaks
--   0x02 = MouseTrackpadTweaks (this Spoon)
--   0x03 = MouseCopyPasteSelection
-- isSiblingSyntheticEvent() below treats anything in that range as
-- "already handled by another tap in the chain, pass through" — so we
-- never double-process a wheel event MouseScrollTweaks already
-- inverted, and the focus-click pair MouseCopyPasteSelection emits
-- after a middle-click doesn't re-trigger our own conversion.
-- New Spoons in this collection should pick an unused byte in the
-- range and document it in every family member.
local SENTINEL              = 0xC0DE5C02
local SENTINEL_PREFIX_MASK  = 0xFFFFFF00
local SENTINEL_PREFIX_VALUE = 0xC0DE5C00

local function isSiblingSyntheticEvent(usd)
  if not usd then return false end
  return (usd & SENTINEL_PREFIX_MASK) == SENTINEL_PREFIX_VALUE
end

-- Belt-and-suspenders synchronous re-entry guard. The sibling-prefix
-- gate on eventSourceUserData handles the common case (events we or a
-- sibling Spoon synthesised), but if the OS were ever to deliver our
-- own otherMouseDown back through this tap on the same call stack
-- (e.g. as a leftMouseDown reclassification) the flag rejects it
-- immediately. Set before emit, cleared after.
local emittingMiddleClick = false

-- Window during which a recently-ended touch still attributes incoming
-- scroll events to its device. Tuned for the ~tens-of-ms gap between
-- the final touch-ended frame and a trailing scrollWheel event.
local RECENT_TOUCH_S = 0.20

local nowS = hs.timer.secondsSinceEpoch

local function deepMerge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then
      deepMerge(dst[k], v)
    else
      dst[k] = v
    end
  end
end

--- MouseTrackpadTweaks:configure(configuration)
--- Method
--- Deep-merges configuration values into the spoon. Accepts any of the
--- public variables; nested sub-tables (e.g.
--- `middleClick.multiFinger.fingerCount`) merge recursively, so partial
--- overrides leave the rest of the defaults intact.
---
--- Parameters:
---  * configuration - a table of configuration values to merge into the spoon
---
--- Returns:
---  * self
function obj:configure(configuration)
  if configuration then deepMerge(self, configuration) end
  return self
end

-- ============================================================
-- Touch tracking
-- ============================================================

local function getDeviceState(self, deviceId, deviceKind)
  local d = self._touches[deviceId]
  if not d then
    d = { kind = deviceKind, byId = {}, count = 0, session = nil }
    self._touches[deviceId] = d
  else
    d.kind = deviceKind
  end
  return d
end

local function startSession(d, ts, nx, ny)
  local pos = hs.mouse.absolutePosition()
  d.session = {
    beganAtS         = ts,
    maxCount         = d.count,
    startMouseX      = pos and pos.x or 0,
    startMouseY      = pos and pos.y or 0,
    clickOccurred    = false,
    firstTouch       = { beganNx = nx, beganNy = ny },
    allTouches       = {},  -- [touchId] = { beganNx, beganNy }, kept
                            -- through touch-ended so the session-end
                            -- evaluator can count touches that were
                            -- inside the topCenter region (Magic Mouse
                            -- registers passive palm/hand contacts
                            -- alongside the intentional finger).
    maxSurfaceSq     = 0,   -- max squared normalized travel of any
                            -- touch from its own start position
  }
end

local function bumpSurfaceTravel(session, t, nx, ny)
  if not session or not t then return end
  local dx = nx - t.beganNx
  local dy = ny - t.beganNy
  local d2 = dx * dx + dy * dy
  if d2 > session.maxSurfaceSq then session.maxSurfaceSq = d2 end
end

local function pointInTopCenter(self, kind, nx, ny)
  local r = self.middleClick.topCenter
  if not r.enabled or not r.devices[kind] then return false end
  return nx and ny
     and nx >= r.xMin and nx <= r.xMax
     and ny >= r.yMin and ny <= r.yMax
end

-- Update a touch's "is currently inside topCenter" and "last entered
-- the region at" timestamps. Called from `began` (using initial pos)
-- and `moved` (using current pos). The entry timestamp resets on each
-- outside→inside transition, so sliding a long-resting finger into the
-- region counts as a fresh placement.
local function updateRegionTracking(self, kind, t, nx, ny, now)
  if not t then return end
  local nowIn = pointInTopCenter(self, kind, nx, ny)
  if nowIn and not t.inRegion then
    t.enteredRegionAtS = now
  end
  t.inRegion = nowIn
end

function obj:_onTouch(deviceId, deviceKind, touchId, phase, nx, ny, _ts)
  local d = getDeviceState(self, deviceId, deviceKind)
  local now = nowS()

  if phase == "began" then
    if not d.byId[touchId] then
      d.byId[touchId] = {
        beganNx = nx, beganNy = ny,
        lastNx  = nx, lastNy  = ny,
        beganAtS = now,
        inRegion = false,           -- set by updateRegionTracking below
        enteredRegionAtS = 0,
      }
      d.count = d.count + 1
      updateRegionTracking(self, deviceKind, d.byId[touchId], nx, ny, now)
    end
    if not d.session then
      startSession(d, now, nx, ny)
    elseif d.count > d.session.maxCount then
      d.session.maxCount = d.count
    end
    if d.session then
      d.session.allTouches[touchId] = { beganNx = nx, beganNy = ny }
    end
    self._lastTouch.kind, self._lastTouch.id, self._lastTouch.atS = deviceKind, deviceId, now

  elseif phase == "moved" then
    local t = d.byId[touchId]
    if t then
      t.lastNx, t.lastNy = nx, ny
      bumpSurfaceTravel(d.session, t, nx, ny)
      updateRegionTracking(self, deviceKind, t, nx, ny, now)
    end
    self._lastTouch.kind, self._lastTouch.id, self._lastTouch.atS = deviceKind, deviceId, now

  elseif phase == "ended" or phase == "cancelled" then
    local t = d.byId[touchId]
    if t then
      bumpSurfaceTravel(d.session, t, nx, ny)
      d.byId[touchId] = nil
      d.count = d.count - 1
    end
    if d.count <= 0 then
      d.count = 0
      local s = d.session
      d.session = nil
      if s and phase == "ended" then
        self:_evaluateTap(deviceKind, s)
      end
    end
    self._lastTouch.kind, self._lastTouch.id, self._lastTouch.atS = deviceKind, deviceId, now
  end
end

-- ============================================================
-- Region check
-- ============================================================

local function inTopCenter(self, kind, nx, ny)
  local r = self.middleClick.topCenter
  if not r.enabled then return false end
  if not r.devices[kind] then return false end
  return nx and ny
     and nx >= r.xMin and nx <= r.xMax
     and ny >= r.yMin and ny <= r.yMax
end

-- Count touches (from any iterable map of `{ beganNx, beganNy }`)
-- whose BEGAN position falls inside the topCenter region for the given
-- device kind. Region's enabled / devices gates are honoured.
local function countInTopCenter(self, kind, touches)
  local r = self.middleClick.topCenter
  if not r.enabled or not r.devices[kind] then return 0 end
  local c = 0
  for _, t in pairs(touches) do
    if t.beganNx and t.beganNy
       and t.beganNx >= r.xMin and t.beganNx <= r.xMax
       and t.beganNy >= r.yMin and t.beganNy <= r.yMax then
      c = c + 1
    end
  end
  return c
end

-- Live count of active touches that are CURRENTLY inside topCenter
-- and entered the region recently (`topCenter.maxAgeMs`). Tracking
-- entry time lets a long-resting touch that slides into the region
-- count as a deliberate placement — vs. a touch that's been resting
-- inside the region for seconds (Magic Mouse passive contacts), which
-- has its entry timestamp far enough in the past to fail the gate.
local function countActiveInTopCenter(self, kind)
  local r = self.middleClick.topCenter
  if not r.enabled or not r.devices[kind] then return 0 end
  local maxAgeS = (r.maxAgeMs or 1500) / 1000
  local now = nowS()
  local c = 0
  for _, d in pairs(self._touches) do
    if d.kind == kind then
      for _, t in pairs(d.byId) do
        if t.inRegion
           and t.enteredRegionAtS and t.enteredRegionAtS > 0
           and (now - t.enteredRegionAtS) <= maxAgeS then
          c = c + 1
        end
      end
    end
  end
  return c
end

-- Live count of fresh active touches on a device of `kind`, regardless
-- of position. Same freshness gate as countActiveInTopCenter — drops
-- the passive hand-rest contacts the Magic Mouse always reports while
-- the user is holding it. Used by the multiFinger click trigger.
local function countActiveFreshTouches(self, kind)
  local mf = self.middleClick.multiFinger
  if not mf.enabled then return 0 end
  local maxAgeS = (mf.maxAgeMs or 1500) / 1000
  local now = nowS()
  local c = 0
  for _, d in pairs(self._touches) do
    if d.kind == kind then
      for _, t in pairs(d.byId) do
        if t.beganAtS and (now - t.beganAtS) <= maxAgeS then
          c = c + 1
        end
      end
    end
  end
  return c
end

-- ============================================================
-- Middle-click emission
-- ============================================================

local function newMiddleEvent(etype, x, y)
  local P = hs.eventtap.event.properties
  local e = hs.eventtap.event.newMouseEvent(etype, { x = x, y = y }, {})
  e:setProperty(P.mouseEventButtonNumber, 2)
  e:setProperty(P.eventSourceUserData, SENTINEL)
  return e
end

local function emitMiddleDown(x, y)
  newMiddleEvent(hs.eventtap.event.types.otherMouseDown, x, y):post()
end

local function emitMiddleUp(x, y)
  newMiddleEvent(hs.eventtap.event.types.otherMouseUp, x, y):post()
end

local function emitMiddleClickPair(self, x, y)
  emittingMiddleClick = true
  emitMiddleDown(x, y)
  emitMiddleUp(x, y)
  emittingMiddleClick = false
  self.logger.d(string.format("middle-click emitted via tap at (%.0f,%.0f)", x, y))
end

-- ============================================================
-- Tap evaluation (touch-session ended with no click)
-- ============================================================

local function triggerAllowsTap(trigger)
  return trigger == "tap" or trigger == "either"
end

local function triggerAllowsClick(trigger)
  return trigger == "click" or trigger == "either"
end

function obj:_evaluateTap(kind, session)
  local mc = self.middleClick
  if not mc.enabled then return end
  if session.clickOccurred then return end

  -- Shared validity gates.
  local durMs = (nowS() - session.beganAtS) * 1000
  if durMs > mc.tap.maxDurationMs then return end

  -- Reject anything that slid on the device surface (Magic Mouse
  -- scrolling, trackpad swipe, etc.). The cursor-travel check below
  -- doesn't catch Magic Mouse scrolls because the cursor stays put
  -- while the finger moves across the surface.
  local maxSurf = mc.tap.maxSurfaceTravel or 0.05
  if session.maxSurfaceSq > (maxSurf * maxSurf) then return end

  local pos = hs.mouse.absolutePosition()
  local px = pos and pos.x or 0
  local py = pos and pos.y or 0
  local dx, dy = px - session.startMouseX, py - session.startMouseY
  if (dx * dx + dy * dy) > (mc.tap.maxTravelPx * mc.tap.maxTravelPx) then return end

  -- multiFinger first; topCenter only if multiFinger didn't match (fire-once).
  local mf = mc.multiFinger
  if mf.enabled and triggerAllowsTap(mf.trigger)
     and session.maxCount >= mf.fingerCount then
    emitMiddleClickPair(self, px, py)
    return
  end

  local tc = mc.topCenter
  if tc.enabled and triggerAllowsTap(tc.trigger) and tc.devices[kind] then
    -- "Exactly one touch BEGAN inside the region" — tolerates passive
    -- contacts (palm, hand-rest) outside the region, which Magic Mouse
    -- almost always reports alongside an intentional finger.
    if countInTopCenter(self, kind, session.allTouches) == 1 then
      emitMiddleClickPair(self, px, py)
    end
  end
end

-- ============================================================
-- Active touch snapshot (used at click time)
-- ============================================================

local function activeTouchSnapshot(self)
  -- Pick the device with the most active touches; tie-break by most
  -- recent activity. Returns nil if no device has active touches.
  local best
  for _, d in pairs(self._touches) do
    if d.count > 0 then
      if not best or d.count > best.count then best = d end
    end
  end
  if not best then return nil end
  return {
    kind       = best.kind,
    count      = best.count,
    firstTouch = best.session and best.session.firstTouch or nil,
  }
end

-- ============================================================
-- Eventtap handlers
-- ============================================================

-- CGScrollPhase values (see CGEventTypes.h):
--   1 = kCGScrollPhaseBegan        2 = kCGScrollPhaseChanged
--   4 = kCGScrollPhaseEnded        8 = kCGScrollPhaseCancelled
--   128 = kCGScrollPhaseMayBegin
-- CGMomentumScrollPhase:
--   0 = none  1 = begin  2 = continue  3 = end
local SCROLL_PHASE_BEGAN     = 1
local SCROLL_PHASE_MAYBEGIN  = 128
local SCROLL_PHASE_ENDED     = 4
local SCROLL_PHASE_CANCELLED = 8
local MOMENTUM_PHASE_BEGIN   = 1
local MOMENTUM_PHASE_END     = 3

function obj:_handleScroll(ev)
  local P = hs.eventtap.event.properties
  if isSiblingSyntheticEvent(ev:getProperty(P.eventSourceUserData)) then
    return false
  end
  if ev:getProperty(P.scrollWheelEventIsContinuous) == 0 then return false end
  if not (self.invertVertical or self.invertHorizontal) then return false end
  if not self._mt then return false end

  local phase = ev:getProperty(P.scrollWheelEventScrollPhase)    or 0
  local mom   = ev:getProperty(P.scrollWheelEventMomentumPhase)  or 0

  -- Decide whether this whole scroll stream (active gesture + momentum
  -- tail) is a Magic Mouse scroll. Lock the decision at gesture-begin
  -- based on live touch attribution; hold through the momentum tail
  -- (where no finger is on the surface, so the touch snapshot is
  -- empty and the 200ms recency window has already expired by the
  -- time the first momentum frame arrives).
  if phase == SCROLL_PHASE_BEGAN or phase == SCROLL_PHASE_MAYBEGIN then
    local snap = activeTouchSnapshot(self)
    local kind = snap and snap.kind
    if not kind and self._lastTouch.kind
       and (nowS() - self._lastTouch.atS) < RECENT_TOUCH_S then
      kind = self._lastTouch.kind
    end
    self._scrollStreamIsMagicMouse = (kind == "magicMouse")
  end

  -- Phase-less continuous scroll (rare on Magic Mouse but possible
  -- from other sources): fall back to live touch attribution so we
  -- don't carry a stale stream flag forward.
  if phase == 0 and mom == 0 and not self._scrollStreamIsMagicMouse then
    local snap = activeTouchSnapshot(self)
    local kind = snap and snap.kind
    if not kind and self._lastTouch.kind
       and (nowS() - self._lastTouch.atS) < RECENT_TOUCH_S then
      kind = self._lastTouch.kind
    end
    if kind == "magicMouse" then self._scrollStreamIsMagicMouse = true end
  end

  if not self._scrollStreamIsMagicMouse then return false end

  -- Clear the flag AFTER processing the momentum-end event, so the
  -- final event itself still gets flipped. We deliberately do NOT
  -- clear on scrollPhase=Ended, because momentum follows immediately
  -- afterwards (with scrollPhase=0, mom=Begin) and we want to keep
  -- inverting through the whole tail. If no momentum follows, the
  -- flag stays set until the next scrollPhase=Began re-attributes it.
  local clearAfter = (mom == MOMENTUM_PHASE_END)

  local function fy(v) return self.invertVertical   and -v or v end
  local function fx(v) return self.invertHorizontal and -v or v end

  -- Mutate the original event in place and let it pass through. Every
  -- delta variant (line / point / fixed-point, both axes) is overwritten
  -- so no app reads a stale unmutated value — the failure mode the old
  -- "build a fresh event with newScrollEvent + post" path was working
  -- around. That path traded the stale-variant bug for a worse one:
  -- newScrollEvent gives the replacement event a new source, timestamp,
  -- and gesture identity, which breaks the per-gesture grouping apps
  -- use to render the momentum tail as a continuous glide. Pass-through
  -- preserves all of it (source, timestamp, scroll-phase, momentum
  -- phase, scroll count, gesture id) and only changes the sign of the
  -- deltas, so the tail renders the same as it would without the Spoon.
  local lineY  = ev:getProperty(P.scrollWheelEventDeltaAxis1)        or 0
  local lineX  = ev:getProperty(P.scrollWheelEventDeltaAxis2)        or 0
  local pointY = ev:getProperty(P.scrollWheelEventPointDeltaAxis1)   or 0
  local pointX = ev:getProperty(P.scrollWheelEventPointDeltaAxis2)   or 0
  local fixedY = ev:getProperty(P.scrollWheelEventFixedPtDeltaAxis1) or 0
  local fixedX = ev:getProperty(P.scrollWheelEventFixedPtDeltaAxis2) or 0

  ev:setProperty(P.scrollWheelEventDeltaAxis1,        fy(lineY))
  ev:setProperty(P.scrollWheelEventDeltaAxis2,        fx(lineX))
  ev:setProperty(P.scrollWheelEventPointDeltaAxis1,   fy(pointY))
  ev:setProperty(P.scrollWheelEventPointDeltaAxis2,   fx(pointX))
  ev:setProperty(P.scrollWheelEventFixedPtDeltaAxis1, fy(fixedY))
  ev:setProperty(P.scrollWheelEventFixedPtDeltaAxis2, fx(fixedX))

  self.logger.d(string.format("magic-mouse scroll inverted (V=%s H=%s ph=%d mom=%d)",
    tostring(self.invertVertical), tostring(self.invertHorizontal),
    phase, mom))
  if clearAfter then self._scrollStreamIsMagicMouse = false end
  return false
end

function obj:_handleLeftDown(ev)
  if emittingMiddleClick then return false end
  local P = hs.eventtap.event.properties
  if isSiblingSyntheticEvent(ev:getProperty(P.eventSourceUserData)) then
    return false
  end

  local mc = self.middleClick
  if not mc.enabled then return false end

  local clickState = ev:getProperty(P.mouseEventClickState) or 1
  local snap = activeTouchSnapshot(self)
  local activeInRegion = snap and countActiveInTopCenter(self, snap.kind) or 0
  local freshTotal     = snap and countActiveFreshTouches(self, snap.kind) or 0

  -- Debug-level dump: where each active touch is right now, whether
  -- it's inside the configured topCenter rectangle, and how fresh its
  -- region-entry is. Lets the user see at a glance why a click did or
  -- didn't qualify as a middle-click. Bump the logger to "debug" via
  --   spoon.MouseTrackpadTweaks.logger.setLogLevel("debug")
  -- to see these lines.
  if snap and self.logger.getLogLevel() >= 4 then  -- 4 == "debug"
    local r = mc.topCenter
    local now = nowS()
    local maxAgeS = (r.maxAgeMs or 1500) / 1000
    local parts = {}
    for _, d in pairs(self._touches) do
      if d.kind == snap.kind then
        for tid, t in pairs(d.byId) do
          local entryAge = (t.enteredRegionAtS and t.enteredRegionAtS > 0)
            and (now - t.enteredRegionAtS) or nil
          table.insert(parts, string.format(
            "[id=%s nx=%.2f ny=%.2f inRegion=%s entryAge=%s]",
            tostring(tid), t.lastNx or 0, t.lastNy or 0,
            tostring(t.inRegion),
            entryAge and string.format("%.2fs", entryAge) or "-"))
        end
      end
    end
    self.logger.d(string.format(
      "leftMouseDown on %s: region=[x=%.2f..%.2f y=%.2f..%.2f maxAge=%.2fs] "
      .. "clickState=%s count=%d freshTotal=%d inRegionFresh=%d touches=%s",
      snap.kind,
      r.xMin, r.xMax, r.yMin, r.yMax, maxAgeS,
      tostring(clickState),
      snap.count, freshTotal, activeInRegion,
      (#parts > 0) and table.concat(parts, " ") or "(none)"))
  end

  -- Skip secondary clicks in a multi-click sequence so that
  -- double-click-to-select-word and triple-click-to-select-line aren't
  -- converted into double/triple middle-clicks → double/triple paste.
  -- Only the first click in a rapid sequence has clickState == 1.
  if clickState > 1 then return false end

  if not snap then return false end  -- no touches: normal click

  -- Mark the click on every device's open session so a trailing
  -- touch-end doesn't double-fire a tap.
  for _, d in pairs(self._touches) do
    if d.session then d.session.clickOccurred = true end
  end

  local shouldMiddle = false

  local mf = mc.multiFinger
  if mf.enabled and triggerAllowsClick(mf.trigger)
     and freshTotal >= mf.fingerCount then
    shouldMiddle = true
  end

  if not shouldMiddle then
    local tc = mc.topCenter
    if tc.enabled and triggerAllowsClick(tc.trigger) and tc.devices[snap.kind] then
      -- Same "exactly one touch BEGAN inside the region" semantics as
      -- the tap path — see the comment in _evaluateTap.
      if countActiveInTopCenter(self, snap.kind) == 1 then
        shouldMiddle = true
      end
    end
  end

  if not shouldMiddle then return false end

  local loc = ev:location()
  -- Emit otherMouseDown + otherMouseUp back-to-back rather than waiting
  -- for the physical leftMouseUp to fire the matching up. Holding the
  -- synthetic middle button "down" across the physical press window
  -- means any scroll events the Magic Mouse generates during that
  -- window arrive while middle is held — iTerm (and other terminals
  -- with mouse reporting features) interpret middle-held + scroll as
  -- additional paste actions, producing the multi-paste symptom.
  --
  -- emittingMiddleClick prevents self re-entry: if :post() ends up
  -- synchronously delivering an event back to this handler (the
  -- sentinel on eventSourceUserData isn't reliably preserved across
  -- the round-trip on some setups), the flag rejects it immediately.
  emittingMiddleClick = true
  emitMiddleDown(loc.x, loc.y)
  emitMiddleUp  (loc.x, loc.y)
  emittingMiddleClick = false
  self._clickPending = true   -- still set so handleLeftUp suppresses
                              -- the matching physical release
  self.logger.d(string.format(
    "middle-click emitted via click (count=%d kind=%s at %.0f,%.0f)",
    snap.count, tostring(snap.kind), loc.x, loc.y))
  return true, {}
end

function obj:_handleLeftUp(ev)
  local P = hs.eventtap.event.properties
  if isSiblingSyntheticEvent(ev:getProperty(P.eventSourceUserData)) then
    return false
  end
  if not self._clickPending then return false end
  -- We already emitted otherMouseUp back-to-back with the down in
  -- _handleLeftDown; here we just need to swallow the orphaned
  -- physical leftMouseUp so the app doesn't see a stray "left button
  -- released" that it had no matching press for.
  self._clickPending = false
  return true, {}
end

function obj:_handle(ev)
  local T = hs.eventtap.event.types
  local etype = ev:getType()
  if etype == T.tapDisabledByTimeout or etype == T.tapDisabledByUserInput then
    self.logger.w("eventtap was disabled; re-enabling")
    if self._tap then self._tap:start() end
    return false
  end
  if etype == T.scrollWheel    then return self:_handleScroll(ev)    end
  if etype == T.leftMouseDown  then return self:_handleLeftDown(ev)  end
  if etype == T.leftMouseUp    then return self:_handleLeftUp(ev)    end
  return false
end

-- ============================================================
-- Lifecycle
-- ============================================================

local function loadNativeMultitouch(self)
  if self._mt then return end
  local path = hs.spoons.resourcePath("native_bridge.lua")
  if not path then
    self.logger.w("native_bridge.lua not found in Spoon dir; touch-dependent "
      .. "features disabled")
    return
  end
  local okLoad, factory = pcall(dofile, path)
  if not okLoad or type(factory) ~= "function" then
    self.logger.w("native_bridge.lua load failed (" .. tostring(factory)
      .. "); touch-dependent features disabled")
    return
  end
  self._mt = factory({ logger = self.logger })
  if not self._mt then
    self.logger.w("hs._ckol.multitouch not available; scroll inversion "
      .. "and middle-click features are disabled (see README for install).")
  end
end

--- MouseTrackpadTweaks:start()
--- Method
--- Installs the eventtap and (if available) starts the multitouch
--- callback. Errors if Hammerspoon does not have Accessibility
--- permission. Idempotent.
---
--- Returns:
---  * self
function obj:start()
  -- Cleanup before re-init.
  if self._startupTimer then self._startupTimer:stop(); self._startupTimer = nil end
  if self._tap        then self._tap:stop();        self._tap        = nil end
  if self._mt and self._mtStarted then
    pcall(function() self._mt.stop() end)
    self._mtStarted = false
  end

  if not hs.accessibilityState() then
    self.logger.e("MouseTrackpadTweaks requires Accessibility permission for "
                  .. "Hammerspoon (System Settings -> Privacy & Security -> "
                  .. "Accessibility); spoon not started.")
    return self
  end

  -- The multitouch shim MUST run synchronously — see `obj.startupDelay`
  -- for the full rationale, but in short: `hs._ckol.multitouch` registers
  -- a native MultitouchSupport callback that is NOT auto-detached when
  -- the Lua state tears down (unlike `hs.eventtap` and
  -- `hs.application.watcher`, both of which have C-level `__gc` cleanup).
  -- If `_mt.start(callback)` is deferred, an `hs.reload()` leaves the
  -- previous Lua state's callback registered for the duration of the
  -- delay, and the next touch event crashes Hammerspoon with a
  -- LuaSkin `pushLuaRef:ref:` assertion (ref points into the dead
  -- state). Calling `_mt.start` synchronously in the new state's
  -- `start()` replaces the stale callback before any touch can arrive.
  loadNativeMultitouch(self)
  if self._mt and not self._mtStarted then
    local okStart, err = pcall(function()
      self._mt.start(function(devId, devKind, touchId, phase, nx, ny, ts)
        self:_onTouch(devId, devKind, touchId, phase, nx, ny, ts)
      end)
    end)
    if okStart then
      self._mtStarted = true
    else
      self.logger.w("hs._ckol.multitouch.start failed: " .. tostring(err))
    end
  end

  -- The eventtap registration is still deferred — that's the actual
  -- cold-start contention point we're addressing. `hs.eventtap` cleans
  -- up its native CGEventTap on Lua state teardown via `__gc`, so the
  -- reload-race that bit multitouch above doesn't apply here.
  self._startupTimer = hs.timer.doAfter(self.startupDelay or 3, function()
    self._startupTimer = nil

    local T = hs.eventtap.event.types
    self._tap = hs.eventtap.new(
      { T.scrollWheel, T.leftMouseDown, T.leftMouseUp },
      function(ev) return self:_handle(ev) end)
    self._tap:start()

    self.logger.i(string.format(
      "started; invertV=%s invertH=%s middleClick=%s multitouch=%s",
      tostring(self.invertVertical),
      tostring(self.invertHorizontal),
      tostring(self.middleClick.enabled),
      self._mtStarted and "active" or "missing"))
  end)

  return self
end

--- MouseTrackpadTweaks:stop()
--- Method
--- Stops the eventtap and the multitouch callback, and clears all
--- per-device touch state.
---
--- Returns:
---  * self
function obj:stop()
  if self._startupTimer then self._startupTimer:stop(); self._startupTimer = nil end
  if self._tap then self._tap:stop(); self._tap = nil end
  if self._mt and self._mtStarted then
    pcall(function() self._mt.stop() end)
    self._mtStarted = false
  end
  self._touches      = {}
  self._lastTouch    = { kind = nil, id = nil, atS = 0 }
  self._clickPending = false
  self._scrollStreamIsMagicMouse = false
  self.logger.i("stopped")
  return self
end

--- MouseTrackpadTweaks:toggle()
--- Method
--- Toggles the Spoon on/off and shows a brief `hs.alert` banner.
function obj:toggle()
  if self._tap and self._tap:isEnabled() then
    self:stop()
    hs.alert.show("MouseTrackpadTweaks: off")
  else
    self:start()
    hs.alert.show("MouseTrackpadTweaks: on")
  end
end

--- MouseTrackpadTweaks:toggleInvertScroll()
--- Method
--- Toggles only the Magic Mouse vertical scroll inversion and shows an
--- `hs.alert` banner.
function obj:toggleInvertScroll()
  self.invertVertical = not self.invertVertical
  hs.alert.show("MouseTrackpadTweaks: invertVertical " ..
    (self.invertVertical and "on" or "off"))
end

--- MouseTrackpadTweaks:toggleMiddleClick()
--- Method
--- Toggles middle-click synthesis (both modes) and shows an `hs.alert`
--- banner.
function obj:toggleMiddleClick()
  self.middleClick.enabled = not self.middleClick.enabled
  hs.alert.show("MouseTrackpadTweaks: middleClick " ..
    (self.middleClick.enabled and "on" or "off"))
end

--- MouseTrackpadTweaks:bindHotkeys(mapping)
--- Method
--- Binds (or rebinds) keyboard shortcuts. Supported actions: `toggle`,
--- `toggleInvertScroll`, `toggleMiddleClick`. Each value is a
--- `{mods, key}` pair compatible with `hs.hotkey.bindSpec`. Calling
--- `bindHotkeys` again clears prior bindings first.
---
--- Parameters:
---  * mapping - table like `{ toggle = {{"ctrl","cmd"}, "m"} }`
---
--- Returns:
---  * self
function obj:bindHotkeys(mapping)
  if self._hotkeys then
    for _, hk in ipairs(self._hotkeys) do hk:delete() end
  end
  self._hotkeys = {}
  local actions = {
    toggle             = function() self:toggle()             end,
    toggleInvertScroll = function() self:toggleInvertScroll() end,
    toggleMiddleClick  = function() self:toggleMiddleClick()  end,
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
