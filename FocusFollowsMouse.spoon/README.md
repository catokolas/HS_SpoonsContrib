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
> [`hs._ckol.sloppyfocus`](https://github.com/catokolas/HS_ModulesContrib) native
> helper is installed, this spoon uses it to focus without raising; otherwise
> it falls back to `hs.window:focus()`.

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
  delay = 0.05,                            -- 50 ms debounce instead of default 100 ms
  excludedApps = {
    "Notification Center",                 -- by app name
    "com.apple.systempreferences",         -- or by bundle ID
  },
})
spoon.FocusFollowsMouse:start()
```

`excludedApps` matches each entry against both `application():name()` and
`application():bundleID()` — bundle IDs are more robust across localised
macOS installs.

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

## Acknowledgments

Derived from the
[MouseFollowsFocus](https://github.com/Hammerspoon/Spoons/tree/master/Source/MouseFollowsFocus.spoon)
spoon by Jason Felice <jason.m.felice@gmail.com>. The event-tap and
focus-management logic here is a ground-up rewrite for the opposite direction
(focus follows mouse rather than mouse follows focus).

## License

MIT — see [`LICENSE`](LICENSE).
