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

obj.logger = hs.logger.new("ModelsUsage")

local SETTINGS = {
  token = "modelsUsage.token",
  defaultKey = "modelsUsage.defaultKey",
  granularity = "modelsUsage.granularity",
  from = "modelsUsage.from",
  to = "modelsUsage.to",
  refreshSeconds = "modelsUsage.refreshSeconds",
  windowFrame = "modelsUsage.windowFrame",
}

obj._state = {
  menubar = nil,
  themeWatcher = nil,
  timer = nil,
  timeoutTimer = nil,
  requestSeq = 0,
  inFlight = false,
  lastError = nil,
  lastStatus = nil,
  lastRefreshAt = nil,
  lastData = nil,
  token = nil,
  defaultKey = nil,
  granularity = nil,
  from = nil,
  to = nil,
  refreshSeconds = nil,
  window = nil,
  usesIcon = false,
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

local function buildViewModel(state, topModelsLimit, seriesRowsLimit)
  local data = state.lastData or {}
  local derived = getDerived(state.lastData, topModelsLimit, seriesRowsLimit)

  local statusText
  if state.lastError then
    statusText = "Error"
  elseif state.inFlight and state.lastData then
    statusText = "Refreshing"
  elseif state.inFlight then
    statusText = "Loading"
  else
    statusText = "OK"
  end

  return {
    status = statusText,
    lastError = state.lastError,
    lastStatus = state.lastStatus,
    lastRefreshAt = state.lastRefreshAt,
    tokenSet = state.token and true or false,
    keys = type(data.keys) == "table" and data.keys or (state.defaultKey and { state.defaultKey } or {}),
    granularity = state.granularity,
    from = state.from,
    to = state.to,
    refreshSeconds = state.refreshSeconds,
    totals = derived.totals,
    topModels = derived.top,
    series = derived.seriesLimited,
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
    .status-pill {
      display: inline-flex; align-items: center; gap: 8px;
      padding: 4px 12px; border-radius: 999px;
      font-size: 13px; font-weight: 600;
      background: var(--border); color: var(--muted);
    }
    .status-pill::before {
      content: ""; display: block; width: 8px; height: 8px;
      border-radius: 999px; background: currentColor;
    }
    .status-pill.ok    { background: rgba(22, 163, 74, 0.12);  color: var(--ok); }
    .status-pill.busy  { background: rgba(217, 119, 6, 0.12);  color: var(--warn); }
    .status-pill.busy::before { animation: pulse 0.9s ease-in-out infinite; }
    .status-pill.error { background: var(--error-bg); color: var(--error); }
    @keyframes pulse { 0%, 100% { opacity: 0.4; } 50% { opacity: 1; } }
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
    .meta-row { margin-top: 6px; min-height: 16px; }
    .meta-row:empty { display: none; }
  </style>
</head>
<body>
  <div class="progressbar" id="progress"></div>
  <div class="wrap">
    <div class="card">
      <div class="row" style="justify-content:space-between; align-items:center;">
        <div>
          <span class="status-pill" id="status">Status</span>
          <div class="mono meta-row" id="meta"></div>
        </div>
        <button id="refresh" onclick="send('refresh')" class="primary">Refresh</button>
      </div>
      <div id="error" class="error-block"></div>
    </div>

    <div class="card">
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
        <div class="cell">
          <label for="key">Default key UUID</label>
          <input id="key" placeholder="78f9ff16-..." />
        </div>
        <div class="cell">
          <label for="interval">Interval (seconds)</label>
          <input id="interval" type="number" min="1" step="1" />
        </div>
      </div>
      <div class="row" style="margin-top:10px;">
        <button id="apply" onclick="applyControls()" class="primary">Apply controls</button>
        <button data-preset="today"       onclick="pickPreset(this)">Today</button>
        <button data-preset="last7d"      onclick="pickPreset(this)">Last 7d</button>
        <button data-preset="last30d"     onclick="pickPreset(this)">Last 30d</button>
        <button data-preset="monthToDate" onclick="pickPreset(this)">MTD</button>
        <button data-preset="yearToDate"  onclick="pickPreset(this)">YTD</button>
      </div>
    </div>

    <div class="card">
      <div class="grid5" id="totals"></div>
    </div>

    <div class="card">
      <h3 style="margin:0 0 8px 0;">Top Models</h3>
      <table>
        <thead>
          <tr><th>Model</th><th>Requests</th><th>Input</th><th>Output</th><th>Cached</th><th>Reasoning</th></tr>
        </thead>
        <tbody id="topModels"></tbody>
      </table>
    </div>

    <div class="card">
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
    function f(n) {
      n = Number(n || 0);
      return Math.floor(n).toLocaleString('en-US');
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

    function setInputIfChanged(id, value) {
      const el = document.getElementById(id);
      if (!el) return;
      const str = (value == null) ? '' : String(value);
      if (el === document.activeElement) return;
      if (el.value === str) return;
      el.value = str;
    }

    function setTextIfChanged(id, value) {
      const el = document.getElementById(id);
      if (!el) return;
      const str = (value == null) ? '' : String(value);
      if (el.textContent === str) return;
      el.textContent = str;
    }

    function setStatus(status) {
      const el = document.getElementById('status');
      const label = status || 'Unknown';
      let klass = '';
      if (label === 'OK') klass = 'ok';
      else if (label === 'Loading' || label === 'Refreshing') klass = 'busy';
      else if (label === 'Error') klass = 'error';
      const wanted = 'status-pill ' + klass;
      if (el.className !== wanted) el.className = wanted.trim();
      setTextIfChanged('status', label);
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

    function setMeta(payload) {
      const parts = [];
      if (payload.lastStatus) parts.push('HTTP ' + payload.lastStatus);
      if (payload.lastRefreshAt) parts.push('updated ' + new Date(payload.lastRefreshAt * 1000).toLocaleString());
      const keys = (payload.keys || []).filter(Boolean);
      if (keys.length) parts.push('keys: ' + keys.join(', '));
      setTextIfChanged('meta', parts.join('  ·  '));
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

    let lastDataSig = null;

    window.ModelsUsageRender = function(payload) {
      setStatus(payload.status);
      setProgress(payload.status === 'Loading' || payload.status === 'Refreshing');
      setError(payload.lastError);
      setMeta(payload);

      setInputIfChanged('granularity', payload.granularity || 'month');
      setInputIfChanged('from', payload.from || '');
      setInputIfChanged('to', payload.to || '');
      setInputIfChanged('key', (payload.keys && payload.keys[0]) || '');
      setInputIfChanged('interval', payload.refreshSeconds || 300);

      const sig = JSON.stringify([
        payload.totals || {},
        payload.topModels || [],
        payload.series || [],
      ]);
      if (sig === lastDataSig) return;
      lastDataSig = sig;

      renderTotals(payload.totals || {});

      renderRows('topModels', payload.topModels || [], 6, r =>
        `<tr><td>${r.model || ''}</td><td>${f(r.requests)}</td><td>${f(r.input_tokens)}</td><td>${f(r.output_tokens)}</td><td>${f(r.cached_tokens)}</td><td>${f(r.reasoning_tokens)}</td></tr>`
      );

      renderRows('series', payload.series || [], 7, r =>
        `<tr><td>${r.date || ''}</td><td>${r.model || ''}</td><td>${f(r.requests)}</td><td>${f(r.input_tokens)}</td><td>${f(r.output_tokens)}</td><td>${f(r.cached_tokens)}</td><td>${f(r.reasoning_tokens)}</td></tr>`
      );
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
  self._state.token = hs.settings.get(SETTINGS.token)
  self._state.defaultKey = hs.settings.get(SETTINGS.defaultKey)
  self._state.granularity = clampGranularity(hs.settings.get(SETTINGS.granularity) or self.defaultGranularity)
  self._state.from = hs.settings.get(SETTINGS.from)
  self._state.to = hs.settings.get(SETTINGS.to)
  self._state.refreshSeconds = coercePositiveNumber(hs.settings.get(SETTINGS.refreshSeconds), self.refreshSeconds)
end

function obj:_saveSettingsImmediate()
  hs.settings.set(SETTINGS.token, self._state.token)
  hs.settings.set(SETTINGS.defaultKey, self._state.defaultKey)
  hs.settings.set(SETTINGS.granularity, self._state.granularity)
  hs.settings.set(SETTINGS.from, self._state.from)
  hs.settings.set(SETTINGS.to, self._state.to)
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

function obj:setToken(token)
  self._state.token = token and tostring(token) or nil
  self:_saveSettings()
  self:_renderWindow()
  return self
end

function obj:setDefaultKey(uuid)
  self._state.defaultKey = uuid and tostring(uuid) or nil
  self:_saveSettings()
  self:_renderWindow()
  return self
end

function obj:setGranularity(granularity)
  self._state.granularity = clampGranularity(granularity)
  self:_saveSettings()
  self:refresh()
  return self
end

function obj:setDateRange(fromIso, toIso)
  self._state.from = fromIso
  self._state.to = toIso
  self:_saveSettings()
  self:refresh()
  return self
end

function obj:setRefreshSeconds(seconds)
  self._state.refreshSeconds = coercePositiveNumber(seconds, self.refreshSeconds)
  self:_saveSettings()
  self:_restartTimer()
  self:_renderWindow()
  return self
end

function obj:_applyPreset(preset)
  if preset == "today" then
    self._state.from = startOfDayUtc(0)
    self._state.to = endOfDayUtc(0)
  elseif preset == "last7d" then
    self._state.from = startOfDayUtc(6)
    self._state.to = endOfDayUtc(0)
  elseif preset == "last30d" then
    self._state.from = startOfDayUtc(29)
    self._state.to = endOfDayUtc(0)
  elseif preset == "monthToDate" then
    self._state.from = startOfMonthUtc()
    self._state.to = nowIsoUtc()
  elseif preset == "yearToDate" then
    self._state.from = startOfYearUtc()
    self._state.to = nowIsoUtc()
  end
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
  local token = self._state.token
  if not token or token == "" then
    return nil, nil, "Missing token. Use setToken(...)"
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

  if self._state.defaultKey and self._state.defaultKey ~= "" then
    table.insert(queryParts, "key=" .. hs.http.encodeForQuery(self._state.defaultKey))
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
    local viewModel = buildViewModel(self._state, self.topModelsLimit, self.seriesRowsLimit)
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
  -- flight) appear immediately instead of waiting for the in-flight
  -- request to settle.
  self:_publishToWindow()

  if self._state.inFlight then
    self.logger.df("refresh skipped: request already in flight")
    return
  end

  local url, headers, preflightErr = self:_buildUrlAndHeaders()
  if preflightErr then
    self.logger.ef("refresh preflight failed: %s", preflightErr)
    self._state.lastError = preflightErr
    self._state.lastStatus = nil
    self:_setMenubarStatus(self._state.lastError, true)
    self:_publishToWindow()
    return
  end

  self._state.requestSeq = (self._state.requestSeq or 0) + 1
  local requestSeq = self._state.requestSeq
  local startedAt = hs.timer.secondsSinceEpoch()

  self._state.inFlight = true
  self:_setMenubarStatus("Loading...", false)
  self:_publishToWindow()

  if self._state.timeoutTimer then
    self._state.timeoutTimer:stop()
    self._state.timeoutTimer = nil
  end

  self.logger.df("refresh start #%d method=GET url=%s headers=%s", requestSeq, url, formatHeadersForLog(headers))

  self._state.timeoutTimer = hs.timer.doAfter(self.timeoutSeconds, function()
    if self._state.inFlight and self._state.requestSeq == requestSeq then
      local elapsed = hs.timer.secondsSinceEpoch() - startedAt
      self.logger.ef("refresh timeout #%d after %.3fs (limit=%ds)", requestSeq, elapsed, self.timeoutSeconds)
      self._state.inFlight = false
      self._state.lastStatus = nil
      self._state.lastRefreshAt = os.time()
      self._state.lastError = "Request timed out after " .. tostring(self.timeoutSeconds) .. "s"
      self._state.timeoutTimer = nil
      self:_setMenubarStatus(self._state.lastError, true)
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
    self._state.lastStatus = status
    self._state.lastRefreshAt = os.time()

    local elapsed = hs.timer.secondsSinceEpoch() - startedAt
    local bodyLen = (type(body) == "string") and #body or 0
    self.logger.df("refresh response #%d status=%s elapsed=%.3fs bytes=%d responseHeaders=%s", requestSeq, tostring(status), elapsed, bodyLen, formatHeadersForLog(responseHeaders))

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
      self._state.lastError = msg
      self.logger.ef("refresh failed #%d: %s", requestSeq, msg)
      self:_setMenubarStatus(msg, true)
      self:_publishToWindow()
      return
    end

    local data, decodeErr = parseJson(body)
    if not data then
      self._state.lastError = decodeErr
      self.logger.ef("refresh parse error #%d: %s body=%s", requestSeq, tostring(decodeErr), tostring(body):sub(1, 200))
      self:_setMenubarStatus(self._state.lastError, true)
      self:_publishToWindow()
      return
    end

    self._state.lastData = data
    self._state.lastError = nil

    if data.from then self._state.from = tostring(data.from) end
    if data.to then self._state.to = tostring(data.to) end
    if data.granularity then self._state.granularity = clampGranularity(data.granularity) end
    if type(data.keys) == "table" and #data.keys > 0 then
      self._state.defaultKey = tostring(data.keys[1])
    end

    self:_saveSettings()
    self:_setMenubarStatus("OK", false)
    self:_publishToWindow()
  end)
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
    self._state.defaultKey = params.key and params.key ~= "" and params.key or nil
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

function obj:_openWindow()
  if self._state.window then
    -- deleteOnClose(false) means the X button only hides the webview, so
    -- the reference is still valid — but show() is required to make it
    -- visible again. Use hs.window:focus() (not webview:bringToFront(true))
    -- to make it key, because the latter bumps the window level above
    -- normal app windows and the dashboard then floats over other apps'
    -- windows persistently.
    self._state.window:show()
    local win = self._state.window:hswindow()
    if win then win:focus() end
    self:_publishToWindow()
    return
  end

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

  -- Fallback path: older Hammerspoon builds without messageHandlers
  -- still drop back to URL hijacking from JS.
  w:navigationCallback(function(_, _, navURL)
    local params = self:_parseActionUrl(navURL)
    if params then
      self:_handleAction(params)
      return false
    end
    return true
  end)

  w:html(htmlTemplate())
  w:show()

  self._state.window = w
  self:_publishToWindow()

  -- Make the dashboard the key window via hs.window:focus(), not
  -- webview:bringToFront(true). bringToFront(true) bumps the window
  -- level above NSNormalWindowLevel, which makes the dashboard float
  -- above other apps' windows persistently — dragging an underlying
  -- window's title bar won't bring it above the dashboard. focus()
  -- routes through normal app activation and leaves the level alone.
  -- The 0.08s deferral catches the case where show() hasn't completed
  -- WebKit's initial layout by the time we ask for focus.
  hs.timer.doAfter(0.08, function()
    if not self._state.window then return end
    local win = self._state.window:hswindow()
    if win then win:focus() end
  end)

  hs.timer.doAfter(0, function() self:refresh() end)
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
  local menu = {
    { title = "Open Usage Dashboard", fn = function() self:_openWindow() end },
    { title = "Refresh now", fn = function() self:refresh() end },
    { title = "-" },
    { title = "Set token...", fn = function()
      local btn, text = hs.dialog.textPrompt("Bearer token", "Enter bearer token:", self._state.token or "", "Save", "Cancel")
      if btn == "Save" then self:setToken(text); self:refresh() end
    end },
    { title = "Set default key...", fn = function()
      local btn, text = hs.dialog.textPrompt("Default key", "Enter key UUID (optional):", self._state.defaultKey or "", "Save", "Cancel")
      if btn == "Save" then
        if text == "" then text = nil end
        self:setDefaultKey(text)
        self:refresh()
      end
    end },
    { title = "Set interval (seconds)...", fn = function()
      local btn, text = hs.dialog.textPrompt("Refresh interval", "Seconds:", tostring(self._state.refreshSeconds), "Save", "Cancel")
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
