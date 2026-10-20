--[[ NameGen -- one place that makes names, and knows what KIND of thing is
  being named.

  WHY THIS EXISTS
  ==============
  The game already had a name generator -- System.lua's genName, a
  consonant/vowel syllable generator -- but it was a LOCAL function inside
  System.lua, so nothing else could use it. Now that sectors, regions,
  jumpgates, stations and outposts all need names, and they need names that
  are DISTINGUISHABLE from each other (a sector name and a station name
  should not look like the same kind of word), the generator has to be
  shared and category-aware.

  The syllable tables are copied VERBATIM from System.lua's genName, so the
  names this produces for existing things (planets, stations, moons) are
  unchanged: same distributions, same 2-5 syllable range, same capitalisation.
  Changing them would change every generated world.

  CATEGORY-AWARE NAMING
  ====================
  Each category has a shape:

    sector      "The Vexing Reach"      -- a definite noun phrase
    region      "Shattered Belt"         -- an adjective + noun, or a bare noun
    planet      "Tannin"                 -- bare syllable word (unchanged)
    station     "Karra Station"          -- word + category noun
    outpost     "Waypost 7"              -- word + category noun + number
    jumpgate    "Gate of Karr"           -- category noun + "of" + word
    field       "The Cinder Drift"       -- definite noun phrase

  The CATEGORY NOUNS are what make the name read as its kind at a glance,
  which matters when the HUD shows a region name and a station name close
  together.
]]

local NameGen = {}

-- The syllable tables. VERBATIM from System.lua's genName -- see the header.
--
-- These are written out as plain weighted lists rather than using the
-- Distribution helper: Distribution is built with the `class` helper, which only
-- exists once env.env has run, so requiring it from a Game module loads it
-- too early and fails. Keeping the tables local avoids that ordering trap
-- entirely, and the sampling is three lines.
--
-- The weights are IDENTICAL to the old Distribution tables, so the names this
-- produces are the same ones the old generator produced -- which is the point:
-- existing worlds must not get new names.
local cons = {
  { w = 1.5, s = 'b' }, { w = 2.8, s = 'c' }, { w = 4.3, s = 'd' },
  { w = 2.2, s = 'f' }, { w = 2.0, s = 'g' }, { w = 6.1, s = 'h' },
  { w = 0.2, s = 'j' }, { w = 0.8, s = 'k' }, { w = 4.0, s = 'l' },
  { w = 2.4, s = 'm' }, { w = 6.7, s = 'n' }, { w = 1.9, s = 'p' },
  { w = 0.1, s = 'q' }, { w = 6.0, s = 'r' }, { w = 6.3, s = 's' },
  { w = 9.1, s = 't' }, { w = 1.0, s = 'v' }, { w = 2.4, s = 'w' },
  { w = 0.2, s = 'x' }, { w = 0.1, s = 'z' },

  { w = 0.4, s = 'll' }, { w = 0.6, s = 'ss' }, { w = 0.9, s = 'tt' },
  { w = 0.2, s = 'ff' }, { w = 0.6, s = 'rr' }, { w = 0.6, s = 'nn' },
  { w = 0.2, s = 'pp' }, { w = 0.3, s = 'cc' },
}

local vowels = {
  { w =  8.2, s = 'a' }, { w = 12.7, s = 'e' }, { w = 7.0, s = 'i' },
  { w =  7.5, s = 'o' }, { w =  2.8, s = 'u' }, { w = 2.0, s = 'y' },

  { w = 1.2, s = 'ee' }, { w = 0.7, s = 'oo' },
}

-- Pick one entry from a weighted table, using the rng's uniform.
local function sample (table_, rng)
  local total = 0
  for i = 1, #table_ do total = total + table_[i].w end
  local pick = rng:getUniform() * total
  for i = 1, #table_ do
    pick = pick - table_[i].w
    if pick <= 0 then return table_[i].s end
  end
  return table_[#table_].s
end

-- Nouns used to give a name its category. These are what make a jumpgate
-- read as a jumpgate rather than as a station.
local CATEGORY_NOUNS = {
  station  = { 'Station', 'Outpost', 'Post', 'Waystation' },
  outpost  = { 'Outpost', 'Waypost', 'Relay', 'Platform' },
  field    = { 'Drift', 'Belt', 'Shoal', 'Reef', 'Expanse', 'Sea' },
  gate     = { 'Gate', 'Wormhole', 'Threshold', 'Gate' },
  mine     = { 'Shaft', 'Claim', 'Pit', 'Work' },
}

-- Adjectives for region names. A region name should read as a PLACE, and
-- an adjective+noun does that better than a bare syllable word.
local REGION_ADJECTIVES = {
  'Shattered', 'Silent', 'Violet', 'Solar', 'Hollow', 'Weeping', 'Broken',
  'Drifting', 'Frozen', 'Burning', 'Sunken', 'Cinder', 'Quiet', 'Endless',
  'Wandering', 'Pale', 'Ashen', 'Verdant', 'Riven', 'Halting',
}

-- Nouns for region names that read as regions rather than as objects.
local REGION_NOUNS = {
  'Belt', 'Reach', 'Expanse', 'Drift', 'Void', 'Marches', 'Wilds', 'Reach',
  'Sprawl', 'Trail', 'Verge', 'Hollow', 'Reach',
}

local function insert (t, v) t[#t + 1] = v end
local join = table.concat

-- The bare syllable word. This is System.lua's genName, unchanged, so
-- existing generated names are unaffected.
local function genName (rng)
  local name = {}
  for i = 1, rng:getInt(2, 5) do
    insert(name, sample(cons, rng))
    insert(name, sample(vowels, rng))
  end
  name[1] = name[1]:upper()
  return join(name)
end

NameGen.genName = genName

-- ---------------------------------------------------------------------------
-- Category-aware names
-- ---------------------------------------------------------------------------

-- A deterministic RNG for a name, derived from a seed and a salt. The salt
-- separates the names within one scope: two stations in a sector must not
-- share a name.
local SpaceField = require('Game.SpaceField')

-- The engine's RNG global is not available when this module is loaded by an
-- OFFLINE tool -- the region validator runs under a bare luajit with no
-- engine environment -- so there is a fallback: a small deterministic
-- generator with the same interface.
--
-- In the engine the global is always present, so the names are the engine's
-- and the fallback never runs in game. The names a fallback produces are
-- still deterministic, which is all the offline checks need.
local function fallbackRng (seed)
  local state = seed % 2147483647
  if state <= 0 then state = state + 2147483646 end
  local rng = {}
  -- Park-Miller: small, well-distributed, and deterministic.
  function rng:getUniform ()
    state = (state * 16807) % 2147483647
    return (state - 1) / 2147483646
  end
  function rng:getInt (a, b)
    if not a then a, b = 1, b end
    if b < a then a, b = b, a end
    return a + math.floor(self:getUniform() * (b - a + 1))
  end
  return rng
end

local function rngFor (seed, salt)
  local derived = SpaceField.deriveSeed(seed, salt)
  if RNG then return RNG.Create(derived) end
  return fallbackRng(derived)
end

-- sector(seed) -> "The Vexing Reach"
function NameGen.sector (seed)
  local rng = rngFor(seed, 1)
  local word = genName(rng)
  local nouns = REGION_NOUNS
  local noun = nouns[rng:getInt(1, #nouns)]
  return 'The ' .. word .. ' ' .. noun
end

-- region(seed, index) -> "Shattered Belt"
--
-- The index separates the regions within one sector.
function NameGen.region (seed, index)
  local rng = rngFor(seed, 100 + (index or 1))
  -- Mostly adjective+noun, sometimes a bare word for variety.
  if rng:getUniform() < 0.7 then
    local adj = REGION_ADJECTIVES[rng:getInt(1, #REGION_ADJECTIVES)]
    local nouns = REGION_NOUNS
    local noun = nouns[rng:getInt(1, #nouns)]
    return adj .. ' ' .. noun
  end
  return genName(rng)
end

-- station(seed, index) -> "Karra Station"
function NameGen.station (seed, index)
  local rng = rngFor(seed, 200 + (index or 1))
  local word = genName(rng)
  local nouns = CATEGORY_NOUNS.station
  return word .. ' ' .. nouns[rng:getInt(1, #nouns)]
end

-- outpost(seed, index) -> "Waypost 7"
function NameGen.outpost (seed, index)
  local rng = rngFor(seed, 300 + (index or 1))
  local word = genName(rng)
  local nouns = CATEGORY_NOUNS.outpost
  return word .. ' ' .. nouns[rng:getInt(1, #nouns)] .. ' ' .. rng:getInt(1, 99)
end

-- field(seed, index) -> "The Cinder Drift"
function NameGen.field (seed, index)
  local rng = rngFor(seed, 400 + (index or 1))
  local word = genName(rng)
  local nouns = CATEGORY_NOUNS.field
  return 'The ' .. word .. ' ' .. nouns[rng:getInt(1, #nouns)]
end

-- jumpgate(seed, index) -> "Gate of Karr"
function NameGen.jumpgate (seed, index)
  local rng = rngFor(seed, 500 + (index or 1))
  local word = genName(rng)
  local nouns = CATEGORY_NOUNS.gate
  return nouns[rng:getInt(1, #nouns)] .. ' of ' .. word
end

-- mine(seed, index) -> "Shaft 12"
function NameGen.mine (seed, index)
  local rng = rngFor(seed, 600 + (index or 1))
  local word = genName(rng)
  local nouns = CATEGORY_NOUNS.mine
  return word .. ' ' .. nouns[rng:getInt(1, #nouns)] .. ' ' .. rng:getInt(1, 99)
end

return NameGen
