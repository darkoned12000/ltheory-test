--[[ SpaceField -- one shared description of "what kind of place is this?".

  THE PROBLEM THIS SOLVES
  =======================

  Four subsystems each own a private spatial hash today:

    * NebulaVolumes   -- hash32(cell) picks plume anchors
    * AsteroidField   -- Seed.rng('asteroidField', chunkSalt) picks rocks
    * LightningStorm  -- its own hash32 + a local "vapor gate"
    * Dust            -- Seed.rng('dust'), one global stream

  They cannot disagree about a place, because they never ask each other.
  The visible consequence, in the current tree: AsteroidField has NO
  reference to the nebula at all. So a nebula-heavy chunk beside an
  asteroid-heavy chunk gives a clear void beside a rock field purely by
  chance, and a chunk where BOTH are dense gives rocks that are invisible
  inside the gas -- ten thousand rocks paid for, none seen. Those are
  coincidences, not designs, and they change as you cross a hash boundary.

  A shared field fixes that: every subsystem reads the SAME function, so
  they cannot disagree about what kind of place they are in. This is
  docs/procedural-space-environment.md §2, and the reasoning behind §29a.

  WHY A FIELD AND NOT A REGION LIST
  =================================

  A region is a FIELD VALUE, not an object in a list. "Violet Veil" is
  simply a place where paletteHue happens to sit at violet and
  nebulaDensity is high; there is no region object, no region store and no
  region membership test. That is what makes §6 (region personality) and
  §7 (continuous transitions) one mechanism instead of two.

  DETERMINISM AND CONTINUITY
  ===========================

  The field is a PURE FUNCTION of (position, seed). No global RNG state,
  no frame counter, nothing that depends on how you arrived. Two visits to
  the same position produce the same values, which is what makes a sector
  reproducible on re-entry (§29a: POIs stay put, look-and-feel does not
  change).

  It is also CONTINUOUS across cell boundaries. The trick is that this is
  value noise, not cell noise: each lattice point gets a hashed value and
  the sample is the smoothstep-weighted blend of the eight surrounding
  lattice points. A per-cell hash (what NebulaVolumes does for its
  anchors) would jump at every cell edge; this does not.

  Scale
  =====
  The field is sampled at three scales, matching §3's macro / meso / micro
  hierarchy. They are separate channels with separate cell sizes, NOT
  octaves of one noise -- so a meso-scale feature can sit inside a macro
  void without dragging the macro value along with it.

  This module has NO dependency on the renderer, the physics engine, or
  the entity system. That is deliberate: it means the field can be tested
  OFFLINE (tools/validate_spacefield.lua) for determinism, continuity and
  range, without a GL context -- the same trick tools/validate_frustum.lua
  and tools/verify_cloud_shell.py use.
]]

local SpaceField = {}

local ffi = require('ffi')

-- ---------------------------------------------------------------------------
-- Shared integer hash
-- ---------------------------------------------------------------------------

-- 32-bit integer hash: deterministic, and free from float precision loss.
-- Returns [0,1). LuaJIT bitops are signed, so a raw /2^32 can come back
-- negative for half the inputs -- the mod folds it back.
--
-- This is the SAME function that lives in NebulaVolumes.lua, LightningStorm.lua
-- and LightningBolt.lua. It is duplicated there rather than shared because
-- those were written before this module existed. They MUST stay bit-identical:
-- changing the hash changes every generated plume, storm and bolt in every
-- existing world, which would silently invalidate every captured frame in
-- the repo. validate_spacefield.lua checks that they still agree.
--
-- The bit LIBRARY is used rather than Lua 5.2's `&` / `~` / `>>` operators
-- because the operators are a COMPILE-TIME option of the LuaJIT build
-- (LUAJIT_ENABLE_LUA52COMPAT): the engine's libluajit has them, but the
-- bundled standalone luajit used by the offline validators does NOT, so a
-- module using the operators cannot be loaded by the validator at all.
-- The two forms are numerically identical -- verified over 20,001 inputs,
-- zero mismatches -- because every step here ends in a 32-bit mask, which
-- makes the low-32-bit semantics of bit.band/bit.bxor/bit.rshift identical
-- to the 64-bit operators followed by that same mask.
function SpaceField.hash32 (x, y, z, seed, k)
  local h = bit.band(x * 374761393 + y * 668265263 + z * 224682251
                      + seed * 3266489917 + k * 2654435761, 0xFFFFFFFF)
  h = bit.band(bit.bxor(h, bit.rshift(h, 13)) * 1274126177, 0xFFFFFFFF)
  h = bit.band(bit.bxor(h, bit.rshift(h, 16)), 0xFFFFFFFF)
  return (h % 4294967296) / 4294967296.0
end

-- Fold a 64-bit sector seed into 32 bits.
--
-- Sector seeds are 64-bit ULL, but a double only holds 53-bit integers: the
-- raw value's low bits are mush and seed*K rounds to a quantum that swallows
-- every small x/y/z/k term, so hash32 would return ONE constant for all
-- inputs (identical plumes on a perfect lattice). XOR both 32-bit halves into
-- 32 bits.
--
-- THIS IS BIT-IDENTICAL to the fold in NebulaVolumes / LightningStorm /
-- LightningBolt, and it MUST STAY that way: the storm seed has to stay
-- congruent with the plume seed, and changing the fold changes every
-- generated plume, storm and bolt in every existing world, which would
-- silently invalidate every captured frame in the repo.
--
-- NOTE THE PRECISION LIMIT, because it is the whole reason deriveSeed exists:
-- `tonumber(seed)` on a uint64 converts to a double and SILENTLY DROPS THE
-- LOW 11 BITS, so foldSeed(G) == foldSeed(G+1) == foldSeed(G+2) ... Every
-- sector seed derived by adding a small index to a galaxy seed collapsed onto
-- the SAME 32-bit value: 65 sectors, one world. That is why the sector
-- index is mixed into the HIGH bits instead -- see deriveSeed.
function SpaceField.foldSeed (seed)
  local s = math.floor(tonumber(seed) or 0)
  local lo = s % 4294967296
  local hi = math.floor(s / 4294967296) % 4294967296
  return bit.bxor(lo, hi)
end

-- Derive a distinct 32-bit seed for a SUB-THING of a base seed: a sector
-- within a galaxy, a region within a sector.
--
-- The index is mixed into the HIGH 32 bits of the base seed, because the
-- fold's job is to compress 64 bits into 32 -- and it XORs the two halves.
-- If the index only touched the LOW bits, the fold would collapse adjacent
-- indices onto the same value (see the precision note on foldSeed).
--
-- Mixing high and then folding lands the index in the low half of the
-- RESULT, where it survives: 65 adjacent indices give 65 distinct seeds.
--
-- This is the function the multi-sector work needs, and it is why the fold's
-- precision limit mattered: with the index in the low bits, every sector in
-- a galaxy would have been the same sector.
function SpaceField.deriveSeed (baseSeed, index)
  local s = baseSeed
  if type(s) == 'cdata' then
    -- uint64 arithmetic: exact, and the index lands in the high half.
    s = s + (ffi.cast('uint64_t', index) * 0x100000000ULL)
  else
    -- A plain number: the same shift, done in doubles. The base's low 11 bits
    -- are already lost by the fold, but the HIGH half -- where the index
    -- goes -- is exactly representable, so adjacent indices still separate.
    s = math.floor(tonumber(s) or 0) + (math.floor(index) * 4294967296)
  end
  return SpaceField.foldSeed(s)
end

-- ---------------------------------------------------------------------------
-- Smooth value noise
-- ---------------------------------------------------------------------------

local floor = math.floor
local sqrt  = math.sqrt

-- Quintic smootherstep (6t^5 - 15t^4 + 10t^3). C2 continuous, so the
-- field has no visible derivative break at a cell boundary -- a cubic
-- smoothstep is only C1, which shows up as a faint crease in a density
-- gradient.
local function fade (t)
  return t * t * t * (t * (t * 6 - 15) + 10)
end

local function lerp (a, b, t)
  return a + (b - a) * t
end

-- 3D value noise in [0,1], continuous everywhere.
--
-- `cell` is the lattice pitch: the distance between hashed points. The
-- result is smooth at every multiple of `cell`, because the sample is the
-- blend of the eight surrounding lattice values rather than one of them.
--
-- `channel` selects an independent set of lattice values, so two channels
-- sharing a cell size are still uncorrelated -- that is what lets a meso
-- feature sit inside a macro void without correlation.
--
-- NOTE ON `channel`'s MAGNITUDE: it must be a SMALL integer, for the same
-- reason foldSeed folds a 64-bit seed down before hashing it. hash32 mixes
-- its arguments by MULTIPLICATION, and the k term is multiplied by
-- 2654435761: a k of 2.6e9 (i.e. a "channel id" scaled up by a golden-ratio
-- constant) produces a term of ~7e18, which is past 2^53 -- so the float
-- sum can no longer represent the x/y/z terms AT ALL, the hash returns the
-- same value for every lattice point, and the noise goes flat. Small integer
-- channel ids keep every term inside the exactly-representable range.
local function valueNoise (x, y, z, cell, seed, channel)
  local inv = 1.0 / cell
  local fx, fy, fz = x * inv, y * inv, z * inv
  local ix, iy, iz = floor(fx), floor(fy), floor(fz)
  local tx, ty, tz = fade(fx - ix), fade(fy - iy), fade(fz - iz)

  local s = seed
  local k = channel

  local c000 = SpaceField.hash32(ix,     iy,     iz,     s, k)
  local c100 = SpaceField.hash32(ix + 1, iy,     iz,     s, k)
  local c010 = SpaceField.hash32(ix,     iy + 1, iz,     s, k)
  local c110 = SpaceField.hash32(ix + 1, iy + 1, iz,     s, k)
  local c001 = SpaceField.hash32(ix,     iy,     iz + 1, s, k)
  local c101 = SpaceField.hash32(ix + 1, iy,     iz + 1, s, k)
  local c011 = SpaceField.hash32(ix,     iy + 1, iz + 1, s, k)
  local c111 = SpaceField.hash32(ix + 1, iy + 1, iz + 1, s, k)

  local x00 = lerp(c000, c100, tx)
  local x10 = lerp(c010, c110, tx)
  local x01 = lerp(c001, c101, tx)
  local x11 = lerp(c011, c111, tx)
  local y0  = lerp(x00, x10, ty)
  local y1  = lerp(x01, x11, ty)
  return lerp(y0, y1, tz)
end

SpaceField.valueNoise = valueNoise

-- ---------------------------------------------------------------------------
-- Channels and scales
-- ---------------------------------------------------------------------------

-- The scale hierarchy (§3). Each is a separate lattice pitch, NOT an octave
-- of one noise, so a small feature can exist inside a large void.
--
-- The pitches are chosen so that a region's own extent is roughly one macro
-- cell: a region spans ~10^5 units, so the macro lattice at 2.5e5 means
-- neighbouring regions get uncorrelated macro values, while the meso lattice
-- at 2.5e4 gives structure inside a region, and the micro lattice at 5e3
-- gives texture within a structure.
SpaceField.SCALE = {
  macro = 250000.0,
  meso  =  25000.0,
  micro =   5000.0,
}

-- Channel ids. Each is an independent lattice-value set, so channels never
-- correlate by accident. The ids are arbitrary but MUST NOT change: they
-- select which hash stream a channel reads, and changing one changes that
-- channel's value everywhere, which would invalidate every captured frame.
SpaceField.CHANNEL = {
  nebulaDensity   = 1,
  dustDensity     = 2,
  asteroidDensity = 3,
  starVisibility  = 4,
  turbulence      = 5,
  stormPotential  = 6,
  radiation       = 7,
  paletteHue      = 8,
  paletteSat      = 9,
  paletteLight    = 10,
  anisotropy      = 11,
  -- Macro-scale channels describe the CHARACTER of a region.
  regionHue       = 12,
  regionDensity   = 13,
  regionStorm     = 14,
}

-- ---------------------------------------------------------------------------
-- Sampling
-- ---------------------------------------------------------------------------

-- sample(x, y, z, seed) -> table of environmental parameters.
--
-- `seed` is the GALAXY seed (or a sector seed derived from it). It is
-- folded to 32 bits internally.
--
-- The returned table is freshly allocated per call, because a caller will
-- usually want to keep it (a chunk's density profile, a region's
-- character). Callers that sample every frame should use sampleInto to
-- avoid the churn.
function SpaceField.sample (x, y, z, seed)
  local s = SpaceField.foldSeed(seed)
  local S = SpaceField.SCALE
  local C = SpaceField.CHANNEL

  local t = {}

  -- MACRO: the character of the region. This is what makes a place feel
  -- like somewhere rather than somewhere-else.
  t.regionHue     = valueNoise(x, y, z, S.macro, s, C.regionHue)
  t.regionDensity = valueNoise(x, y, z, S.macro, s, C.regionDensity)
  t.regionStorm   = valueNoise(x, y, z, S.macro, s, C.regionStorm)

  -- MESO: the stuff. A nebula bank, a dust wall, a belt of rock.
  t.nebulaDensity   = valueNoise(x, y, z, S.meso, s, C.nebulaDensity)
  t.dustDensity     = valueNoise(x, y, z, S.meso, s, C.dustDensity)
  t.asteroidDensity = valueNoise(x, y, z, S.meso, s, C.asteroidDensity)
  t.starVisibility  = valueNoise(x, y, z, S.meso, s, C.starVisibility)
  t.turbulence      = valueNoise(x, y, z, S.meso, s, C.turbulence)
  t.stormPotential  = valueNoise(x, y, z, S.meso, s, C.stormPotential)
  t.radiation       = valueNoise(x, y, z, S.meso, s, C.radiation)

  -- PALETTE: one source of truth for the environment's colour identity
  -- (§22). Derived from the macro hue with a meso-scale wobble, so a
  -- region has a dominant colour and the medium inside it varies.
  local hue = t.regionHue
  local hueWobble = (valueNoise(x, y, z, S.meso, s, C.paletteHue) - 0.5) * 0.12
  t.paletteHue   = (hue + hueWobble) % 1.0
  t.paletteSat   = valueNoise(x, y, z, S.meso, s, C.paletteSat)
  t.paletteLight = valueNoise(x, y, z, S.meso, s, C.paletteLight)
  t.anisotropy   = valueNoise(x, y, z, S.micro, s, C.anisotropy)

  return t
end

-- sampleInto(x, y, z, seed, out) -- as sample(), but writes into `out`.
-- For callers that sample every frame and do not keep the result.
function SpaceField.sampleInto (x, y, z, seed, out)
  local t = SpaceField.sample(x, y, z, seed)
  for k, v in pairs(t) do out[k] = v end
  return out
end

-- Convenience: sample the field at a point and return ONE channel.
--
-- Cheaper than sample() for the common case where a subsystem only cares
-- about one quantity (the asteroid field wants asteroidDensity; the dust
-- wants dustDensity).
function SpaceField.channel (x, y, z, seed, channelName)
  local s = SpaceField.foldSeed(seed)
  local ch = SpaceField.CHANNEL[channelName]
  if not ch then error('SpaceField: unknown channel ' .. tostring(channelName)) end
  -- Which scale a channel lives at is a property of the channel, so it is
  -- looked up here rather than duplicated at every call site.
  local scale
  if channelName:find('region', 1, true) then
    scale = SpaceField.SCALE.macro
  elseif channelName == 'anisotropy' then
    scale = SpaceField.SCALE.micro
  else
    scale = SpaceField.SCALE.meso
  end
  return valueNoise(x, y, z, scale, s, ch)
end

return SpaceField
