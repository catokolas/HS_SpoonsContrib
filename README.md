# HS_SpoonsContrib

Personal [Hammerspoon](https://www.hammerspoon.org/) configuration and shareable spoons.

[Learn Hammerspoon](https://learnhammerspoon.com/chapters/02-setup-hammerspoon/) - installation instruction and nice learning course.

## Install + configure with one click

[**Mac Spoons Tweaks**](https://github.com/catokolas/MacSpoonsTweaks)
is a SwiftUI macOS app that installs and configures the Spoons in
this repo — and any third-party catalog that publishes a compatible
`spoons.json`. It reads each Spoon's `spoon-manifest.json` to render
a typed config form, then writes a managed `init.lua` snippet and
applies changes live through the `hs` CLI. No hand-editing your
Hammerspoon config.

```sh
brew install --cask catokolas/tap/macspoonstweaks
```

Standalone clone + symlink instructions for each Spoon are below if
you'd rather wire things up manually.

## What's here

### Spoons

- **[`FocusFollowsMouse.spoon/`](FocusFollowsMouse.spoon/)** — X11-style
  sloppy focus for macOS. When the mouse comes to rest over a window that
  isn't already focused, that window is focused. Debounce, drag-suppression,
  and per-app exclusions are configurable. If the companion native helper `HS_ModulesContrib-sloppyfocus` is installed (see below) it focuses 
  **without raising** the window; otherwise it falls back to
  `hs.window:focus()` (which raises).

- **[`MouseCopyPasteSelection.spoon/`](MouseCopyPasteSelection.spoon/)** —
  X11-style copy-on-select for macOS. Releasing the mouse after dragging
  across text, or double-clicking a word, captures the selection. By
  default it goes into a **private selection buffer** (the X11 PRIMARY
  analogue) so your real Cmd+C / Cmd+V clipboard is never disturbed; set
  `useSeparateSelectionBuffer = false` for the legacy shared-clipboard
  model. Middle-click pastes the active buffer at the cursor location
  — only inside text, never on buttons / links / other UI. Set
  `enableMiddleClickPaste = false` to disable. A toggle on|off hotkey
  shows an `hs.alert` banner for visual feedback.

- **[`MouseScrollTweaks.spoon/`](MouseScrollTweaks.spoon/)** — tweaks for
  traditional mouse wheels on macOS, leaving trackpad / Magic Mouse
  alone. Per-axis direction inversion (vertical and horizontal
  independently) lets you keep system "Natural scrolling" on for the
  trackpad while the wheel feels normal — macOS ties those two together
  by default. A `smoothness` grade 0 (off) … 20 (longest) interpolates
  each discrete wheel tick into a short sequence of pixel-unit events
  for a buttery glide; consecutive ticks fuse into one longer glide.
  Trackpads and Magic Mouse are detected via the
  `scrollWheelEventIsContinuous` property and passed through untouched.
  Uses `hs.eventtap` for input and direction inversion. If the
  companion native helper `HS_ModulesContrib-smoothscroll` is installed
  (see below), the smoothing engine runs as `IsContinuous=1` CGEvents
  posted from a `CVDisplayLink` callback — a trackpad-style continuous
  scroll stream with proper momentum, which apps treat as one logical
  gesture (one wheel click → one visible scroll step in every app);
  otherwise falls back to an inline pure-Lua smoothing engine.

- **[`MouseTrackpadTweaks.spoon/`](MouseTrackpadTweaks.spoon/)** —
  per-device input tweaks for the Magic Mouse and Trackpad that macOS
  doesn't expose itself. **Magic-Mouse-only scroll inversion** (vertical
  and optional horizontal) — independent of the system "Natural
  scrolling" toggle, so you can keep the trackpad natural while the
  mouse scrolls traditionally. Inversion follows the whole gesture +
  momentum tail via scrollPhase / momentumPhase tracking, so there's no
  "bounce" when the finger leaves the surface. Deltas are flipped on the
  original CGEvent in place, preserving the OS's gesture metadata
  (source, timestamp, gesture id), so the momentum tail decays as
  smoothly as a native scroll. **Middle-click
  synthesis** on either a 3+ finger tap/click or a 1-finger tap/click
  in a configurable top-center region of the device surface; each mode
  picks "tap", "click", or "either" independently. The top-center rule
  counts only touches *inside* the region, so Magic Mouse passive palm
  contacts elsewhere don't disqualify an intentional finger. Uses the
  companion native helper `HS_ModulesContrib-multitouch` to read
  multitouch data (see below); without it the Spoon loads cleanly and
  passes events through unmodified.

- **[`SpotifyPlayPause.spoon/`](SpotifyPlayPause.spoon/)** — auto play /
  pause Spotify based on screen state and the connected audio output
  device. Pauses on screen sleep / screensaver when a preferred audio
  device (headphones, AirPods, USB DAC, …) is connected, and resumes on
  wake — but only if this Spoon was the one that paused it, so
  manually-paused tracks stay paused. With no preferred device present
  at all, Spotify is paused regardless of screen state. Optionally
  auto-switches the macOS default audio output to the first matching
  preferred device, and offers a menubar "Pause Spotify for N hour(s)"
  dropdown with automatic resume. Fully event-driven via
  `hs.caffeinate.watcher`, `hs.audiodevice.watcher`, and
  `hs.application.watcher`.

- **[`MoveSpaces.spoon/`](MoveSpaces.spoon/)** — 
⚠️ macOS 26.5 status: limited. Keyboard shortcut to move
  the currently-focused window to the macOS Space immediately to the left or
  right of the current Space, on the same screen. Uses `hs.spaces` so the
  move itself is silent (no Mission Control flicker); an optional
  `followWindow` setting can make the viewer follow the window. Uses the companion
  native helper `HS_ModulesContrib-movetospace` if available (see below).

- **[`MouseMoveResizeWindows.spoon/`](MouseMoveResizeWindows.spoon/)** —
  hold a configurable modifier chord and drag anywhere inside a window
  to move or resize it — no need to aim for the title bar or a corner.
  The Mutter / GNOME "Super+drag" muscle memory, ported to macOS with
  a modifier that doesn't fight the system shortcuts (Option by
  default). Left-drag moves the window tracking the cursor;
  right-drag resizes by moving the **closest edge** (left, right, top,
  or bottom — picked once at mouse-down from the four edge-distances).
  Releasing the modifier mid-drag aborts cleanly; clicks without the
  modifier pass through untouched. Resize is throttled to ~30Hz with a
  flush on mouse-up so terminal-grid-heavy apps (iTerm + tmux) stay
  responsive without losing precision. The modifier chord is exposed
  to MacSpoonsTweaks via a new `modifierCombo` field type — any subset
  of `ctrl`, `alt`, `shift`, `cmd`, `fn`, set by the user with the
  same recorder-style picker the app uses for hotkeys.

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

- **[`HS_ModulesContrib-multitouch`](https://github.com/catokolas/HS_ModulesContrib-multitouch)**
  — native Hammerspoon module that streams per-touch events from the
  Magic Mouse and Trackpad via Apple's private MultitouchSupport
  framework. Exposes finger count, normalized per-finger surface
  position, and touch phase (began / moved / ended) — none of which is
  reachable from Hammerspoon's pure-Lua API. `MouseTrackpadTweaks.spoon`
  picks the module up automatically when installed under
  `~/.hammerspoon/hs/_ckol/multitouch/`.

- **[`HS_ModulesContrib-smoothscroll`](https://github.com/catokolas/HS_ModulesContrib-smoothscroll)**
  — native Hammerspoon module that posts continuous-scroll CGEvents
  (`NSEventTypeScrollWheel` with `IsContinuous=1`) from a `CVDisplayLink`
  callback — the same event shape macOS trackpads emit during a
  gesture, with smoothly decreasing per-frame deltas during the
  momentum tail. Receiving apps treat the whole stream as one logical
  scroll, so a single wheel click produces one visible scroll step with
  the same magnitude in every app (instead of being defeated by macOS's
  discrete-wheel coalescing). `MouseScrollTweaks.spoon` picks the
  module up automatically when installed under
  `~/.hammerspoon/hs/_ckol/smoothscroll/`; without it, the Spoon falls
  back to an inline pure-Lua smoothing engine.
