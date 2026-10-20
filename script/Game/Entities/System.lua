local ffi = require('ffi')
local Entity = require('Game.Entity')
local Dust = require('Game.Entities.Dust')
local Nebula = require('Game.Entities.Nebula')
local Frustum = require('Game.Frustum')
require('Game.Content')

local System = subclass(Entity, function (self, seed)
  self:addChildren()
  self:addProjectiles()
  self:addEconomy()

  -- NOTE : For now, we will use a flow component on the system to represent
  --        the summed net flow of all entities in the system. Seems natural,
  --        but should keep an eye on gameplay code to ensure this does not
  --        result in unexpected behavior
  self:addFlows()

  self.rng = RNG.Create(seed):managed()
  -- TODO : Will physics be freed correctly?
  self.physics = Physics.Create():managed()
  local starAngle = self.rng:getDir2()
  self.starDir = Vec3f(starAngle.x, 0, starAngle.y)
  self.nebula = Nebula(self.rng:get64(), self.starDir)
  self.dust = Dust()

  self.players = {}
  self.zones = {}

  -- Keep local-light discovery proportional to the number of lights, not the
  -- total number of System children (which includes thousands of asteroids).
  self.lightEntities = {}
  self.lightEntityIndex = {}
  self:register(Event.ChildAdded, function (system, event)
    if event.child.hasLight and event.child:hasLight() then
      system:registerLightEntity(event.child)
    end
  end)
  self:register(Event.ChildRemoved, function (system, event)
    system:unregisterLightEntity(event.child)
  end)
end)

function System:registerLightEntity (entity)
  if entity.parent ~= self or not entity.hasLight or not entity:hasLight()
     or self.lightEntityIndex[entity] then return end
  local i = #self.lightEntities + 1
  self.lightEntities[i] = entity
  self.lightEntityIndex[entity] = i
end

function System:unregisterLightEntity (entity)
  local i = self.lightEntityIndex[entity]
  if not i then return end
  local last = #self.lightEntities
  local moved = self.lightEntities[last]
  self.lightEntities[i] = moved
  self.lightEntities[last] = nil
  self.lightEntityIndex[entity] = nil
  if moved ~= entity then self.lightEntityIndex[moved] = i end
end

function System:addZone (zone)
  insert(self.zones, zone)
end

function System:getZones ()
  return self.zones
end

function System:beginRender ()
  self.nebula:forceLoad()
  ShaderVar.PushFloat3('starDir', self.starDir.x, self.starDir.y, self.starDir.z)
  ShaderVar.PushTexCube('envMap', self.nebula.envMap)
  ShaderVar.PushTexCube('irMap', self.nebula.irMap)
  -- Asteroid-field curtain (material/asteroid.glsl). Far >> Near means "no fade",
  -- which is what keeps ordinary asteroids unaffected when the field is off.
  --
  -- Pushing these unconditionally is safe despite 12's "setting a uniform the
  -- program lacks aborts" rule: Shader_Start only uploads the autovars a program
  -- DECLARED (Shader.cpp walks self->vars), so a stack entry no shader reads is
  -- simply never looked at.
  local af = self.asteroidField
  if af then
    -- getFadeBand, not the raw fields. `far` MUST be the distance beyond which
    -- no rock can be BORN, or rocks stream in already part-visible and the
    -- curtain cannot hide them -- measured at 70% of the field born over 50%
    -- visible before this was routed through the field. See
    -- AsteroidField:getFadeBand.
    local fadeNear, fadeFar = af:getFadeBand()
    ShaderVar.PushFloat('rockFadeNear', fadeNear)
    ShaderVar.PushFloat('rockFadeFar',  fadeFar)
    -- Mirror the band on the CPU so the draw path can skip rocks whose every
    -- fragment the shader would discard anyway. The eye is the camera position
    -- that the shader's length(pos - eye) is measured from.
    local cam = Camera.get()
    if cam then
      Frustum.setFadeBand(fadeNear, fadeFar, cam.pos)
    end
  else
    ShaderVar.PushFloat('rockFadeNear', 1e9)
    ShaderVar.PushFloat('rockFadeFar',  2e9)
    Frustum.setFadeBand(1e9, 2e9)
  end
end

function System:render (state)
  self:send(Event.Broadcast(state))
  self:renderProjectiles(state)
  self.dust:render(state)
  self.nebula:render(state)
end

function System:endRender ()
  ShaderVar.Pop('starDir')
  ShaderVar.Pop('envMap')
  ShaderVar.Pop('irMap')
  ShaderVar.Pop('rockFadeNear')
  ShaderVar.Pop('rockFadeFar')
end

function System:update (dt)
  -- pre-physics update
  local event = Event.Update(dt)
  Profiler.Begin('AI Update')
  for _, player in ipairs(self.players) do player:send(event) end
  Profiler.End()

  self:send(event)
  Profiler.Begin('Broadcast Update')
  self:send(Event.Broadcast(event))
  Profiler.End()

  Profiler.Begin('Physics Update')
  self.physics:update(dt)
  Profiler.End()

  self:handleRamming()
  self:sweepDestroyed()

  -- post-physics update
  event = Event.UpdatePost(dt)
  self:send(Event.Broadcast(event))
  self:send(event)
end

--[[
  sweepDestroyed -- garbage-collect dead entities
  ----------------------------------------------------------------------------
  Limit Theory has no automatic entity GC. `Entity:delete()` only sets a flag,
  and `Health.damage` only flips health to 0. Nothing removed the corpse, so a
  "destroyed" asteroid kept its rigid body in the physics world forever (you
  could still fly into it and die). This sweep fixes that: each frame it walks
  the System's direct children and removes any that are `deleted` or have
  `health <= 0`.

  `removeChild` triggers the entity's `RemovedFromParent` event, which (for a
  RigidBody) calls `physics:removeRigidBody`, pulling it out of the simulation.
  We iterate BACKWARDS because removeChild shrinks the array we are scanning.
]]
function System:sweepDestroyed ()
  local children = self.children
  if not children then return end
  for i = #children, 1, -1 do
    local e = children[i]
    if e.deleted or (e.health and e.health <= 0) then
      self:removeChild(e)
    end
  end
end

--[[
  handleRamming -- collision-based damage
  ----------------------------------------------------------------------------
  Projectiles (Pulse) are not the only way to hurt things: smashing into an
  asteroid at speed should hurt both parties. Bullet exposes the list of
  contacting rigid-body pairs via `physics:getNextCollision()`. For each pair
  we look up the owning Entity, compute the relative speed, and if it exceeds
  `rammingMinSpeed` we deal symmetric damage to both (scaled by how fast they
  hit). Enough damage destroys the asteroid, which then fragments (Asteroid's
  Event.Destroyed handler) and is swept from the world next.

  Tuning: Config.game.rammingMinSpeed (ignore gentle nudges) and
    Config.game.rammingDamageScale (how hard a crash hurts). Both were
    hardcoded at 25 and 2, which is lethal above 75 u/s against the ship's
    100 HP -- survivable against ~30 decorative rocks, not against a field.
    Set rammingDamageScale = 0 to make collision scenery.
  Note this runs AFTER physics:update, so it reads the contacts from this step.
]]
local rammingCollision = ffi.new('Collision')

function System:handleRamming ()
  -- Reset the iterator (Bullet's manifold list is walked via index/count)
  rammingCollision.index = 0
  rammingCollision.count = 0
  while self.physics:getNextCollision(rammingCollision) do
    local b0 = rammingCollision.body0
    local b1 = rammingCollision.body1
    if b0 == nil or b1 == nil then break end   -- nil body marks end-of-list

    -- Map the physics bodies back to gameplay Entities (see RigidBody.lua,
    -- which keeps a body->entity table). This is how you turn "two shapes
    -- touched" into "two game objects collided".
    local e0 = Entity.fromRigidBody(b0)
    local e1 = Entity.fromRigidBody(b1)
    if e0 and e1 then
      -- Immovable world bodies (planets are static -> mass 0) BOUNCE you; they
      -- must not ram-damage. Otherwise flying at a planet at speed dealt
      -- ~(speed-25)*2 damage, killed the only ship instantly, and (no death
      -- handling) black-screened the frame. Damage only between movable bodies.
      --
      -- `mass > 0 OR ramDamage == true` rather than mass alone. The streamed
      -- asteroid field is scenery that must NOT move, so its rocks are mass 0 --
      -- and a mass test alone would silently exempt them, i.e. you would fly
      -- through a thousand asteroids for free. Those rocks opt IN explicitly
      -- (see Asteroid.__init's `opts.static`). Strictly additive: a mass-0 body
      -- with no flag behaves exactly as before, so planet/moon protection is
      -- unchanged. A static rock's velocity reads as zero, so relSpeed is the
      -- ship's own speed, which is the correct impact speed.
      local e0ram = (b0:getMass() > 0) or (e0.ramDamage == true)
      local e1ram = (b1:getMass() > 0) or (e1.ramDamage == true)
      if e0ram and e1ram then
        -- PRE-STEP velocities, deliberately. This used to read getVelocity(),
        -- which is correct for motion and wrong for impacts: physics:update has
        -- already run stepSimulation by the time we get here, and the solver's
        -- contact impulse has removed the approach velocity. Measured on a ship
        -- flying straight into a static field rock at 100 u/s, this reported a
        -- relative speed of 15.9 against a 25 u/s threshold -- every collision in
        -- the game failed the gate and ramming damage was silently dead. The
        -- contact POSITIONS are still valid post-step (the manifold survives),
        -- it is only the velocity that the solver has spent.
        local v0 = e0:getPreStepVelocity()
        local v1 = e1:getPreStepVelocity()
        local relSpeed = v0:distance(v1)
        -- Read from Config each time rather than caching in a local, so a
        -- Config.Local override (or a future panel knob) takes effect without
        -- a code change. These are per-collision, not per-frame-hot.
        local minSpeed = Config.game.rammingMinSpeed or 25.0
        local dmgScale = Config.game.rammingDamageScale or 0.35
        if relSpeed > minSpeed then
          -- Damage scales with how far above the threshold the impact was.
          -- `e.health` is nil for non-damageable objects (e.g. Zones), so the
          -- `if e.health` guard skips them safely.
          local dmg = (relSpeed - minSpeed) * dmgScale
          if e0.health then e0:damage(dmg, e1) end
          if e1.health then e1:damage(dmg, e0) end
        end
      end
    end
  end
end

--[[
  streamAsteroidField -- load/unload asteroid chunks around the ship
  ----------------------------------------------------------------------------
  Thin wrapper so System:update stays a list of phases. The field itself lives
  in Game/Entities/AsteroidField.lua; this only resolves the ship to stream
  around and creates the field on first use.

  Streaming is driven by SHIP position, not by any random draw, and the field
  generates itself from Seed.rng per chunk -- so the shared generation stream is
  never touched and the world stays reproducible. See the module header for why
  the old clump-from-`rng:choose(children)` approach could not be streamed.
]]
function System:streamAsteroidField (ship)
  local cfg = Config.gen and Config.gen.asteroidField
  if not cfg then return end

  -- Read the field knobs from the PANEL when they exist, so the field can
  -- be switched on, re-densified and re-reached while flying -- watching a field
  -- stream in is the point of the feature, and tuning how it reads needs a
  -- slider you can move with the engine running. Falls back to Config.
  local function knob (key, fallback)
    if Settings.exists(key) then return Settings.get(key) end
    return fallback
  end
  local enabled  = knob('gen.asteroidField.enable',     cfg.enable)      or false
  local perChunk = knob('gen.asteroidField.perChunk',   cfg.perChunk)    or 0
  local loadR    = knob('gen.asteroidField.loadRadius', cfg.loadRadius)   or 4
  local fadeR    = knob('gen.asteroidField.fadeStart',  cfg.fadeStart)    or 0

  if not enabled then
    -- Turning it off UNLOADS rather than pauses: a frozen field would still cost
    -- ~2000 entities and ~2 ms every frame while the panel claims "off".
    if self.asteroidField then
      self.asteroidField:clear()
      self.asteroidField = nil
      print('[system] field: cleared')
    end
    return
  end

  if not self.asteroidField then
    local AsteroidField = require('Game.Entities.AsteroidField')
    self.asteroidField = AsteroidField.new(self, cfg)
    print(format('[system] asteroid field: chunk=%d perChunk=%.2f load=%d unload=%d radius=%d static=%s',
                 cfg.chunkSize or 2500, perChunk, loadR,
                 cfg.unloadRadius or 5, cfg.radius or 400000,
                 tostring(cfg.static ~= false)))
  end
  -- Apply the live knobs to the existing field. perChunk only affects chunks as
  -- they stream in (regenerating loaded chunks would teleport visible rocks),
  -- and loadDist likewise only changes which chunks are added from here on.
  self.asteroidField.perChunk = perChunk
  self.asteroidField.loadDist  = self.asteroidField.chunkSize * loadR
  self.asteroidField.fadeStart = self.asteroidField.chunkSize * fadeR

  -- The ship is PASSED IN, not looked up. There is no System:addPlayer: the
  -- `self.players` list is populated only by spawnAI, so with NPCs disabled it
  -- is empty and the human ship is reachable only as a System child -- which is
  -- indistinguishable from a thousand streamed rocks. LTheory.lua already
  -- resolves `player:getControlling()` each frame for handleAtmosphere, so this
  -- takes the same argument rather than inventing a second way to find it.
  --
  -- With no ship (still spawning, or after a death) there is nothing to stream
  -- around, and loading a sphere around the origin would be a large pointless
  -- allocation.
  if not (ship and ship.body) then return end

  local loaded, unloaded = self.asteroidField:update(ship:getPos())
  -- Log only when the stream actually moves, so this cannot spam the console
  -- on a stationary ship (where it would return 0 every frame).
  if loaded > 0 then
    local chunks, rocks = self.asteroidField:getStats()
    -- Keep the normal streaming log cheap. digest() sorts and walks every
    -- loaded rock; minPlanetClearance() checks every rock against every solid.
    -- Those are useful diagnostics, but doing both on each stream step turns
    -- observability into a frame-time spike as the field grows.
    print(format('[system] field: +%d/-%d chunks -> %d chunks, %d rocks (ship %.0f,%.0f,%.0f)',
                 loaded, unloaded, chunks, rocks,
                 ship:getPos().x, ship:getPos().y, ship:getPos().z))
    if os.getenv('PHX_FIELD_DIAGNOSTICS') then
      printf('[system] field diagnostics: digest=%d planetClear=%.2f',
             self.asteroidField:digest(),
             self.asteroidField:minPlanetClearance() or -1)
    end
  end
end

--[[
  handleAtmosphere -- planet atmosphere exclusion bubble
  ----------------------------------------------------------------------------
  Planets collide only as a smooth sphere at `scale`, so pressing into one
  "meshes" with the shaded surface. This is a gameplay-side bubble: any ship
  inside `scale * max(atmoScale, atmoBubbleMin)` is pushed back to that boundary
  and has its inward radial velocity removed, so it bounces off the atmosphere
  instead of grinding the planet. `ship.atmoWarning` drives the HUD banner.
]]
function System:handleAtmosphere (ship)
  if not (ship and ship.body and Config.render.planet.atmoBubble) then return end
  local minFactor = Config.render.planet.atmoBubbleMin or 1.02
  local warn = false

  local function pushOut (body)
    if not (body.typeName and body.getScale and body.getPos) then return end
    local sp = ship:getPos()
    local c  = body:getPos()
    local r  = body:getScale()
    local shell = r * math.max(body.atmoScale or 1.0, minFactor)
    local dx, dy, dz = sp.x - c.x, sp.y - c.y, sp.z - c.z
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d >= shell then return end
    local nx, ny, nz = 0, 0, 1
    if d > 1e-3 then nx, ny, nz = dx / d, dy / d, dz / d end
    -- Clamp to the shell and drop the inward radial velocity component.
    ship:setPos(Vec3f(c.x + nx * shell, c.y + ny * shell, c.z + nz * shell))
    local v = ship:getVelocity()
    local vr = v.x * nx + v.y * ny + v.z * nz        -- >0 = moving outward
    if vr < 0 then
      ship:setVelocity(Vec3f(v.x - vr * nx, v.y - vr * ny, v.z - vr * nz))
    end
    warn = true
  end

  for _, body in self:iterChildren() do
    pushOut(body)
    if body.children then
      for _, moon in ipairs(body.children) do pushOut(moon) end
    end
  end
  ship.atmoWarning = warn
end

-- Helpers For Testing ---------------------------------------------------------

local Item = require('Game.Item')

local kInventory = 100
local kStartCredits = 1000000
local kSystemScale = 10000

-- The name generator now lives in Game/NameGen, so the SECTOR, REGION,
-- STATION, OUTPOST, JUMPGATE and FIELD layers can all use it. The syllable
-- tables and the word shape are copied verbatim from the genName that used to
-- live here, so every name this world already generated is unchanged.
local NameGen = require('Game.NameGen')
local genName = NameGen.genName


function System:spawnAI (shipCount)
  local player = Entities.Player()
  for i = 1, shipCount do
    local ship = self:spawnShip()
    ship:setOwner(player)
  end
  player:addItem(Item.Credit, kStartCredits)
  player:pushAction(Actions.Think())
  insert(self.players, player)
  return player
end

--[[
  Spawn a cluster of asteroids. `count` = total rocks, `oreCount` = how many of
  the LAST `oreCount` rocks also carry a minable yield (see addYield). Each rock
  is an Entities.Asteroid(seed, scale) added both to a Zone (for grouping) and
  to the System (so it is actually simulated + rendered).

  Want a scene full of asteroids? Just call this with a big count, e.g. from
  LTheory:generate():
      self.system:spawnAsteroidField(2000, 20)
  Or spawn a single asteroid anywhere:
      local a = Entities.Asteroid(seed, scale)
      a:setPos(someVec3f)
      self.system:addChild(a)
]]
function System:spawnAsteroidField (count, oreCount)
  local rng = self.rng
  local zone = Entities.Zone(format('%s Field', genName(rng)))
  zone.pos = rng:getDir3():scale(kSystemScale * (1.0 + rng:getExp()))

  for i = 1, count do
    local pos
    if i == 1 then
      -- first rock anchors the cluster at the zone center
      pos = zone.pos
    else
      -- subsequent rocks are placed near a randomly chosen existing rock, so
      -- the field clumps naturally instead of scattering evenly
      pos = rng:choose(zone.children):getPos()
      pos = pos + rng:getDir3():scale((0.1 * kSystemScale) * rng:getExp() ^ rng:getExp())
    end

    -- scale is 2..~5 (exp distribution). Smaller == lower health (see Asteroid).
    local scale = 2 + 3 * rng:getExp()
    local asteroid = Entities.Asteroid(rng:get31(), scale)
    asteroid:setPos(pos)
    asteroid:setScale(scale)
    asteroid:setRot(rng:getQuat())

    -- Mark the last `oreCount` rocks as ore-bearing (mineable later)
    if i > (count - oreCount) then
      asteroid:addYield(rng:choose(Item.T1), 1.0)
    end

    zone:add(asteroid)
    self:addChild(asteroid)   -- <-- this is what puts it in the live world
  end
  self:addZone(zone)
end

function System:spawnPlanet ()
  local rng = self.rng
  local planet = Entities.Planet(rng:get64())

  -- DRAW ORDER IS DELIBERATE. These two draws happen in the same sequence as
  -- before W8 (exp, then Erlang), because this rng stream is shared with the rest
  -- of generation: reordering them silently RESHUFFLES every existing world --
  -- a planet that was at 42520 moved to 23001 purely because the radius was
  -- drawn first. The distance still depends on the radius without needing a
  -- different order; only the DRAW SEQUENCE has to be preserved.
  local expDraw = rng:getExp()
  local base = Config.gen.scalePlanet or Config.gen.planetScaleBase or 1e5
  -- Erlang(2), capped so the far side stays inside the 1e6 far plane at the
  -- ship's stand-off (see Config.gen.planetRadiusMax).
  local scale = math.min(base * rng:getErlang(2),
                          Config.gen.planetRadiusMax or 400000)

  -- Placement distance now also accounts for the RADIUS. The belt and stations
  -- live within kSystemScale, so a planet whose radius approaches its own
  -- distance from the origin engulfs them -- which is exactly what happened:
  -- the old base (1e5, mean radius ~200k) against kSystemScale = 10000 made every
  -- planet ~20x the system it sat in. Deriving clearance from the radius means NO
  -- scalePlanet value can produce an engulfing planet, rather than relying on
  -- the player picking a safe number. With the smaller planets W8 introduces,
  -- this term normally LOSES to the kSystemScale term, so most positions stay
  -- put.
  local clearance = Config.gen.planetClearance or 2.5
  local dist = math.max(kSystemScale * (1.0 + expDraw), scale * clearance)
  local pos = rng:getDir3():scale(dist)
  planet:setPos(pos)
  planet:setScale(scale)
  planet:setName(genName(rng))
  self:addChild(planet)

  -- Moons (planets-work Phase B): a few per planet, orbiting + tidally locked.
  local nMoons = Config.gen.nMoons and Config.gen.nMoons(rng) or 0
  for i = 1, nMoons do self:spawnMoon(planet, i) end
  -- `clouds` is the RESOLVED coverage for this world (see Planet:cloudCoverage):
-- the type's prior x the panel multiplier plus this planet's own seeded bias. It
-- is not the panel's Coverage slider value, and it is what actually decides how
-- cloudy the planet renders -- so logging it means every seed tells you its own
-- weather without a capture harness. Also log the two inputs (weather, cloudLevel)
-- and the planet's generator seed, which is what makes a reported world
-- reproducible from the log line alone.
  -- `clear` is the margin between the planet's SURFACE and the system's own
  -- extent: positive means the belt/stations are outside this planet. It is
  -- logged because W8's bug was planets engulfing the system, and that is
  -- invisible until you print the two numbers side by side.
  -- `surf` is the distance from the system ORIGIN to the planet's surface, which
  -- is what "engulfing" means: W8's bug was radius (~200k) exceeding the planet's
  -- own distance (~20k), so the origin was INSIDE the planet and the belt was
  -- swallowed. surf > 0 means the origin is outside. It is deliberately NOT
  -- measured against kSystemScale -- that measures proximity to the belt, and a
  -- small planet sitting among the asteroids is fine, not a failure. (The first
  -- version of this metric used kSystemScale and reported a healthy radius-1008
  -- planet at 10183 as "clear=-825", which reads like engulfment and is not.)
  --
  -- Vec3 exposes :length() as a METHOD; there is no `.magnitude` field, and an
  -- `or 0.0` fallback on a nil field would have logged a plausible-looking zero
  -- instead of failing -- the same "field nobody reads" trap as the unused
  -- genColor channel.
  -- Named locals, not anonymous functions inside the argument list. This line
  -- carries every per-world number needed to reproduce a reported view, so it is
  -- read and diffed constantly; it used to be one 19-specifier format call with
  -- an inline (function () ... end)() and six repeated `or Vec3f(...)`
  -- fallbacks, which made the field order impossible to check against the
  -- specifier order by eye -- and specifier/argument order is exactly how a
  -- silent transposition hides. Each value now has a name at the point it is
  -- derived, and the specifier order is visible next to its argument.
  local planetDist = planet:getPos():length()
  local spinRad     = planet.spinSpeed or 0.0
  -- Period in minutes. Zero/absent spin logs 0 rather than dividing by zero.
  local spinPeriodMin = (spinRad > 0) and (2 * math.pi / spinRad) / 60.0 or 0.0
  -- Ring summary. ringParams() is a pure getter, so building this first does not
  -- change what the later getters observe.
  local ringDesc
  do
    local r = planet:ringParams()
    if r then
      ringDesc = format('%.2f-%.2f R  ice=%.2f  opacity=%.2f',
                        r.inner, r.outer, r.ice, r.opacity)
    else
      ringDesc = format('none (roll %.2f, type %.2f)',
                        planet.ringRoll or 1.0, planet.ringType or 0.0)
    end
  end
  -- spinAxis and starDir are logged so a reported cloud/ring orientation and
  -- direct-light direction can be reproduced from the boot line.
  local spinAxis = planet.spinAxis or Vec3f(0, 1, 0)
  local starDir  = self.starDir   or Vec3f(1, 0, 0)

  print(format('[system] planet %s  type=%s  moons=%d  radius=%.0f  at=%.0f  surf=%+.0f  clouds=%.2f (weather %.2f + bias %+.2f)  spin=%.4f rad/s (%.1f min)  ring=%s  seed=%.6f  pos=(%.1f,%.1f,%.1f)  axis=(%.2f,%.2f,%.2f)  star=(%.2f,%.2f,%.2f)',
    planet:getName(), tostring(planet.typeName), nMoons, scale,
    planetDist,
    planetDist - scale,
    planet:cloudCoverage(), planet.weather or 0.0, planet.cloudLevel or 0.0,
    spinRad, spinPeriodMin, ringDesc,
    planet.genSeed or 0,
    pos.x or 0.0, pos.y or 0.0, pos.z or 0.0,
    spinAxis.x, spinAxis.y, spinAxis.z,
    starDir.x, starDir.y, starDir.z))
  return planet
end

local kRoman = { 'I', 'II', 'III', 'IV', 'V', 'VI' }

-- A moon is a Planet in a lower detail band that orbits (and faces) its parent.
function System:spawnMoon (planet, index)
  local rng = self.rng
  local cfg = Config.render.planet.moon
  local radius = math.min(planet:getScale() * cfg.orbit(rng), cfg.orbitMax or math.huge)
  -- Never inside the planet: a huge planet's radius can exceed orbitMax.
  radius = math.max(radius, planet:getScale() * 1.5)
  local moon = Entities.Planet(rng:get64(), {
    detail      = 4,
    cubeRes     = 512,
    mass        = 100,
    parent      = planet,
    orbitRadius = radius,
  })
  -- Floor is a FRACTION of the parent (see Config.App): an absolute floor gave
  -- a small planet moons nearly its own size once W8 shrank planets.
  local pScale = planet:getScale()
  moon:setScale(math.max(pScale * cfg.scale(rng), pScale * (cfg.minRadiusFrac or 0.03)))
  moon:setName(planet:getName() .. ' ' .. (kRoman[index] or tostring(index)))
  moon:setPos(planet:getPos() + Vec3f(radius, 0, 0))
  -- Parent the moon to its PLANET (not the system) so the map groups it under
  -- the planet (revealed by drilling, like zone members) instead of stranding
  -- it far off-screen as its own node. The planet shares the system physics
  -- world so the moon's body still enters the simulation, and `addChildren`
  -- enables event forwarding (Update/Render) down to the moon.
  if not planet.children then planet:addChildren() end
  if not planet.physics then planet.physics = self.physics end
  planet:addChild(moon)
  return moon
end

function System:spawnShip ()
  if not self.shipType then
    self.shipType = ShipType(self.rng:get31(), Gen.Ship.ShipFighter, 4)
  end
  local ship = self.shipType:instantiate()
  ship:setInventoryCapacity(kInventory)
  ship:setPos(self.rng:getDir3():scale(kSystemScale * (1.0 + self.rng:getExp())))
  self:addChild(ship)

  if true then
    while true do
      local thruster = Entities.Thruster()
      thruster:setScale(0.5 * ship:getScale())
      -- TODO : Does this leak a Thruster/RigidBody?
      if not ship:plug(thruster) then break end
    end
  end
  if true then
    while true do
      local turret = Entities.Turret()
      turret:setScale(2 * ship:getScale())
      -- TODO : Does this leak a Turret/RigidBody?
      if not ship:plug(turret) then break end
    end
  end
  return ship
end

function System:spawnStation ()
  local station = Entities.Station(self.rng:get31())
  local p = self.rng:getDisc():scale(kSystemScale)
  station:setPos(Vec3f(p.x, 0, p.y))
  station:setScale(100)
  -- station:setFlow(Item.Silver, self.rng:getUniformRange(-1000, 0))
  station:addMarket()
  station:addTrader()

  local prod = self.rng:choose(Production.All())
  station:addFactory()
  station:addProduction(prod)
  station:setName(format('%s %s',
    genName(self.rng),
    prod:getName()))
  self:addChild(station)
  return station
end

return System
