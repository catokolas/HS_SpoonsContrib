# FocusFollowsMouse

Focus the window under the mouse pointer ("sloppy focus" / X11-style
focus-follows-mouse). When the pointer comes to rest over a window that isn't
already focused, that window is focused.

A short debounce delay means focus only changes once the cursor settles, so
quickly sweeping the pointer across windows does not thrash focus. Focus
changes are suppressed while a mouse button is held, so dragging never steals
focus.

> **Note** — on macOS, focusing a window also raises it; there is no public
> system primitive for focus-without-raise. If the optional
> [`hs._ckol.sloppyfocus`](https://github.com/catokolas/HS_ModulesContrib-sloppyfocus) native
> helper is installed, this spoon uses it to focus without raising; otherwise
> it falls back to `hs.window:focus()`.

## Activate hotkey

Default chord: **⇧⌃⌘F**. Press it to toggle the Spoon on/off; an
`hs.alert` banner confirms the new state. Persists across Hammerspoon
reloads.

The chord is declared in `spoon-manifest.json` as `activateHotkey` and
bound automatically when you install via
[MacSpoonsTweaks](https://github.com/catokolas/MacSpoonsTweaks). Users
who wire the Spoon up by hand can bind any chord to `:toggle()` via
`:bindHotkeys` (see below).

## Installation

Clone, then symlink into `~/.hammerspoon/Spoons`:

```bash
git clone git@github.com:catokolas/HS_SpoonsContrib.git
cd HS_SpoonsContrib

mkdir -p ~/.hammerspoon/Spoons
ln -s "$PWD/FocusFollowsMouse.spoon" ~/.hammerspoon/Spoons/FocusFollowsMouse.spoon
```

## Usage

In `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("FocusFollowsMouse")
spoon.FocusFollowsMouse:configure({
  delay = 0.05,                  -- 50 ms debounce instead of default 100 ms
  excludedApps = {
    "Notification Center",       -- by app name
    "org.keepassxc.keepassxc",   -- or by bundle ID
  },
})
spoon.FocusFollowsMouse:start()
spoon.FocusFollowsMouse:bindHotkeys({
  toggle = {{"shift","ctrl","cmd"}, "f"},  -- toggle on/off
})
```

`excludedApps` matches each entry against both `application():name()` and
`application():bundleID()` — bundle IDs are more robust across localised macOS installs.

Optional add to `~/.hammerspoon/init.lua`:
```lua
-- print window/app info to Hammerspoon console window
hs.hotkey.bind({"ctrl","alt","cmd"}, "P", function()
    local w = hs.window.focusedWindow()
    print(string.format("pid=%d app=%s title=%s bundleID=%s", w:pid(), w:application():name(), w:title(), w:application():bundleID()))
    hs.alert.show("pid=" .. w:pid())
end)
```

Then reload Hammerspoon (menu bar → Reload Config).

## API

### Variables

| Variable | Default | Purpose |
|---|---|---|
| `FocusFollowsMouse.delay` | `0.1` | Seconds the pointer must rest over a window before focus changes. |
| `FocusFollowsMouse.excludedApps` | `{}` | App names or bundle IDs whose windows should never be auto-focused. |
| `FocusFollowsMouse.logger` | `hs.logger.new("FocusFollowsMouse")` | Logger; set its level to control verbosity. |

### Methods

#### `FocusFollowsMouse:configure(configuration)`

Configures the spoon. Accepts any of the public variables (`delay`,
`excludedApps`).

- `configuration` — a table of configuration values to merge into the spoon

#### `FocusFollowsMouse:windowUnderPoint(point)`

Returns the topmost standard window whose frame contains the given point, or
nil.

- `point` — a table with `x` and `y` fields (e.g. from
  `hs.mouse.absolutePosition()`)

#### `FocusFollowsMouse:start()`

Starts focusing windows as the mouse moves over them.

#### `FocusFollowsMouse:stop()`

Stops focusing windows as the mouse moves.

#### `FocusFollowsMouse:toggle()`

Toggles the Spoon on/off and shows a brief `hs.alert` banner.

#### `FocusFollowsMouse:bindHotkeys(mapping)`

Binds keyboard shortcuts. Accepts a `toggle` key with a `{mods, key}` pair
compatible with `hs.hotkey.bindSpec`, e.g. `{ toggle = {{"ctrl","cmd"}, "f"} }`.

## Permissions

Hammerspoon needs **Accessibility** (System Settings → Privacy & Security →
Accessibility).

## Logging / debug output

The Spoon exposes `FocusFollowsMouse.logger` (an `hs.logger` instance)
for consistency with the other Spoons in this repo, but the current
implementation **does not emit any log calls of its own** — every
focus decision is a tight inline check with no diagnostic output.
Setting `setLogLevel("debug")` produces nothing extra today.

If you need to see *why* focus didn't shift to the window under the
cursor, inspect the relevant predicates manually in the Console
instead:

```lua
local p = hs.mouse.absolutePosition()
hs.inspect(hs.window.orderedWindows())                       -- z-order
spoon.FocusFollowsMouse:windowUnderPoint(p)                  -- what we'd pick
require("hs.axuielement").systemElementAtPosition(p.x, p.y):attributeValue("AXRole")  -- menu/sheet gate
```

### Diagnosing a dismissed popup / menu / autocomplete

If a popup (right-click menu, browser autofill dropdown, etc.) is
dismissed when the cursor settles, FFM's menu-detection probes didn't
recognise the popup's `AXRole` and treated the underlying window as a
normal focus target. To learn which role the popup actually exposes:

1. **Turn FFM off first** — via your activate hotkey (default
   `⇧⌃⌘F`) or `spoon.FocusFollowsMouse:stop()` in the Console.
   Otherwise FFM
   dismisses the popup before you can inspect it.
2. Open the popup and rest the cursor over it.
3. Bind the snippet below to a hotkey (e.g. `ctrl+alt+cmd+D`) ahead
   of time so triggering it doesn't move the cursor, then press it
   while the popup is showing:

```lua
hs.hotkey.bind({"ctrl","alt","cmd"}, "D", function()
  local ax = require("hs.axuielement")
  local p  = hs.mouse.absolutePosition()
  local el = ax.systemElementAtPosition(p.x, p.y)
  print("hit role:    ", el and el:attributeValue("AXRole"),
                         el and el:attributeValue("AXSubrole"))
  local front = hs.application.frontmostApplication()
  local appEl = front and ax.applicationElement(front)
  local fEl   = appEl and appEl:attributeValue("AXFocusedUIElement")
  print("focused role:", fEl and fEl:attributeValue("AXRole"),
                         fEl and fEl:attributeValue("AXSubrole"))
end)
```

Report the printed role(s) — they tell us what to add to the
menu-detection list in `init.lua` (the `MENU_ROLES` table). Browsers
in particular often use `AXList` / `AXListItem` or `AXPopover` for
autofill suggestions rather than `AXMenu`.

Log calls may be added in a future version (e.g. tracing the
excluded-app / menu / sheet branches at `debug` level); the variable
is reserved for that.

## Acknowledgments

Derived from the
[MouseFollowsFocus](https://github.com/Hammerspoon/Spoons/tree/master/Source/MouseFollowsFocus.spoon)
spoon by Jason Felice <jason.m.felice@gmail.com>. The event-tap and
focus-management logic here is a ground-up rewrite for the opposite direction
(focus follows mouse rather than mouse follows focus).

## License

MIT — see [`LICENSE`](LICENSE).
