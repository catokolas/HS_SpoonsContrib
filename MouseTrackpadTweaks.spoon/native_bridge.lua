--- === MouseTrackpadTweaks native bridge ===
---
--- Optional bridge to the `hs._ckol.multitouch` native helper, which
--- wraps Apple's private `MultitouchSupport.framework` and streams
--- touch events from the Magic Mouse and the built-in Trackpad. When
--- the native module is not installed, init.lua falls through cleanly
--- and disables the touch-dependent features (Magic Mouse scroll
--- inversion and middle-click synthesis) with a logged warning.
---
--- ## Expected native module API
---
--- ```
--- local mt = require("hs._ckol.multitouch")
---
--- mt.start(callback)
---   -- Registers `callback` to be invoked on every touch transition
---   -- from every connected multitouch device.
---   --
---   -- callback(deviceId, deviceKind, touchId, phase, nx, ny, timestamp)
---   --   deviceId   number    -- stable per-session id for the device
---   --   deviceKind string    -- "magicMouse" | "trackpad"
---   --   touchId    number    -- stable id for a single finger from
---   --                           "began" through "ended"/"cancelled"
---   --   phase      string    -- "began" | "moved" | "ended" | "cancelled"
---   --   nx, ny     number    -- normalized 0..1 surface position
---   --                           with (0, 0) at top-left
---   --   timestamp  number    -- monotonic seconds since some epoch;
---   --                           not currently used by this Spoon —
---   --                           may be nil if the bridge omits it
---
--- mt.stop()
---   -- Unregisters the callback and tears down the multitouch
---   -- listener. Safe to call repeatedly.
--- ```
---
--- See `https://github.com/catokolas/HS_ModulesContrib-multitouch` for
--- the reference native-module implementation and build instructions.
--- The bridge below only loads the module and verifies the method
--- surface — it intentionally does no wrapping so the Spoon talks to
--- the native API directly.

return function(ctx)
  local log = ctx and ctx.logger or hs.logger.new("MouseTrackpadTweaks/bridge")

  local ok, mt = pcall(require, "hs._ckol.multitouch")
  if not ok then
    log.w("hs._ckol.multitouch not loaded: " .. tostring(mt))
    return nil
  end
  if type(mt) ~= "table"
     or type(mt.start) ~= "function"
     or type(mt.stop)  ~= "function" then
    log.w("hs._ckol.multitouch present but missing required methods "
          .. "(expected start, stop)")
    return nil
  end
  log.d("hs._ckol.multitouch loaded")
  return mt
end
