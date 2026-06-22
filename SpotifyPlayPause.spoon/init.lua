--- === SpotifyPlayPause ===
---
--- Auto play / pause Spotify based on screen state and audio output device.
---
--- When a preferred audio output device (e.g. headphones, AirPods) is
--- connected and the screen goes to sleep — or the screensaver starts —
--- Spotify is paused. When the screen wakes again, Spotify resumes (only
--- if this spoon was the one that paused it).
---
--- When no preferred audio device is present at all, Spotify is paused
--- regardless of screen state (don't play music to empty speakers).
---
--- Optionally, the macOS default audio output is auto-switched to the
--- first matching preferred device whenever the audio device list changes.
---
--- A menubar dropdown shows the current audio output device (with a
--- submenu to switch it) and a "Pause" submenu offering "Pause Spotify
--- for N hour(s)" entries with an automatic resume timer.
---
--- Fully event-driven.

local obj = {}
obj.__index = obj

-- Metadata
obj.name     = "SpotifyPlayPause"
obj.version  = "0.1"
obj.author   = "Cato Kolås <cato.kolas@gmail.com>"
obj.credits  = "Reimplemented in Lua from the AppleScript spotify-playpause applet"
obj.homepage = "https://github.com/catokolas/HS_SpoonsContrib"
obj.license  = "MIT - https://opensource.org/licenses/MIT"

--- SpotifyPlayPause.preferredDevices
--- Variable
--- List of audio output device-name substrings (case-insensitive) treated as
--- "headphones" for the play/pause logic and as candidates for
--- `autoSwitchOutput`. Matched against the device's `name()`. Default:
--- `{ "usb audio", "airpods", "Headphone", "plantronics", "jabra" }`.
obj.preferredDevices = { "usb audio", "airpods", "Headphone", "plantronics", "jabra" }

--- SpotifyPlayPause.autoSwitchOutput
--- Variable
--- If true (default), whenever the audio device list changes the spoon
--- looks for the first preferred device (in `preferredDevices` order) that
--- is currently available, and makes it the default output — unless the
--- current default already matches one of the preferred substrings.
obj.autoSwitchOutput = true

--- SpotifyPlayPause.respectManualPause
--- Variable
--- If true (default), Spotify is only auto-resumed on screen wake if this
--- spoon was the one that paused it (i.e. the user did not manually pause
--- in the meantime). Set to false to mirror the original AppleScript
--- behaviour of always resuming on wake when a preferred device is
--- present.
obj.respectManualPause = true

--- SpotifyPlayPause.pauseHoursMenu
--- Variable
--- If true (default), a menubar dropdown is shown with "Pause Spotify for
--- N hour(s)" entries. Set to false to suppress the menubar entirely.
obj.pauseHoursMenu = true

--- SpotifyPlayPause.pauseHoursOptions
--- Variable
--- Number of hour entries offered in the menubar pause dropdown. Set to
--- `n` to get entries for 1..n hours. Default `4` → 1, 2, 3, 4 hours.
obj.pauseHoursOptions = 4

--- SpotifyPlayPause.speak
--- Variable
--- If true, spoken feedback is produced via `hs.speech` on key transitions
--- (pause / resume / pause-hours arm / expire). Default `false`.
obj.speak = false

--- SpotifyPlayPause.reevalDebounce
--- Variable
--- Seconds to wait after the last screen/audio watcher event before
--- re-evaluating play/pause state. On wake, USB/Bluetooth headphones
--- reconnect with a delay and the audio route churns (built-in speakers ↔
--- headphones), firing a burst of events; coalescing them into a single
--- delayed evaluation avoids thrashing play/pause and issuing `play()`
--- before CoreAudio has settled on the device (which leaves Spotify
--- reporting "playing" with no audio). Default `1.5`.
obj.reevalDebounce = 1.5

--- SpotifyPlayPause.logger
--- Variable
--- Logger object used within the Spoon. Can be accessed to set the default log level for the messages coming from the Spoon.
obj.logger = hs.logger.new("SpotifyPlayPause")

-- Internal state — not part of the public API.
obj._state = {
  autoPaused          = false,
  displayOn           = true,
  pauseHours          = 0,
  pauseEndsAt         = nil,
  pauseTimer          = nil,
  menubar             = nil,
  caffeinateWatcher   = nil,
  appWatcher          = nil,
  themeWatcher        = nil,
  spotifyStateWatcher = nil,
  presenceTap         = nil, -- input watcher, live only while we believe the screen is off
  reevalTimer         = nil, -- debounce timer coalescing bursts of watcher events
  speech              = nil,
  currentIcon         = nil, -- last path set on the menubar (avoids redundant setIcon)
  suppressAutoSwitchOnce = false, -- skip the next _switchToPreferred (manual output pick)
}

local SPOTIFY_BUNDLE = "com.spotify.client"
-- Spotify posts this distributed notification on every play/pause/track change.
local SPOTIFY_PLAYBACK_NOTE = "com.spotify.client.PlaybackStateChanged"
-- macOS posts this when the system appearance toggles between Light and Dark.
local APPEARANCE_NOTE = "AppleInterfaceThemeChangedNotification"

-- Input event types that mean "the user is present at the machine". Used by
-- the presence watch as a backstop for missed screen-wake events (see
-- obj:_startPresenceWatch).
local PRESENCE_EVENTS = {
  hs.eventtap.event.types.keyDown,
  hs.eventtap.event.types.flagsChanged,
  hs.eventtap.event.types.leftMouseDown,
  hs.eventtap.event.types.rightMouseDown,
  hs.eventtap.event.types.otherMouseDown,
  hs.eventtap.event.types.scrollWheel,
  hs.eventtap.event.types.mouseMoved,
}

local function matchesAny(name, prefs)
  if not name then return false end
  local lower = name:lower()
  for _, p in ipairs(prefs) do
    if lower:find(p:lower(), 1, true) then return true end
  end
  return false
end

local function pluralHours(n)
  return ("%d hour%s"):format(n, n > 1 and "s" or "")
end

-- Compact "1h 5m" / "12m" string for an armed pause's remaining time.
local function formatRemaining(secs)
  if secs <= 0 then return "0m" end
  local h = math.floor(secs / 3600)
  local m = math.floor((secs % 3600) / 60)
  if h > 0 then return ("%dh %dm"):format(h, m) end
  return ("%dm"):format(m)
end

function obj:_say(msg)
  self.logger.d(msg)
  if self.speak then
    self._state.speech = self._state.speech or hs.speech.new()
    if self._state.speech then self._state.speech:speak(msg) end
  end
end

--- SpotifyPlayPause:configure(configuration)
--- Method
--- Configures the spoon. Accepts any of the public variables
--- (`preferredDevices`, `autoSwitchOutput`, `respectManualPause`,
--- `pauseHoursMenu`, `pauseHoursOptions`, `speak`, `reevalDebounce`).
---
--- Parameters:
---  * configuration - a table of configuration values to merge into the spoon
function obj:configure(configuration)
  for k, v in pairs(configuration or {}) do
    self[k] = v
  end
end

function obj:_preferredPresent()
  for _, d in ipairs(hs.audiodevice.allOutputDevices()) do
    if matchesAny(d:name(), self.preferredDevices) then return true end
  end
  return false
end

function obj:_headphonesActive()
  local d = hs.audiodevice.defaultOutputDevice()
  return d ~= nil and matchesAny(d:name(), self.preferredDevices)
end

-- Pick the menubar icon for the current play state and menubar appearance.
-- Filenames live under spoon/icons/ and are resolved via hs.spoons.resourcePath.
-- Conventions:
--   *-light.png   → black glyph for a light menubar
--   *-paused.png  → paused-state glyph (pause bars)
function obj:_iconPath()
  local paused = (not hs.spotify.isRunning()) or (not hs.spotify.isPlaying())
  local light  = (hs.host.interfaceStyle() ~= "Dark")
  local name
  if paused and light then     name = "music24icon-paused-light.png"
  elseif paused          then  name = "music24icon-paused.png"
  elseif light           then  name = "music24icon-light.png"
  else                         name = "music24icon.png"
  end
  return hs.spoons.resourcePath("icons/" .. name)
end

function obj:_updateIcon()
  if not self._state.menubar then return end
  local path = self:_iconPath()
  if path and path ~= self._state.currentIcon then
    self._state.menubar:setIcon(path)
    self._state.currentIcon = path
  end
end

function obj:_switchToPreferred()
  if not self.autoSwitchOutput then return end
  -- A manual output pick (via the menubar) suppresses exactly the one
  -- auto-switch that the resulting default-output-changed event would
  -- otherwise trigger — so a deliberate choice of a non-preferred device
  -- isn't immediately reverted.
  if self._state.suppressAutoSwitchOnce then
    self._state.suppressAutoSwitchOnce = false
    self.logger.d("_switchToPreferred: suppressed once (manual output pick)")
    return
  end
  local cur = hs.audiodevice.defaultOutputDevice()
  if cur and matchesAny(cur:name(), self.preferredDevices) then return end
  -- Preferred-list order wins; among devices, first hit in iteration order.
  for _, p in ipairs(self.preferredDevices) do
    local pl = p:lower()
    for _, d in ipairs(hs.audiodevice.allOutputDevices()) do
      local name = d:name()
      if name and name:lower():find(pl, 1, true) then
        d:setDefaultOutputDevice()
        self.logger.d("switched default output to " .. name)
        return
      end
    end
  end
end

-- Single decision point. Called from every watcher callback.
function obj:_reevaluate()
  self:_decide()
  self:_updateIcon()
end

-- Debounced _reevaluate: collapses a burst of watcher events (e.g. the
-- wake-time audio-route churn) into one evaluation once things settle, after
-- self.reevalDebounce seconds of quiet.
function obj:_scheduleReevaluate()
  if self._state.reevalTimer then self._state.reevalTimer:stop() end
  self._state.reevalTimer = hs.timer.doAfter(self.reevalDebounce, function()
    self._state.reevalTimer = nil
    self:_reevaluate()
  end)
end

function obj:_decide()
  if not hs.spotify.isRunning() then
    self.logger.d("_decide: Spotify not running - nothing to do")
    return
  end

  -- A pause-hours timer is armed: keep paused, don't resume.
  if self._state.pauseHours > 0 then
    self.logger.d(("_decide: pause-hours armed (%dh) - keeping paused"):format(self._state.pauseHours))
    if hs.spotify.isPlaying() then hs.spotify.pause() end
    return
  end

  local preferredPresent = self:_preferredPresent()
  local playing = hs.spotify.isPlaying()
  self.logger.d(("_decide: displayOn=%s preferredPresent=%s playing=%s autoPaused=%s respectManualPause=%s")
    :format(tostring(self._state.displayOn), tostring(preferredPresent),
            tostring(playing), tostring(self._state.autoPaused),
            tostring(self.respectManualPause)))

  if not preferredPresent then
    if playing then
      hs.spotify.pause()
      self._state.autoPaused = true
      self:_say("no preferred audio device - pause spotify")
    end
    return
  end

  if self._state.displayOn then
    local mayResume = (not self.respectManualPause) or self._state.autoPaused
    if playing then
      self.logger.d("_decide: screen on & already playing - nothing to do")
    elseif mayResume then
      hs.spotify.play()
      self._state.autoPaused = false
      self:_say("play spotify")
    else
      self.logger.d("_decide: screen on but resume blocked by respectManualPause (autoPaused=false) - not resuming")
    end
  else
    if playing then
      hs.spotify.pause()
      self._state.autoPaused = true
      self:_say("pause spotify")
    else
      self.logger.d("_decide: screen off & already paused - nothing to do")
    end
  end
end

-- The caffeinate watcher is the only source of truth for displayOn, and its
-- screen-wake events can be dropped or reordered during rapid wake/sleep
-- cycles (e.g. recurring background wakeups while idle). When the final
-- screensDidWake is lost, displayOn stays false even though the user has
-- returned, so _decide never resumes Spotify. As a backstop, while we believe
-- the screen is off we watch for real user input; the first key/mouse event
-- means the user is present and is treated as a wake. The tap lives only while
-- displayOn is false, so it adds no overhead during normal use.
function obj:_onPresence()
  if not self._state.displayOn then
    self.logger.d("_onPresence: user input while screen believed off - treating as wake")
    self._state.displayOn = true
    self:_scheduleReevaluate()
  end
  self:_stopPresenceWatch()
  return false -- never consume the event
end

function obj:_startPresenceWatch()
  if self._state.presenceTap then return end
  self._state.presenceTap = hs.eventtap.new(PRESENCE_EVENTS, function()
    return self:_onPresence()
  end)
  if self._state.presenceTap then
    self._state.presenceTap:start()
    self.logger.d(("_startPresenceWatch: input backstop started (enabled=%s)")
      :format(tostring(self._state.presenceTap:isEnabled())))
  else
    self.logger.w("_startPresenceWatch: could not create eventtap - check Accessibility permission for Hammerspoon")
  end
end

function obj:_stopPresenceWatch()
  if self._state.presenceTap then
    self._state.presenceTap:stop()
    self._state.presenceTap = nil
    self.logger.d("_stopPresenceWatch: input backstop stopped")
  end
end

function obj:_onCaffeinate(event)
  local W = hs.caffeinate.watcher
  if event == W.screensaverDidStart
     or event == W.screensDidSleep
     or event == W.systemWillSleep then
    self.logger.d(("_onCaffeinate: screen-off event (%s) -> displayOn=false"):format(tostring(event)))
    self._state.displayOn = false
    self:_startPresenceWatch()
  elseif event == W.screensaverDidStop
         or event == W.screensDidWake
         or event == W.systemDidWake then
    self.logger.d(("_onCaffeinate: screen-on event (%s) -> displayOn=true"):format(tostring(event)))
    self._state.displayOn = true
    self:_stopPresenceWatch()
  else
    self.logger.d(("_onCaffeinate: ignored event (%s)"):format(tostring(event)))
    return
  end
  self:_scheduleReevaluate()
end

function obj:_onAudioChange(_event)
  local cur = hs.audiodevice.defaultOutputDevice()
  self.logger.d(("_onAudioChange: default output=%s"):format(cur and cur:name() or "nil"))
  self:_switchToPreferred()
  self:_scheduleReevaluate()
end

function obj:_onApp(_name, event, app)
  if not app or app:bundleID() ~= SPOTIFY_BUNDLE then return end
  if event == hs.application.watcher.launched then
    -- Give Spotify a moment to settle before querying its state.
    hs.timer.doAfter(2, function() self:_reevaluate() end)
  end
end

-- Make `dev` the default output device. Used by the menubar output submenu.
-- Suppresses the one auto-switch the resulting audio event would trigger, so
-- a deliberate pick of a non-preferred device isn't immediately reverted.
function obj:_setOutputDevice(dev)
  if not dev then return end
  local cur = hs.audiodevice.defaultOutputDevice()
  if cur and cur:uid() == dev:uid() then return end -- already default
  self._state.suppressAutoSwitchOnce = true
  dev:setDefaultOutputDevice()
  self.logger.d("manually switched default output to " .. (dev:name() or "?"))
  self:_scheduleReevaluate()
end

-- Submenu listing every available output device. The current default is
-- checked; preferred devices are marked with a star. Rebuilt on each open, so
-- it always reflects the settled device list (e.g. after USB reconnect).
function obj:_buildOutputItems()
  local items = {}
  local cur    = hs.audiodevice.defaultOutputDevice()
  local curUID = cur and cur:uid()
  for _, d in ipairs(hs.audiodevice.allOutputDevices()) do
    local name      = d:name() or "?"
    local preferred = matchesAny(name, self.preferredDevices)
    items[#items + 1] = {
      title   = preferred and (name .. " \226\152\133") or name, -- ★
      checked = (curUID ~= nil and d:uid() == curUID),
      fn      = function() self:_setOutputDevice(d) end,
    }
  end
  if #items == 0 then
    items[#items + 1] = { title = "No output devices", disabled = true }
  end
  return items
end

-- Submenu with the "Pause Spotify for N hour(s)" entries (and a cancel entry
-- while a pause is armed).
function obj:_buildPauseItems()
  local items = {}
  for n = 1, self.pauseHoursOptions do
    items[#items + 1] = {
      title   = "Pause for " .. pluralHours(n),
      checked = (self._state.pauseHours == n),
      fn      = function() self:_togglePauseHours(n) end,
    }
  end
  if self._state.pauseHours > 0 then
    items[#items + 1] = { title = "-" }
    items[#items + 1] = {
      title = "Cancel pause",
      fn    = function() self:_cancelPauseHours() end,
    }
  end
  return items
end

function obj:_buildMenu()
  local items = {}

  -- Current output device, with a submenu to switch it.
  local cur = hs.audiodevice.defaultOutputDevice()
  items[#items + 1] = {
    title = "Output: " .. (cur and cur:name() or "\226\128\148"), -- em dash
    menu  = self:_buildOutputItems(),
  }

  items[#items + 1] = { title = "-" }

  -- Pause submenu; show the remaining time in the parent title when armed.
  local pauseTitle = "Pause Spotify"
  if self._state.pauseHours > 0 and self._state.pauseEndsAt then
    pauseTitle = ("Pause Spotify (%s left)")
      :format(formatRemaining(self._state.pauseEndsAt - os.time()))
  end
  items[#items + 1] = {
    title = pauseTitle,
    menu  = self:_buildPauseItems(),
  }

  return items
end

function obj:_togglePauseHours(n)
  if self._state.pauseHours == n then
    self:_cancelPauseHours()
    return
  end
  if self._state.pauseTimer then self._state.pauseTimer:stop() end
  self._state.pauseHours  = n
  self._state.pauseEndsAt = os.time() + n * 3600
  self._state.pauseTimer  = hs.timer.doAfter(n * 3600, function()
    self:_pauseHoursExpired()
  end)
  if hs.spotify.isRunning() and hs.spotify.isPlaying() then
    hs.spotify.pause()
    self._state.autoPaused = true
  end
  self:_say("pause Spotify for " .. pluralHours(n) .. ".")
  self:_updateIcon()
end

function obj:_pauseHoursExpired()
  self._state.pauseHours  = 0
  self._state.pauseEndsAt = nil
  self._state.pauseTimer  = nil
  self:_say("time's up! Pausing Spotify is finished")
  self:_reevaluate()
end

function obj:_cancelPauseHours()
  if self._state.pauseTimer then self._state.pauseTimer:stop() end
  local n = self._state.pauseHours
  self._state.pauseHours  = 0
  self._state.pauseEndsAt = nil
  self._state.pauseTimer  = nil
  if n > 0 then
    self:_say("cancel pausing Spotify for " .. pluralHours(n))
  end
  self:_reevaluate()
end

--- SpotifyPlayPause:start()
--- Method
--- Starts the watchers and shows the menubar dropdown (if enabled). Idempotent.
---
--- Parameters:
---  * None
function obj:start()
  if self._state.caffeinateWatcher then return self end -- already started

  self._state.caffeinateWatcher = hs.caffeinate.watcher.new(function(event)
    self:_onCaffeinate(event)
  end)
  self._state.caffeinateWatcher:start()

  -- hs.audiodevice.watcher.setCallback is module-global: setting it here
  -- replaces any previously registered audio-device callback in this
  -- Hammerspoon process.
  hs.audiodevice.watcher.setCallback(function(event)
    self:_onAudioChange(event)
  end)
  hs.audiodevice.watcher.start()

  self._state.appWatcher = hs.application.watcher.new(function(name, event, app)
    self:_onApp(name, event, app)
  end)
  self._state.appWatcher:start()

  if self.pauseHoursMenu then
    self._state.menubar = hs.menubar.new()
    if self._state.menubar then
      self._state.menubar:setMenu(function() return self:_buildMenu() end)
      self:_updateIcon()
    end
  end

  -- Refresh the icon when the user toggles Light/Dark mode.
  self._state.themeWatcher = hs.distributednotifications.new(function()
    self:_updateIcon()
  end, APPEARANCE_NOTE)
  self._state.themeWatcher:start()

  -- Refresh the icon on every Spotify play/pause/track-change, so the icon
  -- reflects manual transport changes too — not just the ones we trigger.
  self._state.spotifyStateWatcher = hs.distributednotifications.new(function()
    self:_updateIcon()
  end, SPOTIFY_PLAYBACK_NOTE)
  self._state.spotifyStateWatcher:start()

  self:_switchToPreferred()
  self:_reevaluate()
  return self
end

--- SpotifyPlayPause:stop()
--- Method
--- Stops the watchers, cancels any armed pause-hours timer, and removes
--- the menubar dropdown.
---
--- Parameters:
---  * None
function obj:stop()
  if self._state.caffeinateWatcher then
    self._state.caffeinateWatcher:stop()
    self._state.caffeinateWatcher = nil
  end
  -- Clearing the module-global audio-device callback so we don't keep
  -- firing into a stopped spoon.
  hs.audiodevice.watcher.setCallback(nil)
  hs.audiodevice.watcher.stop()
  if self._state.appWatcher then
    self._state.appWatcher:stop()
    self._state.appWatcher = nil
  end
  if self._state.themeWatcher then
    self._state.themeWatcher:stop()
    self._state.themeWatcher = nil
  end
  if self._state.spotifyStateWatcher then
    self._state.spotifyStateWatcher:stop()
    self._state.spotifyStateWatcher = nil
  end
  self:_stopPresenceWatch()
  if self._state.reevalTimer then
    self._state.reevalTimer:stop()
    self._state.reevalTimer = nil
  end
  if self._state.pauseTimer then
    self._state.pauseTimer:stop()
    self._state.pauseTimer  = nil
    self._state.pauseHours  = 0
    self._state.pauseEndsAt = nil
  end
  if self._state.menubar then
    self._state.menubar:delete()
    self._state.menubar = nil
    self._state.currentIcon = nil
  end
  return self
end

return obj
