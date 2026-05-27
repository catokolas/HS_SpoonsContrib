# HS_SpoonsContrib

Personal [Hammerspoon](https://www.hammerspoon.org/) configuration and shareable spoons.

[Learn Hammerspoon](https://learnhammerspoon.com/chapters/02-setup-hammerspoon/) - installation instruction and nice learning course.

## What's here

### Spoons

- **[`FocusFollowsMouse.spoon/`](FocusFollowsMouse.spoon/)** — X11-style
  sloppy focus for macOS. When the mouse comes to rest over a window that
  isn't already focused, that window is focused. Debounce, drag-suppression,
  and per-app exclusions are configurable. If the companion native helper is
  installed (see below) it focuses **without raising** the window; otherwise
  it falls back to `hs.window:focus()` (which raises).

- **[`MouseCopyPasteSelection.spoon/`](MouseCopyPasteSelection.spoon/)** —
  X11-style copy-on-select for macOS. Releasing the mouse after dragging
  across text, or double-clicking a word, captures the selection. By
  default it goes into a **private selection buffer** (the X11 PRIMARY
  analogue) so your real Cmd+C / Cmd+V clipboard is never disturbed; set
  `useSeparateSelectionBuffer = false` for the legacy shared-clipboard
  model. Optional middle-click-to-paste at the cursor location
  (`enableMiddleClickPaste = true`) reads from whichever buffer is
  active. A toggle on|off hotkey shows an `hs.alert` banner for visual
  feedback.

- **[`MoveSpaces.spoon/`](MoveSpaces.spoon/)** — 
⚠️ macOS 26.5 status: limited. Keyboard shortcut to move
  the currently-focused window to the macOS Space immediately to the left or
  right of the current Space, on the same screen. Uses `hs.spaces` so the
  move itself is silent (no Mission Control flicker); an optional
  `followWindow` setting can make the viewer follow the window.

## Companion repos

- **[`HS_ModulesContrib-sloppyfocus`](https://github.com/catokolas/HS_ModulesContrib-sloppyfocus)**
  — native Hammerspoon module for focus-without-raise via macOS SkyLight
  private APIs. Works on Chromium-based PWAs, which the standalone
  [AutoRaise](https://github.com/sbmpost/AutoRaise) tool does not.
  `FocusFollowsMouse.spoon` picks the module up automatically when it's
  installed under `~/.hammerspoon/hs/_ckol/sloppyfocus/`. Future native
  modules will live in similarly-named sibling repos.

- **[`HS_ModulesContrib-movetospace`](https://github.com/catokolas/HS_ModulesContrib-movetospace)**
  — native Hammerspoon module for moving a window to a specific macOS
  Space via SkyLight private APIs. Bypasses `hs.spaces.moveWindowToSpace`,
  which silently no-ops on macOS 26+ for most windows. `MoveSpaces.spoon`
  picks the module up automatically when installed under
  `~/.hammerspoon/hs/_ckol/movetospace/`. On macOS 26.5 the helper still
  only moves windows owned by the calling process (Hammerspoon itself);
  cross-process Space moves are gated at the WindowServer level. See the
  module README for details.
