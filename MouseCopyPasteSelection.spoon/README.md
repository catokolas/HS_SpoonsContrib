# MouseCopyPasteSelection

X11-style copy-on-select for macOS. Releasing the mouse after dragging
across text, or double-clicking a word, captures the selection. By
default it goes into a **private selection buffer** (the X11 PRIMARY
analogue) so your real Cmd+C / Cmd+V clipboard is never disturbed; set
`useSeparateSelectionBuffer = false` for the legacy shared-clipboard
model. Optional middle-click-to-paste at the cursor location
(`enableMiddleClickPaste = true`) reads from whichever buffer is
active. A toggle on|off hotkey shows an `hs.alert` banner for visual
feedback.

| User action | Buffer used (default mode) |
|---|---|
| Cmd+C | system clipboard (untouched by this Spoon) |
| Cmd+V | system clipboard (untouched by this Spoon) |
| drag-select / double-click | private selection buffer |
| middle-click (opt in) | private selection buffer |

The "is the cursor over text" gate uses
[`hs.mouse.currentCursorType()`](https://www.hammerspoon.org/docs/hs.mouse.html#currentCursorType),
which returns `"IBeamCursor"` (or `"IBeamCursorForVerticalLayout"`)
when the system cursor is the text I-beam — the same NSCursor hot-spot
check the original C implementation performs.

> **Middle-click paste caveat** — the implementation synthesises a
> left-click at the cursor before the Cmd+V keystroke to give the
> target field focus. That can trigger unintended actions in apps
> which treat single-click as activation (terminals, hyperlinks).
> Opt in deliberately.

## Prerequisites

Hammerspoon needs **Accessibility permission** (System Settings →
Privacy & Security → Accessibility). `hs.eventtap` silently fails
without it; this Spoon's `start()` errors loudly if the permission
isn't granted.

## Installation

Clone, then symlink into `~/.hammerspoon/Spoons`:

```bash
git clone git@github.com:catokolas/HS_SpoonsContrib.git
cd HS_SpoonsContrib

mkdir -p ~/.hammerspoon/Spoons
ln -s "$PWD/MouseCopyPasteSelection.spoon" ~/.hammerspoon/Spoons/MouseCopyPasteSelection.spoon
```

## Usage

In `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("MouseCopyPasteSelection")
spoon.MouseCopyPasteSelection:configure({
  enableMiddleClickPaste = true,   -- opt in to middle-click paste
  useSeparateSelectionBuffer = false -- if you got used to using the clipboard
})
spoon.MouseCopyPasteSelection:start()
spoon.MouseCopyPasteSelection:bindHotkeys({
  toggle = {{"cmd","alt"}, "p"},   -- optional toggle kill-switch
})
```

Then reload Hammerspoon (menu bar → Reload Config). No quit-and-relaunch
needed — there's no native code.

## API

### Variables

| Variable | Default | Purpose |
|---|---|---|
| `MouseCopyPasteSelection.useSeparateSelectionBuffer` | `true` | X11-style separate selection buffer; `false` for legacy shared-clipboard mode. |
| `MouseCopyPasteSelection.doubleClickMs` | `400` | Max ms between mousedowns for a double-click. |
| `MouseCopyPasteSelection.dragThresholdPx` | `5` | Minimum drag movement (px) before a copy-on-release is armed. |
| `MouseCopyPasteSelection.enableMiddleClickPaste` | `false` | Enable middle-click-to-paste. |
| `MouseCopyPasteSelection.restoreDelayMs` | `200` | ms to wait after middle-click Cmd+V before restoring the real clipboard. |
| `MouseCopyPasteSelection.pasteClickDelayUs` | `15000` | µs after synthesised focus-click before pasting. |
| `MouseCopyPasteSelection.pasteTypeDelayUs` | `1000` | Extra µs before the Cmd+V keystroke. |
| `MouseCopyPasteSelection.logger` | `hs.logger.new("MouseCopyPasteSelection")` | Logger; set its level for debug output. |

### Methods

#### `MouseCopyPasteSelection:configure(configuration)`

Merges values from the table into the spoon. Use this for any of the
variables above.

#### `MouseCopyPasteSelection:start()`

Starts the event tap. Errors if Hammerspoon doesn't have Accessibility
permission.

#### `MouseCopyPasteSelection:stop()`

Stops the event tap.

#### `MouseCopyPasteSelection:toggle()`

Toggles the event tap on/off — handy as a hotkey kill-switch.

#### `MouseCopyPasteSelection:getSelection()`

Returns the most recent copy-on-select text from the private selection
buffer, or `nil` if the buffer is empty. Useful for scripting against
the selection from elsewhere in your Hammerspoon config.

#### `MouseCopyPasteSelection:bindHotkeys(mapping)`

Recognises one key: `toggle`. Example:
`{ toggle = {{"cmd","alt"}, "p"} }`.

## Logging / debug output

All messages go to the **Hammerspoon Console** (menu bar → Hammerspoon →
Console). The Spoon uses `hs.logger`, whose default level is `warning`
— quiet during normal use; only the event-tap auto-recovery warning
ever surfaces by default.

The five `hs.logger` levels (least to most verbose):
`error` < `warning` < `info` < `debug` < `verbose`. Setting a level
shows messages from that level *and everything above it*. Change at
runtime in the Console:

```lua
spoon.MouseCopyPasteSelection.logger.setLogLevel("debug")
```

Or pin it from your `~/.hammerspoon/init.lua` (after `:start()`):

```lua
spoon.MouseCopyPasteSelection:start()
spoon.MouseCopyPasteSelection.logger.setLogLevel("debug")
```

What each level emits in this Spoon:

| Level | Sample messages |
|---|---|
| `warning` | `eventtap was disabled; re-enabling` (the tap was dropped by macOS — auto-recovery fired) |
| `info`    | `started; middleClickPaste=true`, `stopped`, `bindHotkeys: bound N hotkey(s)` |
| `debug`   | `copy - doubleclick`, `copy - was dragging`, `start dragging`, `paste`, `synth Cmd+C: captured selection, restored clipboard`, `middle-click paste: restored real clipboard`, `middle-click paste: empty selection buffer; using system clipboard` |

`debug` is the right level when diagnosing why a particular drag did or
didn't copy, or why a Cmd+V seems to be pasting something stale. Reset
to `warning` (or `nil`, which means default) once you're done — debug
fires on every mousedown/up and gets noisy.

## Caveats

- **Custom cursors that share the I-beam hot-spot** can false-positive.
  Inherited limitation from `lodestone/macpaste`.
- **Secure input** (login fields, 1Password's master-password prompt)
  silently blocks the synthesised Cmd+C / Cmd+V. There's no way around
  that from userspace.
- **`hs.mouse.currentCursorType()`** is built on a semi-private NSCursor
  API. If Apple removes it in a future macOS, the iBeam gate would need
  to switch to `hs.axuielement` (slower, less accurate).
- **Restore window after middle-click paste:** for ~`restoreDelayMs`
  (default 200ms) after a middle-click paste fires, the system
  clipboard temporarily holds the selection. If you press Cmd+V in
  that window, you'll paste the selection instead of your real
  clipboard. After the window elapses, Cmd+V is back to normal.
- **Apps that don't write to NSPasteboard on Cmd+C** (rare — some
  custom text views) won't fill the selection buffer. Logs at debug
  level after a 200ms safety timeout.

## Acknowledgments

Partly reimplementation of [lodestone/macpaste](https://github.com/lodestone/macpaste) in Lua script.
Event-tap + cursor-type gate is the same logic; only the host
(standalone .app → Hammerspoon Spoon) has changed.

## License

[The Unlicense](https://unlicense.org) (public domain) — matching the
upstream [`lodestone/macpaste`](https://github.com/lodestone/macpaste/blob/main/LICENSE).
See [`LICENSE`](LICENSE).
