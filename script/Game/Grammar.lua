-- Grammar -------------------------------------------------------------------
-- Reader for the legacy Limit Theory grammar tables (res/grammar/*.txt).
--
-- All files share the format: `weight|choice1|choice2|...` -- each line is a
-- weighted pick among the choices on it. A choice is space-separated parts;
-- a part is either a literal or `~table`, where `~table` expands recursively
-- to a random weighted entry from the named grammar table. Tables are
-- cached on first load; the RNG comes from the caller.
--
-- Nothing in the game loads these tables today (the name generator that used
-- them lives in Game/NameGen); the NPC-name work (docs/npcwork.md) is the
-- first consumer.

local ffi          = require('ffi')
local Resource     = require('ffi.Resource')
local ResourceType = require('ffi.ResourceType')

local Grammar = {}
Grammar.tables = {}

-- Weighted pick among { { w=, c= }, ... } entries -- returns the raw choice.
local function sample (t, rng)
  local total = 0
  for i = 1, #t do total = total + t[i].w end
  local pick = rng:getUniform() * total
  for i = 1, #t do
    pick = pick - t[i].w
    if pick <= 0 then return t[i].c end
  end
  return t[#t].c
end

-- "weight|choice1|choice2|..." -> { { w=weight, c=choice }, ... } (empty
-- choices dropped).
local function parseLine (line)
  local parts = {}
  for v in string.gmatch(line, '([^|]+)') do
    parts[#parts + 1] = (v:gsub('^%s+', ''):gsub('%s+$', ''))
  end
  local out = {}
  local w = tonumber(parts[1]) or 1
  for i = 2, #parts do
    if parts[i] ~= '' then out[#out + 1] = { w = w, c = parts[i] } end
  end
  return out
end

-- Load + parse the grammar table `name` (res/grammar/<name>.txt).
function Grammar.get (name)
  local t = Grammar.tables[name]
  if t then return t end
  local data = ffi.string(Resource.LoadCstr(ResourceType.Other, 'grammar/' .. name .. '.txt'))
  local lines = {}
  for line in string.gmatch(data, '[^\n]+') do
    local s = line:gsub('^%s+', ''):gsub('%s+$', '')
    if s ~= '' and s:sub(1, 1) ~= '#' then lines[#lines + 1] = s end
  end
  t = {}
  for i = 1, #lines do
    for _, e in ipairs(parseLine(lines[i])) do t[#t + 1] = e end
  end
  Grammar.tables[name] = t
  return t
end

-- Pick a random entry from a loaded table -- returns the raw choice string.
function Grammar.pick (t, rng)
  return sample(t, rng)
end

-- Pick a random entry and expand `~ref` parts recursively, returning a
-- printable string.
function Grammar.generate (t, rng)
  local c = sample(t, rng)
  local out = {}
  for part in string.gmatch(c, '%S+') do
    local ref = part:match('^~(.+)$')
    if ref then
      insert(out, Grammar.generate(Grammar.get(ref), rng))
    else
      insert(out, part)
    end
  end
  return table.concat(out, ' ')
end

return Grammar
