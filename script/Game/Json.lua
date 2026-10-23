--[[ Json -- a minimal JSON encoder and decoder, written for the save slots.

  WHY HAND-ROLLED: the engine has no JSON library exposed to Lua (LuaJIT
  ships none, and libphx speaks neither cjson nor jansson), and the save
  layer wants what JSON gives the old engine's SaveGameJSON: files a
  viewer can read, a schema that survives git diffs, and a corrupt save
  that DEGRADES ("no save") instead of crashing the boot.

  SCOPE AND ITS LIMITS, ON PURPOSE:

  * Values: tables, strings, numbers, booleans, null. That is the whole
    save schema, and assert() keeps a caller honest instead of emitting
    something silently wrong.

  * A table either has a 1..#v sequence (encoded as an array) or it does
    not (encoded as an object with the string keys it has). A mixed table
    drops the non-sequence part -- the save schema has no such table.

  * Numbers round-trip through doubles (Lua's only number). THE 64-BIT
    SEED MUST BE A HEX STRING, never a JSON number -- this is the
    seedFromHex trap from LTheory.lua again: a double holds 53 bits, and
    the low eleven bits of a seed would be rounding noise, so the same
    save would not always reload the same world.

  * The decoder's \uXXXX becomes a literal '?': save strings (slot names,
    item names) are ASCII, and LuaJIT is Lua 5.1, which has no utf8
    machinery. Anything else decodes intact.

  * Errors are VALUES, not throws: Encode errors (assert), Decode returns
    nil, message -- a corrupt hand-edited save lands in the menu as
    "unreadable", exactly where the player can see it.
]]

local Json = {}

-- ---------------------------------------------------------------------------
-- Encoding
-- ---------------------------------------------------------------------------

local escapes = {['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}

local function encodeString (s)
  return '"' .. s:gsub('[%c"\\]', function (c)
    return escapes[c] or string.format('\\u%04X', string.byte(c))
  end) .. '"'
end

local function encodeValue (v, out)
  local t = type(v)
  if t == 'table' then
    if #v > 0 then -- A sequence: an array of its 1..#v values.
      out[#out + 1] = '['
      for i = 1, #v do
        if i > 1 then out[#out + 1] = ',' end
        encodeValue(v[i], out)
      end
      out[#out + 1] = ']'
    else -- Anything else: an object over its string keys.
      out[#out + 1] = '{'
      local first = true
      for k, val in pairs(v) do
        if type(k) ~= 'string' then
          error('Json.Encode: object keys must be strings (got ' .. type(k) .. ')', 2)
        end
        if not first then out[#out + 1] = ',' end
        first = false
        out[#out + 1] = encodeString(k) .. ':'
        encodeValue(val, out)
      end
      out[#out + 1] = '}'
    end
  elseif t == 'string' then
    out[#out + 1] = encodeString(v)
  elseif t == 'boolean' then
    out[#out + 1] = v and 'true' or 'false'
  elseif t == 'number' then
    -- Whole numbers that a double holds exactly go out as integers; a
    -- float goes out as Lua prints it (which round-trips a double).
    if v == math.floor(v) and math.abs(v) < 2.0 ^ 53 then
      out[#out + 1] = string.format('%d', v)
    else
      out[#out + 1] = tostring(v)
    end
  elseif v == nil then
    out[#out + 1] = 'null'
  else
    error('Json.Encode: cannot encode a ' .. t, 2)
  end
end

function Json.Encode (value)
  local out = {}
  encodeValue(value, out)
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Decoding
-- ---------------------------------------------------------------------------

-- The decoder walks (pos, str) with small find/match steps. Every problem
-- is a `return nil, message` from the walk, so a corrupt file reads ONE
-- clean warning at the caller instead of a Lua crash mid-boot.
local Parser = {}
Parser.__index = Parser

function Parser.Create (str)
  return setmetatable({str = str, pos = 1}, Parser)
end

function Parser:skip ()
  local _, p = self.str:find('^[ \t\n\r]*', self.pos)
  self.pos = p + 1
end

function Parser:error (message)
  return nil, string.format('%s at %d', message, self.pos)
end

-- A value at the current position; returns value (nil is legal, it is
-- JSON null) or nil, message on anything the schema does not allow.
function Parser:value ()
  self:skip()
  local c = self.str:sub(self.pos, self.pos)
  if c == '{' then return self:object()
  elseif c == '[' then return self:array()
  elseif c == '"' then return self:string()
  elseif c == '-' or (c >= '0' and c <= '9') then return self:number()
  elseif c == 't' or c == 'f' or c == 'n' then return self:keyword()
  else return self:error('unexpected ' .. (c == '' and 'end of file' or "'" .. c .. "'"))
  end
end

function Parser:keyword ()
  local word = self.str:match('^%a+', self.pos)
  self.pos = self.pos + #word
  if word == 'true' then return true end
  if word == 'false' then return false end
  if word == 'null' then return nil end
  return self:error("bad literal '" .. word .. "'")
end

local function utf8Byte (hex)
  local n = tonumber(hex, 16)
  if n < 0x80 then return string.char(n) end
  if n < 0x800 then return string.char(0xC0 + n / 0x40, 0x80 + n % 0x40) end
  -- BMP only (saves are ASCII); anything wider becomes a '?'. No utf8
  -- library under LuaJIT, and no save string needs it.
  if n < 0x10000 then
    return string.char(0xE0 + n / 0x400, 0x80 + n / 0x40 % 0x40, 0x80 + n % 0x40)
  end
  return '?'
end

function Parser:string ()
  -- The opening quote is at self.pos (checked by :value()).
  local rest = self.str:sub(self.pos)
  local trimmed = 0
  local out = {}
  local i = 2
  while true do
    local c = rest:sub(i, i)
    if c == '' then return self:error('unterminated string') end
    if c == '"' then
      self.pos = self.pos + i
      return table.concat(out)
    end
    if c == '\\' then
      local e = rest:sub(i + 1, i + 1)
      if e == 'u' then
        local hex = rest:sub(i + 2, i + 5)
        if #hex < 4 or hex:match('%X') then return self:error('bad \\u escape') end
        out[#out + 1] = utf8Byte(hex)
        i = i + 6
      else
        local simple = {n = '\n', r = '\r', t = '\t', b = '\b', f = '\f', ['"'] = '"', ['\\'] = '\\', ['/'] = '/'}
        if not simple[e] then return self:error('bad escape \\' .. e) end
        out[#out + 1] = simple[e]
        i = i + 2
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
end

function Parser:number ()
  -- An optional exponent (tostring of a big double emits 1e+15).
  local lit = self.str:match('^%-?%d+[.]?%d*[eE][+-]?%d+', self.pos)
    or self.str:match('^%-?%d+[.]?%d*', self.pos)
  if not lit then return self:error('bad number') end
  self.pos = self.pos + #lit
  local n = tonumber(lit)
  if not n then return self:error("unparseable number '" .. lit .. "'") end
  return n
end

function Parser:object ()
  self.pos = self.pos + 1 -- '{'
  local t = {}
  self:skip()
  if self.str:sub(self.pos, self.pos) == '}' then
    self.pos = self.pos + 1
    return t
  end
  while true do
    self:skip()
    if self.str:sub(self.pos, self.pos) ~= '"' then return self:error('object key must be a string') end
    local k, err = self:string()
    if not k then return nil, err end
    self:skip()
    if self.str:sub(self.pos, self.pos) ~= ':' then return self:error("expected ':'") end
    self.pos = self.pos + 1
    local v, verr = self:value()
    if verr then return nil, verr end
    t[k] = v
    self:skip()
    local c = self.str:sub(self.pos, self.pos)
    if c == ',' then
      self.pos = self.pos + 1
    elseif c == '}' then
      self.pos = self.pos + 1
      return t
    else
      return self:error("expected ',' or '}'")
    end
  end
end

function Parser:array ()
  self.pos = self.pos + 1 -- '['
  local t = {}
  self:skip()
  if self.str:sub(self.pos, self.pos) == ']' then
    self.pos = self.pos + 1
    return t
  end
  while true do
    local v, err = self:value()
    if err then return nil, err end
    t[#t + 1] = v
    self:skip()
    local c = self.str:sub(self.pos, self.pos)
    if c == ',' then
      self.pos = self.pos + 1
    elseif c == ']' then
      self.pos = self.pos + 1
      return t
    else
      return self:error("expected ',' or ']'")
    end
  end
end

function Json.Decode (str)
  if type(str) ~= 'string' then return nil, 'not a string' end
  local p = Parser.Create(str)
  local v, err = p:value()
  if err then return nil, err end
  p:skip()
  if p.pos <= #p.str then return nil, 'trailing characters at ' .. p.pos end
  return v
end

return Json
