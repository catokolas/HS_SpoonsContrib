#!/usr/bin/env lua
-- tools/build-manifest.lua
--
-- Aggregate every <Name>.spoon/spoon-manifest.json (and any
-- overrides/upstream/<Name>.spoon-manifest.json) into the top-level
-- spoons.json that SpoonsManager.app fetches.
--
-- Usage (run from the repo root):
--   lua tools/build-manifest.lua            # write spoons.json
--   lua tools/build-manifest.lua --check    # exit 1 if spoons.json is stale

local script_dir = (arg[0]:match("(.*/)") or "./")
package.path = script_dir .. "lib/?.lua;" .. package.path
local json = require("json")

local CHECK_MODE = false
for _, a in ipairs(arg) do
  if a == "--check" then CHECK_MODE = true end
end

-- ------------------------------------------------------------ file utils

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

-- List directory entries (one per line). Uses POSIX `ls` — present on
-- both macOS and the GitHub Actions Ubuntu runners we target.
local function list_dir(path)
  local out = {}
  local p = io.popen('ls -1 "' .. path .. '" 2>/dev/null')
  if not p then return out end
  for line in p:lines() do out[#out+1] = line end
  p:close()
  return out
end

local function repo_root()
  -- Must be invoked from the repo root (documented in usage at top).
  return "."
end

-- ------------------------------------------------------------ collect

local ROOT = repo_root()

local function read_manifest(path)
  local ok, m = pcall(function() return json.decode(json.read_file(path)) end)
  if not ok then
    io.stderr:write(string.format("FAIL %s: %s\n", path, tostring(m)))
    os.exit(2)
  end
  return m
end

local spoons = json.array({})
for _, entry in ipairs(list_dir(ROOT)) do
  if entry:match("%.spoon$") then
    local mpath = ROOT .. "/" .. entry .. "/spoon-manifest.json"
    if exists(mpath) then
      spoons[#spoons + 1] = read_manifest(mpath)
    end
  end
end

table.sort(spoons, function(a, b) return (a.name or "") < (b.name or "") end)

local overrides = json.object({})
local overrides_dir = ROOT .. "/overrides/upstream"
for _, entry in ipairs(list_dir(overrides_dir)) do
  if entry:match("%.spoon%-manifest%.json$")
     or entry:match("%-manifest%.json$") then
    local m = read_manifest(overrides_dir .. "/" .. entry)
    if m.name then overrides[m.name] = m end
  end
end

-- ------------------------------------------------------------ assemble

local function git(cmd)
  local p = io.popen("git -C " .. ROOT .. " " .. cmd .. " 2>/dev/null")
  if not p then return "" end
  local s = p:read("*l") or ""
  p:close()
  return s
end

local doc = json.object({
  schemaVersion = 1,
  repo          = "catokolas/HS_SpoonsContrib",
  commit        = git("rev-parse HEAD"),
  generatedAt   = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  spoons        = spoons,
  overrides     = overrides,
})

local out = json.encode(doc)
local target = ROOT .. "/spoons.json"

if CHECK_MODE then
  local current = exists(target) and json.read_file(target) or ""
  -- Strip volatile fields (commit, generatedAt) from both sides before
  -- comparing — those legitimately differ on every build and we don't
  -- want CI to flap because of them.
  local function strip(s)
    return (s:gsub('"commit":%s*"[^"]*"', '"commit":""')
              :gsub('"generatedAt":%s*"[^"]*"', '"generatedAt":""'))
  end
  if strip(current) ~= strip(out) then
    io.stderr:write("spoons.json is out of date — run `lua tools/build-manifest.lua`\n")
    -- Helpful diff so CI logs show what's stale.
    local tmp = os.tmpname()
    json.write_file(tmp, out)
    os.execute("diff -u " .. target .. " " .. tmp .. " >&2 || true")
    os.remove(tmp)
    os.exit(1)
  end
  io.stderr:write("spoons.json is up to date.\n")
  os.exit(0)
end

json.write_file(target, out)
io.stderr:write(string.format(
  "wrote %s (%d Spoons, %d upstream overrides)\n",
  target, #spoons, (function() local n = 0; for _ in pairs(overrides) do n = n + 1 end; return n end)()))
