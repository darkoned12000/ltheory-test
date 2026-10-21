#!/usr/bin/env luajit
--[[----------------------------------------------------------------------------
  Offline region/boundary validator.

  The regions are the IDENTITY of a place: the sector's name, the region's
  name, and the arrow that tells you where the next one begins. The HUD is
  the only thing that shows them, so a mistake here is invisible in a
  screenshot but obvious to a player who flies for five minutes and never
  sees a second region.

  The CONTRACT checked here:

    1. COVERAGE -- every position in the sector belongs to SOME region. A
       position with no region shows an empty panel, which reads as a bug.
    2. DETERMINISM -- the same sector seed always lays out the same regions,
       with the same names and the same reaches. A sector's shape is part of
       its identity, so this has to be stable across reloads.
    3. SOFT BOUNDARIES -- membership is continuous. There must be no hard
       edge: crossing a boundary has to slide the character, not snap it.
    4. THE BOUNDARY IS EXACT -- the direction and distance reported for the
       nearest boundary must be where the two regions' memberships are in
       fact equal. This is the big one, and it was wrong twice:
         * the search probed only the XZ plane, so a boundary above or below
           the player was never found;
         * the search sampled a ring of directions and looked for a steepest
           descent, which is an APPROXIMATION -- and the ray it picked often
           never crossed a boundary at all (74 of 125 sample points got no
           distance; 86 of 125 after the 3D fix).
       The boundary is an Apollonius surface, so it can be solved exactly;
       this check proves the closed form agrees with the membership
       function it is supposed to describe.
    5. THE DIRECTION IS A UNIT VECTOR -- an arrow that is not a unit vector
       has a length that depends on how it was computed, which shows up as
       the marker drifting around the rim of the screen.
    6. THE FADE-OUT EDGE -- with only one region in the sector there is no
       rival to cross into, so the boundary is the region's own reach limit:
       the point where its membership reaches zero.

  Runs under luajit with NO GL/Engine context. Exit code non-zero on any
  failure. Wired into `python3 configure.py test` and `cmake --build`.
----------------------------------------------------------------------------]]--

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1,1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.')..'/'..src end
local root = src:gsub('/tools/validate_regions%.lua$', '')
if root == src then root = '.' end
package.path = root..'/script/?.lua;'..root..'/script/?/init.lua;'..package.path

local RegionMod = dofile(root..'/script/Game/Region.lua')
local Region = RegionMod.Region

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

local GALAXY = 15423934050514487609ULL
local ORIGIN = { x = 0, y = 0, z = 0 }
local RADIUS = 60000

-- The membership of ONE region at a position, with NO "fall back to the
-- nearest" rule -- the fall-back in weightsAt hides the very thing this
-- validator is checking.
--
-- The formula is restated here rather than called from the module, so this
-- is an independent check and not a tautology.
local function rawMembership (r, x, y, z)
  local dx, dy, dz = x - r.center.x, y - r.center.y, z - r.center.z
  local d = math.sqrt(dx*dx + dy*dy + dz*dz)
  local t = 1 - d / r.reach
  if t <= 0 then return 0 end
  return t * t * (3 - 2 * t)
end

-- A grid of sample points across the sector.
local function samplePoints (step)
  local pts = {}
  for i = -2, 2 do for j = -2, 2 do for k = -2, 2 do
    pts[#pts + 1] = {
      x = ORIGIN.x + i * step,
      y = ORIGIN.y + j * step,
      z = ORIGIN.z + k * step,
    }
  end end end
  return pts
end

-- ---------------------------------------------------------------------------
-- 1. Coverage
-- ---------------------------------------------------------------------------
do
  local missing, total = 0, 0
  local multiRegionSectors, singleRegionSectors = 0, 0
  -- Twenty sectors, not eight: the single-region shape is a MINORITY (one
  -- sector in five), so a small sample can miss it entirely -- and a check
  -- that only ever sees one shape is not checking the distribution.
  for g = 0, 19 do
    local seed = RegionMod.seedFor(GALAXY + g * 7919, 0)
    local regions = RegionMod.regions(seed, ORIGIN, RADIUS)
    if #regions == 1 then singleRegionSectors = singleRegionSectors + 1
    else multiRegionSectors = multiRegionSectors + 1 end
    for _, p in ipairs(samplePoints(12000)) do
      total = total + 1
      if not Region.containing(regions, p.x, p.y, p.z) then
        missing = missing + 1
      end
    end
  end
  check('every position in a sector belongs to a region',
    missing == 0,
    string.format('%d of %d positions had none, over %d multi-region and %d single-region sectors',
      missing, total, multiRegionSectors, singleRegionSectors))
  check('sectors have both single-region and multi-region layouts',
    multiRegionSectors > 0 and singleRegionSectors > 0,
    string.format('%d multi-region, %d single-region', multiRegionSectors, singleRegionSectors))
  -- The count is a design parameter: one vast region, or five or six smaller
  -- ones. NOT a uniform 1..6 -- two or three is the half-measure the design
  -- does not describe.
  local badCount = 0
  local seenCounts = {}
  for g = 0, 19 do
    local seed = RegionMod.seedFor(GALAXY + g * 7919, 0)
    local regions = RegionMod.regions(seed, ORIGIN, RADIUS)
    seenCounts[#regions] = (seenCounts[#regions] or 0) + 1
    if #regions ~= 1 and #regions ~= 5 and #regions ~= 6 then badCount = badCount + 1 end
  end
  check('a sector has one vast region, or five or six smaller ones',
    badCount == 0,
    string.format('%d sectors had a count the design does not describe', badCount))
end

-- ---------------------------------------------------------------------------
-- 2. Determinism
-- ---------------------------------------------------------------------------
do
  local seed = RegionMod.seedFor(GALAXY, 0)
  local a = RegionMod.regions(seed, ORIGIN, RADIUS)
  local b = RegionMod.regions(seed, ORIGIN, RADIUS)
  local same = #a == #b
  for i = 1, #a do
    local ra, rb = a[i], b[i]
    if ra.name ~= rb.name or ra.reach ~= rb.reach then same = false end
    if ra.center.x ~= rb.center.x or ra.center.y ~= rb.center.y or
       ra.center.z ~= rb.center.z then same = false end
  end
  check('the same sector seed lays out the same regions', same)

  -- A different sector must be a different place.
  local c = RegionMod.regions(RegionMod.seedFor(GALAXY, 1), ORIGIN, RADIUS)
  local differs = #a ~= #c
  for i = 1, math.min(#a, #c) do
    if a[i].name ~= c[i].name or a[i].reach ~= c[i].reach then differs = true end
  end
  check('a different sector seed lays out different regions', differs)
end

-- ---------------------------------------------------------------------------
-- 3. Soft boundaries
-- ---------------------------------------------------------------------------
do
  -- Membership must not jump: the character blend is a weighted sum of
  -- memberships, so a discontinuity in the weights would snap the look as
  -- the player crosses a boundary.
  local worstJump, worstAt = 0, nil
  for g = 0, 3 do
    local seed = RegionMod.seedFor(GALAXY + g * 7919, 0)
    local regions = RegionMod.regions(seed, ORIGIN, RADIUS)
    -- Walk a straight line through the sector in small steps.
    local prev
    for i = -2000, 2000 do
      local p = { x = i * 30, y = i * 17, z = -i * 23 }
      local w = Region.weightsAt(regions, p.x, p.y, p.z)
      local sum = 0
      for _, e in ipairs(w) do sum = sum + e.w end
      if prev then
        local jump = math.abs(sum - prev)
        if jump > worstJump then worstJump = jump; worstAt = i end
      end
      prev = sum
    end
  end
  check('membership is continuous across a walk through the sector',
    worstJump < 0.02,
    string.format('largest step change %s', string.format('%.5f', worstJump)))
end

-- ---------------------------------------------------------------------------
-- 4 + 5 + 6. The boundary is exact, the direction is a unit vector, and the
--             fade-out edge is where the membership reaches zero
-- ---------------------------------------------------------------------------
do
  local total, exact, noDir = 0, 0, 0
  local nonUnit, badRival, badFade = 0, 0, 0
  for g = 0, 5 do
    local seed = RegionMod.seedFor(GALAXY + g * 7919, 0)
    local regions = RegionMod.regions(seed, ORIGIN, RADIUS)
    for _, p in ipairs(samplePoints(12000)) do
      local cur = Region.containing(regions, p.x, p.y, p.z)
      local dir, dist, other = Region.boundaryInfo(regions, p.x, p.y, p.z)
      if not dir then
        noDir = noDir + 1
      else
        total = total + 1
        local len = math.sqrt(dir.x*dir.x + dir.y*dir.y + dir.z*dir.z)
        if len < 0.99 or len > 1.01 then nonUnit = nonUnit + 1 end
        if not dist or dist <= 0 then
          badRival = badRival + 1
        elseif other then
          -- The crossing point must be where the two memberships are EQUAL.
          -- So just short of it the current region leads, and just past it
          -- the rival leads.
          local eps = math.max(1, dist * 0.01)
          local before  = rawMembership(cur, p.x, p.y, p.z)
          local beforeO = rawMembership(other, p.x, p.y, p.z)
          local after   = rawMembership(cur,  p.x + dir.x*(dist+eps), p.y + dir.y*(dist+eps), p.z + dir.z*(dist+eps))
          local afterO  = rawMembership(other, p.x + dir.x*(dist+eps), p.y + dir.y*(dist+eps), p.z + dir.z*(dist+eps))
          if before >= beforeO and afterO > after then
            exact = exact + 1
          else
            badRival = badRival + 1
          end
        else
          -- The fade-out edge: the region's own membership reaches zero.
          local m = rawMembership(cur, p.x + dir.x*dist, p.y + dir.y*dist, p.z + dir.z*dist)
          if m < 0.02 then exact = exact + 1 else badFade = badFade + 1 end
        end
      end
    end
  end
  check('the reported boundary is where the memberships are equal',
    badRival == 0 and badFade == 0,
    string.format('%d of %d verified, %d wrong, %d bad fade-out', exact, total, badRival, badFade))
  check('the boundary direction is a unit vector',
    nonUnit == 0,
    string.format('%d of %d were not unit length', nonUnit, total))
  check('a boundary is found for almost every position',
    noDir <= total * 0.05,
    string.format('%d of %d positions had no boundary', noDir, total))
end

-- ---------------------------------------------------------------------------
-- The sector edge fallback
-- ---------------------------------------------------------------------------
do
  -- A one-region sector has no rival, so the HUD falls back to the sector's
  -- own edge. That fallback must always give a direction and a distance.
  --
  -- The direction always points AT the boundary: straight out when inside,
  -- straight back IN when outside -- because past the edge there is nothing
  -- out there yet (no jumpgates), and pointing further out would be
  -- pointing at nothing.
  local ok = true
  local detail = ''
  local inside, outside = 0, 0
  for g = 0, 3 do
    local seed = RegionMod.seedFor(GALAXY + g * 7919, 0)
    local regions = RegionMod.regions(seed, ORIGIN, RADIUS)
    if #regions == 1 then
      for _, p in ipairs(samplePoints(20000)) do
        local d = math.sqrt(p.x*p.x + p.y*p.y + p.z*p.z)
        local dir, dist, isInside = Region.sectorEdgeBearing(ORIGIN, RADIUS, p.x, p.y, p.z)
        if not dir or dist == nil or dist < 0 then
          ok = false
          detail = string.format('no edge bearing at (%d,%d,%d)', p.x, p.y, p.z)
        elseif d <= RADIUS and not isInside then
          ok = false
          detail = string.format('reported outside at (%d,%d,%d), which is inside', p.x, p.y, p.z)
        elseif d > RADIUS and isInside then
          ok = false
          detail = string.format('reported inside at (%d,%d,%d), which is outside', p.x, p.y, p.z)
        elseif d <= RADIUS then
          -- Inside: the bearing must point AWAY from the sector centre.
          -- (The exact centre has no outward direction, so it is skipped --
          -- the bearing there is a fixed arbitrary one, which is the point.)
          local len = math.sqrt(dir.x*dir.x + dir.y*dir.y + dir.z*dir.z)
          if d > 1 then
            local dot = (dir.x*p.x + dir.y*p.y + dir.z*p.z) / math.max(1e-6, len * d)
            if dot < 0.99 then
              ok = false
              detail = string.format('the bearing points inward at (%d,%d,%d)', p.x, p.y, p.z)
            end
          end
          inside = inside + 1
        else
          -- Outside: the bearing must point BACK toward the centre.
          local len = math.sqrt(dir.x*dir.x + dir.y*dir.y + dir.z*dir.z)
          local dot = (dir.x*p.x + dir.y*p.y + dir.z*p.z) / math.max(1e-6, len * d)
          if dot > -0.99 then
            ok = false
            detail = string.format('the bearing points further out at (%d,%d,%d)', p.x, p.y, p.z)
          end
          outside = outside + 1
        end
      end
    end
  end
  check('the sector edge always gives a bearing that points AT the edge', ok, detail)
end

-- ---------------------------------------------------------------------------
-- The map's region filter
-- ---------------------------------------------------------------------------
do
  -- The map drills into a region by showing the bodies whose DOMINANT region
  -- is that one. The rule has to be the same one the HUD uses to say which
  -- region you are in, or the map and the panel disagree about what is
  -- where.
  --
  -- Two properties matter: the regions PARTITION the sector (every position
  -- belongs to exactly one, so nothing is shown twice and nothing is
  -- missing), and every region is reachable (it is the dominant region
  -- somewhere, so drilling into it shows something).
  local overlap, missing, emptyRegion = 0, 0, 0
  for g = 0, 5 do
    local seed = RegionMod.seedFor(GALAXY + g * 7919, 0)
    local regions = RegionMod.regions(seed, ORIGIN, RADIUS)
    local counts = {}
    for _, r in ipairs(regions) do counts[r] = 0 end
    for _, p in ipairs(samplePoints(15000)) do
      local hits = 0
      for _, r in ipairs(regions) do
        -- The dominant region at this position.
        local w = Region.weightsAt(regions, p.x, p.y, p.z)
        local best, bestW = nil, 0
        for i = 1, #w do
          if w[i].w > bestW then bestW = w[i].w; best = w[i].region end
        end
        if best == r then
          hits = hits + 1
          counts[r] = counts[r] + 1
        end
      end
      if hits == 0 then missing = missing + 1
      elseif hits > 1 then overlap = overlap + 1 end
    end
    for _, c in pairs(counts) do if c == 0 then emptyRegion = emptyRegion + 1 end end
  end
  check('the regions partition the sector -- every position is in exactly one',
    missing == 0 and overlap == 0,
    string.format('%d positions in no region, %d in more than one', missing, overlap))
  check('every region is somewhere dominant, so drilling into it shows something',
    emptyRegion == 0,
    string.format('%d regions were never the dominant one', emptyRegion))
end

-- ---------------------------------------------------------------------------
-- 7. The environmental field (13f)
-- ---------------------------------------------------------------------------
-- A region's ARCHETYPE carries a density, a storminess, a lightness and a rock
-- count. Those four numbers are the region's CHARACTER, and the field is the
-- blend of them across a boundary. Three things have to hold, and none of
-- them is visible in a screenshot:
--
--   a. EVERY archetype channel is present, and in range. A channel that
--      nothing reads is the whole reason this section existed: the
--      archetypes carried a density, a storm and a light for the whole life
--      of the feature and NOTHING READ THEM.
--   b. The field is CONTINUOUS. It is sampled along lines that cross
--      boundaries, and the largest step between neighbouring samples is
--      compared against the size of the difference being crossed. A field
--      that switched would show as a seam in the sky, and a seam is exactly
--      what "the identity is discrete, the appearance is continuous" exists
--      to prevent.
--   c. The regions are actually DIFFERENT from each other. A field where
--      every region reads the same is a field that is not doing anything --
--      the failure mode of a blend whose inputs are all neutral.
do
  -- One sector with several regions, so the blend has something to blend.
  -- The seed is taken the same way the rest of this validator takes it, so
  -- the field is checked against a REAL layout and not a synthetic one.
  local regions
  for g = 0, 19 do
    local seed = RegionMod.seedFor(GALAXY + g * 7919, 0)
    local r = RegionMod.regions(seed, ORIGIN, RADIUS)
    if #r > 1 then regions = r break end
  end

  -- (a) the channels
  local chans = { 'density', 'storm', 'light', 'rocks' }
  local missing, outOfRange = {}, {}
  for _, a in ipairs(Region.ARCHETYPES) do
    for _, c in ipairs(chans) do
      if type(a[c]) ~= 'number' then
        missing[#missing + 1] = a.name .. '.' .. c
      elseif a[c] < 0 or a[c] > 1 then
        outOfRange[#outOfRange + 1] = string.format('%s.%s=%.3f', a.name, c, a[c])
      end
    end
  end
  check('every archetype carries every field channel, in 0..1',
    #missing == 0 and #outOfRange == 0,
    table.concat(missing, ', ') .. ' ' .. table.concat(outOfRange, ', '))

  if not regions then
    check('the field has a multi-region sector to be checked in', false,
      'no multi-region sector was found in the sample')
  else
    -- (b) continuity, along every line that crosses a boundary
    local worst, worstWhere = 0, ''
    -- Fine sampling on purpose. A CONTINUOUS field's step between two
    -- samples shrinks with the sample spacing, while a SWITCHING field's
    -- step does not -- so the finer the sampling, the better the check
    -- separates "a gradient" from "a jump". 200 steps over a 50 km line is
    -- 250 units apart, which is a twentieth of a region.
    local steps = 200
    for i = 1, #regions do
      for j = i + 1, #regions do
        local a, b = regions[i], regions[j]
        local prev
        for k = 0, steps do
          local t = k / steps
          local x = a.center.x + (b.center.x - a.center.x) * t
          local y = a.center.y + (b.center.y - a.center.y) * t
          local z = a.center.z + (b.center.z - a.center.z) * t
          local f = Region.field(regions, x, y, z)
          if prev then
            local step = math.max(math.abs(f.density - prev.density),
                                  math.abs(f.storm - prev.storm),
                                  math.abs(f.rocks - prev.rocks),
                                  math.abs(f.light - prev.light))
            if step > worst then
              worst = step
              worstWhere = string.format('%s -> %s at t=%.2f', a.name, b.name, t)
            end
          end
          prev = f
        end
      end
    end
    -- The step between two samples a third of a boundary apart. A field
    -- that SWITCHED would show a step the size of the whole difference
    -- between the regions -- tens of hundredths. A smooth field moves by a
    -- fraction of that.
    check('the field is continuous across every boundary',
      worst < 0.08,
      string.format('largest step %.4f (%s)', worst, worstWhere))

    -- (c) the regions differ
    local lo, hi = 1, 0
    for _, r in ipairs(regions) do
      local f = Region.field(regions, r.center.x, r.center.y, r.center.z)
      if f.storm < lo then lo = f.storm end
      if f.storm > hi then hi = f.storm end
    end
    check('the regions are measurably different from each other',
      (hi - lo) > 0.15,
      string.format('the storm channel ranges %.3f..%.3f across the regions', lo, hi))

    -- The blend must not depend on WHICH regions happen to lack an
    -- archetype. An un-archetyped region contributes the NEUTRAL value, not
    -- zero, or it would drag the whole field down by however many plain
    -- regions the sector happens to have.
    local plain = 0
    for _, r in ipairs(regions) do if not r.archetype then plain = plain + 1 end end
    if plain > 0 then
      local f = Region.field(regions, regions[1].center.x, regions[1].center.y,
                                            regions[1].center.z)
      check('a plain region does not drag the field to zero',
        f.density > 0.05 and f.storm > 0.02 and f.rocks > 0.05,
        string.format('the field at a region centre reads density=%.3f storm=%.3f rocks=%.3f',
          f.density, f.storm, f.rocks))
    end
  end
end

print(string.format('\n%d checks, %d failure(s)', checks, failures))
if failures > 0 then os.exit(1) end
os.exit(0)
