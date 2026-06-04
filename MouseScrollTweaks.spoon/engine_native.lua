--- === MouseScrollTweaks engine: native ===
---
--- Bridge to the `hs._ckol.smoothscroll` native helper. The native
--- module posts continuous-scroll CGEvents (`NSEventTypeScrollWheel`
--- with `IsContinuous=1`) from a `CVDisplayLink` callback, with a
--- biased point-delta sub-pixelator that emits one event per crossed
--- integer pixel — so a slow click produces exactly one event with
--- delta ±1, and the receiving app's continuous-scroll handler treats
--- the gesture+momentum stream as one logical scroll. This sidesteps
--- the synthetic-discrete-wheel discard ceiling that defeated every
--- prior engine on this branch (see `INTERNALS.md`).
---
--- ## Why this engine isn't shaped like the others
---
--- The standard engine contract (`enqueueAxis` + `advanceAxis`) assumes
--- the Spoon owns the frame loop and CGEvent composition. Here the
--- native module owns both: it runs its own per-vsync display-link
--- callback and posts CGEvents directly from C. The Spoon's job is
--- reduced to:
---
---   * Receive wheel ticks from its eventtap (unchanged).
---   * Forward each tick to the native module via `link.tick(dx, dy)`.
---   * Run the cancellation guards (mouse motion, app switch) on a
---     lightweight watchdog and call `link.cancel()` if any fire.
---
--- This engine therefore declares `nativeOutput = true`, which causes
--- `init.lua` to:
---
---   * Skip starting the per-axis frame timer entirely.
---   * Call `tickNative(dirX, dirY)` instead of two per-axis enqueues.
---   * Run a watchdog (cancellation guards only, ~50 Hz) while gesture
---     activity is recent.
---
--- ## Grade mapping
---
--- The native module exposes `pxStepSize`, `acceleration`, `dragA`
--- and friends; smoothness 0..20 maps to these via `paramsFor(grade)`.
--- Live re-configure on each tick so changes via `:configure({
--- smoothness=N })` take effect without restart.

return function(ctx)

  -- Try to load the native module. If it isn't installed, surface a
  -- clean error to init.lua's _loadEngine so it falls back to default
  -- with a logged warning.
  local ok, link = pcall(require, "hs._ckol.smoothscroll")
  if not ok or type(link) ~= "table" or
     type(link.configure) ~= "function" or
     type(link.tick) ~= "function" then
    error("hs._ckol.smoothscroll not loaded: " .. tostring(link))
  end

  -- ## Per-grade parameter table
  local function lerp(a, b, t) return a + (b - a) * t end
  local function lerp3(g, v0, v10, v20)
    if g <= 0  then return v0  end
    if g >= 20 then return v20 end
    if g <= 10 then return lerp(v0,  v10, g / 10)        end
    return                  lerp(v10, v20, (g - 10) / 10)
  end

  --   pxStepSize:       base px per tick. Flat at the high end so the
  --                     animator's biased sub-pixelator always emits
  --                     exactly one event per slow isolated click — that
  --                     gives "1 line per click in terminals, 5 in
  --                     iTerm+tmux" across the whole grade range.
  --                     Capped at 2: the threshold above which the
  --                     accumulator crosses ±1 a second time during the
  --                     `msPerStep` drain is ~2.16 px, so values up to
  --                     2.0 stay safely in the single-event regime.
  --                     Smoothness still differentiates grades — it's
  --                     `dragCoefficient` that scales (longer momentum
  --                     tail at higher grades), not per-click magnitude.
  --   acceleration:     per-tick burst multiplier (compounds the whole
  --                     buffer, matching default engine semantics).
  --   msPerStep:        ms to drain the buffer at constant rate.
  --   gestureEndGapMs:  ms since last tick before momentum starts.
  --   dragCoefficient:  DragCurve `a` for the momentum tail (1/ms units
  --                     when dragExponent=1). Smaller a → longer tail.
  --                     This is one of two knobs smoothness sweeps:
  --                     g0=0.046, g10=0.023, g20=0.008.
  --   dragExponent:     DragCurve `b` — the v'(t) = -a·v^b shape.
  --                     b=1 (exponential decay) at low/mid grade gives
  --                     even deceleration. b=0.7 at g20 decays slower
  --                     at high velocity and faster at low velocity —
  --                     the "coast at speed, snap to stop" feel.
  --   stopSpeed:        px/ms — momentum cutoff (~10..50 px/s).
  --   linePx:           px per emitted line delta.
  local function paramsFor(grade)
    return {
      pxStepSize       = lerp3(grade, 1,     2,     2    ),
      acceleration     = lerp3(grade, 1.19,  1.55,  1.95 ),
      msPerStep        = 90,
      gestureEndGapMs  = lerp3(grade, 60,    80,    120  ),
      dragCoefficient  = lerp3(grade, 0.046, 0.023, 0.008),
      dragExponent     = lerp3(grade, 1.0,   1.0,   0.7  ),
      stopSpeed        = lerp3(grade, 0.05,  0.030, 0.015),  -- px/ms
      linePx           = 10,
      tickGap          = 0.13,
      swipeGap         = 0.35,
      swipeTickThresh  = 2,
      fastSwipeThresh  = 3,
      fastFactor       = 1.2,
      fastBase         = 1.15,
      sentinel         = 0xC0DE5C01,
    }
  end

  local lastConfiguredGrade = nil

  local function configureForCurrentGrade()
    local g = ctx.smoothness()
    if g ~= lastConfiguredGrade then
      link.configure(paramsFor(g))
      lastConfiguredGrade = g
      ctx.logger.d(string.format("engine 'native': configured for smoothness=%d", g))
    end
  end

  -- Initial config so first tick has sane params.
  configureForCurrentGrade()

  -- ## Engine impl
  --
  -- The contract surface init.lua hits:
  --   * nativeOutput = true → signals init.lua to take the
  --     tick-forwarding path instead of per-axis enqueue/advance.
  --   * tickNative(dirX, dirY) → called once per wheel event with the
  --     resolved (and inversion-adjusted) direction signs.
  --   * cancelNative() / stopNative() → cancellation + lifecycle.
  --
  -- enqueueAxis / advanceAxis are present as no-ops so the loader's
  -- contract check passes; init.lua won't actually call them when
  -- nativeOutput is true.
  return {
    name         = "native",
    nativeOutput = true,
    tickNative = function(dirX, dirY)
      configureForCurrentGrade()
      link.tick(dirX, dirY)
    end,
    cancelNative = function()
      link.cancel()
    end,
    stopNative = function()
      link.stop()
    end,
    enqueueAxis = function() end,
    advanceAxis = function() return 0, 0 end,
  }
end
