--- === ModelsUsage ===
---
--- Menubar + dashboard window client for KIX Models Manager `/api/usage`.
---
--- Menubar opens a webview dashboard where usage is rendered with controls for
--- granularity, date range, refresh, and refresh interval.

local obj = {}
obj.__index = obj

obj.name = "ModelsUsage"
obj.version = "0.2"
obj.author = "KIX Models Manager contributors"
obj.license = "MIT"
obj.homepage = ""

obj.apiBaseUrl = "http://127.0.0.1:8000"
obj.usagePath = "/api/usage"
obj.refreshSeconds = 300
obj.timeoutSeconds = 10
obj.defaultGranularity = "month"
obj.topModelsLimit = 10
obj.seriesRowsLimit = 40
obj.windowWidth = 980
obj.windowHeight = 720

-- Claude Code rolling-window quota assumption. Anthropic Claude Code
-- enforces a rolling 5-hour token cap that varies by plan
-- (Pro/Team/Max). The Summary tab uses this to show `% used` against
-- a quota you can override via `:configure({ claudecodeQuotaTokens =
-- ... })`. Default is a rough Pro-plan estimate; bump it for
-- Max-plan accounts. If you set it to 0 the card just shows absolute
-- counts.
obj.claudecodeQuotaTokens = 45000

-- Pre-warm the dashboard webview at startup so the first menubar-click
-- open doesn't pay the 3-5s WebKit content-process spawn synchronously
-- on the main thread (which queues every other spoon's eventtap
-- callbacks while it runs — `MouseScrollTweaks` invert-scroll going
-- dead being the typical symptom).
--
-- Opt-in because the only spawn-trigger that *actually works* is
-- showing the window visibly: macOS / Quartz / WebKit skip the render
-- path entirely for off-screen or alpha=0 windows, so the cost just
-- relocates back to the menubar click. With this on, the dashboard
-- briefly flashes on screen at startup (~1.5s), then hides itself;
-- subsequent menubar opens are instant.
--
-- Trade-off:
--   false (default) → no flash, but 3-5s scroll hang on first open.
--   true            → 1.5s flash at startup, instant opens after.
obj.prewarmDashboard = false

obj.logger = hs.logger.new("ModelsUsage")

local SETTINGS = {
  -- Global (apply to the active source)
  activeSource    = "modelsUsage.activeSource",
  activePreset    = "modelsUsage.activePreset",
  granularity     = "modelsUsage.granularity",
  from            = "modelsUsage.from",
  to              = "modelsUsage.to",
  refreshSeconds  = "modelsUsage.refreshSeconds",
  windowFrame     = "modelsUsage.windowFrame",
  -- Per-source: KIX
  kixToken        = "modelsUsage.kix.token",
  kixKeys         = "modelsUsage.kix.keys",
  -- Legacy (read-once for one-way migration; no longer written)
  legacyToken        = "modelsUsage.token",
  legacyKeys         = "modelsUsage.keys",
  legacyDefaultKey   = "modelsUsage.defaultKey",
}

obj._state = {
  -- UI / system
  menubar = nil,
  themeWatcher = nil,
  timer = nil,            -- periodic refresh timer (global)
  window = nil,
  usesIcon = false,

  -- Active in-flight request (only one refresh at a time, shared across sources)
  requestSeq = 0,
  inFlight = false,
  timeoutTimer = nil,

  -- Globals (apply to the currently active source)
  granularity = nil,
  from = nil,
  to = nil,
  refreshSeconds = nil,
  -- The most recently picked range preset ("today", "thisWeek",
  -- "thisMonth", "thisYear"). nil when the user has
  -- manually overridden from/to via the Apply Controls path. Persisted
  -- across reloads so the tab's preset highlight + the date scope come
  -- back the way the user left them — with the preset re-evaluated
  -- against *today's* clock, not the saved-then-stale from/to dates.
  activePreset = nil,

  -- Multi-source bookkeeping
  activeSource = "summary",
  sources = {
    summary = {
      config = {},
      lastData = nil,
      lastError = nil,
      lastStatus = nil,
      lastRefreshAt = nil,
    },
    kix = {
      config = { token = nil, keys = {} },
      lastData = nil,
      lastError = nil,
      lastStatus = nil,
      lastRefreshAt = nil,
    },
    claudecode = {
      config = {},
      lastData = nil,
      lastError = nil,
      lastStatus = nil,
      lastRefreshAt = nil,
    },
  },
}

local APPEARANCE_NOTE = "AppleInterfaceThemeChangedNotification"

local function nowIsoUtc()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function startOfDayUtc(daysAgo)
  local t = os.time() - ((daysAgo or 0) * 24 * 60 * 60)
  return os.date("!%Y-%m-%dT00:00:00Z", t)
end

local function endOfDayUtc(daysAgo)
  local t = os.time() - ((daysAgo or 0) * 24 * 60 * 60)
  return os.date("!%Y-%m-%dT23:59:59Z", t)
end

local function startOfMonthUtc()
  local d = os.date("!*t")
  d.day = 1
  d.hour = 0
  d.min = 0
  d.sec = 0
  return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time(d))
end

local function startOfYearUtc()
  local d = os.date("!*t")
  d.month = 1
  d.day = 1
  d.hour = 0
  d.min = 0
  d.sec = 0
  return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time(d))
end

-- Start of *this week* in UTC, with Monday as the first day (ISO 8601
-- / European convention). os.date's `!*t` gives `wday` = 1..7 with
-- Sunday = 1; subtract `(wday - 2) mod 7` days so that Monday lands on
-- the current week's Monday.
local function startOfWeekUtc()
  local d = os.date("!*t")
  local daysSinceMonday = (d.wday - 2) % 7
  local t = os.time(d) - daysSinceMonday * 86400
  return os.date("!%Y-%m-%dT00:00:00Z", t)
end

local function fmtNum(n)
  if type(n) ~= "number" then return "0" end
  local s = tostring(math.floor(n))
  local out = {}
  while #s > 3 do
    table.insert(out, 1, s:sub(-3))
    s = s:sub(1, -4)
  end
  table.insert(out, 1, s)
  return table.concat(out, " ")
end

local function parseJson(body)
  local ok, decoded = pcall(hs.json.decode, body)
  if not ok then return nil, "Failed to parse JSON response" end
  if type(decoded) ~= "table" then return nil, "Response was not a JSON object" end
  return decoded, nil
end

local function redactAuthorization(value)
  if type(value) ~= "string" then return "<nil>" end
  local prefix = "Bearer "
  if value:sub(1, #prefix) == prefix then
    local token = value:sub(#prefix + 1)
    if #token <= 8 then return prefix .. "***" end
    return prefix .. token:sub(1, 4) .. "..." .. token:sub(-4)
  end
  return "***"
end

local function formatHeadersForLog(headers)
  if type(headers) ~= "table" then return "{}" end
  local keys = {}
  for k, _ in pairs(headers) do table.insert(keys, k) end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = headers[k]
    if tostring(k):lower() == "authorization" then
      v = redactAuthorization(v)
    end
    table.insert(parts, string.format("%s=%s", tostring(k), tostring(v)))
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function clampGranularity(g)
  if g == "day" or g == "month" or g == "year" then return g end
  return "month"
end

local function coercePositiveNumber(n, fallback)
  local v = tonumber(n)
  if not v or v <= 0 then return fallback end
  return v
end

-- Parse comma-separated key UUIDs from a string. Whitespace around each
-- entry is trimmed; empty entries are dropped. Always returns a table.
local function parseKeysCsv(s)
  local out = {}
  if type(s) ~= "string" or s == "" then return out end
  for part in string.gmatch(s, "[^,]+") do
    local trimmed = part:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then out[#out + 1] = trimmed end
  end
  return out
end

-- ISO-8601 timestamp ("YYYY-MM-DDThh:mm:ss[.fff][Z|+hh:mm]") → epoch
-- seconds. The Z / offset is ignored: we treat both the input and the
-- range bounds with the same convention, so the offset cancels out
-- when comparing them. Returns nil on shapes we don't recognise.
local function isoToEpoch(iso)
  if type(iso) ~= "string" then return nil end
  local y, mo, d, h, mi, s = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then return nil end
  return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                   hour = tonumber(h), min  = tonumber(mi), sec = tonumber(s) })
end

-- ISO timestamp → date bucket string at the requested granularity.
local function bucketDate(iso, granularity)
  if type(iso) ~= "string" then return nil end
  if granularity == "year"  then return iso:sub(1, 4) end
  if granularity == "month" then return iso:sub(1, 7) end
  return iso:sub(1, 10)  -- day (default)
end

-- Registry of supported data sources, in display order. Adding a new
-- source means appending an entry here (with id, displayName,
-- refreshMethod) and implementing obj:<refreshMethod>(requestSeq) below.
-- The dashboard's tab strip is rendered from this list, the persisted
-- activeSource setting is validated against it, and the dispatch in
-- obj:refresh() looks up the per-source refresh method by name.
local SOURCES = {
  summary = {
    id = "summary",
    displayName = "Summary",
    refreshMethod = "_refreshSummary",
  },
  kix = {
    id = "kix",
    displayName = "KIX",
    refreshMethod = "_refreshKix",
  },
  claudecode = {
    id = "claudecode",
    displayName = "Claude Code",
    refreshMethod = "_refreshClaudeCode",
  },
}
local SOURCE_ORDER = { "summary", "kix", "claudecode" }

-- Get the runtime slot for whichever source is currently active.
-- Falls back to KIX if the configured `activeSource` is unknown, so an
-- old/garbled settings value can't strand the spoon with no data path.
local function activeSourceState(state)
  return state.sources[state.activeSource] or state.sources.kix
end

-- Normalize anything-key-like (string, table, nil) into a clean list of
-- non-empty trimmed strings.
local function normalizeKeys(value)
  if type(value) == "string" then
    return parseKeysCsv(value)
  elseif type(value) == "table" then
    local clean = {}
    for _, k in ipairs(value) do
      if type(k) == "string" then
        local trimmed = k:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then clean[#clean + 1] = trimmed end
      elseif type(k) == "number" then
        clean[#clean + 1] = tostring(k)
      end
    end
    return clean
  end
  return {}
end

local function buildUsageIcon()
  -- Four-point sparkle drawn as an 8-vertex polygon (tip → shoulder ×4,
  -- closed). Drawn via hs.canvas because hs.image.imageFromASCII treats
  -- characters as polygon vertices, not pixels — bitmap-style art there
  -- collapses to its convex hull (a blob).
  local size = 16
  local pad = 1
  local tipFar = pad
  local tipNear = size - pad
  local mid = size / 2
  local waist = 1.6
  local ok, result = pcall(function()
    local canvas = hs.canvas.new({ x = 0, y = 0, w = size, h = size })
    canvas[1] = {
      type = "segments",
      closed = true,
      action = "fill",
      fillColor = { white = 1.0, alpha = 1.0 },
      coordinates = {
        { x = mid,           y = tipFar  }, -- top tip
        { x = mid + waist,   y = mid - waist },
        { x = tipNear,       y = mid     }, -- right tip
        { x = mid + waist,   y = mid + waist },
        { x = mid,           y = tipNear }, -- bottom tip
        { x = mid - waist,   y = mid + waist },
        { x = tipFar,        y = mid     }, -- left tip
        { x = mid - waist,   y = mid - waist },
      },
    }
    local img = canvas:imageFromCanvas()
    canvas:delete()
    if img and img.template then img:template(true) end
    return img
  end)
  if ok then return result end
  return nil
end

-- Weak-keyed cache for the data-derived portion of the view model.
-- The expensive O(N) sums over `lastData.series` and the O(M*K) top-K
-- over `lastData.by_model` only need to be recomputed when the API
-- response itself changes. Keyed by `lastData` identity so a fresh
-- response (new Lua table) misses, while subsequent publishes hit.
-- Weak keys let GC reclaim entries when the response is replaced.
local derivedCache = setmetatable({}, { __mode = "k" })

local function computeDerived(data, topModelsLimit, seriesRowsLimit)
  local series = type(data.series) == "table" and data.series or {}
  local models = type(data.by_model) == "table" and data.by_model or {}

  local totals = {
    requests = 0,
    input_tokens = 0,
    output_tokens = 0,
    cached_tokens = 0,
    reasoning_tokens = 0,
  }
  for _, row in ipairs(series) do
    if type(row) == "table" then
      totals.requests = totals.requests + (tonumber(row.requests) or 0)
      totals.input_tokens = totals.input_tokens + (tonumber(row.input_tokens) or 0)
      totals.output_tokens = totals.output_tokens + (tonumber(row.output_tokens) or 0)
      totals.cached_tokens = totals.cached_tokens + (tonumber(row.cached_tokens) or 0)
      totals.reasoning_tokens = totals.reasoning_tokens + (tonumber(row.reasoning_tokens) or 0)
    end
  end

  local limit = math.max(1, tonumber(topModelsLimit) or 10)
  local top = {}
  for _, row in ipairs(models) do
    if type(row) == "table" and row.model then
      local item = {
        model = tostring(row.model),
        requests = tonumber(row.requests) or 0,
        input_tokens = tonumber(row.input_tokens) or 0,
        output_tokens = tonumber(row.output_tokens) or 0,
        cached_tokens = tonumber(row.cached_tokens) or 0,
        reasoning_tokens = tonumber(row.reasoning_tokens) or 0,
      }
      local inserted = false
      for i = 1, #top do
        local cur = top[i]
        local better = (item.input_tokens > cur.input_tokens)
          or (item.input_tokens == cur.input_tokens and item.model < cur.model)
        if better then
          table.insert(top, i, item)
          inserted = true
          break
        end
      end
      if not inserted and #top < limit then
        top[#top + 1] = item
      end
      if inserted and #top > limit then
        table.remove(top, #top)
      end
    end
  end

  local seriesLimited = {}
  local maxRows = math.max(0, tonumber(seriesRowsLimit) or 0)
  for i = 1, math.min(#series, maxRows) do
    seriesLimited[#seriesLimited + 1] = series[i]
  end

  return { totals = totals, top = top, seriesLimited = seriesLimited }
end

local function getDerived(data, topModelsLimit, seriesRowsLimit)
  if type(data) ~= "table" then
    return computeDerived({}, topModelsLimit, seriesRowsLimit)
  end
  local entry = derivedCache[data]
  if entry and entry.tlim == topModelsLimit and entry.slim == seriesRowsLimit then
    return entry.derived
  end
  local derived = computeDerived(data, topModelsLimit, seriesRowsLimit)
  derivedCache[data] = { derived = derived, tlim = topModelsLimit, slim = seriesRowsLimit }
  return derived
end

-- Build the tab strip's per-source descriptors, in display order.
-- Each entry is what the JS-side tab renderer needs to draw + label a tab.
local function buildSourceTabs(state, sourcesRegistry, sourceOrder)
  local tabs = {}
  for _, id in ipairs(sourceOrder) do
    local def = sourcesRegistry[id]
    local slot = state.sources[id] or {}
    if def then
      tabs[#tabs + 1] = {
        id = id,
        displayName = def.displayName,
        hasError = slot.lastError and true or false,
        hasData = slot.lastData and true or false,
      }
    end
  end
  return tabs
end

local function buildViewModel(state, topModelsLimit, seriesRowsLimit,
                              sourcesRegistry, sourceOrder)
  local active = activeSourceState(state)
  local data = active.lastData or {}
  local derived = getDerived(active.lastData, topModelsLimit, seriesRowsLimit)

  local statusText
  if active.lastError then
    statusText = "Error"
  elseif state.inFlight and active.lastData then
    statusText = "Refreshing"
  elseif state.inFlight then
    statusText = "Loading"
  else
    statusText = "OK"
  end

  local kixCfg = state.sources.kix.config
  return {
    status = statusText,
    lastError = active.lastError,
    lastStatus = active.lastStatus,
    lastRefreshAt = active.lastRefreshAt,
    activeSource = state.activeSource,
    activePreset = state.activePreset,
    sources = buildSourceTabs(state, sourcesRegistry, sourceOrder),
    -- Token presence is only meaningful for KIX; surface that flag so the
    -- dashboard could later show a "missing token" hint when KIX is active.
    tokenSet = kixCfg.token and true or false,
    keys = (kixCfg.keys and #kixCfg.keys > 0) and kixCfg.keys
        or (type(data.keys) == "table" and data.keys)
        or {},
    granularity = state.granularity,
    from = state.from,
    to = state.to,
    refreshSeconds = state.refreshSeconds,
    totals = derived.totals,
    topModels = derived.top,
    series = derived.seriesLimited,
    -- Summary-specific payload only carried when the Summary tab is
    -- active; null otherwise. The JS render skips the summary-table
    -- update when this is missing, so KIX / Claude Code renders stay
    -- unchanged from the per-source code path.
    summaryRows           = (state.activeSource == "summary") and (data.rows or {}) or nil,
    summaryErrors         = (state.activeSource == "summary") and (data.errors or {}) or nil,
    claudecodeSession     = (state.activeSource == "summary") and data.claudecodeSession or nil,
    nowEpoch              = (state.activeSource == "summary") and os.time() or nil,
  }
end

local function htmlTemplate()
  return [[
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <style>
    :root {
      --bg: #f7fafc;
      --surface: #ffffff;
      --text: #1c1c1c;
      --muted: #667085;
      --border: #e4e7ec;
      --accent: #0f766e;
      --accent-hover: #115e59;
      --accent-press: #0c4a45;
      --hover: rgba(15, 118, 110, 0.10);
      --press: rgba(15, 118, 110, 0.18);
      --select: rgba(15, 118, 110, 0.18);
      --zebra: rgba(0, 0, 0, 0.03);
      --error: #b42318;
      --error-bg: rgba(180, 35, 24, 0.08);
      --ok: #16a34a;
      --warn: #d97706;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #0f172a;
        --surface: #111827;
        --text: #f3f4f6;
        --muted: #94a3b8;
        --border: #334155;
        --accent: #14b8a6;
        --accent-hover: #2dd4bf;
        --accent-press: #5eead4;
        --hover: rgba(20, 184, 166, 0.14);
        --press: rgba(20, 184, 166, 0.26);
        --select: rgba(20, 184, 166, 0.26);
        --zebra: rgba(255, 255, 255, 0.04);
        --error: #fda29b;
        --error-bg: rgba(253, 162, 155, 0.10);
        --ok: #4ade80;
        --warn: #fbbf24;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      padding: 16px;
      font-family: ui-sans-serif, -apple-system, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--text);
    }
    .wrap { display: grid; gap: 12px; }
    .card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 12px;
    }
    .row { display: flex; flex-wrap: wrap; gap: 8px 12px; align-items: end; }
    .cell { display: grid; gap: 6px; min-width: 180px; }
    label { font-size: 12px; color: var(--muted); }
    input, select, button {
      font: inherit;
      padding: 8px 10px;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--surface);
      color: var(--text);
      transition: background-color 0.12s ease, border-color 0.12s ease, box-shadow 0.12s ease, transform 0.06s ease;
    }
    select { -webkit-appearance: none; appearance: none; padding-right: 28px; background-image: linear-gradient(45deg, transparent 50%, var(--muted) 50%), linear-gradient(135deg, var(--muted) 50%, transparent 50%); background-position: calc(100% - 14px) 50%, calc(100% - 9px) 50%; background-size: 5px 5px, 5px 5px; background-repeat: no-repeat; }
    input:focus, select:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 3px var(--hover); }
    button { cursor: pointer; user-select: none; }
    button:focus-visible { outline: none; border-color: var(--accent); box-shadow: 0 0 0 3px var(--hover); }
    button:hover:not(:disabled) { background: var(--hover); border-color: var(--accent); }
    button:active:not(:disabled) { background: var(--press); transform: scale(0.97); }
    button:disabled { opacity: 0.5; cursor: not-allowed; transform: none; }
    button.primary { background: var(--accent); color: #fff; border-color: var(--accent); }
    button.primary:hover:not(:disabled) { background: var(--accent-hover); border-color: var(--accent-hover); }
    button.primary:active:not(:disabled) { background: var(--accent-press); border-color: var(--accent-press); transform: scale(0.97); }
    button.is-selected { background: var(--select); border-color: var(--accent); color: var(--accent); font-weight: 600; }
    .tabs {
      display: flex; gap: 2px;
      border-bottom: 1px solid var(--border);
      margin-bottom: 4px;
    }
    .tab {
      border: none;
      background: transparent;
      padding: 8px 16px;
      border-radius: 8px 8px 0 0;
      border-bottom: 2px solid transparent;
      color: var(--muted);
      font-weight: 500;
      cursor: pointer;
      transition: color 0.12s ease, border-color 0.12s ease, background-color 0.12s ease;
      margin-bottom: -1px;
    }
    .tab:hover:not(.is-active) { background: var(--hover); color: var(--text); }
    .tab.is-active { color: var(--accent); border-bottom-color: var(--accent); font-weight: 600; }
    .tab.has-error { color: var(--error); }
    .tab.has-error.is-active { border-bottom-color: var(--error); }
    .error-block {
      margin-top: 10px; padding: 10px 12px;
      background: var(--error-bg); border: 1px solid var(--error);
      color: var(--error); border-radius: 8px;
      white-space: pre-wrap; font-size: 13px;
      display: none;
    }
    .error-block.is-shown { display: block; }
    .progressbar {
      position: fixed; top: 0; left: 0; right: 0; height: 3px;
      overflow: hidden; pointer-events: none; z-index: 1000;
      opacity: 0; transition: opacity 0.15s ease;
    }
    .progressbar.is-active { opacity: 1; }
    .progressbar::after {
      content: ""; position: absolute; top: 0; bottom: 0;
      left: 0; width: 40%;
      background: var(--accent);
      transform: translateX(-100%);
    }
    .progressbar.is-active::after {
      animation: progress-slide 1.1s ease-in-out infinite;
    }
    @keyframes progress-slide {
      0%   { transform: translateX(-100%); }
      100% { transform: translateX(350%); }
    }
    .grid5 { display: grid; gap: 8px; grid-template-columns: repeat(5, minmax(0, 1fr)); }
    .metric { padding: 10px; border: 1px solid var(--border); border-radius: 10px; }
    .metric .k { font-size: 12px; color: var(--muted); }
    .metric .v { font-size: 20px; font-weight: 700; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th, td { border-bottom: 1px solid var(--border); text-align: left; padding: 8px 6px; vertical-align: top; }
    th { color: var(--muted); font-weight: 600; }
    tbody tr:nth-child(even) { background: var(--zebra); }
    tbody tr:hover { background: var(--hover); }
    tbody tr.empty:hover, tbody tr.empty:nth-child(even) { background: transparent; }
    tbody tr.empty td { color: var(--muted); font-style: italic; text-align: center; padding: 16px; }
    .mono { font-family: ui-monospace, Menlo, Monaco, monospace; font-size: 12px; color: var(--muted); }
    .cc-session-headline { font-size: 15px; font-weight: 600; }
    .cc-session-bar {
      margin-top: 8px; height: 6px; border-radius: 3px;
      background: var(--border); overflow: hidden;
    }
    .cc-session-bar-fill {
      height: 100%; width: 0%;
      background: var(--accent);
      transition: width 0.3s ease, background-color 0.3s ease;
    }
    .cc-session-bar-fill.warn  { background: var(--warn); }
    .cc-session-bar-fill.error { background: var(--error); }
    .cc-session-reset { margin-top: 8px; }
  </style>
</head>
<body>
  <div class="progressbar" id="progress"></div>
  <div class="wrap">
    <div class="tabs" id="tabs" role="tablist"></div>
    <div id="error" class="error-block"></div>

    <div class="card summary-card" data-only-for="summary">
      <h3 style="margin:0 0 12px 0;">Token usage summary</h3>
      <table>
        <thead>
          <tr>
            <th>Source</th>
            <th>Model</th>
            <th style="text-align:right;">Today</th>
            <th style="text-align:right;">This Week</th>
            <th style="text-align:right;">This Month</th>
            <th style="text-align:right;">This Year</th>
          </tr>
        </thead>
        <tbody id="summaryRows"></tbody>
      </table>
    </div>

    <!-- Session card visibility is JS-controlled (depends on both tab
         being Summary AND having usage data); no data-only-for. -->
    <div class="card cc-session-card" id="ccSession" style="display:none;">
      <h3 style="margin:0 0 8px 0;">Claude Code session (rolling 5 h)</h3>
      <div class="cc-session-headline" id="ccSessionHeadline"></div>
      <div class="cc-session-bar"><div class="cc-session-bar-fill" id="ccSessionBarFill"></div></div>
      <div class="cc-session-reset mono" id="ccSessionReset"></div>
    </div>

    <div class="card" data-only-for="kix,claudecode">
      <div class="row">
        <div class="cell">
          <label for="granularity">Granularity</label>
          <select id="granularity">
            <option value="day">day</option>
            <option value="month">month</option>
            <option value="year">year</option>
          </select>
        </div>
        <div class="cell">
          <label for="from">From (ISO)</label>
          <input id="from" placeholder="2026-06-01T00:00:00Z" />
        </div>
        <div class="cell">
          <label for="to">To (ISO)</label>
          <input id="to" placeholder="2026-06-30T23:59:59Z" />
        </div>
        <div class="cell" data-only-for="kix">
          <label for="key">Key UUIDs (comma-separated)</label>
          <input id="key" placeholder="78f9ff16-…, 4a2c-…" />
        </div>
        <div class="cell">
          <label for="interval">Interval (seconds)</label>
          <input id="interval" type="number" min="1" step="1" />
        </div>
      </div>
      <div class="row" style="margin-top:10px;">
        <button id="apply" onclick="applyControls()" class="primary">Apply controls</button>
        <button data-preset="today"     onclick="pickPreset(this)">Today</button>
        <button data-preset="thisWeek"  onclick="pickPreset(this)">This Week</button>
        <button data-preset="thisMonth" onclick="pickPreset(this)">This Month</button>
        <button data-preset="thisYear"  onclick="pickPreset(this)">This Year</button>
      </div>
    </div>

    <div class="card" data-only-for="kix,claudecode">
      <div class="grid5" id="totals"></div>
    </div>

    <div class="card" data-only-for="kix,claudecode">
      <h3 style="margin:0 0 8px 0;">Top Models</h3>
      <table>
        <thead>
          <tr><th>Model</th><th>Requests</th><th>Input</th><th>Output</th><th>Cached</th><th>Reasoning</th></tr>
        </thead>
        <tbody id="topModels"></tbody>
      </table>
    </div>

    <div class="card" data-only-for="kix,claudecode">
      <h3 style="margin:0 0 8px 0;">Series</h3>
      <table>
        <thead>
          <tr><th>Date</th><th>Model</th><th>Requests</th><th>Input</th><th>Output</th><th>Cached</th><th>Reasoning</th></tr>
        </thead>
        <tbody id="series"></tbody>
      </table>
    </div>
  </div>

  <script>
    // Compact K / M / B number formatter used by every number-bearing
    // cell in the dashboard (totals tiles, per-source tables, Summary
    // matrix, session card). One decimal where it adds information
    // (`1.2M`) and dropped otherwise (`14M`, `201M`); raw integer when
    // below 1000. 0 stays `0` rather than `0M`.
    function f(n) {
      n = Number(n) || 0;
      if (n === 0) return '0';
      const abs = Math.abs(n);
      const sign = n < 0 ? '-' : '';
      if (abs < 1000) return sign + Math.floor(abs);
      let value, suffix;
      if      (abs < 1e6) { value = abs / 1e3; suffix = 'K'; }
      else if (abs < 1e9) { value = abs / 1e6; suffix = 'M'; }
      else                { value = abs / 1e9; suffix = 'B'; }
      const formatted = value < 10
        ? value.toFixed(1).replace(/\.0$/, '')
        : String(Math.round(value));
      return sign + formatted + suffix;
    }

    const bridge = (window.webkit
      && window.webkit.messageHandlers
      && window.webkit.messageHandlers.modelsusage) || null;

    function send(action, extra) {
      const payload = Object.assign({ action }, extra || {});
      if (bridge) {
        bridge.postMessage(payload);
        return;
      }
      const stringified = {};
      Object.keys(payload).forEach(k => stringified[k] = String(payload[k] == null ? '' : payload[k]));
      stringified._ts = Date.now().toString();
      const q = new URLSearchParams(stringified);
      window.location.href = 'modelsusage://action?' + q.toString();
    }

    let activePreset = null;

    function applyControls() {
      activePreset = null;
      paintPresetSelection();
      send('applyControls', {
        granularity: document.getElementById('granularity').value || '',
        from: document.getElementById('from').value || '',
        to: document.getElementById('to').value || '',
        key: document.getElementById('key').value || '',
        interval: document.getElementById('interval').value || '',
      });
    }

    function pickPreset(btn) {
      activePreset = btn.dataset.preset;
      paintPresetSelection();
      send('preset', { name: activePreset });
    }

    function paintPresetSelection() {
      document.querySelectorAll('button[data-preset]').forEach(b => {
        b.classList.toggle('is-selected', b.dataset.preset === activePreset);
      });
    }

    let lastTabsKey = null;
    function renderTabs(sources, activeId) {
      sources = Array.isArray(sources) ? sources : [];
      // Stable key so we only touch the DOM when the tab set or active
      // tab actually changes (re-renders kill hover state, focus, etc).
      const key = activeId + '|' + sources.map(s =>
        s.id + ':' + (s.hasError ? 'e' : '_')).join(',');
      if (key === lastTabsKey) return;
      lastTabsKey = key;
      const root = document.getElementById('tabs');
      root.innerHTML = sources.map(s => {
        const cls = ['tab'];
        if (s.id === activeId) cls.push('is-active');
        if (s.hasError)         cls.push('has-error');
        return '<button class="' + cls.join(' ')
             + '" data-source="' + s.id + '"'
             + ' onclick="pickSource(this)" role="tab">'
             + (s.displayName || s.id) + '</button>';
      }).join('');
    }

    function pickSource(btn) {
      if (btn.classList.contains('is-active')) return;
      send('setSource', { id: btn.dataset.source });
    }

    function applySourceVisibility(activeId) {
      // data-only-for accepts a comma-separated list. The element is
      // shown when activeId matches any entry; otherwise hidden via
      // `display: none`. Lets one helper drive every per-tab show/hide,
      // including showing the Summary card *only* on the Summary tab and
      // hiding the controls/totals/topModels/series cards on it.
      document.querySelectorAll('[data-only-for]').forEach(el => {
        const allowed = (el.dataset.onlyFor || '').split(',').map(s => s.trim());
        const wanted = allowed.indexOf(activeId) !== -1;
        if (el.style.display === (wanted ? '' : 'none')) return;
        el.style.display = wanted ? '' : 'none';
      });
    }

    function setInputIfChanged(id, value) {
      const el = document.getElementById(id);
      if (!el) return;
      const str = (value == null) ? '' : String(value);
      if (el === document.activeElement) return;
      if (el.value === str) return;
      el.value = str;
    }

    let progressShownAt = 0;
    let progressHideTimer = null;
    const PROGRESS_MIN_VISIBLE_MS = 400;
    function setProgress(active) {
      const el = document.getElementById('progress');
      if (active) {
        if (progressHideTimer) { clearTimeout(progressHideTimer); progressHideTimer = null; }
        if (!el.classList.contains('is-active')) {
          el.classList.add('is-active');
          progressShownAt = Date.now();
        }
        return;
      }
      const elapsed = Date.now() - progressShownAt;
      const remaining = Math.max(0, PROGRESS_MIN_VISIBLE_MS - elapsed);
      if (progressHideTimer) clearTimeout(progressHideTimer);
      progressHideTimer = setTimeout(() => {
        el.classList.remove('is-active');
        progressHideTimer = null;
      }, remaining);
    }

    function setError(msg) {
      const el = document.getElementById('error');
      const text = msg || '';
      if (el.textContent !== text) el.textContent = text;
      el.classList.toggle('is-shown', !!text);
    }

    function renderTotals(totals) {
      const defs = [
        ['Requests', totals.requests],
        ['Input tokens', totals.input_tokens],
        ['Output tokens', totals.output_tokens],
        ['Cached tokens', totals.cached_tokens],
        ['Reasoning tokens', totals.reasoning_tokens],
      ];
      const root = document.getElementById('totals');
      root.innerHTML = defs.map(([k, v]) => `
        <div class="metric"><div class="k">${k}</div><div class="v">${f(v)}</div></div>
      `).join('');
    }

    function renderRows(id, rows, colCount, rowHtml) {
      const root = document.getElementById(id);
      if (!rows || !rows.length) {
        root.innerHTML = '<tr class="empty"><td colspan="' + colCount + '">No data</td></tr>';
        return;
      }
      root.innerHTML = rows.map(rowHtml).join('');
    }

    // Right-aligned numeric cell for the Summary table.
    function num(v) { return '<td style="text-align:right;">' + f(v) + '</td>'; }

    function renderSummary(rows) {
      const root = document.getElementById('summaryRows');
      if (!Array.isArray(rows) || rows.length === 0) {
        root.innerHTML = '<tr class="empty"><td colspan="6">No data</td></tr>';
        return;
      }
      root.innerHTML = rows.map(r =>
        '<tr>'
          + '<td>' + (r.source || '') + '</td>'
          + '<td>' + (r.model  || '') + '</td>'
          + num(r.today) + num(r.thisWeek) + num(r.thisMonth) + num(r.thisYear)
          + '</tr>'
      ).join('');
    }

    // Claude Code session card: % used + countdown to the trailing
    // 5h window's reset. Visibility is JS-driven (Summary tab AND
    // session data present); the countdown ticks every second via
    // setInterval so the displayed time stays current without needing
    // a publish per second.
    let ccSessionPayload = null;
    let ccSessionActiveSource = null;
    let ccSessionTickerStarted = false;

    function formatDuration(seconds) {
      seconds = Math.max(0, Math.floor(seconds));
      const h = Math.floor(seconds / 3600);
      const m = Math.floor((seconds % 3600) / 60);
      const s = seconds % 60;
      const pad = n => String(n).padStart(2, '0');
      if (h > 0) return h + 'h ' + pad(m) + 'm ' + pad(s) + 's';
      if (m > 0) return m + 'm ' + pad(s) + 's';
      return s + 's';
    }

    function setClaudeCodeSession(session, activeSource) {
      ccSessionPayload = session || null;
      ccSessionActiveSource = activeSource || null;
      paintCcSession();
      if (!ccSessionTickerStarted) {
        setInterval(paintCcSession, 1000);
        ccSessionTickerStarted = true;
      }
    }

    function paintCcSession() {
      const card = document.getElementById('ccSession');
      if (!card) return;
      // Card visibility is tied only to the Summary tab. When there's
      // no recent Claude Code activity we keep the card visible but
      // swap in an "idle" message — otherwise the missing card reads
      // as "feature is broken" rather than "you haven't run claude
      // recently."
      const onSummary = ccSessionActiveSource === 'summary';
      const wantDisplay = onSummary ? '' : 'none';
      if (card.style.display !== wantDisplay) card.style.display = wantDisplay;
      if (!onSummary) return;

      const headline = document.getElementById('ccSessionHeadline');
      const fill     = document.getElementById('ccSessionBarFill');
      const reset    = document.getElementById('ccSessionReset');
      const s        = ccSessionPayload;
      const used     = s ? (Number(s.tokensUsed) || 0) : 0;

      if (used === 0) {
        headline.textContent = 'No Claude Code activity in the last 5 hours';
        fill.style.width = '0%';
        fill.className = 'cc-session-bar-fill';
        reset.textContent = '';
        return;
      }

      const quota = Number(s.quotaTokens) || 0;
      const pct   = quota > 0 ? (used / quota) * 100 : 0;
      headline.textContent = quota > 0
        ? pct.toFixed(1) + '% used — ' + f(used) + ' / ' + f(quota) + ' tokens'
        : f(used) + ' tokens used (no quota configured)';

      const clamped = Math.max(0, Math.min(100, pct));
      fill.style.width = clamped + '%';
      let level = '';
      if (pct >= 90) level = 'error';
      else if (pct >= 70) level = 'warn';
      fill.className = 'cc-session-bar-fill' + (level ? ' ' + level : '');

      if (!s.resetEpoch) {
        reset.textContent = '';
        return;
      }
      const nowSec = Math.floor(Date.now() / 1000);
      const left = s.resetEpoch - nowSec;
      reset.textContent = left <= 0
        ? 'window has reset'
        : 'window resets in ' + formatDuration(left);
    }

    let lastDataSig = null;

    window.ModelsUsageRender = function(payload) {
      renderTabs(payload.sources, payload.activeSource);
      applySourceVisibility(payload.activeSource);

      setProgress(payload.status === 'Loading' || payload.status === 'Refreshing');
      setError(payload.lastError);

      setInputIfChanged('granularity', payload.granularity || 'month');
      setInputIfChanged('from', payload.from || '');
      setInputIfChanged('to', payload.to || '');
      setInputIfChanged('key', (Array.isArray(payload.keys) ? payload.keys : []).join(', '));
      setInputIfChanged('interval', payload.refreshSeconds || 300);

      // Sync the JS-side preset highlight with the persisted Lua-side
      // activePreset so reload / first-open lights up the preset that
      // owns the current range.
      const nextPreset = payload.activePreset || null;
      if (nextPreset !== activePreset) {
        activePreset = nextPreset;
        paintPresetSelection();
      }

      // Update the Claude Code session card on every publish, BEFORE
      // the data-signature early-return below. This is a status-style
      // update independent of the table payload, so it has to run on
      // every render — the early-return only suppresses table
      // re-renders. Without this hoist, the first publish (before the
      // refresh finishes) caches a null session, and the follow-up
      // publish carrying the real session data hashes to the same
      // `summaryRows` signature → returns early → the card never
      // updates from its "no activity" initial state.
      setClaudeCodeSession(payload.claudecodeSession || null, payload.activeSource);

      // Data signature includes activeSource AND the Summary rows so
      // switching tabs (or new Summary fetch results) forces a table
      // re-render even when the new source's data happens to hash the
      // same as the old one's (e.g., both empty).
      const sig = JSON.stringify([
        payload.activeSource,
        payload.totals || {},
        payload.topModels || [],
        payload.series || [],
        payload.summaryRows || null,
      ]);
      if (sig === lastDataSig) return;
      lastDataSig = sig;

      if (payload.activeSource === 'summary') {
        renderSummary(payload.summaryRows || []);
      } else {
        renderTotals(payload.totals || {});

        renderRows('topModels', payload.topModels || [], 6, r =>
          `<tr><td>${r.model || ''}</td><td>${f(r.requests)}</td><td>${f(r.input_tokens)}</td><td>${f(r.output_tokens)}</td><td>${f(r.cached_tokens)}</td><td>${f(r.reasoning_tokens)}</td></tr>`
        );

        renderRows('series', payload.series || [], 7, r =>
          `<tr><td>${r.date || ''}</td><td>${r.model || ''}</td><td>${f(r.requests)}</td><td>${f(r.input_tokens)}</td><td>${f(r.output_tokens)}</td><td>${f(r.cached_tokens)}</td><td>${f(r.reasoning_tokens)}</td></tr>`
        );
      }
    };

    document.getElementById('granularity').addEventListener('change', function() {
      send('setGranularity', { value: this.value });
    });

    // Force the webview to take focus on any click so the FIRST click on
    // an input/button does what the user expects (focus the input or
    // press the button), instead of being eaten by macOS's
    // click-to-activate. window.focus() from a mousedown handler is one
    // of the few places WKWebView actually honours a focus request.
    document.addEventListener('mousedown', function() {
      try { window.focus(); } catch (e) {}
    }, true);

    // Signal Lua as soon as ModelsUsageRender exists, so the first
    // publish doesn't race the WebKit content process loading the
    // script. Without this, the Lua-initiated publish that runs right
    // after w:html(...) on the next runloop tick lands while
    // `window.ModelsUsageRender` is still undefined; the
    // `window.ModelsUsageRender && ...` guard in _publishToWindow
    // silently drops the payload and the dashboard renders empty
    // until the user clicks Refresh.
    send('ready');

    // Manually editing date / key / interval inputs invalidates the
    // currently-highlighted preset (the user is overriding it).
    ['from', 'to', 'key', 'interval'].forEach(id => {
      document.getElementById(id).addEventListener('input', () => {
        if (activePreset !== null) { activePreset = null; paintPresetSelection(); }
      });
    });

    // Submit form-style inputs on Enter.
    ['from', 'to', 'key', 'interval'].forEach(id => {
      document.getElementById(id).addEventListener('keydown', (e) => {
        if (e.key === 'Enter') { e.preventDefault(); applyControls(); }
      });
    });
  </script>
</body>
</html>
]]
end

function obj:_loadSettings()
  -- KIX token: new key first, fall back to legacy modelsUsage.token.
  local kixToken = hs.settings.get(SETTINGS.kixToken)
  if type(kixToken) ~= "string" or kixToken == "" then
    kixToken = hs.settings.get(SETTINGS.legacyToken)
  end
  self._state.sources.kix.config.token = (type(kixToken) == "string" and kixToken ~= "") and kixToken or nil

  -- KIX keys: new key first, fall back to legacy list, fall back to legacy
  -- single-string defaultKey wrapped in a one-element list.
  local kixKeys = hs.settings.get(SETTINGS.kixKeys)
  if type(kixKeys) == "table" then
    self._state.sources.kix.config.keys = normalizeKeys(kixKeys)
  else
    local legacyList = hs.settings.get(SETTINGS.legacyKeys)
    if type(legacyList) == "table" then
      self._state.sources.kix.config.keys = normalizeKeys(legacyList)
    else
      local legacySingle = hs.settings.get(SETTINGS.legacyDefaultKey)
      self._state.sources.kix.config.keys =
        (type(legacySingle) == "string" and legacySingle ~= "") and { legacySingle } or {}
    end
  end

  -- Active source: validated against the actual sources table on load.
  local activeStored = hs.settings.get(SETTINGS.activeSource)
  if type(activeStored) == "string" and self._state.sources[activeStored] then
    self._state.activeSource = activeStored
  end

  self._state.granularity = clampGranularity(hs.settings.get(SETTINGS.granularity) or self.defaultGranularity)
  self._state.from = hs.settings.get(SETTINGS.from)
  self._state.to = hs.settings.get(SETTINGS.to)
  self._state.refreshSeconds = coercePositiveNumber(hs.settings.get(SETTINGS.refreshSeconds), self.refreshSeconds)

  -- Restore the active preset and re-evaluate it against today's
  -- clock. This keeps the highlight in the dashboard AND keeps the
  -- date range fresh ("Last 30d" stays last-30-days even across many
  -- reloads spanning days). Three cases:
  --
  --   1. The preset name is persisted → use it.
  --   2. No preset persisted AND no from set → fresh install /
  --      migration target. Default to thisMonth so the initial Claude
  --      Code refresh has a bounded scope (an unbounded one
  --      cold-parses every session file the user has ever recorded).
  --   3. No preset persisted BUT from IS set → upgrading from an
  --      older spoon version that didn't persist the preset name.
  --      Try to backfill the preset by matching the persisted
  --      from/to (compared via epoch so `+00:00` vs `Z` format
  --      differences don't matter) against each preset's *current*
  --      computation. If any matches, the user gets their highlight
  --      back without having to re-click.
  local PRESET_NAMES = { "today", "thisWeek", "thisMonth", "thisYear" }
  -- Migration table: old preset names → new equivalents. Pre-rename
  -- spoons stored e.g. "last30d", which is now spelled "thisMonth"
  -- (with subtly different semantics: was rolling-30-days, now
  -- start-of-month-to-now). Mapping is best-effort: the user gets a
  -- preset highlighted again, even if the underlying dates shift
  -- slightly when `_applyPresetDates` re-evaluates against today.
  local PRESET_MIGRATION = {
    last7d      = "thisWeek",
    last30d     = "thisMonth",
    monthToDate = "thisMonth",
    yearToDate  = "thisYear",
  }
  local storedPreset = hs.settings.get(SETTINGS.activePreset)
  if type(storedPreset) == "string" and storedPreset ~= "" then
    self._state.activePreset = PRESET_MIGRATION[storedPreset] or storedPreset
  elseif not self._state.from then
    self._state.activePreset = "thisMonth"
  else
    local origFrom, origTo = self._state.from, self._state.to
    local storedFromEpoch = isoToEpoch(origFrom)
    local storedToEpoch   = origTo and isoToEpoch(origTo) or nil
    if storedFromEpoch then
      for _, name in ipairs(PRESET_NAMES) do
        self:_applyPresetDates(name)
        local fromMatches = isoToEpoch(self._state.from) == storedFromEpoch
        local toMatches   = isoToEpoch(self._state.to)   == storedToEpoch
        if fromMatches and toMatches then
          self._state.activePreset = name
          break
        end
      end
    end
    if not self._state.activePreset then
      -- No preset matched — restore the user's manually-set range.
      self._state.from, self._state.to = origFrom, origTo
    end
  end
  if self._state.activePreset then
    self:_applyPresetDates(self._state.activePreset)
  end
end

function obj:_saveSettingsImmediate()
  hs.settings.set(SETTINGS.kixToken, self._state.sources.kix.config.token)
  hs.settings.set(SETTINGS.kixKeys,  self._state.sources.kix.config.keys)
  -- Clear legacy single-source settings the first time we save; the new
  -- per-source keys above are authoritative from now on. (No-op once
  -- they've already been cleared.)
  hs.settings.set(SETTINGS.legacyToken,      nil)
  hs.settings.set(SETTINGS.legacyKeys,       nil)
  hs.settings.set(SETTINGS.legacyDefaultKey, nil)

  hs.settings.set(SETTINGS.activeSource,   self._state.activeSource)
  hs.settings.set(SETTINGS.activePreset,   self._state.activePreset)
  hs.settings.set(SETTINGS.granularity,    self._state.granularity)
  hs.settings.set(SETTINGS.from,           self._state.from)
  hs.settings.set(SETTINGS.to,             self._state.to)
  hs.settings.set(SETTINGS.refreshSeconds, self._state.refreshSeconds)
end

function obj:_saveSettings()
  -- Debounced: 6 sync hs.settings.set calls are ~10-60ms of main-thread
  -- disk I/O; collapsing a flurry of clicks to one disk write keeps
  -- mouse events from queueing. Flushed in stop().
  self._state._saveDirty = true
  if self._state._saveTimer then return end
  self._state._saveTimer = hs.timer.doAfter(0.2, function()
    self._state._saveTimer = nil
    if not self._state._saveDirty then return end
    self._state._saveDirty = false
    self:_saveSettingsImmediate()
  end)
end

function obj:_saveWindowFrame(frame)
  if frame then hs.settings.set(SETTINGS.windowFrame, frame) end
end

function obj:_loadWindowFrame()
  local frame = hs.settings.get(SETTINGS.windowFrame)
  if type(frame) == "table" and frame.x and frame.y and frame.w and frame.h then
    return frame
  end

  local screen = hs.screen.mainScreen()
  local f = screen and screen:frame() or { x = 80, y = 80, w = 1200, h = 900 }
  local w = math.min(self.windowWidth, f.w - 40)
  local h = math.min(self.windowHeight, f.h - 40)
  return {
    x = f.x + (f.w - w) / 2,
    y = f.y + (f.h - h) / 2,
    w = w,
    h = h,
  }
end

function obj:configure(configuration)
  for k, v in pairs(configuration or {}) do
    self[k] = v
  end
  self._state.granularity = clampGranularity(self._state.granularity or self.defaultGranularity)
  self._state.refreshSeconds = coercePositiveNumber(self._state.refreshSeconds or self.refreshSeconds, self.refreshSeconds)
  return self
end

-- All API-key / keys setters write into the KIX source's config slot.
-- They keep their original signatures for backward compatibility with
-- existing init.lua snippets — only the storage location changed.

--- ModelsUsage:setApiKey(apiKey)
--- Method
--- Set the KIX API key used in the `Authorization: Bearer ...` header
--- on every KIX HTTP request. Persisted across reloads via
--- `hs.settings`. Passing nil / empty clears it. The internal field
--- is still named `token` for backward compat, but the public
--- terminology says "API key" to avoid colliding with input / output /
--- cached *tokens* — the per-message counts the dashboard surfaces.
function obj:setApiKey(apiKey)
  self._state.sources.kix.config.token = apiKey and tostring(apiKey) or nil
  -- Sync save (not the debounced `_saveSettings`): a typical init.lua
  -- pattern is `:setApiKey(...)` immediately followed by `:start()`,
  -- and `:start()` calls `_loadSettings` which would otherwise read
  -- the stale on-disk key (the 200ms debounce hasn't fired yet) and
  -- overwrite our in-memory value with the old one.
  self:_saveSettingsImmediate()
  self:_renderWindow()
  return self
end


--- ModelsUsage:setKeys(keys)
--- Method
--- Set the list of API key UUIDs the KIX source will pass as repeated
--- `&key=` query parameters on each refresh. Accepts a Lua table of
--- strings (`{ "uuid-a", "uuid-b" }`) or a comma-separated string
--- (`"uuid-a, uuid-b"`). Passing nil / empty clears the list.
function obj:setKeys(keys)
  self._state.sources.kix.config.keys = normalizeKeys(keys)
  -- Sync save (see note on setApiKey): one-shot programmatic setters
  -- must persist immediately so an immediate `:start()` can't
  -- overwrite the in-memory value with the stale on-disk one.
  self:_saveSettingsImmediate()
  self:_renderWindow()
  return self
end

--- ModelsUsage:setDefaultKey(uuid)
--- Method
--- Backward-compatible single-key setter. Wraps the given UUID into a
--- one-element keys list on the KIX source; prefer `:setKeys({...})`
--- for new code.
function obj:setDefaultKey(uuid)
  if uuid and tostring(uuid) ~= "" then
    self._state.sources.kix.config.keys = { tostring(uuid) }
  else
    self._state.sources.kix.config.keys = {}
  end
  -- Sync save (see setApiKey): one-shot programmatic call → persist now.
  self:_saveSettingsImmediate()
  self:_renderWindow()
  return self
end

--- ModelsUsage:setActiveSource(id)
--- Method
--- Switch the dashboard tab + the periodic refresh target to the named
--- source. Triggers a refresh of the new source. Valid ids are `"kix"`
--- and `"claudecode"`. Invalid ids are ignored.
function obj:setActiveSource(id)
  if type(id) ~= "string" or not self._state.sources[id] then return self end
  if self._state.activeSource == id then return self end
  self._state.activeSource = id
  self:_saveSettingsImmediate()  -- sync (see setApiKey)
  self:_publishToWindow()
  self:refresh()
  return self
end

function obj:setGranularity(granularity)
  self._state.granularity = clampGranularity(granularity)
  self:_saveSettingsImmediate()  -- sync (see setApiKey)
  self:refresh()
  return self
end

function obj:setDateRange(fromIso, toIso)
  self._state.from = fromIso
  self._state.to = toIso
  self:_saveSettingsImmediate()  -- sync (see setApiKey)
  self:refresh()
  return self
end

function obj:setRefreshSeconds(seconds)
  self._state.refreshSeconds = coercePositiveNumber(seconds, self.refreshSeconds)
  self:_saveSettingsImmediate()  -- sync (see setApiKey)
  self:_restartTimer()
  self:_renderWindow()
  return self
end

-- Re-compute from/to from a preset name against the current clock.
-- No side effects beyond setting state.from/to — used both by the
-- user-driven `_applyPreset` (which also persists + refreshes) and by
-- the settings-load path (which re-evaluates a persisted preset name
-- against today instead of trusting stale stored timestamps).
function obj:_applyPresetDates(preset)
  if preset == "today" then
    self._state.from = startOfDayUtc(0)
    self._state.to = endOfDayUtc(0)
  elseif preset == "thisWeek" then
    self._state.from = startOfWeekUtc()
    self._state.to = endOfDayUtc(0)
  elseif preset == "thisMonth" then
    self._state.from = startOfMonthUtc()
    self._state.to = endOfDayUtc(0)
  elseif preset == "thisYear" then
    self._state.from = startOfYearUtc()
    self._state.to = endOfDayUtc(0)
  end
end

function obj:_applyPreset(preset)
  self._state.activePreset = preset
  self:_applyPresetDates(preset)
  self:_saveSettings()
  self:refresh()
end

function obj:_setMenubarStatus(statusText, isError)
  if not self._state.menubar then return end
  local prefix = isError and "Models Usage (Error)" or "Models Usage"
  self._state.menubar:setTooltip(prefix .. " - " .. tostring(statusText))
  if not self._state.usesIcon then
    self._state.menubar:setTitle("MU")
  end
end

function obj:_updateMenubarIcon()
  if not self._state.menubar then return end
  local icon = buildUsageIcon()
  if icon then
    -- Template icons are auto-tinted by macOS to match menubar appearance.
    self._state.menubar:setIcon(icon, true)
    self._state.menubar:setTitle(nil)
    self._state.usesIcon = true
  else
    self._state.menubar:setIcon(nil)
    self._state.menubar:setTitle("MU")
    self._state.usesIcon = false
  end
end

function obj:_buildUrlAndHeaders()
  local kixCfg = self._state.sources.kix.config
  local token = kixCfg.token
  if not token or token == "" then
    return nil, nil, "Missing API key. Use setApiKey(...)"
  end

  local queryParts = {
    "granularity=" .. hs.http.encodeForQuery(self._state.granularity or self.defaultGranularity),
  }

  if self._state.from and self._state.from ~= "" then
    table.insert(queryParts, "from=" .. hs.http.encodeForQuery(self._state.from))
  end
  local toValue = self._state.to
  if not toValue or toValue == "" then
    toValue = nowIsoUtc()
  end
  table.insert(queryParts, "to=" .. hs.http.encodeForQuery(toValue))

  -- The API accepts the `key` query param repeated for multi-key filters
  -- (`&key=a&key=b`). Emit one entry per configured key.
  if type(kixCfg.keys) == "table" then
    for _, k in ipairs(kixCfg.keys) do
      if type(k) == "string" and k ~= "" then
        table.insert(queryParts, "key=" .. hs.http.encodeForQuery(k))
      end
    end
  end

  local url = self.apiBaseUrl .. self.usagePath
  if #queryParts > 0 then
    url = url .. "?" .. table.concat(queryParts, "&")
  end

  local headers = {
    ["Authorization"] = "Bearer " .. token,
    ["Accept"] = "application/json",
  }
  return url, headers, nil
end

function obj:_publishToWindow()
  if not self._state.window then return end
  -- Coalesce: mark dirty + schedule one publish for the next runloop
  -- tick. Multiple calls inside the same tick (e.g. an optimistic publish
  -- from refresh() and a status-change publish moments later) collapse
  -- into a single buildViewModel + evaluateJavaScript pair, and the
  -- caller (a click handler, an HTTP response callback) returns
  -- immediately so Hammerspoon's main thread can drain the event queue.
  self._state._publishDirty = true
  if self._state._publishTimer then return end
  self._state._publishTimer = hs.timer.doAfter(0, function()
    self._state._publishTimer = nil
    if not self._state._publishDirty then return end
    self._state._publishDirty = false
    if not self._state.window then return end
    local viewModel = buildViewModel(self._state, self.topModelsLimit, self.seriesRowsLimit, SOURCES, SOURCE_ORDER)
    local payload = hs.json.encode(viewModel)
    if not payload then return end
    local js = "window.ModelsUsageRender && window.ModelsUsageRender(" .. payload .. ");"
    self._state.window:evaluateJavaScript(js)
  end)
end

function obj:_renderWindow()
  self:_publishToWindow()
end

function obj:refresh()
  -- Publish current state first so optimistic UI changes (e.g. preset
  -- clicks that updated from/to while a previous request is still in
  -- flight, or a tab switch that should snap inputs immediately)
  -- appear without waiting for the in-flight request to settle.
  self:_publishToWindow()

  if self._state.inFlight then
    -- Watchdog: any in-flight that has lingered past 3× the per-source
    -- timeoutSeconds is almost certainly leaked — a callback path that
    -- didn't reset `inFlight`, or a timer that never fired on a
    -- machine with unusual HTTP / Lua-timer behaviour. Without this
    -- the spoon gets permanently wedged on "refresh already in flight"
    -- and only a Hammerspoon reload recovers (which is what the user
    -- reported on a second installation). Force-clear and proceed;
    -- the requestSeq bump below makes any zombie callback land as
    -- stale and get dropped.
    local maxAge = (self.timeoutSeconds or 10) * 3
    local startedAt = self._state.inFlightSince or 0
    local elapsed = os.time() - startedAt
    if elapsed > maxAge then
      self.logger.wf("refresh: clearing stuck inFlight after %ds (limit %ds)",
        elapsed, maxAge)
      self._state.inFlight = false
    else
      self.logger.df("refresh skipped: request already in flight (%ds elapsed)", elapsed)
      return
    end
  end

  local id = self._state.activeSource
  local def = SOURCES[id]
  if not def then
    self.logger.ef("refresh: unknown active source %q", tostring(id))
    return
  end
  local method = self[def.refreshMethod]
  if type(method) ~= "function" then
    self.logger.ef("refresh: source %q has no refresh method %s", id, def.refreshMethod)
    return
  end

  self._state.requestSeq = (self._state.requestSeq or 0) + 1
  self._state.inFlightSince = os.time()
  local requestSeq = self._state.requestSeq
  method(self, requestSeq)
end

-- Per-source refresh: KIX. Hits /api/usage with the configured bearer
-- token + key list, parses the JSON response, writes to
-- state.sources.kix.{lastData, lastError, lastStatus, lastRefreshAt}.
function obj:_refreshKix(requestSeq)
  local slot = self._state.sources.kix
  local url, headers, preflightErr = self:_buildUrlAndHeaders()
  if preflightErr then
    self.logger.ef("refresh preflight failed: %s", preflightErr)
    slot.lastError = preflightErr
    slot.lastStatus = nil
    self:_setMenubarStatus(slot.lastError, true)
    self:_publishToWindow()
    return
  end

  local startedAt = hs.timer.secondsSinceEpoch()
  self._state.inFlight = true
  self:_setMenubarStatus("Loading...", false)
  self:_publishToWindow()

  if self._state.timeoutTimer then
    self._state.timeoutTimer:stop()
    self._state.timeoutTimer = nil
  end

  self.logger.df("refresh start #%d source=kix method=GET url=%s headers=%s",
    requestSeq, url, formatHeadersForLog(headers))

  self._state.timeoutTimer = hs.timer.doAfter(self.timeoutSeconds, function()
    if self._state.inFlight and self._state.requestSeq == requestSeq then
      local elapsed = hs.timer.secondsSinceEpoch() - startedAt
      self.logger.ef("refresh timeout #%d after %.3fs (limit=%ds)",
        requestSeq, elapsed, self.timeoutSeconds)
      self._state.inFlight = false
      slot.lastStatus = nil
      slot.lastRefreshAt = os.time()
      slot.lastError = "Request timed out after " .. tostring(self.timeoutSeconds) .. "s"
      self._state.timeoutTimer = nil
      self:_setMenubarStatus(slot.lastError, true)
      self:_publishToWindow()
    end
  end)

  hs.http.asyncGet(url, headers, function(status, body, responseHeaders)
    if requestSeq ~= self._state.requestSeq then
      self.logger.wf("stale response ignored for request #%d", requestSeq)
      return
    end

    if self._state.timeoutTimer then
      self._state.timeoutTimer:stop()
      self._state.timeoutTimer = nil
    end

    self._state.inFlight = false
    slot.lastStatus = status
    slot.lastRefreshAt = os.time()

    local elapsed = hs.timer.secondsSinceEpoch() - startedAt
    local bodyLen = (type(body) == "string") and #body or 0
    self.logger.df("refresh response #%d source=kix status=%s elapsed=%.3fs bytes=%d responseHeaders=%s",
      requestSeq, tostring(status), elapsed, bodyLen, formatHeadersForLog(responseHeaders))

    if status < 200 or status >= 300 then
      local msg = "HTTP " .. tostring(status)
      local data, decodeErr = parseJson(body)
      if data and data.error then
        msg = msg .. ": " .. tostring(data.error)
      elseif decodeErr == nil and data and data.detail then
        msg = msg .. ": " .. tostring(data.detail)
      elseif type(body) == "string" and #body > 0 then
        msg = msg .. ": " .. body:sub(1, 200)
      end
      slot.lastError = msg
      self.logger.ef("refresh failed #%d: %s", requestSeq, msg)
      self:_setMenubarStatus(msg, true)
      self:_publishToWindow()
      return
    end

    local data, decodeErr = parseJson(body)
    if not data then
      slot.lastError = decodeErr
      self.logger.ef("refresh parse error #%d: %s body=%s",
        requestSeq, tostring(decodeErr), tostring(body):sub(1, 200))
      self:_setMenubarStatus(slot.lastError, true)
      self:_publishToWindow()
      return
    end

    slot.lastData = data
    slot.lastError = nil

    if data.from then self._state.from = tostring(data.from) end
    if data.to then self._state.to = tostring(data.to) end
    if data.granularity then self._state.granularity = clampGranularity(data.granularity) end
    -- Only auto-populate keys from the server when the user hasn't set
    -- any themselves — useful for first-run discovery, but otherwise
    -- preserves the user's explicit intent.
    local kixCfg = self._state.sources.kix.config
    if (not kixCfg.keys or #kixCfg.keys == 0)
       and type(data.keys) == "table" and #data.keys > 0 then
      kixCfg.keys = normalizeKeys(data.keys)
    end

    self:_saveSettings()
    self:_setMenubarStatus("OK", false)
    self:_publishToWindow()
  end)
end

-- Claude Code: list every per-session JSONL file under
-- ~/.claude/projects/*/*.jsonl as {path, mtime} pairs. The mtime is
-- used by the refresh step to short-circuit files whose last-write
-- predates the requested `from` (assistant messages are append-only,
-- so a stale file can't contain any matching event).
local function listClaudeCodeFiles()
  local home = os.getenv("HOME")
  if not home or home == "" then return {} end
  local projectsRoot = home .. "/.claude/projects"
  local rootAttr = hs.fs.attributes(projectsRoot)
  if not rootAttr or rootAttr.mode ~= "directory" then return {} end
  local files = {}
  for projectName in hs.fs.dir(projectsRoot) do
    if projectName ~= "." and projectName ~= ".." and projectName:sub(1, 1) ~= "." then
      local projDir = projectsRoot .. "/" .. projectName
      local projAttr = hs.fs.attributes(projDir)
      if projAttr and projAttr.mode == "directory" then
        for entry in hs.fs.dir(projDir) do
          if entry:match("%.jsonl$") then
            local path = projDir .. "/" .. entry
            local attr = hs.fs.attributes(path)
            files[#files + 1] = { path = path, mtime = attr and attr.modification or 0 }
          end
        end
      end
    end
  end
  return files
end

-- Per-file day-resolution cache. Keyed by absolute file path. Value:
-- `{ mtime = <fs mtime>, dayAgg = <"YYYY-MM-DD\0model" → row> }`. The
-- dayAgg is the file's full per-day per-model usage with no from/to
-- filter and no coarser bucketing applied. Subsequent refreshes
-- re-aggregate cached rows in milliseconds; only files whose mtime
-- has changed since last seen need to be re-read from disk.
--
-- Claude Code session files are append-only — once a session ends, the
-- file's mtime is stable forever. The only file that legitimately
-- needs re-parsing across refreshes is the currently-active session.
local _ccFileCache = {}

-- Disk-backed cache: persist `_ccFileCache` to a JSON file so a
-- Hammerspoon reload doesn't dump a hot cache and force a multi-second
-- cold re-parse on the next broad-range refresh. Version-tagged so a
-- shape change in a future spoon release discards stale on-disk data
-- without trying to reuse incompatible entries.
--
-- On-disk shape:
--   { "version": 1,
--     "files": { "<abs path>": { "mtime": N, "rows": [<row>, ...] } } }
-- The in-memory `dayAgg` map is reconstituted from `rows` on load by
-- re-keying `date .. "\0" .. model`. Persisting the list form avoids
-- the JSON encoder having to round-trip null-byte map keys.
local CC_CACHE_VERSION = 1

local function ccCacheFilePath()
  return (os.getenv("HOME") or "/tmp") .. "/.hammerspoon/cache/ModelsUsage-claudecode.json"
end

local function loadClaudeCodeCache()
  local f = io.open(ccCacheFilePath(), "r")
  if not f then return end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then return end
  local ok, decoded = pcall(hs.json.decode, content)
  if not ok or type(decoded) ~= "table" then return end
  if decoded.version ~= CC_CACHE_VERSION then return end
  local restored = 0
  for path, entry in pairs(decoded.files or {}) do
    if type(entry) == "table" and type(entry.mtime) == "number"
       and type(entry.rows) == "table" then
      local dayAgg = {}
      for _, row in ipairs(entry.rows) do
        if type(row) == "table" and row.date and row.model then
          dayAgg[row.date .. "\0" .. row.model] = row
        end
      end
      _ccFileCache[path] = { mtime = entry.mtime, dayAgg = dayAgg }
      restored = restored + 1
    end
  end
  return restored
end

local function saveClaudeCodeCache()
  local out = { version = CC_CACHE_VERSION, files = {} }
  for path, entry in pairs(_ccFileCache) do
    local rows = {}
    for _, row in pairs(entry.dayAgg) do rows[#rows + 1] = row end
    out.files[path] = { mtime = entry.mtime, rows = rows }
  end
  local encoded = hs.json.encode(out)
  if not encoded then return end
  -- Best-effort: create the cache directory if it doesn't exist yet.
  local cacheDir = ccCacheFilePath():match("^(.*)/[^/]+$")
  if cacheDir then hs.fs.mkdir(cacheDir) end
  local f = io.open(ccCacheFilePath(), "w")
  if not f then return end
  f:write(encoded)
  f:close()
end

-- Fold one JSONL line into a per-day agg. Returns true if the line
-- matched the assistant-usage shape and contributed to `agg`, false
-- otherwise. Substring pre-filter: assistant-message lines from
-- Claude Code always carry `"role":"assistant"` and `"usage":`
-- together (compact JSON, no spaces). Most lines in a session log are
-- user / tool / snapshot events that don't match; `string.find` with
-- the plain flag rejects them in microseconds so we never pay the
-- `hs.json.decode` cost on them — the single biggest perf knob.
local function foldClaudeCodeLine(line, agg)
  if not line or line == ""
     or not line:find('"role":"assistant"', 1, true)
     or not line:find('"usage":', 1, true) then
    return false
  end
  local ok, evt = pcall(hs.json.decode, line)
  if not ok or type(evt) ~= "table" then return false end
  local msg = evt.message
  local tsStr = evt.timestamp
  if not (type(msg) == "table" and msg.role == "assistant"
          and type(msg.usage) == "table" and type(tsStr) == "string") then
    return false
  end
  local date = tsStr:sub(1, 10)  -- "YYYY-MM-DD"
  local model = tostring(msg.model or "unknown")
  local key = date .. "\0" .. model
  local row = agg[key]
  if not row then
    row = { date = date, model = model, ts = tsStr,
            requests = 0, input_tokens = 0, output_tokens = 0,
            cached_tokens = 0, reasoning_tokens = 0 }
    agg[key] = row
  end
  local u = msg.usage
  row.requests      = row.requests      + 1
  row.input_tokens  = row.input_tokens  + (tonumber(u.input_tokens)  or 0)
  row.output_tokens = row.output_tokens + (tonumber(u.output_tokens) or 0)
  -- Sum read-cache + write-cache as "cached tokens" — the at-a-glance
  -- aggregate "tokens that touched the cache."
  row.cached_tokens = row.cached_tokens
                    + (tonumber(u.cache_read_input_tokens)     or 0)
                    + (tonumber(u.cache_creation_input_tokens) or 0)
  -- Track the latest timestamp seen for the (day, model) bucket;
  -- used by the from/to filter at merge time for sub-day precision.
  if tsStr > row.ts then row.ts = tsStr end
  -- Anthropic doesn't break out reasoning tokens in `message.usage`;
  -- extended-thinking is counted toward output_tokens. Leave at 0.
  return true
end

-- Async per-file parser with line-level batching. Slurps all lines
-- (cheap io even for multi-MB files), then folds them into the agg in
-- chunks of LINES_PER_TICK per runloop tick, yielding via
-- `hs.timer.doAfter(0)` between chunks. The yields are what let other
-- spoons' event-tap callbacks fire during a cold parse — without them,
-- a single 5000-line session file holds the main thread for ~170 ms.
--
-- `isStillCurrent()` is consulted before each batch so a superseded
-- run (the user clicked another preset mid-parse, bumping requestSeq)
-- bails immediately instead of finishing dead work.
local LINES_PER_TICK = 500

local function parseClaudeCodeFileAsync(filepath, isStillCurrent, callback)
  local f = io.open(filepath, "r")
  if not f then callback({}); return end
  local lines = {}
  for line in f:lines() do lines[#lines + 1] = line end
  f:close()

  local agg = {}
  local idx = 0
  local total = #lines

  local function processBatch()
    if not isStillCurrent() then
      callback(nil)  -- superseded
      return
    end
    local stop = math.min(idx + LINES_PER_TICK, total)
    for i = idx + 1, stop do
      foldClaudeCodeLine(lines[i], agg)
    end
    idx = stop
    if idx >= total then
      callback(agg)
    else
      hs.timer.doAfter(0, processBatch)
    end
  end
  processBatch()
end

-- Look up a file's cached day-agg, or parse it asynchronously and
-- cache the result. `callback(dayAgg, wasCached)` fires once the agg
-- is available; `dayAgg` is nil if the run was superseded.
local function getCachedDayAggAsync(filepath, mtime, isStillCurrent, callback)
  local cached = _ccFileCache[filepath]
  if cached and cached.mtime == mtime then
    callback(cached.dayAgg, true)
    return
  end
  parseClaudeCodeFileAsync(filepath, isStillCurrent, function(dayAgg)
    if dayAgg == nil then callback(nil, false); return end
    _ccFileCache[filepath] = { mtime = mtime, dayAgg = dayAgg }
    callback(dayAgg, false)
  end)
end

-- Apply the user's date range + granularity to a cached day-level agg,
-- merging surviving rows into `target` (the shared global agg for the
-- in-progress refresh). Day-resolution rows whose `ts` falls inside
-- [fromEpoch, toEpoch] contribute; bucketing happens at merge time so
-- the cache stays granularity-agnostic.
local function mergeFilteredDayAgg(dayAgg, fromEpoch, toEpoch, granularity, target)
  for _, row in pairs(dayAgg) do
    local epoch = isoToEpoch(row.ts)
    if epoch
       and (not fromEpoch or epoch >= fromEpoch)
       and (not toEpoch   or epoch <= toEpoch) then
      local bucket = row.date
      if granularity == "month" then bucket = row.date:sub(1, 7)
      elseif granularity == "year" then bucket = row.date:sub(1, 4)
      end
      local key = bucket .. "\0" .. row.model
      local cur = target[key]
      if not cur then
        cur = { date = bucket, model = row.model,
                requests = 0, input_tokens = 0, output_tokens = 0,
                cached_tokens = 0, reasoning_tokens = 0 }
        target[key] = cur
      end
      cur.requests      = cur.requests      + row.requests
      cur.input_tokens  = cur.input_tokens  + row.input_tokens
      cur.output_tokens = cur.output_tokens + row.output_tokens
      cur.cached_tokens = cur.cached_tokens + row.cached_tokens
    end
  end
end

-- Turn the aggregation map into the {series, by_model, ...} shape that
-- buildViewModel + computeDerived already consume for KIX.
local function buildClaudeCodeData(agg, fromIso, toIso, granularity)
  local series = {}
  local perModel = {}
  for _, row in pairs(agg) do
    series[#series + 1] = row
    local bm = perModel[row.model]
    if not bm then
      bm = { model = row.model,
             requests = 0, input_tokens = 0, output_tokens = 0,
             cached_tokens = 0, reasoning_tokens = 0 }
      perModel[row.model] = bm
    end
    bm.requests      = bm.requests      + row.requests
    bm.input_tokens  = bm.input_tokens  + row.input_tokens
    bm.output_tokens = bm.output_tokens + row.output_tokens
    bm.cached_tokens = bm.cached_tokens + row.cached_tokens
  end
  table.sort(series, function(a, b)
    if a.date ~= b.date then return a.date < b.date end
    return a.model < b.model
  end)
  local by_model = {}
  for _, bm in pairs(perModel) do by_model[#by_model + 1] = bm end
  table.sort(by_model, function(a, b) return a.input_tokens > b.input_tokens end)
  return {
    keys = {},
    granularity = granularity,
    from = fromIso,
    to = toIso,
    series = series,
    by_model = by_model,
  }
end

-- Per-source refresh: Claude Code. Walks ~/.claude/projects/*/*.jsonl
-- one file per runloop tick (separated by `hs.timer.doAfter(0)`) so
-- that even a slow individual file only stalls Hammerspoon's main
-- thread for the duration of that file, not a multi-file batch. Files
-- whose mtime predates `from` are skipped without opening — session
-- logs are append-only, so a stale file can't contain any matching
-- event. Writes to state.sources.claudecode.{lastData, ...}.
function obj:_refreshClaudeCode(requestSeq)
  local slot = self._state.sources.claudecode
  local startedAt = hs.timer.secondsSinceEpoch()

  self._state.inFlight = true
  self:_setMenubarStatus("Loading...", false)
  self:_publishToWindow()

  -- Snapshot filter params so a subsequent state change (preset click,
  -- granularity change) that bumps requestSeq cleanly supersedes this run.
  local granularity = self._state.granularity or self.defaultGranularity
  local fromIso = self._state.from
  local toIso   = self._state.to
  local fromEpoch = fromIso and isoToEpoch(fromIso) or nil
  local toEpoch   = toIso   and isoToEpoch(toIso)   or nil

  -- Buffer the mtime cutoff by one day to absorb timezone slop between
  -- `from` (whose isoToEpoch result depends on the local tz interpretation)
  -- and file mtimes (which are real UTC seconds). False positives here are
  -- cheap (one extra file gets walked); a false negative would silently
  -- drop a session's data.
  local mtimeCutoff = fromEpoch and (fromEpoch - 86400) or nil

  local allFiles = listClaudeCodeFiles()
  local files = {}
  for _, e in ipairs(allFiles) do
    if not mtimeCutoff or e.mtime >= mtimeCutoff then
      files[#files + 1] = e
    end
  end
  self.logger.df("refresh start #%d source=claudecode files=%d (of %d, skipped %d via mtime) granularity=%s",
    requestSeq, #files, #allFiles, #allFiles - #files, granularity)

  if #files == 0 then
    self._state.inFlight = false
    slot.lastData = buildClaudeCodeData({}, fromIso, toIso, granularity)
    slot.lastError = nil
    slot.lastStatus = 200
    slot.lastRefreshAt = os.time()
    self:_setMenubarStatus("OK", false)
    self:_publishToWindow()
    return
  end

  local agg = {}
  local idx = 0
  local cacheHits, coldParses = 0, 0

  local isStillCurrent = function() return requestSeq == self._state.requestSeq end

  local function finalize()
    self._state.inFlight = false
    slot.lastData = buildClaudeCodeData(agg, fromIso, toIso, granularity)
    slot.lastError = nil
    slot.lastStatus = 200
    slot.lastRefreshAt = os.time()
    local elapsed = hs.timer.secondsSinceEpoch() - startedAt
    self.logger.df("refresh response #%d source=claudecode elapsed=%.3fs files=%d (%d cached, %d parsed) rows=%d",
      requestSeq, elapsed, #files, cacheHits, coldParses, #slot.lastData.series)
    self:_setMenubarStatus("OK", false)
    self:_publishToWindow()
    -- Persist the cache after a refresh that added entries, so the
    -- next Hammerspoon reload doesn't have to re-parse from cold.
    -- Deferred to the next tick so the disk write doesn't sit on the
    -- response path's critical section.
    if coldParses > 0 then
      hs.timer.doAfter(0, saveClaudeCodeCache)
    end
  end

  local processNext  -- forward declaration
  processNext = function()
    if not isStillCurrent() then
      self.logger.wf("stale claudecode run #%d superseded", requestSeq)
      return
    end
    idx = idx + 1
    if idx > #files then finalize(); return end
    local file = files[idx]
    getCachedDayAggAsync(file.path, file.mtime, isStillCurrent, function(dayAgg, wasCached)
      if dayAgg == nil then return end  -- superseded mid-parse
      mergeFilteredDayAgg(dayAgg, fromEpoch, toEpoch, granularity, agg)
      if wasCached then cacheHits = cacheHits + 1
      else              coldParses = coldParses + 1 end
      -- Yield between files even on cache hits: the merge itself runs
      -- in the closure synchronously, and chaining hundreds of cached
      -- merges back-to-back without yielding would still hold the
      -- main thread.
      hs.timer.doAfter(0, processNext)
    end)
  end

  processNext()
end

-- Compute the four fixed Summary time windows against the current
-- clock. Each returns an `{fromIso, toIso, fromEpoch, toEpoch}` table
-- so aggregations can do both string-keyed (for the API call) and
-- numeric (for fast in-row date checks) comparisons.
local function computeSummaryWindows()
  local function pair(fromIso, toIso)
    return { fromIso = fromIso, toIso = toIso,
             fromEpoch = isoToEpoch(fromIso),
             toEpoch = isoToEpoch(toIso) }
  end
  local today  = pair(startOfDayUtc(0),  endOfDayUtc(0))
  return {
    today     = today,
    thisWeek  = pair(startOfWeekUtc(),  today.toIso),
    thisMonth = pair(startOfMonthUtc(), today.toIso),
    thisYear  = pair(startOfYearUtc(),  today.toIso),
  }
end

-- Sum the three token kinds we surface in the dashboard (input +
-- output + cached) into a single "tokens used" number for the
-- Summary table. Reasoning tokens are folded into output for
-- Anthropic responses, so output already covers thinking.
local function totalTokens(row)
  return (tonumber(row.input_tokens)  or 0)
       + (tonumber(row.output_tokens) or 0)
       + (tonumber(row.cached_tokens) or 0)
end

-- Walk Claude Code's most-recently-modified session files for
-- assistant-role messages whose timestamps fall inside the trailing
-- 5h rolling window. Sums tokens (input + output + cache_read +
-- cache_creation) and tracks the earliest in-window timestamp — the
-- earliest message is what determines when the next token leaves the
-- rolling window. The day-resolution `_ccFileCache` doesn't carry
-- sub-day timestamps so this pays a fresh per-file parse, but the
-- mtime filter keeps it to the 1-2 files that could possibly
-- contain in-window messages.
local function computeClaudeCodeSession()
  local windowSeconds = 5 * 3600
  local nowEpoch = os.time()
  local windowStartEpoch = nowEpoch - windowSeconds
  -- 1h buffer on the mtime filter for files whose mtime crossed the
  -- 5h boundary while the user was idle.
  local mtimeCutoff = windowStartEpoch - 3600

  local relevantFiles = {}
  for _, f in ipairs(listClaudeCodeFiles()) do
    if f.mtime >= mtimeCutoff then
      relevantFiles[#relevantFiles + 1] = f
    end
  end

  local tokensUsed = 0
  local earliestEpoch
  local lastModel

  for _, file in ipairs(relevantFiles) do
    local fh = io.open(file.path, "r")
    if fh then
      for line in fh:lines() do
        if line and line ~= ""
           and line:find('"role":"assistant"', 1, true)
           and line:find('"usage":', 1, true) then
          local ok, evt = pcall(hs.json.decode, line)
          if ok and type(evt) == "table" and type(evt.message) == "table"
             and evt.message.role == "assistant"
             and type(evt.message.usage) == "table"
             and type(evt.timestamp) == "string" then
            local epoch = isoToEpoch(evt.timestamp)
            if epoch and epoch >= windowStartEpoch then
              local u = evt.message.usage
              tokensUsed = tokensUsed
                + (tonumber(u.input_tokens)              or 0)
                + (tonumber(u.output_tokens)             or 0)
                + (tonumber(u.cache_read_input_tokens)   or 0)
                + (tonumber(u.cache_creation_input_tokens) or 0)
              if not earliestEpoch or epoch < earliestEpoch then
                earliestEpoch = epoch
              end
              if evt.message.model then lastModel = tostring(evt.message.model) end
            end
          end
        end
      end
      fh:close()
    end
  end

  return {
    tokensUsed       = tokensUsed,
    windowSeconds    = windowSeconds,
    windowStartEpoch = windowStartEpoch,
    earliestEpoch    = earliestEpoch,
    -- Reset = the moment the *earliest* in-window message ages out.
    -- Until any message is in-window, "reset" is meaningless, so nil.
    resetEpoch       = earliestEpoch and (earliestEpoch + windowSeconds) or nil,
    lastModel        = lastModel,
  }
end

-- A summary row only earns a place in the table when it contributes
-- something to at least one of the four windows. Filters out two
-- failure modes at once:
--   1. Cached day-aggs whose timestamps predate the earliest window
--      (`thisYear`'s start): the row gets created in the per-model
--      map but never lands a contribution → all-zero row.
--   2. Legacy / corrupted cache entries where `model` is an empty
--      string (some old session lines logged with `"model":""` and
--      the `tostring(msg.model or "unknown")` fallback in
--      `foldClaudeCodeLine` only catches nil, not "").
local function hasAnyWindowTokens(row)
  return (row.today     or 0) > 0
      or (row.thisWeek  or 0) > 0
      or (row.thisMonth or 0) > 0
      or (row.thisYear  or 0) > 0
end

-- Aggregate the in-memory Claude Code cache into per-model Summary
-- rows. No async work because everything we need is already in
-- `_ccFileCache`'s day-resolution aggs.
local function buildClaudeCodeSummaryRows(windows)
  local perModel = {}
  for _, fileEntry in pairs(_ccFileCache) do
    for _, dayRow in pairs(fileEntry.dayAgg or {}) do
      local epoch = isoToEpoch(dayRow.ts)
      if epoch then
        local entry = perModel[dayRow.model]
        if not entry then
          entry = { source = "Claude Code", model = dayRow.model,
                    today = 0, thisWeek = 0, thisMonth = 0, thisYear = 0 }
          perModel[dayRow.model] = entry
        end
        local t = totalTokens(dayRow)
        for windowName, window in pairs(windows) do
          if epoch >= (window.fromEpoch or 0)
             and epoch <= (window.toEpoch or math.huge) then
            entry[windowName] = entry[windowName] + t
          end
        end
      end
    end
  end
  local rows = {}
  for _, r in pairs(perModel) do
    if hasAnyWindowTokens(r) then rows[#rows + 1] = r end
  end
  return rows
end

-- Aggregate a KIX `/api/usage` response (one year-to-date call with
-- granularity=day) into per-model Summary rows. The server's
-- `series` is the per-day breakdown; we slice each row into whichever
-- of the four windows it falls into and accumulate.
local function buildKixSummaryRows(data, windows)
  if type(data) ~= "table" or type(data.series) ~= "table" then return {} end
  local perModel = {}
  for _, dayRow in ipairs(data.series) do
    if type(dayRow) == "table" and type(dayRow.date) == "string" then
      -- `date` from the KIX response is a "YYYY-MM-DD" bucket; treat
      -- it as the start of the day for window matching.
      local epoch = isoToEpoch(dayRow.date .. "T00:00:00Z")
      if epoch then
        local model = tostring(dayRow.model or "unknown")
        local entry = perModel[model]
        if not entry then
          entry = { source = "KIX", model = model,
                    today = 0, thisWeek = 0, thisMonth = 0, thisYear = 0 }
          perModel[model] = entry
        end
        local t = totalTokens(dayRow)
        for windowName, window in pairs(windows) do
          if epoch >= (window.fromEpoch or 0)
             and epoch <= (window.toEpoch or math.huge) then
            entry[windowName] = entry[windowName] + t
          end
        end
      end
    end
  end
  local rows = {}
  for _, r in pairs(perModel) do
    if hasAnyWindowTokens(r) then rows[#rows + 1] = r end
  end
  return rows
end

-- Per-source refresh: Summary. Cross-source aggregation that hits each
-- underlying source for *one* broad year-to-date pull, then buckets
-- the result into the four fixed windows client-side. KIX is async
-- (HTTP); Claude Code is sync (cached day-aggs). The Summary slot's
-- `lastData.rows` carries the {source, model, today, thisWeek,
-- thisMonth, thisYear} matrix the JS-side render fills the table from.
function obj:_refreshSummary(requestSeq)
  local slot = self._state.sources.summary
  local startedAt = hs.timer.secondsSinceEpoch()

  self._state.inFlight = true
  self:_setMenubarStatus("Loading...", false)
  self:_publishToWindow()

  local windows = computeSummaryWindows()
  local allRows = {}
  local pending = 0
  local errors = {}

  local function isStillCurrent() return requestSeq == self._state.requestSeq end

  local function finalize()
    if not isStillCurrent() then return end
    self._state.inFlight = false
    -- Sort: highest This-Year first so the biggest spenders rise to
    -- the top. Stable secondary sort by source then model so
    -- recurrent reloads don't visibly reshuffle equal rows.
    table.sort(allRows, function(a, b)
      if a.thisYear ~= b.thisYear then return a.thisYear > b.thisYear end
      if a.source ~= b.source then return a.source < b.source end
      return (a.model or "") < (b.model or "")
    end)
    slot.lastData = { rows = allRows, windows = windows, errors = errors,
                      claudecodeSession = claudecodeSession }
    slot.lastError = nil  -- per-source errors live in lastData.errors
    slot.lastStatus = 200
    slot.lastRefreshAt = os.time()
    local elapsed = hs.timer.secondsSinceEpoch() - startedAt
    self.logger.df("refresh response #%d source=summary elapsed=%.3fs rows=%d",
      requestSeq, elapsed, #allRows)
    self:_setMenubarStatus("OK", false)
    self:_publishToWindow()
  end

  local function sourceDone()
    pending = pending - 1
    if pending == 0 then finalize() end
  end

  -- Claude Code: synchronous aggregation from cached day-aggs, plus
  -- a fresh per-file walk of the trailing 5h to populate the session
  -- quota card. Wrap in a doAfter(0) so `pending` is set up before
  -- we resolve.
  pending = pending + 1
  local claudecodeSession = nil
  hs.timer.doAfter(0, function()
    if not isStillCurrent() then sourceDone(); return end
    local ok, ccRows = pcall(buildClaudeCodeSummaryRows, windows)
    if ok and type(ccRows) == "table" then
      for _, r in ipairs(ccRows) do allRows[#allRows + 1] = r end
    else
      errors.claudecode = tostring(ccRows or "aggregation failed")
    end
    local sessOk, sess = pcall(computeClaudeCodeSession)
    if sessOk and type(sess) == "table" then
      sess.quotaTokens = self.claudecodeQuotaTokens or 0
      claudecodeSession = sess
      self.logger.df("claudecode session: tokensUsed=%d earliestEpoch=%s resetEpoch=%s lastModel=%s",
        sess.tokensUsed or 0,
        tostring(sess.earliestEpoch),
        tostring(sess.resetEpoch),
        tostring(sess.lastModel))
    else
      self.logger.ef("claudecode session compute failed: %s", tostring(sess))
    end
    sourceDone()
  end)

  -- KIX: one year-to-date pull. Skip silently when no token is
  -- configured (the user may have a Claude-Code-only setup).
  local kixCfg = self._state.sources.kix.config
  if kixCfg.token and kixCfg.token ~= "" then
    pending = pending + 1
    local queryParts = {
      "granularity=day",
      "from=" .. hs.http.encodeForQuery(windows.thisYear.fromIso),
      "to="   .. hs.http.encodeForQuery(windows.thisYear.toIso),
    }
    if type(kixCfg.keys) == "table" then
      for _, k in ipairs(kixCfg.keys) do
        if type(k) == "string" and k ~= "" then
          table.insert(queryParts, "key=" .. hs.http.encodeForQuery(k))
        end
      end
    end
    local url = self.apiBaseUrl .. self.usagePath .. "?" .. table.concat(queryParts, "&")
    local headers = {
      ["Authorization"] = "Bearer " .. kixCfg.token,
      ["Accept"] = "application/json",
    }
    self.logger.df("refresh start #%d source=summary kix=GET url=%s headers=%s",
      requestSeq, url, formatHeadersForLog(headers))

    -- Timeout for the KIX HTTP leg. Without this an unreachable / slow
    -- KIX server hangs the entire Summary refresh forever — pending
    -- never decrements, finalize never fires, `state.inFlight` stays
    -- true, and every subsequent refresh skips with "request already
    -- in flight". `kixDone` guards against the timeout and the real
    -- response both firing.
    local kixDone = false
    local kixTimeoutTimer = hs.timer.doAfter(self.timeoutSeconds, function()
      if kixDone or not isStillCurrent() then return end
      kixDone = true
      errors.kix = "Request timed out after " .. tostring(self.timeoutSeconds) .. "s"
      self.logger.ef("refresh timeout #%d source=summary kix after %ds",
        requestSeq, self.timeoutSeconds)
      sourceDone()
    end)

    hs.http.asyncGet(url, headers, function(status, body)
      if kixDone or not isStillCurrent() then return end
      kixDone = true
      if kixTimeoutTimer then kixTimeoutTimer:stop(); kixTimeoutTimer = nil end
      if status < 200 or status >= 300 then
        errors.kix = "HTTP " .. tostring(status)
        sourceDone()
        return
      end
      local data, err = parseJson(body)
      if not data then
        errors.kix = err or "parse failed"
        sourceDone()
        return
      end
      local kixRows = buildKixSummaryRows(data, windows)
      for _, r in ipairs(kixRows) do allRows[#allRows + 1] = r end
      sourceDone()
    end)
  end
end

function obj:_handleAction(params)
  local action = params.action
  if not action then return end

  if action == "refresh" then
    self:refresh()
    return
  end

  if action == "setGranularity" then
    self:setGranularity(params.value)
    return
  end

  if action == "applyControls" then
    if params.granularity then self._state.granularity = clampGranularity(params.granularity) end
    self._state.from = params.from and params.from ~= "" and params.from or nil
    self._state.to = params.to and params.to ~= "" and params.to or nil
    -- User explicitly set from/to via the form, so no preset owns the
    -- range anymore — clear the active preset so the highlight goes
    -- away and a future reload doesn't recompute the preset on top of
    -- whatever the user typed.
    self._state.activePreset = nil
    -- params.key is a comma-separated UUID list from the input field;
    -- only meaningful for the KIX source (the input is hidden on other
    -- tabs by the JS-side render).
    self._state.sources.kix.config.keys = parseKeysCsv(params.key or "")
    if params.interval and params.interval ~= "" then
      self:setRefreshSeconds(params.interval)
    end
    self:_saveSettings()
    self:refresh()
    return
  end

  if action == "preset" and params.name then
    self:_applyPreset(params.name)
    return
  end

  if action == "setSource" and params.id then
    self:setActiveSource(params.id)
    return
  end

  if action == "ready" then
    -- JS-side handshake: the dashboard script has loaded and is ready
    -- to receive ModelsUsageRender calls. Push current state now so
    -- the initial render doesn't depend on the in-flight refresh
    -- completing.
    self:_publishToWindow()
    return
  end
end

function obj:_parseActionUrl(url)
  local q = url:match("^modelsusage://action%??(.*)$")
  if q == nil then return nil end
  local out = {}
  for pair in string.gmatch(q, "[^&]+") do
    local k, v = pair:match("([^=]+)=(.*)")
    if k then
      out[hs.http.decodeForQuery(k)] = hs.http.decodeForQuery(v or "")
    end
  end
  return out
end

-- How long to leave the dashboard visible during pre-warm before
-- hiding it. Has to be long enough for WebKit's content-process spawn
-- + initial layout + JS execution to actually run (which is what
-- we're trying to amortise off the menubar-click critical path). 1.5 s
-- comfortably covers the 3-5 s spawn even on a busy reload — the
-- window stays up only as long as it takes to get the work done; the
-- hide() runs as soon as the timer fires.
local PREWARM_VISIBLE_SECONDS = 1.5

-- Lazy create-only helper. `visible` true → create the window at the
-- user's saved frame + alpha 1 + focus, ready to interact with.
-- `visible` false → pre-warm: show the window briefly (visibly!) so
-- the WebKit content-process spawn + initial paint actually happen,
-- then hide it after PREWARM_VISIBLE_SECONDS. The flash is the
-- unfortunate cost of forcing the work; alpha-0 / off-screen /
-- alpha-0.01 all let macOS skip the render path, so the spawn never
-- actually happens and the cost stays on the user's menubar click.
function obj:_createWindow(visible)
  if self._state.window then return end

  local frame = self:_loadWindowFrame()

  -- WKWebView message bridge: replaces URL-hijack RPC. Each JS-side
  -- send() posts a structured table here without triggering a
  -- navigation, so clicks/Apply feel instant instead of incurring
  -- WebKit's navigate-then-cancel overhead.
  local controller = hs.webview.usercontent.new("modelsusage")
  controller:setCallback(function(message)
    if type(message) == "table" and type(message.body) == "table" then
      self:_handleAction(message.body)
    end
  end)

  -- developerExtrasEnabled exposes right-click → Inspect Element in the
  -- webview, so the user can profile WKWebView with Web Inspector when
  -- the dashboard feels sluggish.
  local w = hs.webview.new(frame, { developerExtrasEnabled = true }, controller)
    :windowTitle("Models Usage Dashboard")
    :windowStyle({ "titled", "closable", "resizable", "miniaturizable" })
    :allowTextEntry(true)
    :closeOnEscape(true)
    :deleteOnClose(false)
    :level(hs.drawing.windowLevels.normal)

  -- URL-hijack fallback for older Hammerspoon builds without
  -- messageHandlers — JS sets `window.location = modelsusage://action?…`
  -- which fires here; we dispatch and cancel the navigation.
  w:navigationCallback(function(_, _, navURL)
    local params = self:_parseActionUrl(navURL)
    if params then
      self:_handleAction(params)
      return false
    end
    return true
  end)

  -- Back the page with a data: URL rather than `w:html()`. Inline-
  -- injected HTML has no URL behind it, so right-click → Reload (or
  -- any WebKit reload) navigates to about:blank and the dashboard
  -- goes white. A data:text/html URL is self-contained (no temp file,
  -- no file:// permissions) and WebKit treats it as a real navigation
  -- target, so reload re-fetches it cleanly.
  w:url("data:text/html;charset=utf-8;base64," .. hs.base64.encode(htmlTemplate()))

  w:alpha(1.0)
  w:show()

  self._state.window = w
  self._state.windowPrewarmed = not visible
  self:_publishToWindow()

  if visible then
    -- Make the dashboard the key window via hs.window:focus(), not
    -- webview:bringToFront(true). bringToFront(true) bumps the level
    -- above NSNormalWindowLevel, making the dashboard float over
    -- other apps' windows persistently. focus() routes through
    -- normal app activation and leaves the level alone. The 0.08s
    -- deferral catches the case where show() hasn't completed
    -- WebKit's initial layout by the time we ask for focus.
    hs.timer.doAfter(0.08, function()
      if not self._state.window then return end
      local win = self._state.window:hswindow()
      if win then win:focus() end
    end)
    hs.timer.doAfter(0, function() self:refresh() end)
  else
    -- Pre-warm path: window is briefly visible (forcing WebKit to
    -- actually spawn + render); hide it after enough time for the
    -- spawn to finish. The hide() makes future menubar opens instant
    -- because the content process stays alive on the hidden window.
    hs.timer.doAfter(PREWARM_VISIBLE_SECONDS, function()
      if self._state.window and self._state.windowPrewarmed then
        self._state.window:hide()
      end
    end)
  end
end

-- Promote a pre-warmed window: it's been hidden after a brief
-- pre-warm flash. show() brings it back instantly because the WebKit
-- content process is already running and the page is already
-- rendered.
function obj:_promotePrewarmedWindow()
  if not (self._state.window and self._state.windowPrewarmed) then return end
  self._state.windowPrewarmed = false
  self._state.window:show()
  hs.timer.doAfter(0.08, function()
    if not self._state.window then return end
    local win = self._state.window:hswindow()
    if win then win:focus() end
  end)
end

function obj:_openWindow()
  if not self._state.window then
    -- No window at all — first open from menubar before pre-warm fired,
    -- or after stop()/start(). Create visible (pays WebKit spawn cost
    -- inline; we tried to avoid this via pre-warm but it's the
    -- correct fallback path).
    self:_createWindow(true)
    return
  end

  if self._state.windowPrewarmed then
    self:_promotePrewarmedWindow()
    self:_publishToWindow()
    return
  end

  -- Existing visible window (was just closed via X with
  -- deleteOnClose(false), so the reference is still live). show() is
  -- required to make it visible again; focus() promotes it to key
  -- without changing window level.
  self._state.window:show()
  local win = self._state.window:hswindow()
  if win then win:focus() end
  self:_publishToWindow()
end

function obj:_closeWindow()
  if self._state.window then
    local f = self._state.window:frame()
    self:_saveWindowFrame(f)
    self._state.window:delete()
    self._state.window = nil
  end
end

function obj:_restartTimer()
  if self._state.timer then
    self._state.timer:stop()
    self._state.timer = nil
  end
  self._state.timer = hs.timer.doEvery(self._state.refreshSeconds or self.refreshSeconds, function() self:refresh() end)
end

function obj:_makeMenu()
  local activeId = self._state.activeSource
  local sourcesSubmenu = {}
  for _, id in ipairs(SOURCE_ORDER) do
    local def = SOURCES[id]
    sourcesSubmenu[#sourcesSubmenu + 1] = {
      title = def.displayName .. (id == activeId and "  ✓" or ""),
      fn = function() self:setActiveSource(id) end,
    }
  end

  local kixCfg = self._state.sources.kix.config
  local kixSubmenu = {
    { title = "Set API key...", fn = function()
      local btn, text = hs.dialog.textPrompt(
        "KIX API key", "Enter the API key used in the Authorization: Bearer header:",
        kixCfg.token or "", "Save", "Cancel")
      if btn == "Save" then self:setApiKey(text); self:refresh() end
    end },
    { title = "Set keys...", fn = function()
      local current = (type(kixCfg.keys) == "table" and #kixCfg.keys > 0)
        and table.concat(kixCfg.keys, ", ")
        or ""
      local btn, text = hs.dialog.textPrompt(
        "KIX keys",
        "Enter key UUIDs, comma-separated (leave empty for none):",
        current, "Save", "Cancel")
      if btn == "Save" then
        self:setKeys(text or "")
        self:refresh()
      end
    end },
  }

  local menu = {
    { title = "Open Usage Dashboard", fn = function() self:_openWindow() end },
    { title = "Refresh now", fn = function() self:refresh() end },
    { title = "-" },
    { title = "Active source", menu = sourcesSubmenu },
    { title = "Configure KIX",  menu = kixSubmenu },
    { title = "Set interval (seconds)...", fn = function()
      local btn, text = hs.dialog.textPrompt("Refresh interval", "Seconds:",
        tostring(self._state.refreshSeconds), "Save", "Cancel")
      if btn == "Save" then self:setRefreshSeconds(text) end
    end },
    { title = "-" },
    { title = "Exit", fn = function() self:stop() end },
  }

  return menu
end

function obj:start()
  if self._state.menubar then return self end

  self:_loadSettings()
  -- Restore the on-disk Claude Code parse cache so the first refresh
  -- after a Hammerspoon reload doesn't have to cold-parse every file
  -- that was already cached in the previous session.
  local restored = loadClaudeCodeCache()
  if restored and restored > 0 then
    self.logger.df("restored claudecode parse cache: %d files", restored)
  end
  if not self._state.granularity then
    self._state.granularity = clampGranularity(self.defaultGranularity)
  end
  self._state.refreshSeconds = coercePositiveNumber(self._state.refreshSeconds or self.refreshSeconds, self.refreshSeconds)

  self._state.menubar = hs.menubar.new()
  self:_updateMenubarIcon()
  self._state.menubar:setMenu(function() return self:_makeMenu() end)

  self._state.themeWatcher = hs.distributednotifications.new(function()
    self:_updateMenubarIcon()
  end, APPEARANCE_NOTE)
  self._state.themeWatcher:start()

  self:_setMenubarStatus("Starting", false)
  self:_restartTimer()
  self:refresh()

  -- Pre-warm the dashboard webview a few seconds after start, IF the
  -- user opted in. See `obj.prewarmDashboard` for the trade-off
  -- (briefly-visible dashboard at startup vs no flash but a 3-5s
  -- scroll hang on first menubar-click open). Default is off because
  -- the flash is a behavioural change that should be explicit.
  if self.prewarmDashboard then
    hs.timer.doAfter(3.0, function()
      if self._state.window then return end  -- user got there first
      self:_createWindow(false)
    end)
  end

  return self
end

function obj:stop()
  if self._state.timeoutTimer then
    self._state.timeoutTimer:stop()
    self._state.timeoutTimer = nil
  end
  if self._state.timer then
    self._state.timer:stop()
    self._state.timer = nil
  end
  if self._state.themeWatcher then
    self._state.themeWatcher:stop()
    self._state.themeWatcher = nil
  end
  if self._state._publishTimer then
    self._state._publishTimer:stop()
    self._state._publishTimer = nil
  end
  if self._state._saveTimer then
    self._state._saveTimer:stop()
    self._state._saveTimer = nil
  end
  if self._state._saveDirty then
    self._state._saveDirty = false
    self:_saveSettingsImmediate()
  end
  self:_closeWindow()
  if self._state.menubar then
    self._state.menubar:delete()
    self._state.menubar = nil
  end
  self._state.inFlight = false
  return self
end

return obj
