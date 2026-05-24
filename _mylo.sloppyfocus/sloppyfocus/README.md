# hs._mylo.sloppyfocus

A small Hammerspoon native module that focuses a window without raising it
(X11-style "sloppy focus" on macOS). Designed to be called from the
[`FocusFollowsMouse`](../../FocusFollowsMouse.spoon) spoon's `_maybeFocus`
hook, but usable from any Lua code that has an `hs.window`.

## Why this exists

[AutoRaise](https://github.com/sbmpost/AutoRaise) does the same thing as a
standalone app, and that's the simpler option for most people. It has one
limitation though: it doesn't reliably focus Chromium-based PWAs (Brave/Chrome
"Install as App" windows). That's the gap this module fills — `hs.window`
identifies PWAs correctly, so passing its pid and window id straight into the
same SkyLight calls AutoRaise uses gets us focus-without-raise that works on
native apps *and* PWAs.

## How it works

Uses three private macOS APIs (resolved via `dlopen`/`dlsym` so a future
macOS that removes them just makes us degrade to a no-op):

- `_SLPSSetFrontProcessWithOptions(psn, wid, flags)` — tells SkyLight to make
  a process front for a specific window. Passing the real window id (not 0)
  is what avoids the raise.
- `SLPSPostEventRecordTo(psn, bytes)` — used to post synthetic key-window
  events (the byte layout was lifted from
  [yabai](https://github.com/koekeishiya/yabai) via AutoRaise).
- `GetProcessForPID` from ApplicationServices — to get a PSN from a pid.

The full recipe is documented inline in `internal.m`; it's a verbatim port
of `AutoRaise.mm` lines 169-221 with the gating logic stripped out (we let
`hs.window` decide what to focus).

## Build & install

```bash
cd sloppyfocus
make install       # copies into ~/.hammerspoon/hs/_mylo/sloppyfocus/
# or for development:
make link          # symlinks instead, so future `make` picks up automatically
```

Then **quit and relaunch Hammerspoon** (Reload Config does not refresh native
modules — already-loaded `.so` files stay pinned in `package.loaded`).

## Usage

```lua
local sloppy = require("hs._mylo.sloppyfocus")

-- Focus the window under the cursor without raising it:
local win = hs.window.windowsForApplication(app)[1]
sloppy.focusWithoutRaise(win)

-- When switching between two windows of the same app, also pass the
-- currently-focused window so SkyLight performs the extra deactivate/
-- activate dance it needs:
local current = hs.window.focusedWindow()
sloppy.focusWithoutRaise(target, current)
```

## API

### `focusWithoutRaise(win [, currentlyFocused]) -> boolean`

Gives keyboard focus to `win` without changing its position in the Z-order.

- `win` — an `hs.window`
- `currentlyFocused` — optional `hs.window` currently holding focus. Required
  only when switching between two windows of the same app (e.g. two iTerm
  windows); if omitted, same-app focus changes may appear to no-op.
- returns `true` on success, `false` if the SkyLight symbols couldn't be
  resolved, `GetProcessForPID` failed, or SLPS returned an error.

## Acknowledgments

- [AutoRaise](https://github.com/sbmpost/AutoRaise) — the focus-without-raise
  recipe, including the same-process dance, is a direct port of its logic.
- [yabai](https://github.com/koekeishiya/yabai) — the original
  `make_key_window` byte layout came from there.
