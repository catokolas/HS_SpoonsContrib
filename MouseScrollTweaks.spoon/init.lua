--- === MouseScrollTweaks ===
---
--- Tweaks for traditional mouse wheels on macOS, without touching the
--- trackpad or Magic Mouse:
---
--- 1. Per-axis direction inversion — flip the vertical and/or horizontal
---    wheel direction independently of the system "Natural scrolling"
---    toggle (which on macOS ties trackpad and mouse-wheel direction
---    together).
--- 2. Smoothness — interpolate each discrete wheel tick into a short
---    sequence of small continuous pixel events, exposed as a grade from
---    0 (off / passthrough) to 10 (longest, smoothest glide).
---
--- Trackpads and Magic Mouse produce continuous scroll events and are
--- passed through untouched, distinguished via the
--- `scrollWheelEventIsContinuous` property.

local obj = {}
obj.__index = obj

-- Metadata
obj.name     = "MouseScrollTweaks"
obj.version  = "0.1"
obj.author   = "Cato Kolås <cato.kolas@gmail.com>"
obj.credits  = "Smoothing ported from mac-mouse-fix by Noah Nuebling (MIT)"
obj.homepage = "https://github.com/catokolas/HS_SpoonsContrib"
obj.license  = "MIT - https://opensource.org/licenses/MIT"

--- MouseScrollTweaks.invertVertical
--- Variable
--- If true (default), the vertical mouse-wheel direction is flipped.
--- Affects only discrete (non-continuous) scroll events — trackpads and
--- Magic Mouse are unaffected.
obj.invertVertical = true

--- MouseScrollTweaks.invertHorizontal
--- Variable
--- If true (default), the horizontal (tilt-wheel) direction is flipped.
--- Affects only discrete scroll events.
obj.invertHorizontal = true

--- MouseScrollTweaks.smoothness
--- Variable
--- Smoothing intensity for discrete wheel ticks, integer in `[0, 20]`.
--- `0` (default) means passthrough — only inversion applies. Higher
--- values primarily tune the momentum tail length and per-tick
--- acceleration multiplier; the per-tick base buffer stays small, so
--- single isolated clicks remain modest at any grade. Magnitude on
--- rapid scrolling comes from the MMF-style two-level acceleration
--- inside `_enqueueAxis`. Mid grades (5–10) feel subtle; 10–15
--- approximates MMF; 15–20 leans further into long glides. Read live
--- at each tick, so it can be retuned via `:configure({smoothness=N})`
--- without restarting the spoon.
obj.smoothness = 15

--- MouseScrollTweaks.startupDelay
--- Variable
--- Seconds to defer all OS-touching work inside `:start()` —
--- the accessibility probe, engine `dofile`, `hs.eventtap.new` +
--- `:start()`, and the `hs.application.watcher` registration. The
--- spoon's `start()` returns immediately and schedules a one-shot
--- timer; only that timer's callback actually wires up the tap.
---
--- Why: Hammerspoon's reload runs every Spoon's `:start()` in tight
--- succession on the main thread. On M1 systems with several event-
--- tap-using Spoons (multiple Mouse-* spoons), the simultaneous
--- `CGEventTapCreate` XPC handshakes with WindowServer + the
--- NSWorkspace observer subscriptions contend with other main-
--- thread cold-start work (notably NSURLSession's first-call
--- init) enough to stall one-shot timers in *other* Spoons for
--- tens of seconds — `ModelsUsage` in particular loses its
--- KIX-request timeout and gets stuck `inFlight` until manually
--- nudged. Pushing this spoon's OS calls a few seconds past the
--- reload storm matches FocusFollowsMouse's `start()` profile
--- (which is a single `hs.timer.doEvery` and provably doesn't
--- trigger the wedge). Scroll inversion + smoothness are
--- unaffected once the deferred init runs.
---
--- Set to 0 to perform the full setup synchronously in `:start()`
--- (the pre-2026-06 behaviour).
---
--- Default 3.0 is staggered against the other Mouse-* spoons
--- (3.3 / 3.6 / 3.9) so their deferred OS calls don't all land in
--- the same run-loop tick.
obj.startupDelay = 3.0

--- MouseScrollTweaks.logger
--- Variable
--- Logger object used within the Spoon. Set its level (e.g.
--- `spoon.MouseScrollTweaks.logger.setLogLevel("debug")`) to see the
--- decision trace.
obj.logger = hs.logger.new("MouseScrollTweaks")

-- Internal state — not part of the public API.
obj._tap        = nil
obj._engineImpl = nil   -- set at start(): either the inline default
                        -- (linear-phase + friction-momentum) or the
                        -- native bridge if `hs._ckol.smoothscroll` is
                        -- installed. The dispatcher routes per-frame
                        -- work through this, so the input / cancel /
                        -- event-emission code below doesn't care which
                        -- backend it is.

-- Optional companion module `hs._ckol.smoothscroll` posts continuous-
-- scroll CGEvents from a CVDisplayLink callback. If installed
-- (~/.hammerspoon/hs/_ckol/smoothscroll/), we route output through it
-- for the trackpad-like glide-to-stop feel; otherwise we use the
-- inline default engine. See the HS_ModulesContrib-smoothscroll repo
-- (https://github.com/catokolas/HS_ModulesContrib-smoothscroll) for
-- build + install instructions.
local _haveNativeSmoothScroll = (function()
  local ok = pcall(require, "hs._ckol.smoothscroll")
  return ok
end)()

-- Per-axis smoothing state (linear + momentum phases, MMF style).
local function newAxisState()
  return {
    buf        = 0,        -- pending pixels (signed)
    msLeft     = 0,        -- ms remaining in the linear phase
    vel        = 0,        -- px/ms velocity at start of momentum
    phase      = "idle",   -- "idle" | "linear" | "momentum"
    onePxCount = 0,        -- consecutive ±1px momentum frames
    lastDir    = 0,        -- last input direction (+1 / -1)
    lineAccum  = 0,        -- fractional line delta accumulator; emits
                           -- integer line units proportional to total
                           -- pixels glided so both line-reading apps
                           -- (iTerm) and pixel-reading apps (browsers,
                           -- VS Code) get a sensible scroll amount
    pxAccum    = 0,        -- fractional pixel accumulator; carries the
                           -- per-frame rounding residual forward so the
                           -- tail decay distributes pixels evenly (no
                           -- visible stairsteps as velocity falls
                           -- through small integer values)
  }
end

obj._anim = {
  x           = newAxisState(),
  y           = newAxisState(),
  frameTimer  = nil,
  lastFrameS  = 0,
  startPid    = 0,   -- frontmost-app pid at glide start; per-frame guard
                     -- in _frameTick cancels the glide if it changes
  startMouseX = 0,   -- mouse position at glide start; per-frame guard
  startMouseY = 0,   -- cancels if the mouse moves further than
                     -- MOUSE_CANCEL_PX (FFM-style sloppy-focus switches
                     -- change focus without a click, beating both the
                     -- leftMouseDown branch and the frontmost-pid check)
  lastTickS   = 0,   -- abs-seconds of most recent forwarded tick;
                     -- used by _nativeWatchdog to stop polling once
                     -- the native module's gesture + momentum have
                     -- had time to wind down
}

-- Cross-axis "burst" tracker — counts wheel ticks and "swipes" (bursts
-- of ≥2 ticks within a short gap). Powers MMF's two-level acceleration:
-- a per-tick multiplier inside a single burst, and a fast-scroll
-- multiplier once 3+ swipes have accumulated. Ported from
-- mac-mouse-fix/Helper/InputTransformation/Scroll/ScrollUtility.m:202-234.
obj._burst = {
  tickCount     = 0,   -- ticks in the current burst
  swipeCount    = 0,   -- swipes accumulated recently
  lastTickS     = 0,   -- abs-seconds of previous wheel tick
  lastSwipeEndS = 0,   -- abs-seconds when the previous burst ended
}

obj._appWatcher = nil  -- cancels the glide when the active app changes
                       -- so residual scroll doesn't bleed into the new
                       -- window

-- Smoothing parameters per grade. The base per-tick buffer is small;
-- magnitude on rapid scrolling comes from the two-level acceleration in
-- _enqueueAxis (per-tick + fast-scroll-on-swipes), mirroring MMF.
-- `grade` primarily tunes the *feel*: friction (tail length) and the
-- per-tick acceleration multiplier.
--   pxStepSize   - linear-phase buffer added per wheel tick (px)
--   msPerStep    - linear-phase duration per tick (ms); refreshed each tick
--   acceleration - multiplier applied to buffer on consecutive ticks
--   friction     - momentum friction strength (lower = longer tail)
--   frictionDepth- exponent on |velocity| inside friction term
--   onePxLimit   - consecutive ±1px momentum frames tolerated before end
local function paramsFor(grade)
  -- Grades 0..15: MMF-recipe defaults (friction 2.3, onePxLimit 2)
  -- → short, dense ~100–200 ms tail, smooth across apps.
  -- Grades 16..20: friction relaxes / onePxLimit extends modestly so
  -- the tail stretches past MMF without crossing the perceptual
  -- stutter threshold (humans see 1-pixel-per-frame scroll as
  -- discrete steps at 60 Hz, regardless of how vsync-precise the
  -- timing is). At grade 20 the tail is ~250 ms — noticeably longer
  -- than MMF but still smooth.
  local extra = math.max(0, grade - 15)
  return {
    pxStepSize    = 4 + grade * 0.5,         -- 4..14 px per tick
    msPerStep     = 90,                      -- MMF default
    acceleration  = 1.05 + grade * 0.01,     -- 1.05..1.25
    friction      = 2.3 - extra * 0.18,      -- 2.3 (grade 0–15) → 1.40 (grade 20)
    frictionDepth = 1.0,                     -- MMF default
    onePxLimit    = 2 + extra * 1,           -- 2 (grade 0–15) → 7 (grade 20)
  }
end

local FRAME_S          = 1 / 240  -- 240Hz frame loop. Halves per-frame
                                  -- pixel delta vs 60/120Hz so each
                                  -- residual hs.timer-vs-vsync jitter
                                  -- event is small enough to drop below
                                  -- the perceptible-stairstep threshold.
local TICK_GAP_S       = 0.13     -- MMF consecutiveScrollTickMaxIntervall
local SWIPE_GAP_S      = 0.35     -- MMF consecutiveScrollSwipeMaxIntervall
local SWIPE_TICK_THRESH = 2       -- MMF scrollSwipeThreshold_inTicks
local FAST_SWIPE_THRESH = 3       -- MMF fastScrollThreshold_inSwipes
local FAST_FACTOR       = 1.1     -- base fast-scroll multiplier (matches MMF)
local FAST_BASE         = 1.1     -- per-extra-swipe multiplier (matches MMF)
-- Pixels per line for synthetic line delta accumulation. ~40 keeps
-- iTerm's per-click line count reasonable (1–2 lines per slow tick,
-- handful per rapid burst). Browsers/VS Code use pixel delta in
-- parallel, so the lower line emission density doesn't hurt them.
local LINE_PX = 40
local MOUSE_CANCEL_PX   = 400     -- per-frame mouse-motion threshold;
                                  -- beyond this we assume the user is
                                  -- targeting a different window and
                                  -- cancel the glide (handles FFM /
                                  -- sloppy-focus where no click fires)
-- Sentinel stamped on every synthetic event we post via
-- `eventSourceUserData`. The tap's first check looks for this value
-- (and the broader sibling-family prefix below) and short-circuits so
-- neither our own posts nor a sibling Spoon's synthetic events loop
-- back through the handler. We no longer rely on `IsContinuous = 1`
-- for this, because IsContinuous flips iTerm into pixel-scrolling
-- mode and overshoots.
--
-- Convention shared across this Spoon family: every sibling Spoon that
-- posts synthetic events stamps `eventSourceUserData` with a value in
-- the range `0xC0DE5C00 .. 0xC0DE5CFF`. Low-byte assignments:
--   0x01 = MouseScrollTweaks (this Spoon)
--   0x02 = MouseTrackpadTweaks
--   0x03 = MouseCopyPasteSelection
-- isSiblingSyntheticEvent() below treats anything in that range as
-- "already handled by another tap in the chain, pass through" — so we
-- never react to a synthetic click another Spoon emitted (e.g.
-- MouseCopyPasteSelection's focus-click pair) as if it were the user
-- redirecting their attention away from an in-flight glide.
-- New Spoons in this collection should pick an unused byte in the
-- range and document it in every family member.
local SENTINEL              = 0xC0DE5C01
local SENTINEL_PREFIX_MASK  = 0xFFFFFF00
local SENTINEL_PREFIX_VALUE = 0xC0DE5C00

local function isSiblingSyntheticEvent(usd)
  if not usd then return false end
  return (usd & SENTINEL_PREFIX_MASK) == SENTINEL_PREFIX_VALUE
end

local function sign(v)
  if v > 0 then return 1 end
  if v < 0 then return -1 end
  return 0
end

-- Round half away from zero. round(0.4)=0, round(0.6)=1, round(-1.5)=-2.
local function round(v)
  if v >= 0 then return math.floor(v + 0.5) end
  return math.ceil(v - 0.5)
end

local function nowS() return hs.timer.absoluteTime() / 1e9 end

local function clamp(n, lo, hi)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

local function normaliseSmoothness(n)
  return math.floor(clamp(n or 0, 0, 20) + 0.5)
end

--- MouseScrollTweaks:configure(configuration)
--- Method
--- Merges configuration values into the spoon. Accepts any of the public
--- variables (`invertVertical`, `invertHorizontal`, `smoothness`).
--- `smoothness` is clamped to `[0, 20]` and rounded to the nearest
--- integer.
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
  self.smoothness = normaliseSmoothness(self.smoothness)
  return self
end

-- Tick / swipe counter update — call once per real wheel tick from
-- _handle. Mirrors MMF's ScrollUtility.m:202-234. A "burst" is a run of
-- ticks separated by <= TICK_GAP_S; a "swipe" is a burst that contained
-- >= SWIPE_TICK_THRESH ticks. Consecutive swipes (separated by <=
-- SWIPE_GAP_S between burst-ends and the next burst's start) accumulate
-- in swipeCount, which gates the fast-scroll multiplier in _enqueueAxis.
function obj:_updateBurst()
  local now = nowS()
  local b = self._burst
  if now - b.lastTickS > TICK_GAP_S then
    -- The previous burst just ended. Did it qualify as a swipe?
    if b.tickCount >= SWIPE_TICK_THRESH then
      if now - b.lastSwipeEndS > SWIPE_GAP_S then
        b.swipeCount = 1
      else
        b.swipeCount = b.swipeCount + 1
      end
      b.lastSwipeEndS = b.lastTickS
    elseif now - b.lastSwipeEndS > SWIPE_GAP_S then
      b.swipeCount = 0
    end
    b.tickCount = 1
  else
    b.tickCount = b.tickCount + 1
  end
  b.lastTickS = now
end

-- Handle one wheel tick on a given axis. `dir` is +1 or -1.
-- Adds pxStepSize to the linear-phase buffer, then applies the two-level
-- acceleration (per-tick × fast-scroll) read from self._burst. Reverses
-- cleanly on direction change.
function obj:_enqueueAxis(axis, dir)
  if dir == 0 then return end
  local p = paramsFor(self.smoothness)
  local b = self._burst

  if axis.lastDir ~= 0 and axis.lastDir ~= dir then
    axis.buf, axis.vel, axis.phase, axis.onePxCount = 0, 0, "idle", 0
    axis.lineAccum = 0
    axis.pxAccum   = 0
  end

  -- MMF-style: apply both acceleration multipliers to the *incoming*
  -- tick only, then add it to the buffer. The earlier "multiply the
  -- whole buffer" form compounded undrained remnants from previous
  -- ticks and produced burst-by-burst amplitude growth that MMF
  -- doesn't have.
  local stepPx = dir * p.pxStepSize

  -- Level 1: per-tick boost on every tick after the first in a burst.
  if b.tickCount > 1 then
    stepPx = stepPx * p.acceleration
  end

  -- Level 2: fast-scroll boost once we're 3+ swipes deep.
  local fastDelta = b.swipeCount - FAST_SWIPE_THRESH
  if fastDelta >= 0 then
    stepPx = stepPx * FAST_FACTOR * (FAST_BASE ^ fastDelta)
  end

  axis.buf = axis.buf + stepPx

  axis.msLeft  = p.msPerStep
  axis.phase   = "linear"
  axis.lastDir = dir
end

-- Advance one axis by `dtMs` real elapsed milliseconds. Returns two
-- values:
--   * `px`     - the integer pixel delta to post this frame (0 if the
--                fractional accumulator hasn't crossed an integer yet)
--   * `rawPx`  - the smooth fractional displacement for this frame, used
--                for the fixed-point delta property so apps that respect
--                it (most modern browsers) can render sub-pixel motion
--                even on frames where the integer delta is 0
function obj:_advanceAxis(axis, dtMs)
  if axis.phase == "idle" then return 0, 0 end
  local p = paramsFor(self.smoothness)

  -- Drain the fractional accumulator toward zero (floor for positive,
  -- ceil for negative); leftover stays in axis.pxAccum.
  local function drainPx()
    if axis.pxAccum >= 0 then
      local px = math.floor(axis.pxAccum)
      axis.pxAccum = axis.pxAccum - px
      return px
    else
      local px = math.ceil(axis.pxAccum)
      axis.pxAccum = axis.pxAccum - px
      return px
    end
  end

  if axis.phase == "linear" then
    if axis.msLeft <= 0 then axis.msLeft = dtMs end
    local rawPx = (axis.buf / axis.msLeft) * dtMs
    axis.pxAccum = axis.pxAccum + rawPx
    local px = drainPx()
    axis.buf    = axis.buf - rawPx       -- subtract the fractional amount
    axis.msLeft = axis.msLeft - dtMs
    if axis.msLeft <= 0 or math.abs(axis.buf) < 0.5 then
      axis.phase      = "momentum"
      axis.vel        = (dtMs > 0) and (rawPx / dtMs) or 0
      axis.msLeft     = 0
      axis.buf        = 0
      axis.onePxCount = 0
    end
    return px, rawPx
  end

  -- momentum
  local v = axis.vel
  local rawPx = v * dtMs
  axis.pxAccum = axis.pxAccum + rawPx
  local px = drainPx()
  local newV = v - sign(v) * (math.abs(v) ^ p.frictionDepth) * (p.friction / 100) * dtMs
  if sign(newV) ~= sign(v) then newV = 0 end
  axis.vel = newV
  if newV == 0 and math.abs(axis.pxAccum) < 0.5 then
    -- Velocity died and there's no fractional remainder left to flush.
    axis.phase, axis.lastDir, axis.onePxCount, axis.vel = "idle", 0, 0, 0
    axis.pxAccum = 0
  elseif math.abs(px) == 1 then
    axis.onePxCount = axis.onePxCount + 1
    if axis.onePxCount > p.onePxLimit then
      axis.phase, axis.lastDir, axis.onePxCount, axis.vel = "idle", 0, 0, 0
      axis.pxAccum = 0
    end
  end
  return px, rawPx
end

-- Drain integer lines from a fractional accumulator, leaving the
-- residual for the next frame. e.g. 1.3 → emit 1, leave 0.3.
local function drainLine(accum)
  if math.abs(accum) < 1 then return 0, accum end
  local whole = (accum > 0) and math.floor(accum) or math.ceil(accum)
  return whole, accum - whole
end

-- Build the "default" engine impl: wraps the inline _enqueueAxis /
-- _advanceAxis methods so the dispatcher can route through a uniform
-- `{enqueueAxis, advanceAxis}` table regardless of engine choice.
local function defaultEngineImpl(self)
  return {
    name = "default",
    enqueueAxis = function(axis, dir) return self:_enqueueAxis(axis, dir) end,
    advanceAxis = function(axis, dtMs) return self:_advanceAxis(axis, dtMs) end,
  }
end

-- Pick the engine impl: native if `hs._ckol.smoothscroll` is installed,
-- inline default otherwise. Called from start(). Any failure loading
-- the native engine falls back to default with a logged warning.
function obj:_loadEngine()
  if not _haveNativeSmoothScroll then
    self._engineImpl = defaultEngineImpl(self)
    self.logger.d("engine: default (hs._ckol.smoothscroll not installed)")
    return
  end

  local path = hs.spoons.resourcePath("engine_native.lua")
  if not path then
    self.logger.w("engine_native.lua not found in Spoon dir; using default")
    self._engineImpl = defaultEngineImpl(self)
    return
  end

  local okLoad, factory = pcall(dofile, path)
  if not okLoad or type(factory) ~= "function" then
    self.logger.w(string.format("engine_native.lua load failed (%s); using default",
      tostring(factory)))
    self._engineImpl = defaultEngineImpl(self)
    return
  end

  -- Shared utilities the engine factory may want. `default*` lets the
  -- native engine delegate per-axis work to the inline default if it
  -- needs to (currently it doesn't — it owns its own frame loop).
  local ctx = {
    nowS               = nowS,
    sign               = sign,
    round              = round,
    burst              = function() return self._burst end,
    smoothness         = function() return self.smoothness end,
    logger             = self.logger,
    defaultEnqueueAxis = function(axis, dir)  return self:_enqueueAxis(axis, dir)  end,
    defaultAdvanceAxis = function(axis, dtMs) return self:_advanceAxis(axis, dtMs) end,
  }

  local okFactory, impl = pcall(factory, ctx)
  if not okFactory or type(impl) ~= "table"
     or type(impl.enqueueAxis) ~= "function"
     or type(impl.advanceAxis) ~= "function" then
    self.logger.w(string.format("engine_native factory returned invalid impl (%s); using default",
      tostring(impl)))
    self._engineImpl = defaultEngineImpl(self)
    return
  end

  impl.name = impl.name or "native"
  self._engineImpl = impl
  self.logger.d("engine: native (hs._ckol.smoothscroll detected)")
end

function obj:_frameTick()
  local a   = self._anim

  -- Per-frame focus guard: if the frontmost app has changed since the
  -- glide started, cancel before posting more events into the new
  -- window. Catches Cmd-Tab, Spaces switches, and any focus change
  -- that bypasses the leftMouseDown branch.
  if a.startPid > 0 then
    local front = hs.application.frontmostApplication()
    if front and front:pid() ~= a.startPid then
      self:_cancelGlide()
      return
    end
  end

  -- Per-frame mouse-motion guard: catches sloppy-focus / FFM scenarios
  -- where the user moves the cursor over a different window. FFM's
  -- focus-switch debounce is too slow for the frontmost-pid check
  -- above, so we cancel as soon as the cursor has moved beyond a
  -- threshold from where the glide began.
  local pos = hs.mouse.absolutePosition()
  if pos then
    local dx = pos.x - a.startMouseX
    local dy = pos.y - a.startMouseY
    if (dx * dx + dy * dy) > (MOUSE_CANCEL_PX * MOUSE_CANCEL_PX) then
      self:_cancelGlide()
      return
    end
  end

  local now = nowS()
  local dtMs = (a.lastFrameS == 0) and (FRAME_S * 1000) or ((now - a.lastFrameS) * 1000)
  a.lastFrameS = now

  local dx, rawDx = self._engineImpl.advanceAxis(a.x, dtMs)
  local dy, rawDy = self._engineImpl.advanceAxis(a.y, dtMs)

  -- Accumulate fractional lines proportional to the pixel delta this
  -- frame, then drain any whole-line amount that's accumulated. Total
  -- lines per glide ≈ total_pixels / (LINE_PX × linePxScale). Matching
  -- MMF: both line and pixel delta are emitted on EVERY frame including
  -- the momentum tail (MMF explicitly sets ScrollPhase / MomentumPhase
  -- to 0 — no gesture/inertia signalling — and the dense per-frame
  -- delta stream is what makes apps render smoothly).
  --
  -- `linePxScale` is an opt-in per-engine multiplier on the divisor so
  -- engines with substantially-different per-tick pixel budgets keep
  -- iTerm line counts comparable. Default engine: ~50-100 px/tick →
  -- scale 1 (≈ 1-2 lines/click). Spring engine: ~250 px/tick → scale
  -- ~3 (≈ 2 lines/click). See per-engine impl tables.
  local linePx = LINE_PX * (self._engineImpl.linePxScale or 1)
  a.y.lineAccum = a.y.lineAccum + dy / linePx
  a.x.lineAccum = a.x.lineAccum + dx / linePx
  local lineY; lineY, a.y.lineAccum = drainLine(a.y.lineAccum)
  local lineX; lineX, a.x.lineAccum = drainLine(a.x.lineAccum)

  -- Post an event whenever there's any motion to deliver — including
  -- frames where the integer pixel delta is 0 but a fractional rawDx /
  -- rawDy is non-zero. The fixed-point delta carries the sub-pixel
  -- amount so apps that respect it (most modern browsers, AppKit
  -- scroll views) render smoothly even through the tail decay where
  -- the integer delta would otherwise be 0 for several frames at a
  -- stretch.
  if dx ~= 0 or dy ~= 0 or lineX ~= 0 or lineY ~= 0
     or rawDx ~= 0 or rawDy ~= 0 then
    local ev = hs.eventtap.event.newScrollEvent({ dx, dy }, {}, "pixel")
    local P  = hs.eventtap.event.properties
    ev:setProperty(P.scrollWheelEventDeltaAxis1, lineY)
    ev:setProperty(P.scrollWheelEventDeltaAxis2, lineX)
    -- Smooth fractional delta — apps that respect FixedPt can render
    -- sub-pixel resolution from this.
    ev:setProperty(P.scrollWheelEventFixedPtDeltaAxis1, rawDy)
    ev:setProperty(P.scrollWheelEventFixedPtDeltaAxis2, rawDx)
    -- Stamp sentinel so our own tap skips this event on re-entry.
    ev:setProperty(P.eventSourceUserData, SENTINEL)
    ev:post()
  end

  if a.x.phase == "idle" and a.y.phase == "idle" then
    if a.frameTimer then a.frameTimer:stop(); a.frameTimer = nil end
    a.lastFrameS    = 0
    a.x.lineAccum   = 0
    a.y.lineAccum   = 0
    a.x.pxAccum     = 0
    a.y.pxAccum     = 0
  end
end

function obj:_enqueueSmooth(dirX, dirY)
  if dirX == 0 and dirY == 0 then return end

  -- Snapshot front-most app pid + mouse position so the per-frame
  -- (or watchdog) cancellation guards know what to compare against.
  -- Captured here in both engine paths so the values stay current
  -- across long, multi-burst glides.
  local function snapshotGuardState()
    local front = hs.application.frontmostApplication()
    self._anim.startPid    = front and front:pid() or 0
    local pos = hs.mouse.absolutePosition()
    self._anim.startMouseX = pos and pos.x or 0
    self._anim.startMouseY = pos and pos.y or 0
  end

  -- Native-output engines own their own frame loop + CGEvent posting;
  -- this side just forwards the tick and runs a lightweight watchdog
  -- for cancellation guards (mouse motion, app switch).
  if self._engineImpl.nativeOutput then
    self._engineImpl.tickNative(dirX, dirY)
    self._anim.lastTickS = nowS()
    if not self._anim.frameTimer then
      snapshotGuardState()
      self._anim.frameTimer = hs.timer.doEvery(0.020, function() self:_nativeWatchdog() end)
    end
    return
  end

  self._engineImpl.enqueueAxis(self._anim.x, dirX)
  self._engineImpl.enqueueAxis(self._anim.y, dirY)
  if not self._anim.frameTimer then
    snapshotGuardState()
    self._anim.lastFrameS  = 0
    self._anim.frameTimer  = hs.timer.doEvery(FRAME_S, function() self:_frameTick() end)
  end
end

-- Cancellation-guard watchdog for native-output engines. Runs at ~50 Hz
-- (cheap; only does the four guards from _frameTick, no per-frame math
-- or CGEvent posting). Stops itself after `NATIVE_WATCHDOG_IDLE_S` of
-- no tick activity — long enough to cover any momentum tail the native
-- module is running.
local NATIVE_WATCHDOG_IDLE_S = 3.0

function obj:_nativeWatchdog()
  local a = self._anim

  -- Frontmost-pid guard.
  if a.startPid > 0 then
    local front = hs.application.frontmostApplication()
    if front and front:pid() ~= a.startPid then
      self:_cancelGlide()
      return
    end
  end

  -- Mouse-motion guard.
  local pos = hs.mouse.absolutePosition()
  if pos then
    local dx = pos.x - a.startMouseX
    local dy = pos.y - a.startMouseY
    if (dx * dx + dy * dy) > (MOUSE_CANCEL_PX * MOUSE_CANCEL_PX) then
      self:_cancelGlide()
      return
    end
  end

  -- Idle timeout — assume the native module's gesture + momentum have
  -- finished and stop polling.
  if a.lastTickS > 0 and (nowS() - a.lastTickS) > NATIVE_WATCHDOG_IDLE_S then
    if a.frameTimer then a.frameTimer:stop(); a.frameTimer = nil end
    a.lastTickS    = 0
    a.startPid     = 0
    a.startMouseX  = 0
    a.startMouseY  = 0
  end
end

-- Drop any in-flight glide. Called when the active app changes (or the
-- user clicks anywhere) so residual synthetic scroll doesn't follow into
-- a new window.
function obj:_cancelGlide()
  if self._engineImpl and self._engineImpl.nativeOutput
     and type(self._engineImpl.cancelNative) == "function" then
    self._engineImpl.cancelNative()
  end
  if self._anim.frameTimer then
    self._anim.frameTimer:stop()
    self._anim.frameTimer = nil
  end
  self._anim.x           = newAxisState()
  self._anim.y           = newAxisState()
  self._anim.lastFrameS  = 0
  self._anim.lastTickS   = 0
  self._anim.startPid    = 0
  self._anim.startMouseX = 0
  self._anim.startMouseY = 0
end

function obj:_handle(ev)
  local T = hs.eventtap.event.types
  local etype = ev:getType()

  -- WindowServer can drop the tap if a callback misbehaves or the
  -- runloop stalls. Re-arm in place.
  if etype == T.tapDisabledByTimeout or etype == T.tapDisabledByUserInput then
    self.logger.w("eventtap was disabled; re-enabling")
    if self._tap then self._tap:start() end
    return false, {}
  end

  local P = hs.eventtap.event.properties

  -- Skip events synthesised by us or any sibling Spoon. Without this
  -- gate, a sibling's synthetic leftMouseDown (e.g. the focus-click
  -- MouseCopyPasteSelection emits before Cmd+V) would cancel an
  -- in-flight glide, and our own synthetic scroll events would loop
  -- back through the smoothing engine.
  if isSiblingSyntheticEvent(ev:getProperty(P.eventSourceUserData)) then
    return false, {}
  end

  -- Any real mouse click is treated as "user redirected attention".
  -- Cancel in-flight glide synchronously so residual scroll never
  -- lands in the newly-clicked window. The click itself always passes
  -- through.
  if etype == T.leftMouseDown then
    if self._anim.frameTimer then self:_cancelGlide() end
    return false, {}
  end

  -- Trackpad / Magic Mouse produce continuous scroll events; passthrough.
  if ev:getProperty(P.scrollWheelEventIsContinuous) ~= 0 then
    return false, {}
  end

  local function fy(v) return self.invertVertical   and -v or v end
  local function fx(v) return self.invertHorizontal and -v or v end

  if self.smoothness == 0 then
    -- Passthrough fast path when no inversion is configured.
    if not self.invertVertical and not self.invertHorizontal then
      return false, {}
    end

    -- Otherwise suppress the original and post a fresh event with the
    -- deltas already flipped. Mutating-in-place via setProperty turned
    -- out to be unreliable: some apps read a delta variant we didn't
    -- mutate and scroll in the original direction.
    local lineY  = ev:getProperty(P.scrollWheelEventDeltaAxis1)      or 0
    local lineX  = ev:getProperty(P.scrollWheelEventDeltaAxis2)      or 0
    local pointY = ev:getProperty(P.scrollWheelEventPointDeltaAxis1) or 0
    local pointX = ev:getProperty(P.scrollWheelEventPointDeltaAxis2) or 0

    local newLineY,  newLineX  = fy(lineY),  fx(lineX)
    local newPointY, newPointX = fy(pointY), fx(pointX)
    -- If the source event carried only line units, derive a pixel
    -- amount from them so newScrollEvent has something to scroll.
    if newPointY == 0 and newLineY ~= 0 then newPointY = newLineY * 10 end
    if newPointX == 0 and newLineX ~= 0 then newPointX = newLineX * 10 end

    local newEv = hs.eventtap.event.newScrollEvent({ newPointX, newPointY }, {}, "pixel")
    newEv:setProperty(P.scrollWheelEventDeltaAxis1, newLineY)
    newEv:setProperty(P.scrollWheelEventDeltaAxis2, newLineX)
    -- Stamp sentinel so our own tap skips this event on re-entry.
    newEv:setProperty(P.eventSourceUserData, SENTINEL)
    newEv:post()
    return true, {}
  end

  -- Smoothing path. Mirror MMF: the glide magnitude comes from
  -- pxStepSize (grade-driven), not the event delta. We only read the
  -- direction sign per axis here; fall back to point delta if the line
  -- delta is missing on this particular wheel.
  local sigY = sign(ev:getProperty(P.scrollWheelEventDeltaAxis1) or 0)
  local sigX = sign(ev:getProperty(P.scrollWheelEventDeltaAxis2) or 0)
  if sigY == 0 and sigX == 0 then
    sigY = sign(ev:getProperty(P.scrollWheelEventPointDeltaAxis1) or 0)
    sigX = sign(ev:getProperty(P.scrollWheelEventPointDeltaAxis2) or 0)
  end

  self:_updateBurst()
  self:_enqueueSmooth(fx(sigX), fy(sigY))
  self.logger.d(string.format("smooth: tick dirX=%d dirY=%d grade=%d tick=%d swipe=%d",
    fx(sigX), fy(sigY), self.smoothness,
    self._burst.tickCount, self._burst.swipeCount))
  return true, {}
end

--- MouseScrollTweaks:start()
--- Method
--- Installs the scroll-event tap. Errors loudly if Hammerspoon does not
--- have Accessibility permission, since `hs.eventtap` silently fails
--- without it. Idempotent — calling `start()` again replaces the tap.
---
--- Returns:
---  * self
function obj:start()
  -- Pure-Lua setup only — no OS calls.
  --
  -- All the OS-touching work (accessibility check, engine dofile,
  -- eventtap creation/registration, NSWorkspace app-watcher) is
  -- pushed into a `hs.timer.doAfter(self.startupDelay, ...)`
  -- callback so this spoon's `:start()` returns immediately at
  -- reload time and looks like FocusFollowsMouse's polling
  -- `start()` to the main run loop. See `obj.startupDelay` doc
  -- for the cold-start contention rationale.
  --
  -- Idempotent: cancels any pending deferred init and stops any
  -- previously-running tap/watcher before scheduling fresh ones.
  self.smoothness = normaliseSmoothness(self.smoothness)
  if self._startupTimer then self._startupTimer:stop(); self._startupTimer = nil end
  if self._tap        then self._tap:stop();        self._tap        = nil end
  if self._appWatcher then self._appWatcher:stop(); self._appWatcher = nil end

  self._startupTimer = hs.timer.doAfter(self.startupDelay or 3, function()
    self._startupTimer = nil

    if not hs.accessibilityState() then
      self.logger.e("MouseScrollTweaks requires Accessibility permission for "
                    .. "Hammerspoon (System Settings -> Privacy & Security -> "
                    .. "Accessibility); spoon not started.")
      return
    end

    -- Auto-detect: use the smoothscroll module if installed, else default.
    self:_loadEngine()

    self._tap = hs.eventtap.new(
      { hs.eventtap.event.types.scrollWheel,
        hs.eventtap.event.types.leftMouseDown },
      function(ev) return self:_handle(ev) end
    )
    self._tap:start()

    -- App-activation watcher: cancel any in-flight glide when the
    -- frontmost app changes (Cmd-Tab, clicking another window) so the
    -- residual scroll doesn't bleed into the new window.
    self._appWatcher = hs.application.watcher.new(function(_, eventType, _)
      if eventType == hs.application.watcher.activated then
        self:_cancelGlide()
      end
    end)
    self._appWatcher:start()

    self.logger.i(string.format(
      "started; invertV=%s invertH=%s smoothness=%d engine=%s",
      tostring(self.invertVertical),
      tostring(self.invertHorizontal),
      self.smoothness,
      (self._engineImpl and self._engineImpl.name) or "?"))
  end)

  return self
end

--- MouseScrollTweaks:stop()
--- Method
--- Stops the event tap and cancels any in-flight smoothing animation.
---
--- Returns:
---  * self
function obj:stop()
  if self._startupTimer then self._startupTimer:stop(); self._startupTimer = nil end
  if self._tap then self._tap:stop(); self._tap = nil end
  if self._appWatcher then self._appWatcher:stop(); self._appWatcher = nil end
  if self._anim.frameTimer then self._anim.frameTimer:stop(); self._anim.frameTimer = nil end
  if self._engineImpl and self._engineImpl.nativeOutput
     and type(self._engineImpl.stopNative) == "function" then
    self._engineImpl.stopNative()
  end
  self._anim.x              = newAxisState()
  self._anim.y              = newAxisState()
  self._anim.lastFrameS  = 0
  self._anim.lastTickS   = 0
  self._anim.startPid    = 0
  self._anim.startMouseX = 0
  self._anim.startMouseY = 0
  self._burst.tickCount     = 0
  self._burst.swipeCount    = 0
  self._burst.lastTickS     = 0
  self._burst.lastSwipeEndS = 0
  self._engineImpl = nil
  self.logger.i("stopped")
  return self
end

--- MouseScrollTweaks:toggle()
--- Method
--- Toggles the Spoon on/off and shows a brief `hs.alert` banner so the
--- user can tell which state they're in without checking the console.
--- Useful as a hotkey binding for apps where wheel-direction inversion
--- or smoothing would get in the way (games, drawing apps).
function obj:toggle()
  if self._tap and self._tap:isEnabled() then
    self:stop()
    hs.alert.show("MouseScrollTweaks: off")
  else
    self:start()
    hs.alert.show("MouseScrollTweaks: on")
  end
end

--- MouseScrollTweaks:bindHotkeys(mapping)
--- Method
--- Binds (or rebinds) keyboard shortcuts. The mapping table accepts a
--- `toggle` key with a `{mods, key}` pair compatible with
--- `hs.hotkey.bindSpec`. Calling `bindHotkeys` again clears prior
--- bindings first.
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

  if mapping and mapping.toggle then
    table.insert(self._hotkeys, hs.hotkey.bindSpec(mapping.toggle, function()
      self:toggle()
    end))
  end
  self.logger.i("bindHotkeys: bound " .. #self._hotkeys .. " hotkey(s)")
  return self
end

return obj
