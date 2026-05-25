# HS_SpoonsContrib

Personal [Hammerspoon](https://www.hammerspoon.org/) configuration and shareable spoons.

## What's here

### Spoons

- **[`FocusFollowsMouse.spoon/`](FocusFollowsMouse.spoon/)** — X11-style
  sloppy focus for macOS. When the mouse comes to rest over a window that
  isn't already focused, that window is focused. Debounce, drag-suppression,
  and per-app exclusions are configurable. If the companion native helper is
  installed (see below) it focuses **without raising** the window; otherwise
  it falls back to `hs.window:focus()` (which raises).

### Configuration

- **`init.lua`** — the Hammerspoon entry point. Loads and configures the
  spoons above. Symlinked from `~/.hammerspoon/init.lua`.

## Companion repos

- **[`HS_ModulesContrib-sloppyfocus`](https://github.com/catokolas/HS_ModulesContrib-sloppyfocus)**
  — native Hammerspoon module for focus-without-raise via macOS SkyLight
  private APIs. Works on Chromium-based PWAs, which the standalone
  [AutoRaise](https://github.com/sbmpost/AutoRaise) tool does not.
  `FocusFollowsMouse.spoon` picks the module up automatically when it's
  installed under `~/.hammerspoon/hs/_ckol/sloppyfocus/`. Future native
  modules will live in similarly-named sibling repos.

## Installation

See [`FocusFollowsMouse.spoon/README.md`](FocusFollowsMouse.spoon/README.md)
for installation and configuration instructions.
