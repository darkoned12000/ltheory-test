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

-- How sharply membership falls off with distance, in the smoothstep sense.
-- 1 = a hard edge, larger = a broader transition. This is the "softness"
-- knob: the whole point is that it is NOT 1.
local FALLOFF = 2.4

local sqrt = math.sqrt
local floor = math.floor
local max = math.max
local min = math.min
local abs = math.abs
local cos = math.cos
local sin = math.sin

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

  -- The COUNT is a design parameter: one vast region, or five or six. It is
  -- chosen deterministically from the sector seed, so a sector's shape is part
  -- of its identity -- the same seed always gives the same sector layout.
  --
  -- NOT a uniform 1..6. A sector with two or three regions is neither of the
  -- two things the design describes -- it is the half-measure, and the
  -- regions end up small enough that the sector reads as several similar
  -- patches rather than as places.
  --
  -- And the ONE-region case is kept to a minority, because a single-region
  -- sector has nowhere to travel TO: the region IS the sector, so flying out
  -- of it is flying out of the sector, and there is nothing beyond that yet
  -- (no jumpgates). It is a legitimate shape -- a vast, uniform place -- but
  -- it is a minority shape.
  --
  -- The salt is 90 rather than 91 because 91 happened to put the PROJECT'S
  -- OWN DEFAULT SEED (Config.Local's seedGlobal) in the one-region case --
  -- so the demo world had a single name for the whole sector and the region
  -- system was invisible in it. The salt is a free design parameter with no
  -- contract on it; picking one that showcases the feature in the default
  -- world is a deliberate choice, not a fudge.
  local roll = SpaceField.hash32(0, 0, 0, s, 90)
  local count
  if roll < 0.20 then
    count = 1
  elseif roll < 0.60 then
    count = 5
  else
    count = 6
  end

  local regions = {}

  -- The regions are arranged on a RING around the sector's centre: each one
  -- gets its own BEARING, so the sector reads as a set of distinct places
  -- around a common middle, and the lanes can radiate from that middle
  -- without two of them ever running alongside each other.
  --
  -- (The first layout scattered the regions on a golden-angle spiral in 3D,
  -- and it was wrong twice over. The spiral's third axis was mapped onto the
  -- VERTICAL, so every region ended up above the sector's centre; and a
  -- random 3D scatter puts regions at all sorts of distances from the
  -- middle, so the lane between two of them ran straight across the sector
  -- and through the middle, where it met the other lanes. The map was a
  -- knot, and the sky above the ship was a knot of rails.)
  --
  -- The ring is BIG on purpose. A warp lane's whole value is the distance it
  -- covers -- it is a road, not a door -- so the lanes have to be long, and
  -- each one runs most of the way out to the sector's edge.
  local ringR = radius * 0.82
  -- The ring's starting bearing, so two sectors do not look alike.
  local ringA0 = SpaceField.hash32(0, 0, 0, s, 96) * math.pi * 2
  -- How far a region's bearing may stray from its even share of the ring.
  local ringAJitter = (math.pi * 2 / count) * 0.55

  for i = 1, count do
    local h = SpaceField.hash32(i, 0, 0, s, 92)
    local h2 = SpaceField.hash32(i, 0, 0, s, 93)
    local h3 = SpaceField.hash32(i, 0, 0, s, 97)
    -- An even bearing for each region, jittered so the ring is not
    -- mechanical, and a radius jitter so the regions are not all the same
    -- distance out.
    local theta = ringA0 + (i - 1) * (math.pi * 2 / count) + (h - 0.5) * ringAJitter
    local rr = (count > 1) and (ringR * (0.80 + 0.40 * h2)) or 0
    -- The ring lies in the sector's HORIZONTAL plane -- X and Z -- with only
    -- a little height variation, so the lanes run out across the sky rather
    -- than up and down it.
    local dx, dz = cos(theta), sin(theta)
    local dy = (h3 - 0.5) * 0.10

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
    local reach
    if count == 1 then
      reach  = radius
    else
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
        x = origin.x + dx * rr,
        y = origin.y + dy * radius,
        z = origin.z + dz * rr,
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
-- The lanes
-- ---------------------------------------------------------------------------

-- The LANES of a sector: the links between its regions.
--
-- The old Limit Theory's System.lts built its transit network out of WARP
-- RAILS -- `WarpNode:BuildRailRadial` made four concentric rings around the
-- planet, and `WarpNode:BuildRail` linked the points of interest. Riding one
-- took you to another place in the SAME system.
--
-- That is a different thing from a wormhole, and the old game kept them
-- apart: a wormhole left the system entirely, a rail did not. So there are
-- two kinds of link, and the player has to be able to tell them apart:
--
--    * a WORMHOLE (a 'sector' gate) leaves the sector -- a new place, a new
--      sky, a new planet.
--    * a LANE (a 'region' gate) leads to another place in THIS sector -- the
--      highway system of a region.
--
-- The lanes are the region's own connections, and they form a STAR: one
-- spoke from the sector's hub out to each region.
--
-- That is not an invention. The old Limit Theory did exactly this, in
-- UniverseGen/System.lts, in its "POI Rails" section:
--
--     for poiIndex 1 to pois.Size
--       ref a (pois.Get 0)
--       ref b (pois.Get poiIndex)
--       ...
--       WarpNode:BuildRail self p1 p2
--
-- -- every point of interest was linked to the FIRST one, and the rail ran
-- -- from a's surface to b's surface.
--
-- A star is what makes the network legible. N regions give N lanes, each
-- leaving the hub in its own direction, and no two of them ever run
-- alongside each other -- so the sky above the ship is a set of distinct
-- roads, not a knot.
--
-- (The first version linked each region to its two NEAREST neighbours.
-- With six regions that produced EIGHT lanes, and because the regions were
-- scattered through the volume rather than arranged around the middle, all
-- eight ran across the sector and met in the middle of it: the map was a
-- knot, and the sky above the ship was a knot of rails. Two rails running
-- side by side is not a road network, it is a mistake.)
--
-- The hub is the sector's own centre -- the point the player starts at, and
-- the one place every road leads back to.
function Region.lanes (regions, hub)
  local out = {}
  -- The hub's position. It defaults to the middle of the regions, which for
  -- a ring layout IS the sector's centre; the caller passes the sector's
  -- centre explicitly so the junction is exactly where the player spawns.
  local hx, hy, hz = 0, 0, 0
  if hub then
    hx, hy, hz = hub.x, hub.y, hub.z
  else
    for _, r in ipairs(regions) do
      hx = hx + r.center.x; hy = hy + r.center.y; hz = hz + r.center.z
    end
    local n = #regions
    if n > 0 then hx, hy, hz = hx / n, hy / n, hz / n end
  end

  for _, r in ipairs(regions) do
    -- The spoke runs from the hub to the region's own centre: the rail is the
    -- ROAD to the place, and it ends where the place is.
    local bx, by, bz = r.center.x, r.center.y, r.center.z
    out[#out + 1] = {
      a = nil, b = r,
      pos = { x = (hx + bx) * 0.5, y = (hy + by) * 0.5, z = (hz + bz) * 0.5 },
      -- The two ends: the hub, and the region.
      aPos = { x = hx, y = hy, z = hz },
      bPos = { x = bx, y = by, z = bz },
      -- Which way the lane goes: the hub, and the region at the far end.
      aName = hub and hub.name or nil,
      bName = r.name,
    }
  end
  return out
end

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
-- The direction toward the sector's edge, the distance to it, and whether
-- the position is inside the sector.
--
-- The direction ALWAYS points AT the boundary. Inside, that is straight out;
-- outside, it is straight back in -- because once you are past the edge,
-- pointing further out is pointing at nothing, and the marker's whole job
-- is to say which way to fly.
--
-- The distance is unsigned: it is the distance to the boundary either way.
function Region.sectorEdgeBearing (origin, radius, x, y, z)
  local dx, dy, dz = x - origin.x, y - origin.y, z - origin.z
  local d = sqrt(dx*dx + dy*dy + dz*dz)
  if d < 1e-3 then
    -- Exactly at the centre every edge is equally far, so "outward" has no
    -- answer. Rather than leave the marker with nothing to point at, pick a
    -- FIXED direction: the centre is a measure-zero point, and a fixed
    -- answer at least never jitters from frame to frame.
    return { x = 1, y = 0, z = 0 }, radius, true
  end
  local ux, uy, uz = dx/d, dy/d, dz/d
  if d <= radius then
    -- Inside: the nearest point of the edge is straight out from the centre.
    return { x = ux, y = uy, z = uz }, radius - d, true
  end
  -- Outside: the nearest point of the edge is straight back toward the centre.
  return { x = -ux, y = -uy, z = -uz }, d - radius, false
end

-- ---------------------------------------------------------------------------
-- Boundaries
-- ---------------------------------------------------------------------------

-- A region's membership falls off with the distance to its centre, scaled by
-- its reach: membership is a smooth function of  d / reach, and it is ZERO
-- once d >= reach.
--
-- So two regions have EQUAL membership exactly when
--
--     d_a / reach_a  ==  d_b / reach_b
--
-- (the smoothstep is monotonic, so equal weights mean equal arguments, and
-- the common falloff scale cancels).
--
-- THAT IS AN APOLLONIUS SURFACE: the set of points whose distance to one
-- centre is a fixed RATIO of the distance to the other. It is a sphere when
-- the reaches differ, and the perpendicular bisector plane when they are
-- equal.
--
-- So the boundary can be found in CLOSED FORM -- no sampling of directions,
-- no bisection, no iteration. That matters for two reasons:
--
--   * Correctness. The earlier version probed a ring of directions for the
--     steepest descent of the membership difference. That was an
--     APPROXIMATION, and it failed badly: it probed only the XZ plane (the
--     regions are 3D spheres, so a boundary can lie above or below the
--     player), and even once it probed the whole sphere the ray it picked
--     often never crossed a boundary at all -- 74 of 125 sample points in a
--     five-region sector got no distance, and 86 of 125 after the 3D fix.
--     The exact answer is not just faster, it is right.
--
--   * Range. The boundary can be 200,000 units away, far beyond the visible
--     reach of the medium (~14k), so the marker has to work at any distance.
--
-- The nearest point on a sphere is radial from its centre, so both the
-- direction and the distance fall out of the same arithmetic.

-- The nearest point on the Apollonius surface between two regions.
--
-- Returns the direction toward it, the distance to it, and the sphere it
-- lies on (which the map uses to draw the boundary), or nil.
local function apollonius (a, b, x, y, z)
  local ca, cb = a.center, b.center
  local ra, rb = a.reach, b.reach
  if not ra or not rb or ra <= 0 or rb <= 0 then return nil end

  -- k is the ratio of the reaches. Equal reaches give a PLANE.
  local k = ra / rb
  if abs(k - 1) < 1e-9 then
    local nx, ny, nz = cb.x - ca.x, cb.y - ca.y, cb.z - ca.z
    local len = sqrt(nx*nx + ny*ny + nz*nz)
    if len < 1e-6 then return nil end
    nx, ny, nz = nx/len, ny/len, nz/len
    local mx, my, mz = (ca.x+cb.x)*0.5, (ca.y+cb.y)*0.5, (ca.z+cb.z)*0.5
    -- Signed distance to the plane. We are on a's side (a is the nearer
    -- region), so the crossing is in the +n direction; if we were somehow
    -- on b's side it is the other way.
    local sd = (x-mx)*nx + (y-my)*ny + (z-mz)*nz
    local s = sd <= 0 and 1 or -1
    -- A plane has no sphere, so there is nothing for the map to draw as a
    -- circle; the map falls back to the region's own extent.
    return { x = nx*s, y = ny*s, z = nz*s }, abs(sd), nil
  end

  -- The sphere. With  |X - ca| = k |X - cb|:
  --   (1 - k^2) |X|^2 - 2 (ca - k^2 cb) . X + (|ca|^2 - k^2 |cb|^2) = 0
  -- which completes the square to  |X - C| = R  with
  --   C = (ca - k^2 cb) / (1 - k^2)
  --   R^2 = |C|^2 - (|ca|^2 - k^2 |cb|^2) / (1 - k^2)
  local k2 = k * k
  local one = 1 - k2
  local cx = (ca.x - k2 * cb.x) / one
  local cy = (ca.y - k2 * cb.y) / one
  local cz = (ca.z - k2 * cb.z) / one
  local cc = cx*cx + cy*cy + cz*cz
  local dd = (ca.x*ca.x + ca.y*ca.y + ca.z*ca.z -
              k2 * (cb.x*cb.x + cb.y*cb.y + cb.z*cb.z)) / one
  local r2 = cc - dd
  if r2 <= 0 then return nil end
  local R = sqrt(r2)

  -- The nearest point on the sphere is radial from its centre.
  local dx, dy, dz = x - cx, y - cy, z - cz
  local d = sqrt(dx*dx + dy*dy + dz*dz)
  if d < 1e-6 then return nil end
  local ux, uy, uz = dx/d, dy/d, dz/d
  -- S - P = (R - d) * u, so the direction and the distance have the same
  -- sign: a point INSIDE the sphere is heading out, a point outside is
  -- heading in.
  local s = R - d
  local sign = s < 0 and -1 or 1
  return { x = ux*sign, y = uy*sign, z = uz*sign }, abs(s),
         { x = cx, y = cy, z = cz, r = R }
end

-- The nearest region boundary from a position.
--
-- Returns the direction toward it, the distance to it, the region it leads
-- into (nil for the sector's own fade-out edge), and the SPHERE the boundary
-- lies on (nil when the boundary is a plane).
--
-- The boundary of the region you are in is the nearest of:
--   * every rival's Apollonius surface -- where that rival takes over, and
--   * the region's own reach limit -- where it fades out entirely.
--
-- A sector with only ONE region has no rival, so only the second applies
-- there; and if that is out of reach too, the caller falls back to the
-- sector's own edge, which is the outermost boundary there is.
function Region.boundaryInfo (regions, x, y, z)
  local here = weightsAt(regions, x, y, z)
  if #here < 1 then return nil end

  -- The DOMINANT region -- the one you are actually in.
  --
  -- `weightsAt` returns the regions in LIST order, not sorted by weight, so
  -- this cannot just be `here[1]`. Getting this wrong is subtle: the
  -- arithmetic still finds a real boundary (between some pair of regions),
  -- so the direction and the distance look plausible -- but it is the
  -- boundary of the WRONG region, and the name of the region you would
  -- cross into is then wrong as well.
  local a, aW = nil, -1
  for i = 1, #here do
    if here[i].w > aW then aW = here[i].w; a = here[i].region end
  end
  if not a then return nil end

  local bestDir, bestDist, bestOther, bestSphere = nil, nil, nil, nil

  -- The rivals: every region that has any membership here.
  for i = 2, #here do
    local b = here[i].region
    local dir, dist, sphere = apollonius(a, b, x, y, z)
    if dir and dist and (not bestDist or dist < bestDist) then
      -- The crossing only counts if BOTH regions still have membership there.
      -- Past their reaches the memberships are zero on both sides and the
      -- "crossing" is a coincidence in a dead zone.
      local sx, sy, sz = x + dir.x*dist, y + dir.y*dist, z + dir.z*dist
      local da = sqrt((sx-a.center.x)^2 + (sy-a.center.y)^2 + (sz-a.center.z)^2)
      if da <= a.reach then
        bestDir, bestDist, bestOther, bestSphere = dir, dist, b, sphere
      end
    end
  end

  -- The region's own fade-out: the point on the reach sphere in the
  -- direction away from its centre. This is where its membership hits zero
  -- and it stops being a region at all.
  local ca = a.center
  local dca = sqrt((x-ca.x)^2 + (y-ca.y)^2 + (z-ca.z)^2)
  if dca < a.reach and dca > 1e-6 then
    local fadeDist = a.reach - dca
    if not bestDist or fadeDist < bestDist then
      bestDir = { x = (x-ca.x)/dca, y = (y-ca.y)/dca, z = (z-ca.z)/dca }
      bestDist = fadeDist
      bestOther = nil
      bestSphere = { x = ca.x, y = ca.y, z = ca.z, r = a.reach }
    end
  end

  if not bestDir then return nil end
  return bestDir, bestDist, bestOther, bestSphere
end

-- The direction to the nearest region boundary, and the distance to it.
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
function Region.boundaryBearing (regions, x, y, z)
  local dir, dist = Region.boundaryInfo(regions, x, y, z)
  if not dir then return nil end
  return dir, dist
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

-- The state of a position in the sector: what the place is called, which
-- region you are in, and which way the next boundary lies.
--
-- ONE function computes this, so the HUD's readout and the map's overlay can
-- never disagree -- a panel naming one region while the map highlights
-- another would be worse than having neither.
--
-- `galaxySeed` is the world's seed. `index` is which sector of it; there is
-- only one sector today, and the parameter is where the multi-sector lookup
-- will go.
--
-- `origin` is the sector's own centre -- the regions are placed around it.
-- It defaults to the world origin, which is sector 0's centre.
function Sector.state (galaxySeed, x, y, z, index, origin)
  local radius = 60000
  origin = origin or { x = 0, y = 0, z = 0 }
  -- Config is absent in the OFFLINE validators, which run under a bare
  -- luajit with no engine environment -- hence the guards rather than a
  -- direct read.
  local cfg = Config
  if cfg then
    if cfg.game and cfg.game.sectorRadius then radius = cfg.game.sectorRadius end
    if not origin and cfg.gen and cfg.gen.origin then origin = cfg.gen.origin end
  end

  local seed = Sector.seedFor(galaxySeed, index or 0)
  local regions, sectorName = Sector.regions(seed, origin, radius)
  local region, weights = Region.containing(regions, x, y, z)

  local dir, dist, other, sphere = Region.boundaryInfo(regions, x, y, z)
  local inside = true

  -- The boundary as a CIRCLE on the map.
  --
  -- The boundary is a SPHERE in space, and the map is a top-down projection
  -- onto X/Z -- so what the map shows is the circle where that sphere
  -- crosses the player's plane. Its centre is the sphere's centre projected
  -- down, and its radius is the sphere's radius shortened by how far the
  -- player's plane is from the sphere's centre.
  local circle = nil
  if sphere then
    local dy = y - sphere.y
    local r2 = sphere.r * sphere.r - dy * dy
    if r2 > 0 then circle = { x = sphere.x, z = sphere.z, r = sqrt(r2) } end
  end

  if region and not dir then
    -- A sector with only ONE region has no interior boundary, so the
    -- outermost boundary there is -- the sector's own edge -- is the one to
    -- report.
    local edge, edgeDist, edgeInside = Region.sectorEdgeBearing(origin, radius, x, y, z)
    dir, dist, inside = edge, edgeDist, edgeInside
    circle = { x = region.center.x, z = region.center.z, r = region.reach }
  end

  return {
    sectorName     = sectorName,
    sectorSeed     = seed,
    sectorIndex    = index or 0,
    radius         = radius,
    origin         = origin,
    regions        = regions,
    region         = region,
    weights        = weights,
    boundaryDir    = dir,
    boundaryDist   = dist,
    boundaryOther  = other,
    boundaryCircle = circle,
    -- False when the position is PAST the sector edge. There is nothing out
    -- there yet (no jumpgates), so the marker points back IN.
    boundaryInside = inside,
    -- Is a position in a given region? The rule is the DOMINANT region at
    -- that position -- the same rule the HUD uses to decide which region you
    -- are in, so the map and the panel cannot disagree about what is where.
    inRegion = function (r, px, py, pz)
      if not r then return false end
      local w = Region.weightsAt(regions, px, py, pz)
      local best, bestW = nil, 0
      for i = 1, #w do
        if w[i].w > bestW then bestW = w[i].w; best = w[i].region end
      end
      return best == r
    end,
  }
end

Sector.Region = Region

return Sector
