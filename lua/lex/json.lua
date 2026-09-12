-- lex.json: JSON that keeps the order of keys and writes the file back the
-- way it was.
--
-- `vim.json` is the right tool for the store: fast, and a record's key order
-- is nobody's business. It is the wrong tool for a settings file a person
-- keeps by hand: `vim.json.encode` puts everything on one line in whatever
-- order the hash table has, so one `:LexInstallHook` would turn a 300-line
-- `~/.claude/settings.json` into a single unreadable line. This module reads
-- objects into ordered pairs and writes them back two-space indented, one
-- item per line, which is the shape Claude Code itself writes. An install
-- then changes exactly the lines it adds.
--
-- Objects are `lex.json.Object` (a list of {key, value} pairs with get/set),
-- arrays are plain lists tagged with the `Array` metatable so an empty array
-- stays `[]`, `null` is `vim.NIL`.

local M = {}

---@class lex.json.Object
---@field pairs { [1]: string, [2]: any }[]
local Object = {}
Object.__index = Object
M.Object = Object
M.Array = {}

--- A new, empty object.
---@return lex.json.Object
function M.object()
  return setmetatable({ pairs = {} }, Object)
end

--- A new array; `[]` when empty.
---@param items? any[]
---@return any[]
function M.array(items)
  return setmetatable(items or {}, M.Array)
end

function Object:get(key)
  for _, kv in ipairs(self.pairs) do
    if kv[1] == key then
      return kv[2]
    end
  end
  return nil
end

--- Set a key. A new key goes last; an existing one keeps its place.
function Object:set(key, value)
  for _, kv in ipairs(self.pairs) do
    if kv[1] == key then
      kv[2] = value
      return
    end
  end
  self.pairs[#self.pairs + 1] = { key, value }
end

function M.is_object(v)
  return getmetatable(v) == Object
end

-- ── decode ─────────────────────────────────────────────────────────────────

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function utf8(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40, 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

--- Decode a JSON text. Raises on a syntax error, with the byte position.
---@param text string
---@return any
function M.decode(text)
  local pos = 1
  local value

  local function err(msg)
    error(("json: %s at byte %d"):format(msg, pos), 0)
  end

  local function skip()
    pos = text:find("[^ \t\r\n]", pos) or #text + 1
  end

  local function str()
    local out, i = {}, pos + 1
    while true do
      local c = text:sub(i, i)
      if c == "" then
        err("unterminated string")
      elseif c == '"' then
        pos = i + 1
        return table.concat(out)
      elseif c == "\\" then
        local e = text:sub(i + 1, i + 1)
        if e == "u" then
          local hex = text:sub(i + 2, i + 5)
          local cp = tonumber(hex, 16)
          if not cp or #hex < 4 then
            err("bad \\u escape")
          end
          i = i + 6
          if cp >= 0xD800 and cp <= 0xDBFF and text:sub(i, i + 1) == "\\u" then
            local lo = tonumber(text:sub(i + 2, i + 5), 16)
            if lo and lo >= 0xDC00 and lo <= 0xDFFF then
              cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
              i = i + 6
            end
          end
          out[#out + 1] = utf8(cp)
        elseif ESCAPES[e] then
          out[#out + 1] = ESCAPES[e]
          i = i + 2
        else
          err("bad escape")
        end
      else
        local j = text:find('["\\]', i) or #text + 1
        out[#out + 1] = text:sub(i, j - 1)
        i = j
      end
    end
  end

  local function num()
    local s, e = text:find("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not s then
      err("bad number")
    end
    pos = e + 1
    return tonumber(text:sub(s, e)) or err("bad number")
  end

  local function arr()
    local out = M.array()
    pos = pos + 1
    skip()
    if text:sub(pos, pos) == "]" then
      pos = pos + 1
      return out
    end
    while true do
      out[#out + 1] = value()
      skip()
      local c = text:sub(pos, pos)
      pos = pos + 1
      if c == "]" then
        return out
      elseif c ~= "," then
        err("expected , or ]")
      end
      skip()
    end
  end

  local function obj()
    local out = M.object()
    pos = pos + 1
    skip()
    if text:sub(pos, pos) == "}" then
      pos = pos + 1
      return out
    end
    while true do
      if text:sub(pos, pos) ~= '"' then
        err("expected a key")
      end
      local k = str()
      skip()
      if text:sub(pos, pos) ~= ":" then
        err("expected :")
      end
      pos = pos + 1
      skip()
      out.pairs[#out.pairs + 1] = { k, value() }
      skip()
      local c = text:sub(pos, pos)
      pos = pos + 1
      if c == "}" then
        return out
      elseif c ~= "," then
        err("expected , or }")
      end
      skip()
    end
  end

  value = function()
    skip()
    local c = text:sub(pos, pos)
    if c == "{" then
      return obj()
    elseif c == "[" then
      return arr()
    elseif c == '"' then
      return str()
    elseif c == "t" and text:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif c == "f" and text:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif c == "n" and text:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return vim.NIL
    elseif c == "-" or c:match("%d") then
      return num()
    end
    err("unexpected character")
  end

  local v = value()
  skip()
  if pos <= #text then
    err("trailing characters")
  end
  return v
end

-- ── encode ─────────────────────────────────────────────────────────────────

local OUT = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function quote(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return OUT[c] or ("\\u%04x"):format(c:byte())
  end) .. '"'
end

local function is_array(v)
  if getmetatable(v) == M.Array then
    return true
  end
  return getmetatable(v) == nil and (#v > 0 or next(v) == nil)
end

--- Encode, two-space indented, one item per line, `[]` and `{}` for empties.
---@param v any
---@param indent? string current indentation, for recursion
---@return string
function M.encode(v, indent)
  indent = indent or ""
  local t = type(v)
  if v == vim.NIL or v == nil then
    return "null"
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "number" then
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
      return ("%d"):format(v)
    end
    return ("%.17g"):format(v)
  elseif t == "string" then
    return quote(v)
  elseif t ~= "table" then
    error("json: cannot encode a " .. t, 0)
  end
  local inner = indent .. "  "
  local items = {}
  if M.is_object(v) then
    if #v.pairs == 0 then
      return "{}"
    end
    for _, kv in ipairs(v.pairs) do
      items[#items + 1] = inner .. quote(kv[1]) .. ": " .. M.encode(kv[2], inner)
    end
    return "{\n" .. table.concat(items, ",\n") .. "\n" .. indent .. "}"
  elseif is_array(v) then
    if #v == 0 then
      return "[]"
    end
    for _, item in ipairs(v) do
      items[#items + 1] = inner .. M.encode(item, inner)
    end
    return "[\n" .. table.concat(items, ",\n") .. "\n" .. indent .. "]"
  end
  -- A plain Lua table with string keys: sorted, so the output is stable.
  local keys = {}
  for k in pairs(v) do
    keys[#keys + 1] = tostring(k)
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    items[#items + 1] = inner .. quote(k) .. ": " .. M.encode(v[k], inner)
  end
  return "{\n" .. table.concat(items, ",\n") .. "\n" .. indent .. "}"
end

return M
