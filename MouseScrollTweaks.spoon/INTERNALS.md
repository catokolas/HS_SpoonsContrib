# MouseScrollTweaks — Internals

Technical notes on the smoothing engine, scroll-event handling, glide
cancellation logic, and tuning knobs. Aimed at anyone reading the code
or tweaking the per-grade table.

Public API and end-user usage live in [`README.md`](README.md).

## Behaviour

The Spoon installs a single `hs.eventtap` on `scrollWheel` and
`leftMouseDown`. For each event:

| Condition | Action |
|---|---|
| Tap was disabled (timeout / user input) | Re-enable in place |
| `leftMouseDown` | Cancel any in-flight glide (passthrough the click) |
| Event came from our own synthetic posts (sentinel match) | Passthrough |
| `scrollWheelEventIsContinuous` ≠ 0 (trackpad / Magic Mouse) | Passthrough |
| Discrete wheel, `smoothness == 0` | Suppress; post a fresh event with inverted deltas |
| Discrete wheel, `smoothness > 0` | Suppress; update burst counters; add to per-axis glide buffer; pump synthetic pixel events on a 240 Hz timer |

### Smoothing model

Ported from
[mac-mouse-fix](https://github.com/noah-nuebling/mac-mouse-fix)'s
`SmoothScroll.m` (MIT, © Noah Nuebling). Each wheel tick drives a two-
phase glide on a ~240 Hz frame loop:

- **Linear phase.** A grade-driven `pxStepSize` of pixels is added to a
  per-axis buffer; the frame loop distributes that buffer linearly over
  `msPerStep` ms at constant velocity. The event's delta magnitude is
  **ignored** — only its sign drives direction, so every notch glides
  the same configured amount regardless of how big the OS scaled it.
- **Momentum phase.** When the linear budget runs out, the final
  velocity carries on while friction
  (`Δv = -sign(v)·|v|^frictionDepth·friction/100·Δt`) decays it. The
  glide ends when velocity hits zero or `±1px` frames pile up.

The per-tick `pxStepSize` is deliberately **small**; magnitude on rapid
scroll comes from the two-level acceleration below, not from `grade`.
`grade` mainly tunes the *feel*: friction (tail length), per-tick
acceleration multiplier, and the 1-px dribble at the end.

| grade | pxStepSize | msPerStep | acceleration | friction | onePxLimit |
|---|---|---|---|---|---|
| 1  | 8   | 90ms | 1.19 | 2.30 | 2 |
| 5  | 16  | 90ms | 1.35 | 2.30 | 2 |
| 10 | 26  | 90ms | 1.55 | 2.30 | 2 |
| 15 | 36  | 90ms | 1.75 | 2.30 | 2 |
| 16 | 38  | 90ms | 1.79 | 2.12 | 3 |
| 18 | 42  | 90ms | 1.87 | 1.76 | 5 |
| 20 | 46  | 90ms | 1.95 | 1.40 | 7 |

Grades **0–15** use MMF's defaults verbatim for `friction` (2.3) and
`onePxLimit` (2), producing a short dense ~100–200 ms momentum tail —
the recipe behind MMF's smooth glide end. Grades **16–20** taper
`friction` down to `1.40` and stretch `onePxLimit` up to `7`,
modestly extending the tail to ~250 ms — longer than MMF but still
below the perceptual stutter threshold (the human eye perceives
1-pixel-per-frame scroll as discrete steps at 60 Hz, so a much longer
tail would look jerky regardless of frame timing precision). Grade
scales **magnitude** (`pxStepSize`) and **per-tick acceleration**
across the whole range.

Direction reversal flushes any in-flight buffer/momentum on that axis.

### Acceleration — MMF tick / swipe model

Ported from
[mac-mouse-fix](https://github.com/noah-nuebling/mac-mouse-fix)'s
`ScrollUtility.m` (MIT, © Noah Nuebling). A cross-axis `_burst` tracker
counts:

- **Ticks** — wheel events. Resets after a gap > **130 ms**.
- **Swipes** — completed bursts of ≥ 2 ticks. Reset if the gap between
  burst-end and the next burst-start is > **350 ms**.

Two multipliers stack on top of the small base `pxStepSize`:

- **Per-tick** (`× acceleration`) on every tick after the first within
  the current burst. So a five-click burst at grade 5 scales the buffer
  by `1.25⁴ ≈ 2.4×` over the same five ticks.
- **Fast-scroll** (`× 1.1 × 1.1^(swipes − 3)`) once **3** swipes have
  accumulated. Sustained spinning ramps roughly geometrically and
  produces the long, smooth sweep.

This is why a single isolated wheel click feels nearly silent in
browsers / ~1 line in iTerm — there's no burst, no swipe, just
`pxStepSize` of motion plus a brief momentum tail — while rapid
spinning quickly accelerates into a long glide.

### Glide cancellation

Four layered triggers cancel an in-flight glide so residual scroll
doesn't bleed into a window the user has moved to:

- **`leftMouseDown` in the event tap.** The fastest, synchronous
  catch — clicking any window stops the glide before the very next
  frame ticks. The click itself always passes through.
- **Per-frame mouse-motion guard.** `_frameTick` reads
  `hs.mouse.absolutePosition()` and compares against the position
  captured at glide start. If the cursor has moved more than
  `MOUSE_CANCEL_PX` (60 px), cancel. Important for sloppy-focus
  setups (e.g. `FocusFollowsMouse.spoon`) where focus changes on
  mouse-rest without any click — this trigger fires *before* the
  sloppy-focus debounce does its swap, so no scroll leaks into the
  new window.
- **Per-frame frontmost-pid guard.** Compares
  `hs.application.frontmostApplication():pid()` against the pid
  captured at glide start. Catches Cmd-Tab, Spaces switches, and any
  same-app window change the click and motion branches missed.
- **`hs.application.watcher` `activated` callback.** Safety net for
  edge cases (notification stealing focus without a mouse click or
  cursor motion).

### Event composition

Posted synthetic events carry both **pixel delta** and an integer
**line delta** on **every frame** (including the momentum tail), with
the line delta drained from a per-axis fractional accumulator that
grows in proportion to the pixels glided (`Δaccum = px / 40`). The
`40` is a compromise between iTerm's line-count sensitivity and the
browser/VS Code-side smoothness — increase it (e.g. to `60`) for less
iTerm scroll per click, or lower it (e.g. to `20`) for denser line
emission if browsers feel chunky. MMF emits at `px / 8` from a helper
process and runs its frame loop on a `CVDisplayLink` (true display
refresh). This Spoon's frame loop runs at **240 Hz** via
`hs.timer.doEvery` — the closest `hs.timer` can practically get to
MMF's display-synced refresh — and uses a **per-axis sub-pixel
accumulator** (`pxAccum`) so the per-frame rounding residual carries
forward instead of being discarded. In addition, every posted event
carries the smooth fractional displacement in
`scrollWheelEventFixedPtDeltaAxis1/2` (16.16 fixed-point), which
modern browsers / AppKit scroll views consume for **sub-pixel
resolution** even on frames where the integer pixel delta rounds to
zero — the tail decay therefore renders continuously instead of
stairstepping through visible integer velocity transitions.

The synthetic events are **not** marked `IsContinuous = 1`, because
that flag flips iTerm into pixel-scrolling mode (each glide pixel ≈
1/10 of a terminal line, badly overshooting). Re-entry through the
tap is prevented instead with a sentinel stamped on
`eventSourceUserData` — the handler short-circuits any event carrying
it.

### Caveats

- Smoothing only affects **discrete** mouse-wheel events. Trackpad and
  Magic Mouse always passthrough — that's the whole point.
- The grade-driven `pxStepSize` overrides the event's delta magnitude
  (only the sign is used). If you have macOS "Scroll speed" set very
  low or very high, the smoothed scroll won't follow that setting;
  tune `smoothness` instead.
- `hs.eventtap.event.types.scrollWheel` is global; if you currently
  intercept scroll events elsewhere in your `init.lua`, expect
  interaction with this Spoon.
- Changing `invertVertical`/`invertHorizontal`/`smoothness` after
  `start()` is read live at each tick — no restart needed.
