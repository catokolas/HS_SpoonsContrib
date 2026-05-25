# MoveSpaces

Keyboard shortcut to move the currently-focused window to the macOS Space
immediately to the left or right of the current Space, on the same screen.

## ⚠️ macOS 26.5 status: limited

On macOS 26 (Tahoe), Apple has gated cross-process Space movement at the
WindowServer level. Every userspace path tried — including
`hs.spaces.moveWindowToSpace`, the SkyLight private APIs called by the
optional [`hs._ckol.movetospace`](https://github.com/catokolas/HS_ModulesContrib-movetospace)
native helper, and synthesised `Ctrl+arrow` keystrokes at every event-tap
level — silently fails for windows owned by other applications.

In practice on macOS 26.5 the spoon:

- ✅ **Moves Hammerspoon's own windows** (Console, alerts).
- ❌ **Does not move windows owned by other apps** (Finder, Notes, VS Code,
  Brave, iTerm, Terminal, etc.) — the hotkey fires, but the window stays
  put.

For day-to-day cross-app Space management on macOS 26+, the practical
workaround is macOS's own **Mission Control drag-and-drop** (`F3` or
3-finger swipe up; then drag window thumbnails between Spaces).

The spoon is published here because:
- The implementation is correct and ready the day Apple loosens the
  restriction.
- It still works for same-process (Hammerspoon) windows.
- It demonstrates the limit clearly for anyone investigating the same
  problem.

## Installation

Clone this repo and symlink (or copy) `MoveSpaces.spoon` into
`~/.hammerspoon/Spoons/`:

```bash
ln -s "$PWD/MoveSpaces.spoon" ~/.hammerspoon/Spoons/MoveSpaces.spoon
```

For the best chance of actually moving a window (still only Hammerspoon-
owned ones on macOS 26.5), also install the
[`hs._ckol.movetospace`](https://github.com/catokolas/HS_ModulesContrib-movetospace)
native helper to `~/.hammerspoon/hs/_ckol/movetospace/`. The spoon picks it
up automatically.

## Usage

In `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("MoveSpaces")
spoon.MoveSpaces:bindHotkeys({
  space_left  = {{"shift","ctrl"}, "left"},
  space_right = {{"shift","ctrl"}, "right"},
})

-- Optional: silent move (viewer stays on the origin Space)
-- spoon.MoveSpaces.followWindow = false
```

Then reload Hammerspoon (menu bar → Reload Config). On macOS 26+ a Mission
Control transition is unavoidable because the only working code path needs
to switch the viewer.

## API

### Variables

| Variable | Default | Purpose |
|---|---|---|
| `MoveSpaces.followWindow` | `true` | After moving, also switch the viewer to the destination Space (Linux-desktop style). Set to `false` to snap the view back to the origin Space after the move (extra Mission Control transition). |
| `MoveSpaces.wrap` | `false` | At the leftmost/rightmost Space, wrap around instead of no-op. |
| `MoveSpaces.skipFullScreenSpaces` | `true` | Skip fullscreen-app Spaces when looking for a destination. |
| `MoveSpaces.logger` | `hs.logger.new("MoveSpaces")` | Logger; set its level to control verbosity. |

### Methods

#### `MoveSpaces:bindHotkeys(mapping)`

Binds keyboard shortcuts. The `mapping` table accepts `space_left` and
`space_right` keys, each a `{mods, key}` pair compatible with
`hs.hotkey.bindSpec`. Either may be omitted. Re-callable; clears prior
bindings first.

```lua
spoon.MoveSpaces:bindHotkeys({
  space_left  = {{"shift","ctrl"}, "left"},
  space_right = {{"shift","ctrl"}, "right"},
})
```

#### `MoveSpaces:moveFocusedWindowLeft()` / `:moveFocusedWindowRight()`

Public methods callable directly — e.g. from your own hotkey, menu item, or
`hs.urlevent` handler.

## Permissions

Hammerspoon needs **Accessibility** (System Settings → Privacy & Security →
Accessibility) and on macOS 26+ also **Screen Recording** (Privacy &
Security → Screen Recording) for `hs.spaces` calls to succeed.

## Acknowledgments

Inspired by an earlier `MoveSpaces.spoon` by Tyler Thrailkill (Spoon
packaging) and Szymon Kaliski (original code). That version simulated a
title-bar drag against the now-deprecated `hs._asm.undocumented.spaces`
module; this is a rewrite using `hs.spaces` plus the
`hs._ckol.movetospace` native helper for the SkyLight code paths.

## License

MIT — see [`LICENSE`](LICENSE).
