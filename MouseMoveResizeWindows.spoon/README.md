# MouseMoveResizeWindows

Hold a configurable modifier chord and drag anywhere inside a window
to move or resize it — no need to aim for the title bar or a corner.
The Mutter / GNOME "Super+drag" muscle memory, ported to macOS with a
modifier that doesn't fight the system shortcuts (Option by default).

* **Modifier + left-drag** → moves the window, tracking the cursor.
* **Modifier + right-drag** → resizes the window by moving the
  **closest edge** (left, right, top, or bottom — picked once at
  mouse-down from the four edge-distances).

Releasing the modifier mid-drag aborts the gesture cleanly. Clicks
without the modifier are passed through untouched.

## Activate hotkey

Default chord: **⇧⌃⌘W**. Press it to toggle the Spoon on/off; an
`hs.alert` banner confirms the new state. Declared as `activateHotkey`
in `spoon-manifest.json` and bound automatically by
[MacSpoonsTweaks](https://github.com/catokolas/MacSpoonsTweaks).
Standalone users can bind `:toggle()` via `:bindHotkeys`.

## Installation

Clone, then symlink into `~/.hammerspoon/Spoons`:

```bash
git clone git@github.com:catokolas/HS_SpoonsContrib.git
cd HS_SpoonsContrib

mkdir -p ~/.hammerspoon/Spoons
ln -s "$PWD/MouseMoveResizeWindows.spoon" ~/.hammerspoon/Spoons/MouseMoveResizeWindows.spoon
```

## Usage

In `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("MouseMoveResizeWindows")
spoon.MouseMoveResizeWindows:configure({
  modifiers  = { "alt" },     -- any modifier names hs.eventtap surfaces (today: ctrl/alt/shift/cmd/fn)
  firstRaise = true,          -- focus and raise the window at drag start
})
spoon.MouseMoveResizeWindows:bindHotkeys({
  toggle = { { "shift", "ctrl", "cmd" }, "w" },
})
spoon.MouseMoveResizeWindows:start()
```

## Configuration

| Field        | Type             | Default   | Description                                           |
| ------------ | ---------------- | --------- | ----------------------------------------------------- |
| `modifiers`  | `{string,…}`     | `{"alt"}` | Modifier chord required to arm a drag. Names are matched exactly against `hs.eventtap.event:getFlags()`; the Spoon doesn't hardcode a list. Today Hammerspoon surfaces `ctrl`, `alt`, `shift`, `cmd`, `fn`. Match is exact — extra held modifiers won't arm the gesture. |
| `firstRaise` | `boolean`        | `true`    | Focus and raise the target window at the start of each drag. Set `false` to move/resize without changing focus order. |

## Permissions

Requires Hammerspoon's **Accessibility** permission (System Settings →
Privacy & Security → Accessibility) — the eventtap and
`hs.window:setFrame` both need it. The Spoon errors at `:start()` if
the permission is missing.

## License

MIT.
