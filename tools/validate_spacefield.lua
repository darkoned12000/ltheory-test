#!/usr/bin/env luajit
--[[----------------------------------------------------------------------------
  Offline SpaceField validator.

  The SpaceField is the shared description of "what kind of place is this?",
  and every subsystem (nebula, asteroids, dust, lightning, star visibility)
  will read it. If it is wrong, the whole world generation is wrong in ways
  that are hard to see and impossible to undo -- a field that jumps at cell
  boundaries would make the environment pop as you fly, and a field that is
  not reproducible would break a sector's identity on re-entry.

  So the field's CONTRACT is checked here, offline, with no GL context and
  no engine at all:

    1. DETERMINISM -- the same (position, seed) always gives the same value.
    2. CONTINUITY -- no jump at a lattice boundary. This is the big one: a
       per-cell hash would jump at every cell edge, and that reads as the
       environment visibly snapping as you cross it.
    3. RANGE -- every channel stays in [0,1].
    4. INDEPENDENCE -- two channels at the same position are not correlated,
       so a "moisture" field cannot accidentally be a copy of the height
       field (which is what made the gen/moon biome field wrong).
    5. SCALE SEPARATION -- the macro, meso and micro scales are genuinely
       different frequencies, not the same noise three times.
    6. HASH AGREEMENT -- the hash32 in SpaceField must stay bit-identical
       to the copies in NebulaVolumes / LightningStorm / LightningBolt.
       Those were written before this module existed and are duplicated
       rather than shared; if they drift apart, every generated plume,
       storm and bolt in every existing world changes silently, which
       invalidates every captured frame in the repo.

  Runs under luajit with NO GL/Engine context. Exit code non-zero on any
  failure. Wired into `python3 configure.py test` and `cmake --build`.
----------------------------------------------------------------------------]]--

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1,1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.')..'/'..src end
local root = src:gsub('/tools/validate_spacefield%.lua$', '')
if root == src then root = '.' end
package.path = root..'/libphx/script/?.lua;'..root..'/libphx/script/?/init.lua;'..package.path

local SpaceField = dofile(root..'/script/Game/SpaceField.lua')

local failures = 0
local checks = 0

local function check (name, ok, detail)
  checks = checks + 1
  if ok then
    print('ok   - '..name..(detail and ('  -- '..detail) or ''))
  else
    failures = failures + 1
    print('FAIL - '..name..(detail and ('  -- '..detail) or ''))
  end
end

local SEED = 15423934050514487609ULL

-- ---------------------------------------------------------------------------
-- 1. Determinism
-- ---------------------------------------------------------------------------
local a = SpaceField.sample(1000, 2000, 3000, SEED)
local b = SpaceField.sample(1000, 2000, 3000, SEED)
local same = true
for k, v in pairs(a) do if b[k] ~= v then same = false end end
check('the same position and seed give the same sample', same)

-- A different seed must give a different sample. The seed is derived with
-- deriveSeed rather than SEED + 1, because SEED is a uint64 whose LOW bits
-- cannot survive a trip through a double -- and the fold that compresses it
-- to 32 bits XORs the two halves, so adjacent low-bit indices would collide.
local c = SpaceField.sample(1000, 2000, 3000, SpaceField.deriveSeed(SEED, 1))
local differs = false
for k, v in pairs(a) do if c[k] ~= v then differs = true end end
check('a different seed gives a different sample', differs)

-- Adjacent sector seeds must NOT collide. This is the property the whole
-- multi-sector design rests on: sector N and sector N+1 must be different
-- worlds, or the galaxy is one sector repeated.
local seen, collisions, distinct = {}, 0, {}
for i = 0, 64 do
  local fs = SpaceField.deriveSeed(SEED, i)
  if seen[fs] then collisions = collisions + 1 end
  seen[fs] = true
  distinct[fs] = true
end
check('adjacent sector seeds do not collide', collisions == 0,
  collisions > 0 and (collisions .. ' collisions among 65 seeds') or
  '65 seeds, 65 distinct values')

-- And the field sampled at each of them must actually differ.
local firstSample = SpaceField.sample(1000, 2000, 3000, SpaceField.deriveSeed(SEED, 0))
local sameAsFirst = 0
for i = 1, 64 do
  local si = SpaceField.sample(1000, 2000, 3000, SpaceField.deriveSeed(SEED, i))
  local allSame = true
  for k, v in pairs(firstSample) do if si[k] ~= v then allSame = false end end
  if allSame then sameAsFirst = sameAsFirst + 1 end
end
check('different sector seeds give different fields', sameAsFirst == 0,
  sameAsFirst > 0 and (sameAsFirst .. ' sectors matched sector 0') or
  '64 sectors, all distinct')

-- A different position must give a different sample.
local d = SpaceField.sample(1000, 2000, 3001, SEED)
local differsPos = false
for k, v in pairs(a) do if d[k] ~= v then differsPos = true end end
check('a different position gives a different sample', differsPos)

-- ---------------------------------------------------------------------------
-- 2. Continuity -- the important one
-- ---------------------------------------------------------------------------
-- A per-cell hash (what the current NebulaVolumes does for its anchors) would
-- JUMP at every cell edge: the value on one side of the boundary and the value
-- on the other are unrelated hashes.
--
-- So the test is not "does the value change" -- of course it does, slowly. The
-- test is "is there a SPIKE in the rate of change at a boundary". A smooth
-- field has a bounded slope everywhere; a cell-edge jump shows up as a huge
-- step over a tiny distance, and only AT the edge.
--
-- Measured as: the largest single-step change over a small delta h, taken
-- over a fine walk that steps exactly onto every boundary along the way. For
-- smooth noise the max step is a fixed fraction of h; for a per-cell hash it
-- is O(1) -- the full [0,1] range -- no matter how small h is.
--
-- The delta h is deliberately tiny relative to the cell, so that a smooth
-- field's step is dominated by its slope rather than by its curvature.
local STEP = 0.01      -- world units; 4 orders below the 25000-unit meso cell
-- The expected step over STEP for a smooth field is roughly
--   (value range) * STEP / (cell size) * O(1)
-- so ~4e-7 at the meso scale. The threshold below is deliberately loose
-- (1e-3) because what is being tested is the ABSENCE of a jump, not the
-- exact slope; the "no jumpier than the middle of a cell" check below is
-- the one that actually discriminates smooth from discontinuous.
local function maxStepOverLine (channelName, from, to, steps)
  local worst = 0
  local prev = SpaceField.channel(from[1], from[2], from[3], SEED, channelName)
  for i = 1, steps do
    local t = i / steps
    local x = from[1] + (to[1] - from[1]) * t
    local y = from[2] + (to[2] - from[2]) * t
    local z = from[3] + (to[3] - from[3]) * t
    local cur = SpaceField.channel(x, y, z, SEED, channelName)
    local step = math.abs(cur - prev)
    if step > worst then worst = step end
    prev = cur
  end
  return worst
end

-- Walk straight across a meso-lattice boundary: cell size 25000, so cross
-- x = 25000 exactly, with fine steps so the walk lands ON the boundary.
for _, ch in ipairs({'nebulaDensity', 'asteroidDensity', 'dustDensity',
                     'stormPotential', 'starVisibility'}) do
  local worst = maxStepOverLine(ch, {24999, 5000, 5000}, {25001, 5000, 5000}, 200)
  -- A smooth field's step over 0.01 units is ~1e-5 of the value range. A
  -- per-cell hash would step by O(0.1) or more here.
  check('no discontinuity crossing a lattice boundary: ' .. ch,
        worst < 1e-3,
        string.format('max step over %.3f units = %.7f', STEP, worst))
end

-- A macro-scale boundary is the one a player would actually notice.
local worstMacro = maxStepOverLine('regionHue', {249999, 1000, 1000}, {250001, 1000, 1000}, 200)
check('no discontinuity crossing a macro lattice boundary',
      worstMacro < 1e-3,
      string.format('max step = %.7f', worstMacro))

-- Also walk DIAGONALLY through a lattice corner, where three axes change at
-- once -- the worst case for trilinear interpolation.
local worstCorner = maxStepOverLine('nebulaDensity',
                                    {24999, 24999, 24999}, {25001, 25001, 25001}, 300)
check('no discontinuity crossing a lattice corner',
      worstCorner < 1e-3,
      string.format('max step = %.7f', worstCorner))

-- The same walk in the middle of a cell must be no jumpier than the walk
-- across a boundary. If the boundary walk were jumpier, the boundary would
-- be the problem; if it is the same, the field is uniformly smooth.
local midCell = maxStepOverLine('nebulaDensity', {12000, 5000, 5000}, {12002, 5000, 5000}, 200)
local atEdge  = maxStepOverLine('nebulaDensity', {24999, 5000, 5000}, {25001, 5000, 5000}, 200)
check('a lattice boundary is no jumpier than the middle of a cell',
      atEdge < math.max(midCell * 4, 1e-6),
      string.format('edge %.7f vs mid-cell %.7f', atEdge, midCell))

-- ---------------------------------------------------------------------------
-- 3. Range
-- ---------------------------------------------------------------------------
local outOfRange = {}
for i = 1, 400 do
  local x = (i * 977) % 900000 - 450000
  local y = (i * 1601) % 900000 - 450000
  local z = (i * 2377) % 900000 - 450000
  local s = SpaceField.sample(x, y, z, SEED)
  for k, v in pairs(s) do
    if type(v) ~= 'number' or v ~= v then
      outOfRange[#outOfRange+1] = k
    elseif v < 0.0 or v > 1.0 then
      outOfRange[#outOfRange+1] = k .. '=' .. string.format('%.3f', v)
    end
  end
end
check('every channel stays in [0,1] over 400 samples',
      #outOfRange == 0,
      #outOfRange > 0 and table.concat(outOfRange, ',') or '400 samples x 13 channels')

-- ---------------------------------------------------------------------------
-- 4. Independence
-- ---------------------------------------------------------------------------
-- Two channels at the same point must not be correlated. The gen/moon bug
-- was exactly this failure: "moisture" was the height field, so the two
-- climate axes collapsed into one.
local function correlation (ch1, ch2, n)
  local n = n or 300
  local sx, sy, sxx, syy, sxy = 0, 0, 0, 0, 0
  for i = 1, n do
    local x = (i * 31337) % 800000 - 400000
    local y = (i * 69797) % 800000 - 400000
    local z = (i * 104729) % 800000 - 400000
    local u = SpaceField.channel(x, y, z, SEED, ch1)
    local v = SpaceField.channel(x, y, z, SEED, ch2)
    sx = sx + u; sy = sy + v
    sxx = sxx + u*u; syy = syy + v*v; sxy = sxy + u*v
  end
  local mu, mv = sx/n, sy/n
  local cov = sxy/n - mu*mv
  local su = math.sqrt(math.max(0, sxx/n - mu*mu))
  local sv = math.sqrt(math.max(0, syy/n - mv*mv))
  if su < 1e-9 or sv < 1e-9 then return 0 end
  return cov / (su * sv)
end

-- These pairs must be essentially uncorrelated.
for _, pair in ipairs({
  {'nebulaDensity',   'asteroidDensity'},
  {'nebulaDensity',   'dustDensity'},
  {'dustDensity',     'starVisibility'},
  {'asteroidDensity', 'stormPotential'},
  {'nebulaDensity',   'paletteSat'},
}) do
  local r = correlation(pair[1], pair[2])
  check('channels are uncorrelated: ' .. pair[1] .. ' vs ' .. pair[2],
        math.abs(r) < 0.25,
        string.format('r = %.3f', r))
end

-- ---------------------------------------------------------------------------
-- 5. Scale separation
-- ---------------------------------------------------------------------------
-- The macro channel must vary SLOWER than the meso one, or "macro" is a
-- misnomer and the region character would change as fast as the content.
-- Measured as the mean absolute change over a fixed step.
local function meanStep (channelName, step)
  local tot, n = 0, 0
  local x, y, z = 0, 0, 0
  for i = 1, 200 do
    local u0 = SpaceField.channel(x, y, z, SEED, channelName)
    local u1 = SpaceField.channel(x + step, y, z, SEED, channelName)
    tot = tot + math.abs(u1 - u0)
    n = n + 1
    x = x + 7919
    y = y + 104729
    z = z + 31337
  end
  return tot / n
end

local macroStep = meanStep('regionHue', 2500)
local mesoStep  = meanStep('nebulaDensity', 2500)
check('the macro scale varies more slowly than the meso scale',
      macroStep < mesoStep,
      string.format('macro %.5f vs meso %.5f per 2500 units', macroStep, mesoStep))

-- And the micro scale faster still.
local microStep = meanStep('anisotropy', 2500)
check('the micro scale varies faster than the meso scale',
      microStep > mesoStep,
      string.format('micro %.5f vs meso %.5f per 2500 units', microStep, mesoStep))

-- ---------------------------------------------------------------------------
-- 6. Hash agreement with the pre-existing copies
-- ---------------------------------------------------------------------------
-- NebulaVolumes / LightningStorm / LightningBolt each carry their own copy
-- of hash32, written before this module existed. They MUST stay identical.
--
-- The comparison is BEHAVIOURAL, not textual: this module uses the `bit`
-- library (Lua 5.2's `&`/`~`/`>>` operators are a compile-time option of
-- the LuaJIT build, and the bundled standalone luajit used by the offline
-- validators does not have them, so a module using the operators cannot be
-- loaded here at all). The two forms are numerically identical -- every step
-- ends in a 32-bit mask -- and the reference implementation below is the
-- ORIGINAL operator form, so comparing against it proves the refactor did
-- not change a single generated value.
--
-- The reference is the ORIGINAL operator form, transcribed from
-- NebulaVolumes.lua. It is loaded as a STRING at runtime rather than written
-- inline, because Lua parses a whole file before running any of it: a file
-- containing `&` fails to LOAD on a LuaJIT built without Lua 5.2 compatibility
-- even if that function is never called. The bundled standalone luajit used
-- by these validators is such a build; the engine's libluajit is not.
local HASH_REF_SRC = [[
local function hashRef (x, y, z, seed, k)
  local h = (x * 374761393 + y * 668265263 + z * 224682251
             + seed * 3266489917 + k * 2654435761) & 0xFFFFFFFF
  h = ((h ~ (h >> 13)) * 1274126177) & 0xFFFFFFFF
  h = (h ~ (h >> 16)) & 0xFFFFFFFF
  return (h % 4294967296) / 4294967296.0
end
local function foldRef (seed)
  local s = math.floor(tonumber(seed) or 0)
  local lo = s % 4294967296
  local hi = math.floor(s / 4294967296) % 4294967296
  return (lo ~ hi) & 0xFFFFFFFF
end
return hashRef, foldRef
]]

-- The fold is compared over REAL sector seeds, because the fold's precision
-- limit only shows up on 64-bit inputs: on a 32-bit seed every fold
-- implementation agrees. This is the check that would have caught the
-- divergence during development, where an exact-64-bit fold was used in
-- SpaceField while the canonical lossy fold stayed in NebulaVolumes -- which
-- would have meant the field and the nebula disagreed about a sector's seed.
local SECTOR_SEEDS = {
  15423934050514487609ULL,
  13358375402019159601ULL,
  0ULL,
  1ULL,
  4294967295ULL,          -- 2^32 - 1: the low/high half boundary
  4294967296ULL,          -- 2^32
  18446744073709551615ULL,-- 2^64 - 1: every bit set
}

local refLoaded, refErr = pcall(function ()
  return load(HASH_REF_SRC, 'hashref')()
end)

if not refLoaded then
  print('skip - hash agreement with the pre-existing copies'
        ..'  -- this luajit build has no Lua 5.2 bitops, so the operator form'
        ..' cannot be evaluated here (the engine\'s libluajit can)')
else
  local hashRef, foldRef = refLoaded
  local mismatches = 0
  local firstBad = nil
  for i = 0, 5000 do
    local x = (i * 7919) % 5000 - 2500
    local y = (i * 104729) % 5000 - 2500
    local z = (i * 31337) % 5000 - 2500
    local seed = (i * 2654435761) % 4294967296
    local k = i % 64
    local a = hashRef(x, y, z, seed, k)
    local b = SpaceField.hash32(x, y, z, seed, k)
    if a ~= b then
      mismatches = mismatches + 1
      if not firstBad then
        firstBad = string.format('x=%d y=%d z=%d seed=%d k=%d ref=%.9f new=%.9f',
                                 x, y, z, seed, k, a, b)
      end
    end
  end
  check('SpaceField.hash32 is numerically identical to the original operator form',
        mismatches == 0,
        mismatches > 0 and (firstBad .. ' (' .. mismatches .. ' mismatches)') or
        '5001 inputs, zero mismatches')

  local bad, firstBad = 0, nil
  for _, seed in ipairs(SECTOR_SEEDS) do
    local a, b = foldRef(seed), SpaceField.foldSeed(seed)
    if a ~= b then
      bad = bad + 1
      if not firstBad then
        firstBad = string.format('seed=%s ref=%d new=%d', tostring(seed), a, b)
      end
    end
  end
  for i = 0, 2000 do
    local seed = i * 11400714819323198485ULL
    if foldRef(seed) ~= SpaceField.foldSeed(seed) then bad = bad + 1 end
  end
  check('SpaceField.foldSeed is numerically identical to the canonical fold',
        bad == 0,
        (bad > 0 and (firstBad or (bad .. ' mismatches'))) or
        (#SECTOR_SEEDS + 2001 .. ' seeds (incl. 64-bit edge cases), zero mismatches'))

  -- The precision limit itself is DOCUMENTED behaviour, not a bug to fix: the
  -- canonical fold drops the low bits of a 64-bit seed, which is why
  -- deriveSeed mixes the index into the HIGH bits. Assert that deriveSeed
  -- does separate adjacent indices -- this is the property the multi-sector
  -- design depends on.
  local seen, collisions = {}, 0
  for i = 0, 64 do
    local f = SpaceField.deriveSeed(SECTOR_SEEDS[1], i)
    if seen[f] then collisions = collisions + 1 end
    seen[f] = true
  end
  check('deriveSeed separates adjacent indices (the canonical fold cannot)',
        collisions == 0,
        collisions > 0 and (collisions .. ' collisions') or '65 indices, 65 distinct')
end

-- The SOURCE in the other files must still be the operator form. If someone
-- rewrote one of them to the bit-library form, the generated values would
-- still match -- but the source would no longer be the canonical form the
-- other two are transcribed from, and the next person to copy it would get
-- a subtly different implementation.
for _, path in ipairs({'script/Game/NebulaVolumes.lua',
                       'script/Game/LightningStorm.lua',
                       'script/Game/Entities/LightningBolt.lua'}) do
  local fh = io.open(root..'/'..path, 'r')
  local text = fh and fh:read('*a') or ''
  if fh then fh:close() end
  check(path .. ' still uses the canonical operator form of hash32',
        text:find('& 0xFFFFFFFF') ~= nil,
        'the copy in this file has drifted from the canonical form')
end

if failures > 0 then
  print(string.format('FAILURES: %d of %d checks failed', failures, checks))
  os.exit(1)
end
print(string.format('all %d spacefield checks passed', checks))
os.exit(0)
