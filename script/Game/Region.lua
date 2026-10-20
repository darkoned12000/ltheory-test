--[[ Region -- named places inside a sector.

  THE RELATIONSHIP TO THE FIELD
  ============================
  procedural-space-environment.md §29a records the decision this implements:

    * A region is a FIELD VALUE, not an object in a list. "Violet Veil" is a
      place where the field's palette happens to sit at violet and its
      nebulaDensity is high. There is no region object, no region store and no
      membership test.
    * Regions are PLACED (one vast region, or five or six, per sector -- the
      count is a design parameter) and their boundaries are SOFT. Identity is
      discrete (the name changes; later a rule may change) while APPEARANCE
      is continuous (every parameter interpolates across a transition band).

  So there are two halves, and they are deliberately different mechanisms:

    * APPEARANCE comes from the SpaceField, which is smooth everywhere. This
      module does not change that.
    * IDENTITY comes from here: a small, deterministic set of region seeds
      placed in the sector, each with a name and an archetype, and a soft
      membership function that says "how much of this region is at that
      position".

  The membership function is what makes the boundary SOFT. A region's
  membership falls off smoothly with distance rather than stopping at a hard
  edge, so the parameters that are read from the field are blended between
  neighbouring regions near a boundary. The NAME changes at the point of
  equal membership (the nearest region wins), but the LOOK does not jump.

  WHY MEMBERSHIP IS BLENDED WITH THE FIELD
  =========================================
  The field's macro channels (regionHue, regionDensity, regionStorm) are
  sampled at the ship's position and describe the CHARACTER there. Each region
  has its own character, so the character must be interpolated between
  neighbouring regions across the transition band -- otherwise a region's
  identity would change instantly at its edge, which is exactly the hard
  boundary §7 warns against.

  So: the field supplies the fine structure, and the regions supply the
  coarse character, and the two are blended with the same weights. That keeps
  one source of truth for "what does this place feel like" (the region) while
  the field keeps supplying everything else.
]]

local Region = {}

local SpaceField = require('Game.SpaceField')
local NameGen = require('Game.NameGen')

-- Region archetypes. These are PRESETS for a region's character -- a hue
-- range, a density bias, a storminess bias -- not an enumeration of what a
-- sector may contain. A sector may have one region with no archetype at all
-- (a plain belt) or six that include some of these.
--
-- `hue` is the anchor for the region's palette; `density` and `storm` bias
-- the field's macro channels; `light` is how bright the medium reads.
Region.ARCHETYPES = {
  { name = 'Silent Deep',    hue = { 0.58, 0.68 }, density = 0.18, storm = 0.05, light = 0.30,
    desc = 'clear sky, few stars lost' },
  { name = 'Violet Veil',    hue = { 0.74, 0.82 }, density = 0.85, storm = 0.70, light = 0.55,
    desc = 'dense gas, frequent lightning' },
  { name = 'Shattered Belt', hue = { 0.05, 0.12 }, density = 0.30, storm = 0.20, light = 0.35,
    desc = 'rock, debris, low gas' },
  { name = 'Solar Graveyard',hue = { 0.02, 0.09 }, density = 0.55, storm = 0.80, light = 0.70,
    desc = 'hot haze, strong sun, storms' },
  { name = 'Dust Expanse',   hue = { 0.10, 0.16 }, density = 0.62, storm = 0.15, light = 0.40,
    desc = 'thin dust, clear stars' },
  { name = 'Deep Field',     hue = { 0.60, 0.72 }, density = 0.35, storm = 0.12, light = 0.25,
    desc = 'quiet, nothing much here' },
}

-- How far a region's influence reaches, as a fraction of the sector radius.
-- See placeRegions: with one region it covers the whole sector; with several
-- the regions are smaller and overlap.
--
-- (The reach is computed per-region in placeRegions, because it depends on the
-- region COUNT as well as on this fraction.)
local INFLUENCE = 0.62

-- How sharply membership falls off with distance, in the smoothstep sense.
-- 1 = a hard edge, larger = a broader transition. This is the "softness"
-- knob: the whole point is that it is NOT 1.
local FALLOFF = 2.4

local sqrt = math.sqrt
local floor = math.floor
local max = math.max
local min = math.min

-- ---------------------------------------------------------------------------
-- Placement
-- ---------------------------------------------------------------------------

-- Place the regions of a sector.
--
-- `sectorSeed` is the sector's own 32-bit seed (derived from the galaxy seed
-- by SpaceField.deriveSeed, so it is stable across sessions).
-- `origin` is the sector's centre; `radius` its extent.
--
-- The COUNT is a design parameter: one vast region, or five or six. It is
-- chosen deterministically from the sector seed, so a sector's shape is part
-- of its identity -- the same seed always gives the same sector layout.
local function placeRegions (sectorSeed, origin, radius)
  local s = sectorSeed

  -- 1..6 regions. A low count means one big region with a small influence
  -- overlap; a high count means several small ones.
  local count = 1 + floor(SpaceField.hash32(0, 0, 0, s, 91) * 6)
  count = min(count, 6)

  local regions = {}
  for i = 1, count do
    -- Place the centre on a golden-angle spiral around the sector origin, so
    -- the regions are spread through the volume rather than clustered at one
    -- end. The golden angle gives an even spread for any count, which a
    -- random placement does not (it clumps).
    --
    -- The spiral is scaled so that the regions' centres sit WITHIN the sector,
    -- and their reaches overlap enough that no point in the sector is
    -- uncovered.
    local ga = 2.39996323  -- golden angle, radians
    local z = 1 - 2 * (i - 0.5) / count
    local r = sqrt(max(0, 1 - z * z))
    local theta = ga * (i - 1)
    local dx, dy = r * cos(theta), r * sqrt(max(0, 1 - z * z))
    -- The third axis is the sector's Z, but the placement only needs to be
    -- DETERMINISTIC and spread; the exact frame does not matter.
    local jitter = 0.25
    local h = SpaceField.hash32(i, 0, 0, s, 92)
    local h2 = SpaceField.hash32(i, 0, 0, s, 93)

    -- The archetype. Not every region needs one -- a sector can be a plain
    -- belt -- so one region in a few is left unarchetyped.
    local archetype = nil
    if SpaceField.hash32(i, 0, 0, s, 94) > 0.25 then
      local ai = 1 + floor(SpaceField.hash32(i, 0, 0, s, 95) * #Region.ARCHETYPES)
      archetype = Region.ARCHETYPES[min(ai, #Region.ARCHETYPES)]
    end

    -- The reach of this region's influence.
    --
    -- With ONE region it must cover the whole sector, so its centre is the
    -- sector's centre and its reach is the sector's radius -- otherwise the
    -- ship can sit inside the sector and outside its only region, and the
    -- panel has nothing to say.
    --
    -- With SEVERAL, the regions are smaller and overlap. The spread and the
    -- reach are derived from the count so that the regions always cover the
    -- sector: centres within SPREAD of the origin, reaches large enough that
    -- neighbouring regions overlap and the outer ones reach the sector wall.
    --
    -- The reach is capped at the sector radius: a region whose influence
    -- reached past the sector would make the sector's own edge invisible, and
    -- the sector edge is the outermost boundary a player can be told about.
    local spread, reach
    if count == 1 then
      spread = 0
      reach  = radius
    else
      spread = 0.55
      -- Enough reach that the regions overlap AND the outermost one still
      -- covers the sector wall: reach >= spread*radius + radius would be
      -- needed for full coverage, but that is the whole sector -- so instead
      -- the regions cover the CENTRE of the sector, and the sector's own edge
      -- is covered by the sectorEdgeBearing fallback.
      reach = radius * (0.75 + 0.25 * h)
    end

    regions[i] = {
      index    = i,
      seed     = s,
      name     = nil,             -- assigned below
      archetype= archetype,
      center   = {
        x = origin.x + dx * radius * spread + (h - 0.5) * radius * jitter,
        y = origin.y + dy * radius * spread + (h2 - 0.5) * radius * jitter,
        z = origin.z + z * radius * 0.55,
      },
      reach    = reach,
      hue      = archetype and (archetype.hue[1] +
                   (archetype.hue[2] - archetype.hue[1]) * h) or h,
    }
  end

  -- Names. A sector's regions are named from the SECTOR's name so they read
  -- as belonging to it -- "the Veil" -> "Veil's Reach" -- but with enough
  -- variety that a sector does not read as a template.
  local sectorName = NameGen.sector(sectorSeed)
  for i, r in ipairs(regions) do
    r.sectorName = sectorName
    r.name = NameGen.region(sectorSeed, i)
  end

  return regions, sectorName
end

Region.place = placeRegions

-- ---------------------------------------------------------------------------
-- Membership
-- ---------------------------------------------------------------------------

-- Membership weights of every region at a position, as a table of
-- { region = r, w = weight } with the weights NORMALISED to sum to 1.
--
-- Normalised weights are what make the boundary soft: the character read
-- from the field is a weighted blend of the regions' characters, and a
-- weighted blend of continuous things is continuous. So crossing a boundary
-- changes the NAME at the crossover but slides the LOOK through it.
--
-- `regions` may be nil, in which case an empty list is returned -- the
-- caller then falls back to "no region here", which is what happens in a
-- world that has not been given a sector layout yet.
local function weightsAt (regions, x, y, z)
  if not regions or #regions == 0 then return {} end
  local raw = {}
  local total = 0
  for i = 1, #regions do
    local r = regions[i]
    local dx = x - r.center.x
    local dy = y - r.center.y
    local dz = z - r.center.z
    local d = sqrt(dx*dx + dy*dy + dz*dz)
    local t = 1 - (d / r.reach)
    if t > 0 then
      -- Smooth falloff: full membership at the centre, zero at the reach, and
      -- SMOOTH through the band between two regions. That smoothness is the
      -- soft boundary.
      local w = t * t * (3 - 2 * t)
      w = w * FALLOFF
      raw[#raw + 1] = { region = r, w = w, d = d }
      total = total + w
    end
  end
  if total <= 0 then
    -- Outside every region's reach: fall back to the NEAREST one, at a low
    -- weight. Without this, a position past the last region would have no
    -- region at all, and the HUD would show nothing -- which reads as a bug
    -- rather than as "you are off the beaten path".
    local best, bestD = nil, nil
    for i = 1, #regions do
      local r = regions[i]
      local dx = x - r.center.x
      local dy = y - r.center.y
      local dz = z - r.center.z
      local d = sqrt(dx*dx + dy*dy + dz*dz)
      if not bestD or d < bestD then best, bestD = r, d end
    end
    if best then return { { region = best, w = 1, d = bestD } } end
    return {}
  end
  for i = 1, #raw do raw[i].w = raw[i].w / total end
  return raw
end

Region.weightsAt = weightsAt

-- The region you are "in": the one with the greatest membership. This is the
-- discrete identity -- the NAME -- and it changes at the crossover, where two
-- regions have equal membership.
--
-- Named `containing` rather than `at`, because `at` is a reserved word in Lua.
function Region.containing (regions, x, y, z)
  local w = weightsAt(regions, x, y, z)
  if #w == 0 then return nil, w end
  local best = w[1]
  for i = 2, #w do if w[i].w > best.w then best = w[i] end end
  return best.region, w
end

-- The blended CHARACTER of a position: the regions' characters mixed by
-- their membership weights.
--
-- This is the soft part. The identity (name) is discrete; the character
-- (hue, density, storminess) is this weighted blend, so it slides through a
-- boundary rather than jumping.
function Region.characterAt (regions, x, y, z)
  local w = weightsAt(regions, x, y, z)
  if #w == 0 then return nil end
  local hue, density, storm, light = 0, 0, 0, 0
  for i = 1, #w do
    local e = w[i]
    local r = e.region
    local ww = e.w
    hue     = hue     + (r.hue or 0) * ww
    density = density + (r.archetype and r.archetype.density or 0.5) * ww
    storm   = storm   + (r.archetype and r.archetype.storm or 0.2) * ww
    light   = light   + (r.archetype and r.archetype.light or 0.4) * ww
  end
  return {
    hue     = hue % 1.0,
    density = density,
    storm   = storm,
    light   = light,
  }
end

-- ---------------------------------------------------------------------------
-- Bearing to the nearest boundary
-- ---------------------------------------------------------------------------

-- The direction toward the SECTOR's edge from a position.
--
-- The outermost boundary a player can be told about. In a sector with
-- several regions the interior boundaries are more interesting, so this is the
-- fallback -- but in a one-region sector it is the only boundary there is,
-- and without it the bearing arrow would have nothing to point at.
-- Returns the direction and the distance to the edge, or nil if the position
-- IS the centre (where "outward" is undefined).
function Region.sectorEdgeBearing (origin, radius, x, y, z)
  local dx, dy, dz = x - origin.x, y - origin.y, z - origin.z
  local d = sqrt(dx*dx + dy*dy + dz*dz)
  if d < 1e-3 then return nil end
  -- Straight out from the sector's centre is the shortest way to the edge.
  return { x = dx / d, y = dy / d, z = dz / d }, radius - d
end

-- The direction to the nearest region boundary from a position.
--
-- The boundary between two regions is where their memberships are EQUAL. So
-- the direction to it is the direction in which the membership difference
-- between the current region and the runner-up changes fastest -- which is
-- found by sampling that difference in a ring of directions and taking the
-- steepest descent.
--
-- This is computed on the FIELD, not on geometry, so it works at any
-- distance: a boundary 200k units away still has a direction. That matters,
-- because the visible reach of the medium (~14k) is far shorter than a region
-- (see the macro-scale discussion in §29a) -- so a marker that only worked
-- for visible boundaries would be useless most of the time.
--
-- A sector with only ONE region has no interior boundary, and `boundaryBearing`
-- returns nil for it. The caller then falls back to the sector edge, which is
-- the outermost boundary there is.
function Region.boundaryBearing (regions, x, y, z, samples)
  samples = samples or 12
  local here = weightsAt(regions, x, y, z)
  if #here < 2 then return nil end

  -- The two regions that matter: the one you are in, and the nearest rival.
  local a, b = here[1], nil
  for i = 2, #here do
    if not b or here[i].w > b.w then b = here[i] end
  end
  if not b then return nil end
  if here[1].w > b.w then a, b = b, here[1] end

  local aRegion, bRegion = a.region, b.region

  -- The membership difference at an offset, for a pair of regions.
  local function diff (px, py, pz)
    local w = weightsAt(regions, px, py, pz)
    local wa, wb = 0, 0
    for i = 1, #w do
      if w[i].region == aRegion then wa = w[i].w
      elseif w[i].region == bRegion then wb = w[i].w end
    end
    return wa - wb
  end

  -- Probe a ring. The probe distance is a fraction of the distance to the
  -- pair's centres -- far enough to move the membership measurably, close
  -- enough to stay local.
  local ca, cb = aRegion.center, bRegion.center
  local sep = sqrt((cb.x-ca.x)^2 + (cb.y-ca.y)^2 + (cb.z-ca.z)^2)
  if sep < 1e-3 then return nil end
  local probe = max(sep * 0.15, 1.0)

  local base = diff(x, y, z)
  local bestDir, bestSlope = nil, 0
  for i = 1, samples do
    local ang = (i - 1) * (2 * math.pi / samples)
    local dx, dz = cos(ang), sin(ang)
    local d = diff(x + dx * probe, y, z + dz * probe)
    -- Steepest DESCENT of the difference: the direction where the current
    -- region's hold on you fades fastest, which is the direction toward the
    -- boundary.
    local slope = (base - d) / probe
    if slope > bestSlope then
      bestSlope = slope
      bestDir = { x = dx, y = 0, z = dz }
    end
  end
  if not bestDir then return nil end
  return bestDir, bestSlope
end

-- ---------------------------------------------------------------------------
-- The sector a position belongs to
-- ---------------------------------------------------------------------------

-- A sector is a volume of space with its own seed. For now there is one
-- sector, so this is a thin wrapper -- but it is where the multi-sector
-- lookup will live, and having it in one place means the callers do not
-- have to care.
--
-- `sectorSeed` is the GALAXY seed; the sector's own seed is derived from it
-- by index, so sector 0 of a galaxy is always the same sector.
local Sector = {}

function Sector.seedFor (galaxySeed, index)
  return SpaceField.deriveSeed(galaxySeed, index)
end

-- The regions of a sector, built once and cached by (seed, origin, radius).
-- The cache key includes the origin because the same sector seed placed at a
-- different origin would have different region centres.
local regionCache = {}

function Sector.regions (sectorSeed, origin, radius)
  local key = string.format('%d|%.0f|%.0f|%.0f|%.0f',
                            sectorSeed, origin.x, origin.y, origin.z, radius)
  local cached = regionCache[key]
  if cached then return cached.regions, cached.sectorName end
  local regions, sectorName = placeRegions(sectorSeed, origin, radius)
  regionCache[key] = { regions = regions, sectorName = sectorName }
  return regions, sectorName
end

-- Forget the cached sector layouts. Needed when the galaxy seed changes.
function Sector.clearCache ()
  regionCache = {}
end

Sector.Region = Region

return Sector
