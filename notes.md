❯ lets be brave and start planning to create a hybrid module for this functionality, following
  https://github.com/asmagill/HS_ModuleWalkthrough - lets call the module something like
  _mylo.SloppyFocusWithoutAutoRaise or suggest a better name

⏺ Quick read before we plan: SloppyFocusWithoutAutoRaise is descriptive but breaks the Hammerspoon
  convention of short lowercase leaves (hs.window, hs._asm.undocumented, etc.). I'd suggest
  hs._mylo.sloppyfocus — the namespace already implies it's your fork, and "sloppy focus" is the
  standard term for this behaviour in window-management circles.

  Before sketching the plan, two things worth checking up front because they shape the work
  significantly:

⏺ User answered Claude's questions:
  ⎿  · What's the scope you want for this module? → Minimal: just focus-without-raise
     · How do you want to handle the PWA bug investigation? → Diagnose first, then code
     · What's your build setup? → Need to install/configure tooling

⏺ Here's the plan. Four phases, with explicit checkpoints so you can bail early if a phase reveals the
  next won't work.

  Phase 0 — Tooling setup (~15 min)

  Verification list. Run each; report any failures:

  xcode-select -p                         # path to active developer dir; if missing → xcode-select
  --install
  clang --version                         # any recent Apple clang is fine
  make --version                          # ships with CLT
  which lua                               # not strictly required; HS uses its embedded Lua

  Then clone two repos somewhere convenient (e.g., ~/git/):

  git clone https://github.com/Hammerspoon/hammerspoon.git      # headers + Lua API for linking
  git clone https://github.com/asmagill/HS_ModuleWalkthrough.git # scaffold + Makefile we'll adapt

  Checkpoint 0: build asmagill's walkthrough module unmodified (make install from his repo, then
  print(require("hs._asm.module")) in HS console). If that works, our toolchain is good. If not, we fix
  that first — no point writing C code against a broken build.

  Phase 1 — Diagnostic spike (no module yet, ~1 hour)

  Goal: prove the PWA-vs-native difference is what we think before writing native code. Build a tiny
  throwaway diag.m (single file, compiled with clang -framework AppKit -framework ApplicationServices …)
   that takes a pid argument and prints:

  pid:               12345
  bundleID:          com.google.Chrome.app.<hash>     ← PWA marker
  NSRunningApplication.localizedName
  NSRunningApplication.activationPolicy             ← regular vs accessory matters
  GetProcessForPID → PSN
  parent pid (via proc_pidpath/sysctl)
  AXApplication AXTitle / AXRole

  Workflow:
  1. Open a native app (Safari) and a PWA (one you actually use that AutoRaise fails on).
  2. Get each window's pid from the HS console: hs.window.focusedWindow():pid().
  3. Run ./diag <pid> on each. Compare the two dumps.

  Checkpoint 1: we should see a concrete difference — most likely PSN resolves to a helper process for
  the PWA, or activationPolicy is wrong, or the pid we have is a renderer rather than the browser. If
  the dumps look identical, our PWA theory is wrong and we need to step back before building anything.
  This is the highest-risk assumption in the plan, which is why it gets its own phase.

  Phase 2 — Build the module (~2–4 hours)

  Layout (mirrors HS_ModuleWalkthrough):

  ~/git/Hammerspoon/_mylo.sloppyfocus/
  ├── Makefile
  ├── init.lua             ← thin Lua wrapper, hs.docstrings, returns C module
  ├── internal.m           ← Objective-C: focusWithoutRaise(window) + helpers
  ├── SkyLight_private.h   ← declarations for _SLPSSetFrontProcessWithOptions etc.
  └── README.md

  Single exported function:

  require("hs._mylo.sloppyfocus").focusWithoutRaise(win)  -- win: hs.window
  -- returns true on success, false + reason on failure

  Implementation steps inside internal.m:
  1. Extract pid from the hs.window userdata
  2. Resolve PSN — with whatever PWA-aware fix Phase 1 revealed
  3. dlsym _SLPSSetFrontProcessWithOptions from
  /System/Library/PrivateFrameworks/SkyLight.framework/SkyLight at module load (don't crash if missing
  on future macOS)
  4. Call it with the no-raise flags AutoRaise uses (constants we'll lift from its source)
  5. Optionally set AXMain = true on the target window so the right window within the app becomes key

  Checkpoint 2: call focusWithoutRaise(someWindow) from the HS console. Window should become
  keyboard-focused without changing Z-order. Test with native app, PWA, and full-screen app.

  Phase 3 — Integrate with the spoon (~15 min)

  Tiny edit to FocusFollowsMouse:_maybeFocus:

  local sloppy = (function() local ok, m = pcall(require, "hs._mylo.sloppyfocus"); return ok and m or
  nil end)()
  …
  if sloppy and sloppy.focusWithoutRaise(win) then
    return
  end
  win:focus()  -- fallback

  So the spoon still works on machines without the module built.

  Open risks worth naming

  - Private symbol stability: _SLPSSetFrontProcessWithOptions has existed since ~10.10 but Apple could
  rename it. The dlsym fallback protects against crashes but not behaviour loss.
  - Hardened runtime / signing: Hammerspoon is unsigned by default for personal use, so dlopen-ing a
  private framework works. If you ever sign Hammerspoon you'll need entitlements.
  - AXMain may not be sufficient for the within-app window-switch case (e.g., focusing a background
  Finder window when Finder itself is frontmost). If so we'll need an additional AX dance, which we'll
  handle if it comes up.

  ---
  Want me to start with Phase 0 — write the verification script and confirm the toolchain? That's
  risk-free and unblocks everything else.