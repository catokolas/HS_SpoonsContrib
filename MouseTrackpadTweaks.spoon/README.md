# MouseTrackpadTweaks

Per-device input tweaks for the Magic Mouse and the built-in Trackpad
that macOS doesn't expose itself:

1. **Magic-Mouse-only scroll inversion.** Flips vertical (and optionally
   horizontal) scroll on the Magic Mouse while leaving the trackpad
   untouched — useful when the trackpad is set to "Natural" and the
   mouse should scroll the other way.
2. **Middle-click synthesis.** Fires a middle-click on either
   (a) an N-finger tap or click, or (b) a 1-finger tap or click inside
   a configurable top-center region of the device surface. Each
   trigger mode can independently be set to fire on `"tap"`, `"click"`,
   or `"either"`.

> **Note** — both features depend on the optional
> [`hs._ckol.multitouch`](https://github.com/catokolas/HS_ModulesContrib-multitouch)
> native helper, which wraps Apple's `MultitouchSupport.framework`.
> Without it, the Spoon loads cleanly, logs a warning, and lets all
> events pass through unmodified.

## Installation

Clone, then symlink into `~/.hammerspoon/Spoons`:

```bash
git clone git@github.com:catokolas/HS_SpoonsContrib.git
cd HS_SpoonsContrib

mkdir -p ~/.hammerspoon/Spoons
ln -s "$PWD/MouseTrackpadTweaks.spoon" ~/.hammerspoon/Spoons/MouseTrackpadTweaks.spoon
```

## Usage

In `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("MouseTrackpadTweaks")
spoon.MouseTrackpadTweaks:configure({
  invertVertical   = true,
  invertHorizontal = false,
  middleClick = {
    enabled = true,
    multiFinger = {
      fingerCount = 3,             -- 3-finger tap/click → middle-click
      trigger     = "either",
    },
    topCenter = {
      xMin = 0.30, xMax = 0.70,    -- middle 40% of the device, top 30%
      yMin = 0.00, yMax = 0.30,
      trigger = "tap",             -- only taps in the region trigger
                                   -- (clicks in the region stay normal)
    },
    tap = {
      maxDurationMs = 200,
      maxTravelPx   = 12,
    },
  },
})
spoon.MouseTrackpadTweaks:start()
spoon.MouseTrackpadTweaks:bindHotkeys({
  toggle             = {{"ctrl","cmd"}, "m"},
  toggleInvertScroll = {{"ctrl","cmd"}, "i"},
  toggleMiddleClick  = {{"ctrl","cmd"}, "k"},
})
```

Then reload Hammerspoon (menu bar → Reload Config).

## API

### Variables

| Variable | Default | Purpose |
|---|---|---|
| `MouseTrackpadTweaks.invertVertical` | `true` | If true, flip Magic Mouse vertical scroll. Trackpad unaffected. |
| `MouseTrackpadTweaks.invertHorizontal` | `false` | If true, flip Magic Mouse horizontal scroll. |
| `MouseTrackpadTweaks.middleClick` | _(table — see below)_ | Middle-click synthesis configuration. |
| `MouseTrackpadTweaks.logger` | `hs.logger.new("MouseTrackpadTweaks")` | Logger; set its level to control verbosity. |

### `middleClick` configuration table

```lua
middleClick = {
  enabled = true,

  multiFinger = {
    enabled     = true,
    fingerCount = 3,                -- ≥ this many fingers triggers middle-click
    trigger     = "either",         -- "tap" | "click" | "either"
  },

  topCenter = {
    enabled = true,
    devices = { magicMouse = true, trackpad = true },
    trigger = "either",             -- "tap" | "click" | "either"
    xMin = 0.30, xMax = 0.70,       -- normalized fractions of the
    yMin = 0.00, yMax = 0.30,       -- device surface (0,0 = top-left)
  },

  tap = {                           -- shared tap-validity thresholds
    maxDurationMs = 200,            -- touch-begin → all-touches-ended
    maxTravelPx   = 12,             -- cursor travel during the touch
  },
}
```

`trigger` values:

- `"tap"` — fire on touch-and-lift without a physical click.
- `"click"` — fire only when the device's physical click occurs.
- `"either"` — fire on either, the default.

Region coordinates are **fractions of the device surface**, not screen
pixels. `(0, 0)` is the top-left of the device's touch surface;
`(1, 1)` is the bottom-right. This makes the same region setting
sensible across the Magic Mouse and the built-in Trackpad.

### Methods

#### `MouseTrackpadTweaks:configure(configuration)`

Deep-merges configuration values into the spoon. Partial sub-tables
override only the keys they contain, e.g.:

```lua
spoon.MouseTrackpadTweaks:configure({
  middleClick = { multiFinger = { fingerCount = 4 } },
})
```

…leaves every other `middleClick` field at its current value.

#### `MouseTrackpadTweaks:start()`

Installs the eventtap and (if the native module is available) starts
the multitouch callback. Errors if Hammerspoon does not have
Accessibility permission.

#### `MouseTrackpadTweaks:stop()`

Stops the eventtap and multitouch callback; clears all per-device
touch state.

#### `MouseTrackpadTweaks:toggle()`

Toggles the Spoon on/off and shows a brief `hs.alert` banner.

#### `MouseTrackpadTweaks:toggleInvertScroll()`

Toggles `invertVertical` and shows an `hs.alert` banner.

#### `MouseTrackpadTweaks:toggleMiddleClick()`

Toggles `middleClick.enabled` and shows an `hs.alert` banner.

#### `MouseTrackpadTweaks:bindHotkeys(mapping)`

Binds keyboard shortcuts. Supported actions: `toggle`,
`toggleInvertScroll`, `toggleMiddleClick`. Each value is a
`{mods, key}` pair compatible with `hs.hotkey.bindSpec`.

## Permissions

Hammerspoon needs **Accessibility** (System Settings → Privacy &
Security → Accessibility) for the eventtap. The `hs._ckol.multitouch`
native module does not require any additional permissions —
MultitouchSupport.framework is accessible to any process.

## Companion native module

`hs._ckol.multitouch` is expected to expose:

```
hs._ckol.multitouch.start(callback)
  -- callback(deviceId, deviceKind, touchId, phase, nx, ny, timestamp)
hs._ckol.multitouch.stop()
```

See [`native_bridge.lua`](native_bridge.lua) for the full contract.
Build/install instructions live with the module repo
(`HS_ModulesContrib-multitouch`).

The Spoon also functions partially without the native module:

| Feature | Without `hs._ckol.multitouch` |
|---|---|
| Magic Mouse scroll inversion | disabled (events pass through unchanged) |
| Middle-click via tap         | disabled (no touch events to observe)    |
| Middle-click via click       | disabled (no way to count fingers)       |

A single warning is logged on `start()`; nothing else is touched.

## Coexistence with `MouseScrollTweaks.spoon`

Both Spoons install scroll-wheel event taps. They do not conflict:

- `MouseScrollTweaks` ignores continuous-scroll events (trackpad / Magic
  Mouse) via `scrollWheelEventIsContinuous`, so its delta-flipping and
  smoothing logic never see Magic Mouse events.
- `MouseTrackpadTweaks` ignores non-continuous (traditional wheel)
  events, so MouseScrollTweaks' smoothing for wheel mice is untouched.
- Each Spoon stamps its own sentinel on synthetic events
  (`eventSourceUserData`); neither re-enters the other's handler.

## Logging / debug output

Set the Spoon's logger level to `debug` to trace touch sessions and
middle-click decisions:

```lua
spoon.MouseTrackpadTweaks.logger.setLogLevel("debug")
```

Inspect live state from the Console:

```lua
-- Currently active touches per device
hs.inspect(spoon.MouseTrackpadTweaks._touches)

-- Last observed touch (used for scroll attribution)
hs.inspect(spoon.MouseTrackpadTweaks._lastTouch)
```

## License

MIT — see [`LICENSE`](LICENSE).
