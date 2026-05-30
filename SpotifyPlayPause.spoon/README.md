# SpotifyPlayPause

Auto play / pause Spotify based on screen state and the connected audio
output device.

- When a **preferred audio device** (e.g. headphones, AirPods, USB DAC) is
  connected and the **screen goes to sleep** or the screensaver starts,
  Spotify is paused. When the screen wakes again, Spotify resumes — only
  if this spoon was the one that paused it (`respectManualPause = true`,
  default), so manually-paused tracks stay paused.
- When **no preferred audio device is present at all**, Spotify is paused
  regardless of screen state (don't play music to empty room speakers).
- Optionally, the macOS default audio output is **auto-switched** to the
  first matching preferred device whenever the audio device list changes.
- A menubar dropdown offers **"Pause Spotify for N hour(s)"** entries with
  an automatic resume timer.

Fully event-driven via `hs.caffeinate.watcher`, `hs.audiodevice.watcher`, and
`hs.application.watcher`.

## Installation

Clone, then symlink into `~/.hammerspoon/Spoons`:

```bash
git clone git@github.com:catokolas/HS_SpoonsContrib.git
cd HS_SpoonsContrib

mkdir -p ~/.hammerspoon/Spoons
ln -s "$PWD/SpotifyPlayPause.spoon" ~/.hammerspoon/Spoons/SpotifyPlayPause.spoon
```

## Usage

In `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("SpotifyPlayPause")
spoon.SpotifyPlayPause:configure({
  preferredDevices = { "usb audio", "airpods", "Headphone", "plantronics", "jabra" },
  -- speak = true,                  -- spoken feedback via hs.speech
  -- autoSwitchOutput = false,      -- don't change default audio output
  -- respectManualPause = false,    -- always auto-resume on wake (original AppleScript parity)
})
spoon.SpotifyPlayPause:start()
```

Then reload Hammerspoon (menu bar → Reload Config).

`preferredDevices` entries are matched **case-insensitively as substrings**
against `hs.audiodevice` device names. The order is the priority order
used by `autoSwitchOutput`.

## API

### Variables

| Variable | Default | Purpose |
|---|---|---|
| `SpotifyPlayPause.preferredDevices` | `{ "usb audio", "airpods", "Headphone", "plantronics", "jabra" }` | Substrings treated as "headphones" — gates play/pause + drives `autoSwitchOutput`. |
| `SpotifyPlayPause.autoSwitchOutput` | `true` | Switch the default output to the first preferred device available when the device list changes. |
| `SpotifyPlayPause.respectManualPause` | `true` | Only auto-resume on wake if **this spoon** paused Spotify. |
| `SpotifyPlayPause.pauseHoursMenu` | `true` | Show the "Pause Spotify for N hour(s)" menubar dropdown. |
| `SpotifyPlayPause.pauseHoursOptions` | `4` | Number of hour entries in the dropdown — set to `n` to get 1..n hours. |
| `SpotifyPlayPause.speak` | `false` | Spoken feedback via `hs.speech` on key transitions. |
| `SpotifyPlayPause.logger` | `hs.logger.new("SpotifyPlayPause")` | Logger; set its level to control verbosity. |

### Methods

#### `SpotifyPlayPause:configure(configuration)`

Configures the spoon. Accepts any of the public variables listed above.

- `configuration` — a table of configuration values to merge into the spoon

#### `SpotifyPlayPause:start()`

Starts the watchers and shows the menubar dropdown (if enabled). Idempotent.

#### `SpotifyPlayPause:stop()`

Stops the watchers, cancels any armed pause-hours timer, and removes the
menubar dropdown.

## Behaviour

Triggered by these events (no polling):

- `hs.caffeinate.watcher` → `screensaverDidStart` / `screensDidSleep` /
  `systemWillSleep` mark the display as off; `screensaverDidStop` /
  `screensDidWake` / `systemDidWake` mark it as on.
- `hs.audiodevice.watcher` → any device-list or default-output change
  re-evaluates `preferredPresent` and (optionally) switches the default
  output.
- `hs.application.watcher` → when Spotify launches, the spoon re-runs its
  evaluation after a 2 s settle delay.

Decision table on each event:

| Condition | Action |
|---|---|
| Spotify not running | no-op |
| Pause-hours timer armed | ensure paused; ignore other signals until expiry |
| No preferred device present anywhere, and playing | pause |
| Preferred device present, display off, playing | pause (mark "auto-paused") |
| Preferred device present, display on, paused, auto-paused was true | resume |

### Caveats

- `hs.audiodevice.watcher.setCallback` is **module-global** (single slot).
  `start()` takes ownership of that callback. If you currently have
  `hs.audiodevice.watcher.setCallback(...)` elsewhere in your
  `init.lua`, remove or merge it.
- The `respectManualPause = true` default deviates from the original
  AppleScript, which always resumed on wake. Set it to `false` for
  strict parity.

## Logging / debug output

All messages go to the **Hammerspoon Console** (menu bar → Hammerspoon →
Console). The Spoon uses `hs.logger`; default level is `warning`, so
normal pause/resume cycles are silent and only outright failures show.

The five `hs.logger` levels (least to most verbose):
`error` < `warning` < `info` < `debug` < `verbose`. A given level
shows messages at that level and everything above. Change at runtime
in the Console:

```lua
spoon.SpotifyPlayPause.logger.setLogLevel("debug")
```

Or pin it from your `~/.hammerspoon/init.lua` (after `start()`):

```lua
spoon.SpotifyPlayPause.logger.setLogLevel("debug")
```

What each level emits in this Spoon:

| Level | Sample messages |
|---|---|
| `warning` | _(none today; reserved for future failure paths)_ |
| `info`    | _(none today)_ |
| `debug`   | The decision trace: `display off - pause spotify`, `display on - play spotify`, `no preferred audio device - pause spotify`, `switched default output to <name>`, `Will pause Spotify for N hour(s).`, `Cancel pausing Spotify for N hour(s)`, `Time's up! Pausing Spotify is finished` |

`debug` is the right level when diagnosing why Spotify did or didn't
pause/resume — the trace shows which branch of the decision table ran
on each event. Reset to `warning` (or omit the `setLogLevel` line) once
you've confirmed behaviour.

## License

MIT — see [`LICENSE`](LICENSE).
