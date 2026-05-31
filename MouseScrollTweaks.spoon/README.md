# MouseScrollTweaks

Tweaks for traditional mouse wheels on macOS, without touching the
trackpad or Magic Mouse:

- **Per-axis direction inversion.** Flip the vertical and / or
  horizontal (tilt-wheel) direction independently of the system
  "Natural scrolling" toggle — which on macOS ties trackpad and mouse-
  wheel direction together. You can keep natural scrolling **on** for
  the trackpad and have the mouse wheel feel "normal".
- **Smoothness grade 0–20.** Each discrete wheel tick is interpolated
  into a short sequence of small pixel-unit events, giving the chunky
  notched wheel a buttery glide. `0` is off (passthrough), `20` is the
  longest, smoothest curve, `15` has a shorter curve.

Trackpads and Magic Mouse produce continuous scroll events; they are
detected via `scrollWheelEventIsContinuous` and **passed through
untouched** at every grade.

Implemented entirely in pure Lua on `hs.eventtap` — no native helper,
no companion app.

## Installation

Clone, then symlink into `~/.hammerspoon/Spoons`:

```bash
git clone git@github.com:catokolas/HS_SpoonsContrib.git
cd HS_SpoonsContrib

mkdir -p ~/.hammerspoon/Spoons
ln -s "$PWD/MouseScrollTweaks.spoon" ~/.hammerspoon/Spoons/MouseScrollTweaks.spoon
```

Hammerspoon needs **Accessibility permission** (System Settings →
Privacy & Security → Accessibility). `start()` will error loudly if it
doesn't.

## Usage

In `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("MouseScrollTweaks")
spoon.MouseScrollTweaks:configure({
  -- invertVertical   = true,    -- flip mouse-wheel vertical (default true)
  -- invertHorizontal = true,    -- flip tilt-wheel horizontal (default true)
  smoothness          = 20,      -- 0 = off, 20 = max
}):start()

-- Optional: toggle on/off with Ctrl+Cmd+M.
spoon.MouseScrollTweaks:bindHotkeys({
  toggle = { {"ctrl", "cmd"}, "m" },
})
```

Then reload Hammerspoon (menu bar → Reload Config).

Live re-tuning works without restarting the spoon:

```lua
spoon.MouseScrollTweaks:configure({ smoothness = 8 })
spoon.MouseScrollTweaks:configure({ invertHorizontal = false })
```

## API

### Variables

| Variable | Default | Purpose |
|---|---|---|
| `MouseScrollTweaks.invertVertical` | `true` | Flip vertical wheel direction. Discrete events only. |
| `MouseScrollTweaks.invertHorizontal` | `true` | Flip horizontal (tilt-wheel) direction. Discrete events only. |
| `MouseScrollTweaks.smoothness` | `0` | Smoothing intensity, integer in `[0, 20]`. `0` = off / passthrough; `5–10` is subtle; `10–15` approximates MMF; `15–20` leans into long glides. Clamped + rounded in `configure`. |
| `MouseScrollTweaks.logger` | `hs.logger.new("MouseScrollTweaks")` | Logger; set its level to control verbosity. |

### Methods

#### `MouseScrollTweaks:configure(configuration)`

Merges configuration values into the spoon. Accepts any of the public
variables above. `smoothness` is clamped to `[0, 10]` and rounded.

- `configuration` — a table of configuration values

Returns: `self` (chainable).

#### `MouseScrollTweaks:start()`

Installs the scroll-event tap. Errors loudly if Accessibility
permission is missing. Idempotent — calling again replaces the tap.

Returns: `self`.

#### `MouseScrollTweaks:stop()`

Stops the event tap and cancels any in-flight smoothing animation.

Returns: `self`.

#### `MouseScrollTweaks:toggle()`

Toggles the spoon on/off and shows a brief `hs.alert` banner. Useful as
a hotkey binding for apps where inversion or smoothing gets in the way
(games, drawing apps).

#### `MouseScrollTweaks:bindHotkeys(mapping)`

Binds (or rebinds) keyboard shortcuts. The mapping table accepts a
`toggle` key with a `{mods, key}` pair compatible with
`hs.hotkey.bindSpec`. Calling `bindHotkeys` again clears prior bindings
first.

- `mapping` — table like `{ toggle = {{"ctrl","cmd"}, "m"} }`

Returns: `self`.

## Behaviour, smoothing model, internals

The full design — eventtap dispatch table, MMF-derived two-phase glide,
per-tick / per-swipe acceleration, glide-cancellation layers, event
composition, and caveats — is in [`INTERNALS.md`](INTERNALS.md).

## Logging / debug output

All messages go to the **Hammerspoon Console** (menu bar → Hammerspoon
→ Console). The Spoon uses `hs.logger`; default level is `warning`, so
normal scroll traffic is silent.

The five `hs.logger` levels (least to most verbose):
`error` < `warning` < `info` < `debug` < `verbose`. A given level
shows messages at that level and everything above. Change at runtime
in the Console:

```lua
spoon.MouseScrollTweaks.logger.setLogLevel("debug")
```

Or pin it from your `~/.hammerspoon/init.lua` (after `start()`):

```lua
spoon.MouseScrollTweaks.logger.setLogLevel("debug")
```

What each level emits in this Spoon:

| Level | Sample messages |
|---|---|
| `warning` | `eventtap was disabled; re-enabling` (the tap auto-rearms after a timeout / user-input drop) |
| `info`    | `started; invertV=true invertH=true smoothness=5`, `stopped` |
| `debug`   | `smooth: enqueue dx=… dy=… grade=…` (per wheel tick when `smoothness > 0`) |

`debug` is the right level when tuning the smoothness curve or
verifying that a particular device is being treated as
discrete vs. continuous. Reset to `warning` (or omit the
`setLogLevel` line) once you're happy.

## Acknowledgments

The smoothing engine — two-phase linear + momentum glide, friction-
based velocity decay, the tick / swipe counters and the two-level
acceleration model — is ported from the Obj-C scroll subsystem of
[Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix)
by Noah Nuebling. The specific sources we read came from a local MMF
clone at `master` commit `fd5119c04` (16 November 2022) —
`Helper/InputTransformation/Scroll/SmoothScroll.m`,
`ScrollUtility.m`, and `App/Config/default_config.plist`. That tree
was MIT-licensed (`Copyright (c) 2019 noah.n`).

The mainline of MMF (v3) was substantially **rewritten in Swift**
earlier the same year — the scroll subsystem moved under
`Helper/Core/Scroll/`, with new analytic animation curves
(`DragCurve.swift`, `HybridCurves.swift`) added on **7-8 August 2022**
(commits `853bd1773` and `50e1656ec`). MMF was also **relicensed** on
**11 September 2022** (commit `0449cf1c9`) under a custom "MMF
License" (more restrictive than MIT — see
[`License`](https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
upstream). **Neither change is in the ancestry of the v2-maintenance
commit our snapshot sits on** — both happened on the v3 development
line and were not merged back into v2-maintenance. So the source we
ported is genuinely MIT-licensed and this Spoon continues under MIT
with the original MMF copyright notice preserved in this credit.

This Spoon is a Lua reimplementation on `hs.eventtap` / `hs.timer`;
the per-grade curve, per-axis inversion, the cancel-on-focus / click
/ mouse-motion layers, and the 240 Hz sub-pixel-accumulator frame
loop are Spoon-side additions.

## License

MIT — see [`LICENSE`](LICENSE).
