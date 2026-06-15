# ModelsUsage.spoon

Menubar launcher + webview dashboard for the KIX Models Manager usage API (`/api/usage`).

## Features

- Bearer-authenticated usage fetches (`Authorization: Bearer ...`)
- Dashboard window (HTML/webview) with:
  - granularity: `day`, `month`, `year`
  - explicit `from` / `to` ISO fields
  - optional key filter (one or many UUIDs; emitted as repeated `&key=` params)
  - refresh interval control
  - preset ranges (`Today`, `Last 7d`, `Last 30d`, `MTD`, `YTD`)
- Request/response debug logging (URL, redacted auth header, status, elapsed, response headers)
- Periodic background refresh
- Persistent settings via `hs.settings`

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
  topModelsLimit = 10,
})

spoon.ModelsUsage:setToken("<bearer-token>")
-- One or many key UUIDs; the spoon emits `&key=` once per entry.
-- Pass a list or a comma-separated string. Empty / nil clears all keys.
spoon.ModelsUsage:setKeys({ "<uuid-a>", "<uuid-b>" })            -- optional
-- spoon.ModelsUsage:setKeys("<uuid-a>, <uuid-b>")               -- equivalent
-- spoon.ModelsUsage:setDefaultKey("<uuid-key>")                 -- back-compat single-key shim
spoon.ModelsUsage:start()
```

Open the dashboard from the menubar item: `Open Usage Dashboard`.

## Persisted settings

- `modelsUsage.token`
- `modelsUsage.keys` — list of UUID strings (migrated one-way from the
  older `modelsUsage.defaultKey` single-string setting on first load)
- `modelsUsage.granularity`
- `modelsUsage.from`
- `modelsUsage.to`
- `modelsUsage.refreshSeconds`

## API expectations

The dashboard expects `/api/usage` to return:

- `keys`
- `granularity`
- `from`
- `to`
- `series`
- `by_model`

Totals are computed client-side from `series`.

## Debugging

```lua
hs.loadSpoon("ModelsUsage")
spoon.ModelsUsage:start()
spoon.ModelsUsage.logger.setLogLevel("debug")
spoon.ModelsUsage:refresh()
```

Set log level before `start()` if you also want startup traces.

Key log lines:

- `refresh start #... method=GET url=... headers=...`
- `refresh response #... status=... elapsed=... bytes=... responseHeaders=...`
- `refresh timeout #...`
- `refresh failed #...`
