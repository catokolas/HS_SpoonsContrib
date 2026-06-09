-- tools/lib/json.lua
-- Minimal JSON encoder + decoder for the SpoonsContrib build tools.
-- Pure Lua 5.3, no dependencies. Designed for round-trip stability:
-- arrays decoded from JSON carry a metatable tag so the encoder reproduces
-- them as arrays (rather than objects). Encoder always sorts object keys
-- for stable diffs.

local M = {}

local ARRAY_MT = { __jsontype = "array"  }
local OBJECT_MT = { __jsontype = "object" }

function M.array(t)  return setmetatable(t or {}, ARRAY_MT)  end
function M.object(t) return setmetatable(t or {}, OBJECT_MT) end

local function is_array(t)
  local mt = getmetatable(t)
  if mt == ARRAY_MT or (mt and mt.__jsontype == "array")  then return true  end
  if mt == OBJECT_MT or (mt and mt.__jsontype == "object") then return false end
  -- Heuristic for untagged tables: dense 1..n integer keys → array;
  -- anything else → object. Empty tables default to object.
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  if n == 0 then return false end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end

-- ---------------------------------------------------------------- ENCODE

local encode_value

local function encode_string(s)
  local function esc(c)
    local b = string.byte(c)
    if c == '"'  then return '\\"'  end
    if c == "\\" then return "\\\\" end
    if c == "\n" then return "\\n"  end
    if c == "\r" then return "\\r"  end
    if c == "\t" then return "\\t"  end
    if c == "\b" then return "\\b"  end
    if c == "\f" then return "\\f"  end
    if b < 0x20 then return string.format("\\u%04x", b) end
    return c
  end
  return '"' .. s:gsub("[%c\\\"]", esc) .. '"'
end

local function encode_number(n)
  if n ~= n then         error("cannot encode NaN")                 end
  if n == math.huge or n == -math.huge then error("cannot encode infinity") end
  if math.type(n) == "integer" then return string.format("%d", n)   end
  -- Float: emit the shortest decimal representation that round-trips
  -- back to the same double. Loops from precision 1..17 and picks the
  -- first that survives a tonumber round-trip. Keeps human-typed
  -- values like 0.1 short (vs `%.17g` which gives "0.10000000000000001").
  for p = 1, 17 do
    local s = string.format("%." .. p .. "g", n)
    if tonumber(s) == n then return s end
  end
  return string.format("%.17g", n)
end

local function encode_indent(d)
  return string.rep("  ", d)
end

local function encode_array(t, depth)
  if #t == 0 then return "[]" end
  local parts = { "[\n" }
  for i, v in ipairs(t) do
    parts[#parts+1] = encode_indent(depth + 1)
    parts[#parts+1] = encode_value(v, depth + 1)
    if i < #t then parts[#parts+1] = ",\n" else parts[#parts+1] = "\n" end
  end
  parts[#parts+1] = encode_indent(depth) .. "]"
  return table.concat(parts)
end

local function encode_object(t, depth)
  local keys = {}
  for k in pairs(t) do
    if type(k) ~= "string" then
      error("object key must be string, got " .. type(k))
    end
    keys[#keys+1] = k
  end
  if #keys == 0 then return "{}" end
  table.sort(keys)
  local parts = { "{\n" }
  for i, k in ipairs(keys) do
    parts[#parts+1] = encode_indent(depth + 1)
    parts[#parts+1] = encode_string(k)
    parts[#parts+1] = ": "
    parts[#parts+1] = encode_value(t[k], depth + 1)
    if i < #keys then parts[#parts+1] = ",\n" else parts[#parts+1] = "\n" end
  end
  parts[#parts+1] = encode_indent(depth) .. "}"
  return table.concat(parts)
end

encode_value = function(v, depth)
  local tv = type(v)
  if v == M.null      then return "null"                end
  if tv == "nil"      then return "null"                end
  if tv == "boolean"  then return v and "true" or "false" end
  if tv == "number"   then return encode_number(v)      end
  if tv == "string"   then return encode_string(v)      end
  if tv == "table" then
    if is_array(v) then return encode_array(v,  depth) end
    return                       encode_object(v, depth)
  end
  error("cannot encode value of type " .. tv)
end

function M.encode(v)
  return encode_value(v, 0) .. "\n"
end

M.null = setmetatable({}, { __tostring = function() return "null" end })

-- ---------------------------------------------------------------- DECODE

local decode_value

local function skip_ws(s, i)
  while i <= #s do
    local c = s:sub(i, i)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      i = i + 1
    elseif c == "/" and s:sub(i + 1, i + 1) == "/" then
      -- line comment (non-standard, but tolerated for hand-edited files)
      while i <= #s and s:sub(i, i) ~= "\n" do i = i + 1 end
    else
      break
    end
  end
  return i
end

local function decode_string(s, i)
  assert(s:sub(i, i) == '"', "expected string at " .. i)
  i = i + 1
  local parts = {}
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(parts), i + 1
    elseif c == "\\" then
      local nxt = s:sub(i + 1, i + 1)
      if     nxt == '"'  then parts[#parts+1] = '"';  i = i + 2
      elseif nxt == "\\" then parts[#parts+1] = "\\"; i = i + 2
      elseif nxt == "/"  then parts[#parts+1] = "/";  i = i + 2
      elseif nxt == "n"  then parts[#parts+1] = "\n"; i = i + 2
      elseif nxt == "r"  then parts[#parts+1] = "\r"; i = i + 2
      elseif nxt == "t"  then parts[#parts+1] = "\t"; i = i + 2
      elseif nxt == "b"  then parts[#parts+1] = "\b"; i = i + 2
      elseif nxt == "f"  then parts[#parts+1] = "\f"; i = i + 2
      elseif nxt == "u"  then
        local hex = s:sub(i + 2, i + 5)
        if not hex:match("^%x%x%x%x$") then error("bad \\u escape at " .. i) end
        local cp = tonumber(hex, 16)
        -- UTF-8 encode (BMP only — surrogate pairs not handled)
        if cp < 0x80 then
          parts[#parts+1] = string.char(cp)
        elseif cp < 0x800 then
          parts[#parts+1] = string.char(0xC0 + (cp >> 6), 0x80 + (cp & 0x3F))
        else
          parts[#parts+1] = string.char(
            0xE0 + (cp >> 12),
            0x80 + ((cp >> 6) & 0x3F),
            0x80 + (cp & 0x3F))
        end
        i = i + 6
      else
        error("bad escape \\" .. nxt .. " at " .. i)
      end
    else
      parts[#parts+1] = c
      i = i + 1
    end
  end
  error("unterminated string starting at " .. i)
end

local function decode_number(s, i)
  local j = i
  if s:sub(j, j) == "-" then j = j + 1 end
  while j <= #s and s:sub(j, j):match("[%d%.eE%+%-]") do j = j + 1 end
  local lit = s:sub(i, j - 1)
  local n = tonumber(lit)
  if not n then error("bad number '" .. lit .. "' at " .. i) end
  -- Preserve integer vs float for round-trip stability.
  if lit:match("[%.eE]") then return n + 0.0, j end
  return math.tointeger(n) or n, j
end

local function decode_array(s, i)
  assert(s:sub(i, i) == "[", "expected [ at " .. i)
  i = i + 1
  local arr = M.array({})
  i = skip_ws(s, i)
  if s:sub(i, i) == "]" then return arr, i + 1 end
  while true do
    local v
    v, i = decode_value(s, i)
    arr[#arr + 1] = v
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "," then
      i = skip_ws(s, i + 1)
    elseif c == "]" then
      return arr, i + 1
    else
      error("expected , or ] in array at " .. i .. " (got '" .. c .. "')")
    end
  end
end

local function decode_object(s, i)
  assert(s:sub(i, i) == "{", "expected { at " .. i)
  i = i + 1
  local obj = M.object({})
  i = skip_ws(s, i)
  if s:sub(i, i) == "}" then return obj, i + 1 end
  while true do
    i = skip_ws(s, i)
    local k
    k, i = decode_string(s, i)
    i = skip_ws(s, i)
    if s:sub(i, i) ~= ":" then
      error("expected : after object key at " .. i)
    end
    i = skip_ws(s, i + 1)
    local v
    v, i = decode_value(s, i)
    obj[k] = v
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "," then
      i = i + 1
    elseif c == "}" then
      return obj, i + 1
    else
      error("expected , or } in object at " .. i .. " (got '" .. c .. "')")
    end
  end
end

decode_value = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == "{" then return decode_object(s, i) end
  if c == "[" then return decode_array(s, i)  end
  if c == '"' then return decode_string(s, i) end
  if c == "-" or c:match("%d") then return decode_number(s, i) end
  if s:sub(i, i + 3) == "true"  then return true,  i + 4 end
  if s:sub(i, i + 4) == "false" then return false, i + 5 end
  if s:sub(i, i + 3) == "null"  then return M.null, i + 4 end
  error("unexpected character '" .. c .. "' at " .. i)
end

function M.decode(s)
  local v, i = decode_value(s, 1)
  i = skip_ws(s, i)
  if i <= #s then error("trailing garbage at " .. i) end
  return v
end

-- Convenience helpers used by the tools.
function M.read_file(path)
  local f, err = io.open(path, "rb")
  if not f then error("could not open " .. path .. ": " .. tostring(err)) end
  local s = f:read("*a")
  f:close()
  return s
end

function M.write_file(path, s)
  local f, err = io.open(path, "wb")
  if not f then error("could not open " .. path .. " for writing: " .. tostring(err)) end
  f:write(s)
  f:close()
end

return M
