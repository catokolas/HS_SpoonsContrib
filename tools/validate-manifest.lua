#!/usr/bin/env lua
-- tools/validate-manifest.lua
--
-- For every <Name>.spoon/spoon-manifest.json, load the sibling
-- <Name>.spoon/init.lua in a sandbox that stubs `hs.*` enough for the
-- file's top-level variable assignments to execute, then assert every
-- manifest default matches the actual obj.<key> value. Also asserts
-- manifest name / version match obj.name / obj.version.
--
-- Override manifests under overrides/upstream/ are NOT validated (we
-- don't have the upstream Spoon source locally during CI).
--
-- Usage (from the repo root):
--   lua tools/validate-manifest.lua

local script_dir = (arg[0]:match("(.*/)") or "./")
package.path = script_dir .. "lib/?.lua;" .. package.path
local json = require("json")

-- ----------------------------------------------------------------- utils

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

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

-- Deep equality. Treats Lua tables structurally; nil == json.null.
local function deep_equal(a, b)
  if a == json.null then a = nil end
  if b == json.null then b = nil end
  if a == nil and b == nil then return true end
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  -- Both tables. Compare key sets and recursively compare values.
  local seen = {}
  for k, v in pairs(a) do
    seen[k] = true
    if not deep_equal(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if not seen[k] then return false end
  end
  return true
end

local function format_value(v)
  if v == nil       then return "nil"     end
  if v == json.null then return "null"    end
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) == "table"  then
    local parts = {}
    for k, vv in pairs(v) do
      parts[#parts+1] = tostring(k) .. "=" .. format_value(vv)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return tostring(v)
end

-- ---------------------------------------------------------------- sandbox

-- A permissive recursive stub: any access returns a callable sub-stub.
-- This is sufficient for every Spoon's top-level variable assignments —
-- `hs.logger.new(name)`, `hs.timer.secondsSinceEpoch` (reference only,
-- not invoked at load time), etc. Method bodies are only DEFINED at
-- top level, not run, so anything they touch never executes here.
local function make_stub()
  local t = {}
  setmetatable(t, {
    __index = function(self, k)
      local sub = make_stub()
      rawset(self, k, sub)
      return sub
    end,
    __call = function() return make_stub() end,
  })
  return t
end

local function build_env()
  -- Some Spoons probe optional native modules via pcall(require, ...)
  -- at module-load time; let require fall through to the real package
  -- system inside the pcall, where the require error gets swallowed.
  local env = {
    hs       = make_stub(),
    pcall    = pcall,
    require  = require,
    string   = string,  table   = table,  math   = math,
    pairs    = pairs,   ipairs  = ipairs, type   = type,
    tostring = tostring, tonumber = tonumber,
    select   = select,  error   = error, assert = assert,
    setmetatable = setmetatable, getmetatable = getmetatable,
    rawequal = rawequal, rawget = rawget, rawset = rawset,
    next     = next,    print   = print,  os    = os, io = io,
  }
  env._G = env
  return env
end

local function load_spoon(init_path)
  local fn, err = loadfile(init_path, "t", build_env())
  if not fn then error("loadfile " .. init_path .. ": " .. err) end
  local ok, obj = pcall(fn)
  if not ok then error("running " .. init_path .. ": " .. tostring(obj)) end
  if type(obj) ~= "table" then
    error(init_path .. ": expected init.lua to return a table, got " .. type(obj))
  end
  return obj
end

-- ---------------------------------------------------- manifest walking

local errors = {}

local function fail(spoon, path, msg)
  errors[#errors+1] = string.format("[%s] %s: %s", spoon, path, msg)
end

local function walk_fields(spoon, fields, current_obj, prefix)
  for _, field in ipairs(fields) do
    local key      = field.key
    local fpath    = prefix == "" and key or (prefix .. "." .. key)
    local ftype    = field.type

    if ftype == "object" then
      local sub = current_obj and current_obj[key]
      if type(sub) ~= "table" then
        fail(spoon, fpath, "expected nested table on obj, got " .. type(sub))
      else
        walk_fields(spoon, field.fields or {}, sub, fpath)
      end
    else
      local actual   = current_obj and current_obj[key]
      local expected = field.default
      if not deep_equal(actual, expected) then
        fail(spoon, fpath, string.format(
          "manifest default %s does not match init.lua value %s",
          format_value(expected), format_value(actual)))
      end
    end
  end
end

-- ---------------------------------------------------------------- run

local ROOT = repo_root()

local checked = 0
for _, entry in ipairs(list_dir(ROOT)) do
  if entry:match("%.spoon$") then
    local mpath = ROOT .. "/" .. entry .. "/spoon-manifest.json"
    local ipath = ROOT .. "/" .. entry .. "/init.lua"
    if exists(mpath) then
      checked = checked + 1
      local manifest = json.decode(json.read_file(mpath))
      local obj      = load_spoon(ipath)
      local spoon    = manifest.name or entry

      if obj.name ~= manifest.name then
        fail(spoon, "name", string.format(
          "manifest %q != init.lua obj.name %q",
          tostring(manifest.name), tostring(obj.name)))
      end
      if obj.version ~= manifest.version then
        fail(spoon, "version", string.format(
          "manifest %q != init.lua obj.version %q",
          tostring(manifest.version), tostring(obj.version)))
      end

      walk_fields(spoon, manifest.config or {}, obj, "")

      -- activateHotkey shape check. Optional field — Spoons without
      -- a meaningful on/off (MoveSpaces, SpotifyPlayPause) omit it.
      -- When present it must be a `{ mods = {strings...}, key = string }`
      -- table; the chord must not also appear in `hotkeys[]` for the
      -- same Spoon (avoid the snippet binding the same chord twice).
      local ah = manifest.activateHotkey
      if ah ~= nil then
        if type(ah) ~= "table" then
          fail(spoon, "activateHotkey",
            "expected object, got " .. type(ah))
        else
          if type(ah.mods) ~= "table" then
            fail(spoon, "activateHotkey.mods",
              "expected array of strings, got " .. type(ah.mods))
          else
            for i, m in ipairs(ah.mods) do
              if type(m) ~= "string" then
                fail(spoon, "activateHotkey.mods["..i.."]",
                  "expected string, got " .. type(m))
              end
            end
          end
          if type(ah.key) ~= "string" then
            fail(spoon, "activateHotkey.key",
              "expected string, got " .. type(ah.key))
          end
          -- Collision check against hotkeys[].default.
          for _, h in ipairs(manifest.hotkeys or {}) do
            local d = h.default
            if d and type(d) == "table" and d.key == ah.key
               and deep_equal(d.mods, ah.mods) then
              fail(spoon, "activateHotkey",
                "chord collides with hotkeys[]."..tostring(h.action))
            end
          end
        end
      end
    end
  end
end

if #errors > 0 then
  io.stderr:write(string.format(
    "validate-manifest: %d error(s) across %d spoon(s):\n", #errors, checked))
  for _, e in ipairs(errors) do io.stderr:write("  " .. e .. "\n") end
  os.exit(1)
end

io.stderr:write(string.format(
  "validate-manifest: OK (%d spoon(s) checked)\n", checked))
