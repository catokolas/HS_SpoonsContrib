# ModelsUsage.spoon

Menubar launcher + webview dashboard for AI model usage. Tab-per-source:

| Source       | What it reads                                                     |
| ------------ | ----------------------------------------------------------------- |
| **KIX**      | KIX Models Manager `/api/usage` (HTTP, bearer-token authenticated) |
| **Claude Code** | `~/.claude/projects/<slug>/*.jsonl` session logs (local files) |

The same date range + granularity + presets apply to whichever tab is
active. The dashboard remembers the last-selected tab across reloads.

## Features

- Dashboard window (HTML/webview) with:
  - tab strip — click to switch source
  - granularity: `day`, `month`, `year`
  - explicit `from` / `to` ISO fields
  - preset ranges (`Today`, `Last 7d`, `Last 30d`, `MTD`, `YTD`)
  - refresh interval control
  - KIX-only: optional key filter (one or many UUIDs; emitted as
    repeated `&key=` params on the HTTP request)
- Periodic background refresh of the active source
- Persistent settings (per-source token / keys, active source,
  granularity, range, interval)
- Bearer-authenticated KIX fetches (`Authorization: Bearer ...`)
- Async, non-blocking Claude Code log walk (batched per runloop tick)
- Request/response debug logging

## Install

Place `ModelsUsage.spoon` in `~/.hammerspoon/Spoons/`.

## Usage

```lua
hs.loadSpoon("ModelsUsage")
spoon.ModelsUsage:configure({
  apiBaseUrl = "http://127.0.0.1:8000",
  usagePath = "/api/usage",
  refreshSeconds = 300,
  defaultGranularity = "month",
  numberFormat = "auto",                                           -- "auto", "us", or "no"
  defaultHotkeys = { refresh = { { "ctrl" }, "r" } },              -- set false to disable
  topModelsLimit = 10,
  claudecodeQuotaTokens = 7000000,                                 -- Claude Code 5h session cap; 0 hides the % (see Claude Code section)
})

-- KIX source config (only needed if you actually use the KIX tab):
spoon.ModelsUsage:setApiKey("<api-key>")
spoon.ModelsUsage:setKeys({ "<uuid-a>", "<uuid-b>" })             -- optional
-- spoon.ModelsUsage:setKeys("<uuid-a>, <uuid-b>")                -- equivalent
-- spoon.ModelsUsage:setDefaultKey("<uuid>")                      -- back-compat shim

-- Choose which tab opens first (persisted across reloads):
spoon.ModelsUsage:setActiveSource("kix")                          -- or "claudecode"
spoon.ModelsUsage:setNumberFormat("no")                           -- optional: "auto", "us", or "no"
spoon.ModelsUsage:bindHotkeys({
  refresh = { { "alt" }, "r" },                                   -- optional override; default is ctrl+r
})

spoon.ModelsUsage:start()
```

Open the dashboard from the menubar item: `Open Usage Dashboard`.

## Sources

### KIX

HTTP client for KIX Models Manager `/api/usage`. Requires an API key
(`:setApiKey`), emitted as `Authorization: Bearer …` on every
request, and optionally one or more key UUIDs to filter on
(`:setKeys`). The dashboard's "Key UUIDs" input is only visible while
the KIX tab is active.

"API key" rather than "token" deliberately: the dashboard reports
*input / output / cached tokens* per model, and using "token" for
the credential would collide with that.

### Claude Code

Walks `~/.claude/projects/<sanitized-project-path>/*.jsonl` — one file
per Claude Code session. Every line where `message.role == "assistant"`
contributes its `message.usage` counts (`input_tokens`, `output_tokens`,
plus `cache_read_input_tokens` + `cache_creation_input_tokens` summed
into `cached_tokens`) into the matching (date, model) bucket. The walk
is batched (a few files per runloop tick) so an idle Hammerspoon
doesn't beachball even on multi-hundred-session corpora.

No configuration needed for the usage table. If `~/.claude/projects/`
doesn't exist (you don't use Claude Code), the source reports zero rows.

The Summary tab also shows a **5-hour session card** modelling
Anthropic's rolling usage limit: a block opens at the first message and
lasts 5h, and the bar shows cost-weighted token use (`input + output +
1.25× cache-write + 0.1× cache-read`) against an assumed cap. That cap is
a guess — set it to your plan via the menubar (`Configure Claude Code →
Set 5h quota (tokens)…`) or `:setClaudecodeQuota(n)` / `configure({
claudecodeQuotaTokens = n })`. Set `0` to hide the percentage and show
the raw count. Because this reads only Claude Code's local logs (not
claude.ai web or API usage), it can't match the website's percentage
exactly — calibrate the cap so the bar tracks what you care about.

## Persisted settings

- `modelsUsage.activeSource` — `"kix"` or `"claudecode"`
- `modelsUsage.granularity`, `modelsUsage.from`, `modelsUsage.to`,
  `modelsUsage.refreshSeconds`, `modelsUsage.numberFormat`,
  `modelsUsage.windowFrame` — global
- `modelsUsage.kix.token`, `modelsUsage.kix.keys` — KIX source config
- `modelsUsage.claudecode.quota` — Claude Code 5h session cap (tokens)

On first load, the legacy single-source keys (`modelsUsage.token`,
`modelsUsage.keys`, `modelsUsage.defaultKey`) are migrated one-way into
the new per-source slots and then cleared. Rolling back to a previous
spoon version reads nothing from the new keys.

## API expectations (KIX)

The KIX `/api/usage` endpoint should return:

- `keys`
- `granularity`
- `from`
- `to`
- `series`
- `by_model`

Totals are computed client-side from `series`.

## Debugging

```lua
spoon.ModelsUsage.logger.setLogLevel("debug")
spoon.ModelsUsage:refresh()
```

Key log lines (prefix `ModelsUsag:`):

- `refresh start #N source=<id> ...`
- `refresh response #N source=<id> status=… elapsed=… …`
- `refresh timeout #N ...` (KIX only — local sources don't time out)
- `refresh failed #N: ...`

Right-click → Inspect Element in the dashboard window opens Web
Inspector for performance / DOM debugging.
