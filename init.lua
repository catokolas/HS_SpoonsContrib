-- Hammerspoon configuration

--  require nativly created (Claude) ~/.hammerspoon/hs/_mylo/sloppyfocus/
hs.loadSpoon("FocusFollowsMouse")
spoon.FocusFollowsMouse:configure({ delay = 0.05 })  -- 50ms instead of 100ms
spoon.FocusFollowsMouse:start()

--[[
spoon.FocusFollowsMouse:configure({
    delay = 0.05,                        -- 50 ms debounce
    excludedApps = {
      "Notification Center",             -- app name (so banners don't steal focus)
      "Hammerspoon",                     -- by name
      "com.apple.systempreferences",     -- bundle ID also works
      "com.apple.dock",                  -- the Dock
      "1Password 7",                     -- modal-heavy apps you want to click first
    },
})
spoon.FocusFollowsMouse:start()
]]

--[[
Matching rules (from the spoon's isExcluded): each entry is compared against both the window's
application():name() and application():bundleID(). Either match excludes that window from auto-focus.
Order doesn't matter, case is exact.

Finding the right strings: from the Hammerspoon console:

-- For the currently focused app:
local a = hs.application.frontmostApplication()
print(a:name(), a:bundleID())

-- Or list everything running:
for _, a in pairs(hs.application.runningApplications()) do
print(a:name(), "|", a:bundleID())
end

You can mix name and bundle ID in the same list — bundle ID is more robust against localization (an
app named "Calculator" on English macOS becomes "Lommeregner" on Danish, but the bundle ID
com.apple.calculator is stable).
]]

--[[
-- debug
hs.hotkey.bind({"ctrl","alt","cmd"}, "P", function()
    local w = hs.window.focusedWindow()
    print(string.format("pid=%d  app=%s  title=%s",
      w:pid(), w:application():name(), w:title()))
    hs.alert.show("pid=" .. w:pid())
end)
--]]

hs.loadSpoon("ClickThrough")
spoon.ClickThrough:configure({ logToFile = true, healthCheckInterval = 10 })
spoon.ClickThrough:start()

