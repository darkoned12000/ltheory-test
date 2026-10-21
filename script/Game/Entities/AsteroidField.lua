--[[ Asteroids.AsteroidField -- an endless, chunk-streamed asteroid field.

  WHY THIS EXISTS
  The previous field (System:spawnAsteroidField) built a fixed cluster of N
  rocks once, at world generation. It also placed every rock relative to a
  randomly CHOSEN existing rock:

      pos = rng:choose(zone.children):getPos() + rng:getDir3():scale(...)

  which is a lovely way to make a natural clump and a terrible way to make a
  STREAMING field, for two reasons:

    1. It is order-dependent over the whole field, so it cannot be reproduced
       per chunk. Chunk 5 cannot be generated without having generated 1..4.
    2. It draws from System.rng, the shared generation stream. Streaming means
       consuming draws as the player flies, which is precisely the bug this
       project already paid for once -- two draws swapping order moved a planet
       from 42520 to 23001 and reshuffled the entire world.

  So the field is generated PER CHUNK from Seed.rng('asteroidField', <chunk>).
  That makes each chunk a pure function of (worldSeed, chunkX, chunkY, chunkZ):
  loading chunk B cannot perturb chunk A, flying away and back reproduces the
  identical field, and nothing here touches the shared stream. Clumping is kept
  (it is what makes a field read as a field rather than as gravel), but it is
  now clumping WITHIN a chunk, driven by that chunk's own RNG.

  BOUNDS. The field is bounded to a radius around the system origin rather than
  being literally infinite. Your system has a real extent (kSystemScale = 10000,
  planets at 1e4..3e4), and a field you can leave forever dissolves the system
  boundary -- you could fly out until the end of time and never arrive anywhere.
  Bounded-and-large reads as endless from inside it, which is the illusion you
  actually want. Set radius = 0 for unbounded.

  ROCKS DO NOT MOVE. They are static bodies (mass 0, the same idiom planets
  already use). That is both correct for scenery and much cheaper than 1000
  dynamic bodies: a zero-mass body is not integrated and never deactivates.
  See Asteroid.__init's `opts.static` and System:handleRamming for the one
  gameplay consequence, which is that a mass test alone would silently exempt
  these rocks from ramming damage -- they carry an explicit `ramDamage` flag
  instead.
]]

-- Require the constructor module DIRECTLY rather than going through
-- requireAll('Game.Entities'): requireAll recurses the whole directory, and this
-- file lives in it, so that would be a circular require of itself.
local Asteroid = require('Game.Entities.Asteroid')
local Seed     = require('Game.Seed')

local AsteroidField = {}
AsteroidField.__index = AsteroidField

local StreamTag = 'asteroidField'

-- Mix three signed cell coordinates into one non-negative integer below 2^53,
-- so it survives as an exact LuaJIT number and can be fed to Seed.tag as a
-- salt. Wrapping multiply-add only; no bit ops, matching Seed.tag's own rule.
local function chunkSalt (cx, cy, cz)
  local h = 0x9E3779B1
  h = (h * 31 + cx) % 0x7FFFFFFF
  h = (h * 31 + cy) % 0x7FFFFFFF
  h = (h * 31 + cz) % 0x7FFFFFFF
  return h
end

function AsteroidField.new (system, opts)
  opts = opts or {}
  local self = setmetatable({
    system      = system,
    -- key -> { cx, cy, cz, rocks = { ... } }
    chunks      = {},
    loadedCount = 0,
  }, AsteroidField)

  self.chunkSize  = opts.chunkSize  or 2500
  self.streamTag  = opts.streamTag or StreamTag

  -- Streaming radii are resolved to WORLD UNITS here and measured to a chunk's
  -- CENTRE with a EUCLIDEAN test.
  --
  -- They used to be a chunk count tested with CHEBYSHEV distance, which loads
  -- the whole (2L+1)^3 cube -- so the boundary was sqrt(3)x further out in the
  -- corners than along the axes and "loadRadius" did not mean what it said.
  --
  -- Why world units at all: the boundary has to sit OUTSIDE visual range, and
  -- visual range is a distance. Measured -- the camera's far plane is
  -- zFar = 1e6 (Util/Camera.lua:13), i.e. there is NO distance cutoff, so any
  -- boundary inside ~20000 units is genuinely visible. Confirmed by capture:
  -- raising the radius from 3 to 6 chunks changed 10380 pixels, so the
  -- 7500..15000 band is on screen. Distances stay expressed as multiples of
  -- chunkSize for readability, and the multiples are REQUIRED to be ordered
  -- fadeStart < load < unload or the fade band does not exist.
  local lr = opts.loadRadius  or 8
  local ur = opts.unloadRadius or 9
  local fs = opts.fadeStart   or 6
  self.loadDist   = self.chunkSize * lr
  self.unloadDist = self.chunkSize * ur
  self.fadeStart  = self.chunkSize * fs

  self.perChunk   = opts.perChunk   or 6
  self.radius     = opts.radius     or 400000
  -- Rock size. These are WORLD units on the entity scale, and the generated
  -- mesh's collision/visual radius comes out at roughly 0.54 * scale, so:
  --   scale 40 -> radius ~21, scale 180 -> radius ~97.
  -- Why so large? A rock only reads if it covers a few pixels. At 1280 px over
  -- an 80 deg FOV one pixel is ~0.0625 deg, so a rock needs radius
  -- ~0.0044 * distance to cover ~4 px: at 2000 units that is ~9, and at the
  -- far edge of the loaded field (~10000 units) it is ~44. The original range
  -- of 2..9 therefore rendered a field that was measurably INVISIBLE -- capture
  -- with the field on vs off differed by 600 px against a 309 px noise floor.
  -- The old 30-rock visibility cloud used scale 250 for the same reason.
  self.minScale   = opts.minScale   or 40
  self.maxScale   = opts.maxScale   or 180
  self.clumpChance = opts.clumpChance or 0.65
  self.clumpRadius  = opts.clumpRadius  or 0.18   -- fraction of chunkSize
  -- Fraction of rocks that get a 2..4x multiplier on top of their exponential
  -- base size. At ~2000 rocks, 0.05 gives ~100 large ones spread over a
  -- 10000-unit sphere, so a handful are in view at a time -- landmarks rather
  -- than clutter. 0 disables the tier.
  self.largeChance  = opts.largeChance  or 0.05
  -- Soft bound on the exponential size draw: u = E / (E + sizeSoftCap) maps the
  -- unbounded exponential into [0,1) without ever saturating, so the size
  -- distribution has no spike at maxScale. See generateChunk. Larger = the mass
  -- sits lower in the range and big rocks are rarer.
  --
  -- 0.7 was chosen against the earlier 10000-unit visibility target. Measured
  -- over 200k draws: median scale 155 (radius ~84). At the new ~27k fade edge
  -- that is about 3px across; large-tier landmarks remain legible farther out.
  -- Raising this value pushes more of the field to small sizes, so distant
  -- asteroids become specks and the field reads sparser.
  self.sizeSoftCap  = opts.sizeSoftCap  or 0.7
  -- Ceiling for the rare large tier ONLY. Deliberately above maxScale: a
  -- landmark rock has to be able to exceed the biggest ordinary one, which is
  -- the entire point of the tier.
  self.largeMaxScale = opts.largeMaxScale or self.maxScale * 3
  -- Fade is evaluated per fragment in the asteroid shader, not at the entity
  -- centre. Include the biggest possible rendered rock radius as well as the
  -- cell half-diagonal, so the nearest surface point of any newly loaded rock
  -- is still beyond the fade's far edge. The extra 32 units cover float and
  -- interpolation error at the boundary.
  self.spawnMargin = 0.5 * math.sqrt(3) * self.chunkSize
                   + 0.6 * self.largeMaxScale + 32
  self.oreChance  = opts.oreChance  or 0.0
  -- Rocks are immovable by default (see the module header). `static = false`
  -- gives back dynamic bodies with mass and drag, which is how every asteroid
  -- behaved before -- useful for A/B-ing the physics cost, not for scenery.
  self.static     = (opts.static ~= false)
  -- How far outside a planet's surface a rock may sit. Planets collide as a
  -- smooth sphere at `scale`, so anything nearer is inside the collision hull
  -- even though the shaded mesh may bulge past it.
  self.planetMargin = opts.planetMargin or 1500

  return self
end

function AsteroidField:chunkOf (x, y, z)
  local cs = self.chunkSize
  return math.floor(x / cs), math.floor(y / cs), math.floor(z / cs)
end

--[[ getFadeBand -- the (near, far) the renderer should use for the curtain.

  THE POP. A rock that is born part-way through the fade band appears at that
  partial visibility and the curtain cannot hide it -- it only hides the
  boundary, not a spawn inside itself. Measured before this was fixed, with the
  old centre-distance load test: of 2400 spawned rocks, 70% were born more than
  50% visible and the worst case was 100% visible.

  Chunks are loaded by CENTRE distance. Since generated rocks stay inside their
  cell, every rock in a loaded chunk is at least `centerDistance - spawnMargin`
  from the ship. Therefore the nearest possible birth distance is
  `loadDist - spawnMargin`; `far` must be no greater than that:

      far = loadDist - spawnMargin

  Derived here rather than stored, so it cannot drift out of step with the load
  test if that test is ever changed.

  Keep the far edge outside the band if the load radius is adjusted live. ]]
function AsteroidField:getFadeBand ()
  local far = math.max(1, self.loadDist - self.spawnMargin)
  -- Keep a non-zero transition even if the live slider is moved too close to
  -- Reach. 1000 units is the shortest band offered by the control, avoiding an
  -- accidental near-instant pop while still allowing a much quicker dissolve.
  local minWidth = math.min(1000, far)
  local near = math.max(0, math.min(self.fadeStart, far - minWidth))
  return near, far
end

-- Every solid body that must not have rocks inside it. Planets are direct
-- children of the System and moons hang off them, which is the same traversal
-- handleAtmosphere already uses -- duck-typed on typeName rather than on class,
-- because this codebase has no reliable class introspection.
--
-- Re-read on every chunk generation rather than cached: bodies are added and
-- removed during play (and moons orbit), and a cached exclusion list is exactly
-- the kind of stale-data bug that only shows up as "a rock is inside a planet".
function AsteroidField:solids ()
  local out = {}
  for _, body in self.system:iterChildren() do
    if body.typeName and body.getScale and body.getPos then
      out[#out + 1] = body
      if body.children then
        for _, moon in ipairs(body.children) do
          if moon.typeName and moon.getScale and moon.getPos then
            out[#out + 1] = moon
          end
        end
      end
    end
  end
  return out
end

-- Is this position clear of every solid body?
function AsteroidField:isClear (solids, x, y, z)
  for i = 1, #solids do
    local b  = solids[i]
    local bp = b:getPos()
    local bx, by, bz = bp.x, bp.y, bp.z
    local r  = b:getScale() + self.planetMargin
    local dx, dy, dz = x - bx, y - by, z - bz
    if dx * dx + dy * dy + dz * dz < r * r then return false end
  end
  return true
end

--[[ Generate one chunk's rocks. Deterministic in (worldSeed, cx, cy, cz).

  Clumping is preserved but scoped: the first rock of a chunk is placed
  uniformly in the chunk, and each subsequent rock either joins a previously
  placed rock in THIS chunk (clumpChance) or is scattered uniformly. The old
  code chose from `zone.children`, i.e. from the entire field built so far --
  which is precisely what cannot be reproduced per chunk. ]]
function AsteroidField:generateChunk (cx, cy, cz, solids)
  local rng  = Seed.rng(self.streamTag, chunkSalt(cx, cy, cz))
  local cs   = self.chunkSize
  local ox, oy, oz = cx * cs, cy * cs, cz * cs
  -- update() passes a snapshot shared by all chunks generated in that scan.
  -- Rewalking the whole System child list per chunk made a boundary crossing
  -- O(newChunks * alreadyLoadedEntities), even though planets do not change
  -- during the scan.
  solids = solids or self:solids()

  local rocks = {}
  -- The region's CHARACTER (13f): a "Shattered Belt" region is a rock field
  -- and a "Deep Field" is not.
  --
  -- The density comes from the same field the gas and the lightning read, so
  -- the three cannot disagree about what kind of place this is -- which is
  -- the whole point of having one field (29a). It is sampled at the chunk's
  -- CENTRE and baked in: the chunk is generated once and cached, so the
  -- field must not change under it, and the regions do not change within a
  -- sector.
  local rockScale = 1
  local oreChance = 0
  local regions = self.system and self.system.sectorRegions
  if regions and #regions > 0 then
    local Sector = require('Game.Region')
    local f = Sector.Region.field(regions, ox + cs * 0.5, oy + cs * 0.5, oz + cs * 0.5)
    -- The archetype's `rocks` runs 0.15..0.95, so this is a 0.55x..1.6x
    -- multiplier: a belt is about three times rockier than a deep field.
    rockScale = 0.35 + f.rocks * 1.3
    -- The ORE, which is the whole reason a belt is worth riding a lane to.
    -- It comes from the same field as the density, so the ore is IN the
    -- belts and nowhere else, and the lanes lead to the belts.
    oreChance = f.ore
  end

  -- `perChunk` is a density control and the settings panel stores it as a
  -- float. Honour fractional values deterministically per chunk rather than
  -- silently truncating them in Lua's numeric for loop.
  local perChunk = self.perChunk * rockScale
  local rockCount = math.floor(perChunk)
  if rng:getUniform() < perChunk - rockCount then
    rockCount = rockCount + 1
  end
  for i = 1, rockCount do
    local x, y, z
    local clustered = #rocks > 0 and rng:getUniform() < self.clumpChance
    if clustered then
      local anchor = rocks[rng:getInt(1, #rocks)]
      local spread = self.clumpRadius * cs
      local offset = rng:getSphere():scale(spread)
      x = anchor.pos.x + offset.x
      y = anchor.pos.y + offset.y
      z = anchor.pos.z + offset.z
    else
      x = ox + (rng:getUniform() - 0.5) * cs
      y = oy + (rng:getUniform() - 0.5) * cs
      z = oz + (rng:getUniform() - 0.5) * cs
    end

    -- A clump is a random walk if each rock anchors the next. Without this
    -- clamp, a chain of individually small offsets can wander arbitrarily far
    -- outside its nominal chunk and invalidate the loader/fade distance bound.
    -- Clamping preserves local clustering while making the cell boundary real.
    x = math.max(ox, math.min(ox + cs, x))
    y = math.max(oy, math.min(oy + cs, y))
    z = math.max(oz, math.min(oz + cs, z))

    -- Bounds: a rock whose CENTRE is outside the field radius would still show
    -- a mesh poking into it, and at radius 60000 that is not visible in
    -- practice -- but the check keeps the field a true sphere.
    if self.radius > 0 then
      if x * x + y * y + z * z > self.radius * self.radius then goto continue end
    end

    -- Planet clearance. Rejected, not re-rolled: a fixed decision rule is what
    -- keeps the chunk reproducible, and a rock that fails clearance is simply
    -- absent from this world.
    if not self:isClear(solids, x, y, z) then goto continue end

    -- Size: an exponential draw mapped through a SOFT bound.
    --
    -- rng:getExp() is unbounded (exponential, mean 1), so the obvious
    -- `min(max, min + (max-min)*E)` piles a huge mass onto exactly one value.
    -- Measured on the real Config values (minScale 12, maxScale 300): E >= 1
    -- already reaches maxScale, and P(E >= 1) = 1/e = 36.8%, so 38.5% of the
    -- entire field was rendering at *exactly* scale 300. Nearly two rocks in
    -- five were the same object, and the size knob did nothing until the range
    -- was wide enough for the tail to fit.
    --
    -- u = E / (E + k) maps [0, inf) into [0, 1) smoothly: still monotonically
    -- decreasing (so most rocks stay small and a few are large, which is what
    -- makes a field read as a field), but it never saturates, so no two draws
    -- collapse onto one size. See sizeSoftCap for how k was chosen.
    local E = rng:getExp()
    local u = E / (E + self.sizeSoftCap)
    local scale = self.minScale + (self.maxScale - self.minScale) * u
    -- Rare large tier. Play-tested feedback: the field had small and medium
    -- rocks but nothing that felt like a landmark -- "can we produce large
    -- asteroids 2-4x the size of some of the larger ones I see, somewhat rare
    -- but you should see a few when you are flying". A flat size range cannot
    -- do that (raising maxScale just makes EVERY rock bigger), so the large
    -- rocks are a separate, low-probability draw that MULTIPLIES an already
    -- exponential base size.
    --
    -- This used to clamp the multiplied result back to maxScale, which made the
    -- tier DEAD: since the base draw was already clamped, ~38% of bases sat at
    -- exactly maxScale and 100% of large-tier draws were multiplied back down
    -- to it, so a "2-4x" landmark rock was indistinguishable from an ordinary
    -- one. The ceiling for a landmark is therefore its own value,
    -- largeMaxScale, not maxScale.
    if self.largeChance > 0 and rng:getUniform() < self.largeChance then
      scale = scale * (2.0 + 2.0 * rng:getUniform())
      if scale > self.largeMaxScale then scale = self.largeMaxScale end
    end
    local asteroid = Asteroid(rng:get31(), scale, { static = self.static })
    asteroid:setPos(Vec3f(x, y, z))
    asteroid:setRot(rng:getQuat())
    -- The ORE: whether this rock is worth mining comes from the region's
    -- character, so the ore is in the BELTS and the lanes are worth riding
    -- to get to it. A belt region's rock is ore nine times in ten; a deep
    -- field's is one time in ten.
    --
    -- The draw is from the chunk's own rng, so a chunk's ore is fixed once
    -- it is generated and does not change under the player.
    if oreChance > 0 and rng:getUniform() < oreChance then
      -- Which commodity, from the game's own list (Content.lua's T1), so
      -- the belts yield what the rest of the economy is built around: the
      -- isotopes are the reactors' fuel, the silver is the money.
      local Item = require('Game.Item')
      asteroid:addYield(rng:choose(Item.T1), 1.0)
    end
    -- Remember the generating position (NOT the entity's live position) so
    -- clumping anchors stay put even if a rock is later destroyed.
    rocks[#rocks + 1] = { entity = asteroid, pos = Vec3f(x, y, z) }
    self.loadedCount = self.loadedCount + 1

    ::continue::
  end

  local chunk = { cx = cx, cy = cy, cz = cz, rocks = rocks }
  self.chunks[chunkSalt(cx, cy, cz)] = chunk
  return chunk
end

function AsteroidField:unloadChunk (chunk)
  for i = 1, #chunk.rocks do
    local entity = chunk.rocks[i].entity
    if entity.parent then
      self.system:removeChild(entity)
    end
    self.loadedCount = self.loadedCount - 1
  end
  chunk.rocks = {}
end

--[[ NO LONGER HERE: a scale-based fade.

  The first implementation shrank each rock linearly as it approached the stream
  boundary. Play-testing rejected it on two counts:

    * "it's very obvious the asteroids are growing in front of me instead of
      slightly getting bigger as I get closer" -- scaling a rock to hide it makes
      it visibly inflate IN PLACE, which reads as an animation rather than as
      distance. Quantising to 1/16 steps (to stop the per-frame collision-shape
      reallocation, see 12) made it worse, not better: it turned a smooth grow
      into visible steps.
    * It was also the lockup. `RigidBody_SetScale` allocates a new
      btCollisionShape, swaps it into the body (invalidating the broadphase
      proxy, so the AABB recomputes) and recalculates inertia -- so animating
      scale per frame reallocated a shape for every rock in the band every frame,
      and flying up to a rock puts you INSIDE the band, so approaching one made
      it worse until the game hung.

  The curtain is now a FRAGMENT DISCARD in material/asteroid.glsl, driven by
  rockFadeNear/rockFadeFar pushed from System:beginRender. A rock is always at
  its true size and is simply not drawn until you are close enough. Nothing here
  touches an entity, so there is no physics interaction at all -- and because the
  discard happens before any sampling or G-buffer write, the far rocks that make
  up the bulk of the field cost one distance calculation each. That is what makes
  a dense field affordable. ]]

--[[ Load/unload around `shipPos`. Returns (touched, unloaded).

  Load and unload use the same Euclidean centre-distance test with different
  radii, which is what produces hysteresis: a ship loitering near the boundary
  cannot thrash, because a chunk is only dropped once it is past unloadDist,
  which is strictly beyond the distance at which it would have been re-added. ]]
function AsteroidField:update (shipPos)
  local cs = self.chunkSize
  local px, py, pz = shipPos.x, shipPos.y, shipPos.z

  -- Chunk membership does not need a full neighborhood scan every frame. Scan
  -- after 250 world units of travel (or immediately when a live stream setting
  -- changes). The candidate radius is expanded by that same interval, so a
  -- chunk that crossed the normal load radius between scans is still loaded
  -- early, never late relative to the fade.
  local scanStep = math.min(250, cs * 0.1)
  local lastX, lastY, lastZ = self.lastScanX, self.lastScanY, self.lastScanZ
  if lastX ~= nil
     and self.lastScanLoadDist == self.loadDist
     and self.lastScanUnloadDist == self.unloadDist
     and self.lastScanPerChunk == self.perChunk then
    local dx, dy, dz = px - lastX, py - lastY, pz - lastZ
    if dx * dx + dy * dy + dz * dz < scanStep * scanStep then
      return 0, 0
    end
  end
  self.lastScanX, self.lastScanY, self.lastScanZ = px, py, pz
  self.lastScanLoadDist = self.loadDist
  self.lastScanUnloadDist = self.unloadDist
  self.lastScanPerChunk = self.perChunk

  local ccx, ccy, ccz = self:chunkOf(px, py, pz)
  local ld, ud = self.loadDist, self.unloadDist
  local ud2 = ud * ud
  local touched = 0

  -- Load chunks by CENTRE distance. With rocks clamped to their cell, the
  -- half-diagonal bound is exact and getFadeBand places the end of the fade
  -- before the nearest possible newly loaded rock.
  local loadLimit = ld + scanStep
  local loadLimit2 = loadLimit * loadLimit
  local r = math.ceil(loadLimit / cs) + 1
  local solids
  for dx = -r, r do
    for dy = -r, r do
      for dz = -r, r do
        local cx, cy, cz = ccx + dx, ccy + dy, ccz + dz
        local ox = (cx + 0.5) * cs - px
        local oy = (cy + 0.5) * cs - py
        local oz = (cz + 0.5) * cs - pz
        if ox * ox + oy * oy + oz * oz <= loadLimit2
           and not self.chunks[chunkSalt(cx, cy, cz)] then
          if not solids then solids = self:solids() end
          local chunk = self:generateChunk(cx, cy, cz, solids)
          for i = 1, #chunk.rocks do
            self.system:addChild(chunk.rocks[i].entity)
          end
          touched = touched + 1
        end
      end
    end
  end

  -- Unload: strictly beyond unloadDist. Collected first so nothing is freed
  -- while the table is being walked.
  local doomed = {}
  for key, chunk in pairs(self.chunks) do
    local ox = (chunk.cx + 0.5) * cs - px
    local oy = (chunk.cy + 0.5) * cs - py
    local oz = (chunk.cz + 0.5) * cs - pz
    if ox * ox + oy * oy + oz * oz > ud2 then
      doomed[#doomed + 1] = chunk
    end
  end
  for i = 1, #doomed do
    local c = doomed[i]
    self:unloadChunk(c)
    self.chunks[chunkSalt(c.cx, c.cy, c.cz)] = nil
    touched = touched + 1
  end

  return touched, #doomed
end

function AsteroidField:getStats ()
  local n = 0
  for _ in pairs(self.chunks) do n = n + 1 end
  return n, self.loadedCount
end

-- Unload every chunk and reset. Used by the panel's off switch, so that turning
-- the field off actually gives the ~2000 entities and ~2 ms back rather than
-- freezing them in place.
function AsteroidField:clear ()
  for _, chunk in pairs(self.chunks) do self:unloadChunk(chunk) end
  self.chunks = {}
  self.loadedCount = 0
end

--[[ A stable digest of every loaded rock's generating position.

  The streaming field's whole correctness argument is "a chunk is a pure
  function of (worldSeed, cell)". That is easy to break by accident -- one stray
  draw from the shared stream, one `pairs()` iteration used for generation --
  and the symptom is not a crash, it is a field that quietly rearranges itself
  as you fly. This digest makes that checkable: two runs of the same seed at
  the same ship position must print the same number, and a run at a different
  ship position must NOT (it has a different chunk set).

  Positions are accumulated in a canonical order (sorted by chunk key) so the
  digest does not depend on `pairs()` iteration order, which is unspecified. ]]
function AsteroidField:digest ()
  local keys = {}
  for key in pairs(self.chunks) do keys[#keys + 1] = key end
  table.sort(keys)

  -- Kept inside 2^31 EVERY step. FNV's usual 0xCBF29CE484222325 seed is above
  -- 2^53, so on LuaJIT it silently becomes a double, loses the low bits, and
  -- prints something like -9223372036854775808 (int64 overflow) -- a digest
  -- that is neither stable nor comparable. Modding each step keeps h*31 below
  -- 2^36, exact in a double. Lua's `%` takes the sign of the dividend and
  -- coordinates are negative, hence the normalisation.
  local MOD = 0x7FFFFFFF
  local function mix (h, v)
    h = (h * 31 + v) % MOD
    if h < 0 then h = h + MOD end
    return h
  end

  local h = 0
  for _, key in ipairs(keys) do
    local chunk = self.chunks[key]
    h = mix(h, chunk.cx); h = mix(h, chunk.cy); h = mix(h, chunk.cz)
    h = mix(h, #chunk.rocks)
    for i = 1, #chunk.rocks do
      local p = chunk.rocks[i].pos
      h = mix(h, math.floor(p.x))
      h = mix(h, math.floor(p.y))
      h = mix(h, math.floor(p.z))
    end
  end
  return h
end

-- Closest approach of any loaded rock to any solid body's surface, as a
-- fraction of that body's radius. Should be >= 1 for every rock (planetMargin
-- is extra). Returns the minimum margin seen, so a value below 1 means a rock
-- is inside a planet -- the W8 bug class, and the reason this check exists.
function AsteroidField:minPlanetClearance ()
  local solids = self:solids()
  if #solids == 0 then return nil end
  local worst = nil
  for _, chunk in pairs(self.chunks) do
    for i = 1, #chunk.rocks do
      local p = chunk.rocks[i].pos
      for j = 1, #solids do
        local b = solids[j]
        local c = b:getPos()
        local dx, dy, dz = p.x - c.x, p.y - c.y, p.z - c.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        local frac = d / b:getScale()
        if worst == nil or frac < worst then worst = frac end
      end
    end
  end
  return worst
end

return AsteroidField
