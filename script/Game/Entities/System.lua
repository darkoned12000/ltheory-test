local ffi = require('ffi')
local Entity = require('Game.Entity')
local Dust = require('Game.Entities.Dust')
local Nebula = require('Game.Entities.Nebula')
local Frustum = require('Game.Frustum')
-- THE RECIPES ARE LOAD-TIME SCOPE: this file loaded under the kernel
-- require once, Content registered its recipes on THAT copy of the
-- module, and a require INSIDE the app-sandbox (spawnStation runs
-- there) hands back a FRESH module with no recipes at all --
-- EnergyNuclear was nil and the station's seeding crashed. The file
-- top is the only可靠 place to bind it.
-- THE RECIPES ARE LOAD-TIME SCOPE: this file loads under the kernel's
-- require, and Game.Content registers its recipes on THAT copy of the
-- module. A require INSIDE the app-sandbox (where spawnStation's body
-- runs) hands back a fresh module with no recipes attached --
-- EnergyNuclear read nil and the station's seeding crashed. The file
-- top is the only place to bind it.
require('Game.Content')
local Item = require('Game.Item')
local Production = require('Game.Production')
local ShipArchetypes = require('Game.ShipArchetypes')
local Communication = require('Game.Communication')
local Directives = require('Game.Directives')
local NpcPopulation = require('Game.NpcPopulation')
local NpcRegistry = require('Game.NpcRegistry')
local NpcLog = require('Game.NpcLog')
local Tombstones = require('Game.Tombstones')
local Fingerprint = require('Game.GenerationFingerprint')
local Knowledge = require('Game.Knowledge')

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
  -- The dust asks the SYSTEM for the field (13a): it is the last of the
  -- four subsystems that had a private stream of its own.
  self.dust = Dust(self)

  self.players = {}
  self.npcs = NpcRegistry.Create()
  self.npcTransit = {}
  self.sectorIndex = nil
  self.directives = Directives.Create()
  self.comms = Communication.Create()
  self.npcSerial = 0
  self.seed = seed
  self.time = 0
  self.zones = {}
  -- Stable asteroid-key -> remaining deposit units. Additive to the seeded
  -- world and serialized in saves, so streamed unload/reload cannot refill a rock.
  self.depositState = {}
  self.depositFingerprints = {}
  self.tombstones = Tombstones.Create((Config.game and Config.game.tombstoneLimit) or 4096)
  self.stableIndex = {}
  self.knowledgeShips = {}
  self.npcStations = {}
  self.npcStationIndex = {}

  -- The current sector's REGIONS and SEED, for the environmental field
  -- (13a/13f).
  --
  -- The field is a function of a position and the regions, so anything that
  -- wants to know "what kind of place is this" needs the regions. They are
  -- set by the app when the sector changes, and they are stable for the
  -- sector's lifetime -- which is what lets the asteroid field bake a
  -- chunk's density in at generation time and never revisit it.
  self.sectorRegions = nil
  self.sectorSeed = nil

  -- Keep local-light discovery proportional to the number of lights, not the
  -- total number of System children (which includes thousands of asteroids).
  self.lightEntities = {}
  self.lightEntityIndex = {}
  self:register(Event.ChildAdded, function (system, event)
    local child = event.child
    if child.stableId then system.stableIndex[child.stableId] = child end
    if child.hasHealth and not child.tombstoneHook then
      child.tombstoneHook = true
      child:register(Event.Destroyed, function (entity)
        system:recordDestroyed(entity)
      end)
    end
    if child.hasLight and child:hasLight() then
      system:registerLightEntity(event.child)
    end
    system:registerNpcStation(child)
  end)
  self:register(Event.ChildRemoved, function (system, event)
    system:handleChildRemoved(event)
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

function System:registerNpcStation (entity)
  if not entity or entity.isWormhole or not entity.hasDockable or not entity:hasDockable()
     or not entity.addItem or not entity.removeItem or self.npcStationIndex[entity] then return end
  local i = #self.npcStations + 1
  self.npcStations[i], self.npcStationIndex[entity] = entity, i
end

function System:unregisterNpcStation (entity)
  local i = self.npcStationIndex and self.npcStationIndex[entity]
  if not i then return end
  local last = #self.npcStations
  local moved = self.npcStations[last]
  self.npcStations[i], self.npcStations[last] = moved, nil
  self.npcStationIndex[entity] = nil
  if moved ~= entity then self.npcStationIndex[moved] = i end
end

function System:handleChildRemoved (event)
  local child = event.child
  if child.stableId and self.stableIndex[child.stableId] == child then
    self.stableIndex[child.stableId] = nil
  end
  -- Docking reparents a live ship under a station. Keep its knowledge rebind
  -- registration; deletion/despawn is the terminal removal path.
  if child.deleted or (child.health and child.health <= 0) then
    self:unregisterKnowledgeShip(child)
  end
  self:unregisterNpcStation(child)
  self:unregisterLightEntity(child)
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

function System:getTime ()
  return self.time or 0
end

function System:markTombstone (stableId, fingerprint)
  if stableId == 'ship:player' then return false end
  return self.tombstones and self.tombstones:Mark(stableId, fingerprint) or false
end

function System:isTombstoned (stableId, fingerprint)
  if not self.tombstones then return false end
  if fingerprint ~= nil then return self.tombstones:Matches(stableId, fingerprint) end
  return self.tombstones:Has(stableId)
end

function System:captureTombstones ()
  return self.tombstones and self.tombstones:Capture() or {}
end

function System:restoreTombstones (data)
  if not self.tombstones or type(data) ~= 'table' then return end
  local filtered = {}
  for _, entry in ipairs(data) do
    local key = type(entry) == 'string' and entry or type(entry) == 'table' and entry.key or nil
    if key ~= 'ship:player' then filtered[#filtered + 1] = entry end
  end
  self.tombstones:Restore(filtered)
end

function System:resolveStableId (stableId)
  return self.stableIndex and self.stableIndex[stableId] or nil
end

function System:registerKnowledgeShip (ship)
  if not ship or not ship.knowledge then return end
  self.knowledgeShips = self.knowledgeShips or {}
  self.knowledgeShips[ship] = true
  ship.knownYields = ship.knowledge.knownYields
  ship.scannedAsteroids = ship.knowledge.scannedAsteroids
end

function System:unregisterKnowledgeShip (ship)
  if self.knowledgeShips then self.knowledgeShips[ship] = nil end
end

function System:rebindKnowledge ()
  if not self.knowledgeShips then return end
  local sector = self.sectorSeed or self.seed
  for ship in pairs(self.knowledgeShips) do
    if ship.deleted or (ship.health and ship.health <= 0) then
      self.knowledgeShips[ship] = nil
    else
      Knowledge.Rebind(ship.knowledge, function (key) return self:resolveStableId(key) end,
        function (key, fingerprint) return self:isTombstoned(key, fingerprint) end, sector)
      ship.knownYields = ship.knowledge.knownYields
      ship.scannedAsteroids = ship.knowledge.scannedAsteroids
    end
  end
end

function System:recordDestroyed (entity)
  if entity.stableId then self:markTombstone(entity.stableId, Knowledge.Fingerprint(entity)) end
  local owner = entity.destroyedOwner or (entity.getOwner and entity:getOwner())
  if owner and owner.isNpc and owner:isNpc() and #owner:getAssets() == 0 then
    if owner.stableId then self:markTombstone(owner.stableId) end
    owner:delete()
    if owner:getParent() then owner:getParent():removeChild(owner) end
  end
end

function System:update (dt)
  self.time = self:getTime() + dt
  Communication.update(self.comms, self:getTime())
  Directives.update(self.directives, self:getTime())
  -- Pre-physics update. Broadcast reaches NPC brains through their parent
  -- link; sending directly to system.players as well would tick Think twice.
  local event = Event.Update(dt)
  Profiler.Begin('AI Update')
  self:broadcast(event)
  Profiler.End()

  self:send(event)

  Profiler.Begin('Physics Update')
  self.physics:update(dt)
  Profiler.End()

  self:handleRamming()
  self:sweepDestroyed()

  -- Post-physics update, likewise exactly once per entity.
  event = Event.UpdatePost(dt)
  self:broadcast(event)
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
  Removal is lazy, so the sweep walks backwards and skips stale parent slots;
  nested children are swept as well (for example, a ship docked at a station).
]]
function System:sweepDestroyed ()
  local function sweep (parent)
    local children = parent.children
    if not children then return end
    for i = #children, 1, -1 do
      local e = children[i]
      -- removeChild is deliberately lazy; a prior reparent/removal can leave a
      -- stale array slot until the next broadcast compacts it.
      if e.parent == parent then
        local destroyed = e.health and e.health <= 0
        if destroyed then self:recordDestroyed(e) end
        if e.deleted or destroyed then
          parent:removeChild(e)
        elseif e.children then
          sweep(e)
        end
      end
    end
  end
  sweep(self)
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
-- The sector's regions and seed, for the environmental field (13a). The app
-- calls this when the sector changes.
function System:setSectorRegions (regions, seed)
  self.sectorRegions = regions
  self.sectorSeed = seed
end

-- THE FIELD (13a).
--
-- One entry point, so that every subsystem that asks "what kind of place is
-- this" gets the SAME answer: the rocks, the gas, the dust, the lightning
-- and the shafts all come through here.
--
-- The field is a function of a position and the sector -- never of what
-- you did last, or of how you got here -- so two visits to the same place
-- give the same place (29a: POIs stay put, look-and-feel does not
-- change).
function System:fieldAt (x, y, z)
  if not self.sectorRegions or #self.sectorRegions == 0 then return nil end
  local Region = require('Game.Region')
  return Region.Region.field(self.sectorRegions, x, y, z, self.sectorSeed)
end

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
  local maxChunks = knob('gen.asteroidField.maxChunks', cfg.maxChunks)    or 0

  if not enabled then
    -- Turning it off UNLOADS rather than pauses: a frozen field would still cost
    -- ~2000 entities and ~2 ms every frame while the panel claims "off".
    if self.asteroidField then
      self.asteroidField:clear()
      self.asteroidField = nil
      self:rebindKnowledge()
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
  self.asteroidField.maxChunks = maxChunks

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
  if loaded > 0 or unloaded > 0 then self:rebindKnowledge() end
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


function System:spawnAI (shipCount, opts)
  opts = opts or {}
  self.npcSerial = (self.npcSerial or 0) + 1
  local npcId = opts.npcId or (tostring(self.seed or Seed.get() or 0) .. ':' .. self.npcSerial)
  local role = opts.role or 'capital'
  local roleDef = NpcPopulation.Roles[role] or NpcPopulation.Roles.capital
  local player = Entities.Player({
    isNpc = true,
    npcId = npcId,
    profile = opts.profile,
    organization = opts.organization or roleDef.organization,
  })
  player.stableId = npcId
  -- THE BRAIN MUST BE IN THE WORLD: the capital's Think action ticks via
  -- Event.Update, which only fires for entities in the tree. The capital
  -- was never added to the system -- its Think never ran, and every ship
  -- it owned sat idle forever (the whole AI economy was a no-op).
  self:addChild(player)
  self:registerNpc(player)
  self:registerCommunicator(player)
  player:register(Event.RemovedFromParent, function (self, event)
    event.parent:unregisterCommunicator(self)
    event.parent:unregisterNpc(self)
  end)
  -- Think queries each ship's root (the System), which already owns the one
  -- shared economy cache. A second Economy on every brain rebuilt the same
  -- job list once per NPC each frame; keep only the System instance.
  for i = 1, shipCount do
    local ship = self:spawnShip(opts.shipType or roleDef.shipType, {
      seed = opts.prototypeSeed,
      variant = opts.variant,
      scale = roleDef.scale,
      pos = opts.pos,
      shipId = opts.shipId and (shipCount > 1 and (opts.shipId .. ':' .. i) or opts.shipId),
    })
    if ship then
      ship.npcRole = role
      ship:setInventoryCapacity(roleDef.cargo)
      ship:setOwner(player) -- routes through addAsset: the ship book
      ship:setName(opts.name or NameGen.npcShipName(self.rng))
    end
  end
  player:addItem(Item.Credit, kStartCredits)
  player:pushAction(Actions.Think())
  self:addPlayer(player)
  return player
end

function System:transitIdsFor (sectorIndex)
  local out = {}
  for _, entry in ipairs(self.npcTransit or {}) do
    if entry.destination == sectorIndex and entry.npc and entry.npc.getNpcId then
      out[entry.npc:getNpcId()] = true
    end
  end
  return out
end

function System:holdNPCPopulation (sectorIndex)
  local actors = {}
  for _, npc in ipairs(self.npcPopulationActors or {}) do actors[#actors + 1] = npc end
  local held = 0
  for _, npc in ipairs(actors) do
    local ship = npc:getControlling()
    if not ship then
      for _, asset in ipairs(npc:getAssets()) do ship = asset; break end
    end
    if ship then
      local pos = ship:getPos()
      local gate = {
        getPartnerSector = function () return sectorIndex end,
        getPartnerPos = function () return pos end,
        getName = function () return 'sector boundary' end,
      }
      if self:beginNpcTransit(npc, ship, gate, 'sector-hold', true) then held = held + 1 end
    end
  end
  return held
end

function System:beginNpcTransit (npc, ship, gate, reason, allowCurrentSector)
  if not (npc and ship and gate and gate.getPartnerSector and gate.getPartnerPos) then return false end
  if npc.transit then return false end
  local destination = gate:getPartnerSector()
  if destination == nil or (destination == self.sectorIndex and not allowCurrentSector) then return false end
  local assets = {}
  for _, asset in ipairs(npc:getAssets()) do assets[#assets + 1] = asset end
  if #assets == 0 then assets[1] = ship end
  local arrival = gate:getPartnerPos()
  local ax, ay, az = tonumber(arrival and arrival.x), tonumber(arrival and arrival.y), tonumber(arrival and arrival.z)
  if not ax or not ay or not az or ax ~= ax or ay ~= ay or az ~= az
     or math.abs(ax) == math.huge or math.abs(ay) == math.huge or math.abs(az) == math.huge then return false end
  local SaveGame
  for _, asset in ipairs(assets) do
    if asset.job then
      SaveGame = SaveGame or require('Game.SaveGame')
      asset.pendingJob = SaveGame.CaptureJob(asset)
      NpcLog.Event(asset, 'job checkpoint captured before sector transit')
    end
  end
  local entry = {
    npc = npc, ship = ship, assets = assets, destination = destination,
    fromSector = self.sectorIndex, reason = reason or 'travel', departedAt = self:getTime(),
    arrivalPos = arrival and { x = arrival.x, y = arrival.y, z = arrival.z } or nil,
  }
  npc.transit = {
    destination = destination, fromSector = entry.fromSector, reason = entry.reason,
    departedAt = entry.departedAt, arrivalPos = entry.arrivalPos,
  }
  self.npcTransit = self.npcTransit or {}
  self.npcTransit[#self.npcTransit + 1] = entry
  for i = #(self.npcPopulationActors or {}), 1, -1 do
    if self.npcPopulationActors[i] == npc then table.remove(self.npcPopulationActors, i) end
  end
  for _, asset in ipairs(assets) do
    local controller = asset.thrustController
    if controller then
      controller:clear()
      if controller.engineSound then controller.engineSound:setVolume(0) end
    end
    if asset.setVelocity then asset:setVelocity(Vec3f(0, 0, 0)) end
    local parent = asset.getParent and asset:getParent()
    if parent and parent.hasDockable and parent:hasDockable() then parent:removeDocked(asset) end
    parent = asset.getParent and asset:getParent()
    if parent then parent:removeChild(asset, true) end
  end
  if npc.getParent and npc:getParent() then npc:getParent():removeChild(npc) end
  NpcLog.Event(ship, format('entered %s: sector %s -> %s, identity/cargo/job held in transit',
    gate:getName(), tostring(entry.fromSector), tostring(destination)))
  return true
end

function System:restoreNpcTransit (sectorIndex)
  local restored = 0
  for i = #(self.npcTransit or {}), 1, -1 do
    local entry = self.npcTransit[i]
    if entry.destination == sectorIndex then
      table.remove(self.npcTransit, i)
      local npc, ship = entry.npc, entry.ship
      if npc.deleted or ship.deleted or self:isTombstoned(npc:getNpcId())
         or (ship.stableId and self:isTombstoned(ship.stableId)) then
        self:despawnNpc(npc)
      else
        local arrival = entry.arrivalPos or { x = 0, y = 0, z = 0 }
        for j, asset in ipairs(entry.assets) do
          if not asset.deleted then
            if asset.clearActions then
              asset.npcJobCheckpoint = true
              asset:clearActions()
              asset.npcJobCheckpoint = false
            end
            asset.job = nil
            local offset = j == 1 and Vec3f(0, 0, 0)
              or Vec3f((j - 1) * 200, 0, (j - 1) * 100)
            asset:setPos(Vec3f(arrival.x + offset.x, arrival.y + offset.y, arrival.z + offset.z))
            self:addChild(asset)
          end
        end
        self:addChild(npc)
        self:registerNpc(npc)
        self:registerCommunicator(npc)
        self:addPlayer(npc)
        if not npc:getControlling() or npc:getControlling().deleted then npc:setControlling(ship) end
        self.npcPopulationActors = self.npcPopulationActors or {}
        self.npcPopulationActors[#self.npcPopulationActors + 1] = npc
        npc.transit, ship.npcTravel = nil, nil
        npc.npcNextTravelAt = self:getTime()
          + ((Config and Config.game and Config.game.npcTravelInterval) or 300)
        restored = restored + 1
        NpcLog.Event(ship, format('arrived sector %s at (%.0f,%.0f,%.0f); same actor/ship/job resumed',
          tostring(sectorIndex), arrival.x, arrival.y, arrival.z))
      end
    end
  end
  return restored
end

function System:despawnNpc (npc)
  local assets = {}
  for _, ship in ipairs(npc:getAssets()) do assets[#assets + 1] = ship end
  for _, ship in ipairs(assets) do
    ship:clearActions()
    local parent = ship:getParent()
    if parent and parent.hasDockable and parent:hasDockable() then
      parent:removeDocked(ship)
    end
    local controller = ship.thrustController
    if controller and controller.engineSound then
      controller.engineSound:free()
      controller.engineSound = nil
    end
    ship:delete()
    if ship:getParent() then ship:getParent():removeChild(ship) end
  end
  npc:clearActions()
  npc:delete()
  if npc:getParent() then npc:getParent():removeChild(npc) end
end

function System:despawnNPCPopulation ()
  local actors = self.npcPopulationActors or {}
  local count = #actors
  for _, npc in ipairs(actors) do self:despawnNpc(npc) end
  self.npcPopulationActors = {}
  return count
end

function System:spawnNPCPopulation (seed, opts)
  self:despawnNPCPopulation()
  opts = opts or {}
  local plan = NpcPopulation.Plan(seed or self.seed, opts.mix)
  local center = opts.center or Vec3f(0, 0, 0)
  local radius = math.max(500, opts.radius or 12000)
  local actors = {}
  for i, entry in ipairs(plan) do
    if opts.exclude and opts.exclude[entry.id] then goto continue end
    local roleDef = NpcPopulation.Roles[entry.role]
    local angle = (entry.seed % 628318) / 1000.0
    local distance = radius * (0.35 + (entry.seed % 1000) / 1800.0)
    local height = ((entry.seed % 17) - 8) * radius * 0.025
    local pos = center + Vec3f(math.cos(angle) * distance, height, math.sin(angle) * distance)
    local npc = self:spawnAI(1, {
      npcId = entry.id,
      shipId = entry.shipId,
      name = roleDef.name .. ' ' .. i,
      role = entry.role,
      shipType = roleDef.shipType,
      prototypeSeed = entry.seed,
      variant = entry.variant,
      pos = pos,
      profile = { role = entry.role, variant = entry.variant },
      organization = roleDef.organization,
    })
    if self:isTombstoned(entry.id) then
      self:despawnNpc(npc)
    else
      actors[#actors + 1] = npc
    end
    ::continue::
  end
  self.npcPopulationActors = actors
  return actors
end

function System:registerCommunicator (actor)
  return Communication.register(self.comms, actor)
end

function System:unregisterCommunicator (actor)
  return Communication.unregister(self.comms, actor)
end

function System:registerNpc (npc)
  if not (npc and npc.isNpc and npc:isNpc()) then return false end
  return NpcRegistry.register(self.npcs, npc)
end

function System:unregisterNpc (npc)
  local removed = NpcRegistry.unregister(self.npcs, npc)
  self:removePlayer(npc)
  return removed
end

function System:getNpc (id)
  return NpcRegistry.get(self.npcs, id)
end

function System:createDefendDirective (issuer, target, opts)
  opts = opts or {}
  opts.now = opts.now or self:getTime()
  opts.expiresAt = opts.expiresAt or (opts.now + 60)
  return Directives.create(self.directives, issuer, 'defend', target, opts)
end

function System:addPlayer (player)
  for _, e in ipairs(self.players) do
    if e == player then return false end
  end
  insert(self.players, player)
  return true
end

function System:removePlayer (player)
  for i = 1, #self.players do
    if self.players[i] == player then
      self.players[i] = self.players[#self.players]
      self.players[#self.players] = nil
      return true
    end
  end
  return false
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
-- The NPC caps of this system: ships that have an owner (the brain -- see
-- spawnAI). Used by the targeting keys (Ship:targetNearestNpc etc.) and the
-- NPC info panel (GameView.infoPanel). docs/npcwork.md.
function System:getPatrolCenter ()
  for _, entity in ipairs(self.children or {}) do
    if entity.parent == self and entity.hasDockable and entity:hasDockable() then
      return entity:getPos()
    end
  end
  return Vec3f(0, 0, 0)
end

function System:findScanTarget (scanner, maxRange)
  local range = maxRange or (Config.game and Config.game.scanSearchRange) or 15000
  local range2 = range * range
  local origin = scanner:getPos()
  scanner.knowledge = scanner.knowledge or Knowledge.Create()
  scanner.scannedAsteroids = scanner.knowledge.scannedAsteroids
  local scanned = scanner.knowledge
  local best, bestDist = nil, range2
  for _, entity in ipairs(self.children or {}) do
    if entity ~= scanner and entity.parent == self and entity.isAsteroid and entity.body
       and not entity.deleted and not (entity.isDestroyed and entity:isDestroyed())
       and not Knowledge.Scanned(scanned, entity) then
      local delta = entity:getPos() - origin
      local dist = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z
      if dist < bestDist then best, bestDist = entity, dist end
    end
  end
  return best
end

function System:npcTargets (exclude)
  local out = {}
  for _, e in ipairs(self.children or {}) do
    local owner = e:getOwner()
    -- Target only ships owned by explicit NPC actors. Human-owned escorts are
    -- not NPCs, and stale children awaiting broadcast compaction are ignored.
    if e ~= exclude and e.parent == self and owner and owner.isNpc and owner:isNpc()
       and e:isAlive() and e.body and not e.deleted then
      insert(out, e)
    end
  end
  return out
end

local function refreshStartupFingerprint (asteroid)
  local meta = asteroid.startupGeneration
  if not meta then return end
  local pos = asteroid:getPos()
  asteroid.generationFingerprint = Fingerprint.Physical({
    generator = 'startup', worldSeed = meta.worldSeed, sectorSeed = meta.sectorSeed,
    scope = meta.scope, slot = meta.slot, chunkSize = 0, perChunk = meta.perChunk,
    rockScale = 1, oreChance = meta.oreChance, seed = meta.seed, scale = meta.scale,
    x = pos.x, y = pos.y, z = pos.z,
  })
  if asteroid:hasYield() then
    local yield = asteroid:getYield()
    asteroid.depositFingerprint = Fingerprint.Deposit(asteroid.generationFingerprint,
      yield.item:getName(), yield.size, yield.initial)
  else
    asteroid.depositFingerprint = nil
  end
end

function System:spawnAsteroidField (count, oreCount, fieldPos, opts)
  opts = type(opts) == 'table' and opts or {}
  local rng = self.rng
  local worldSeed = tostring(self.seed or 0)
  local fieldScope = fieldPos and format('startup:%d:%d:%s:%s:%s', count, oreCount,
    tostring(fieldPos.x), tostring(fieldPos.y), tostring(fieldPos.z)) or 'startup:random'
  local zone = Entities.Zone(format('%s Field', genName(rng)))
  zone.pos = fieldPos or rng:getDir3():scale(kSystemScale * (1.0 + rng:getExp()))

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
    local rockSeed = rng:get31()
    local asteroid = Entities.Asteroid(rockSeed, scale)
    asteroid:setPos(pos)
    asteroid:setScale(scale)
    asteroid:setRot(rng:getQuat())

    -- Mark the last `oreCount` rocks as ore-bearing (mineable later).
    -- THE ORE IS A REAL COMMODITY: this used to read `Item.Ore`, a name
    -- from the old game's item set that this one never defined -- the
    -- silent nil seeded yields with NO item, and the first AI miner that
    -- priced a job crashed on item:getMass(). The belt's rock now yields
    -- one of the T1 commodities the stations' standing bids actually
    -- want (the same rule the streaming field's rocks use).
    if i > (count - oreCount) then
      asteroid:addYield(rng:choose(Item.T1), 1.0)
    end

    local stableId = 'startup:' .. i
    asteroid.stableId = stableId
    asteroid.startupGeneration = {
      worldSeed = worldSeed, sectorSeed = tostring(self.sectorSeed or 0),
      scope = fieldScope, slot = i, perChunk = count,
      oreChance = oreCount / math.max(1, count), seed = rockSeed, scale = asteroid:getScale(),
    }
    refreshStartupFingerprint(asteroid)
    zone:add(asteroid)        -- preserve deterministic clumping anchors
    if opts.deferTombstones or not self:isTombstoned(stableId, Knowledge.Fingerprint(asteroid)) then
      self:addChild(asteroid) -- <-- this is what puts it in the live world
      asteroid:setDepositKey(stableId, asteroid.depositFingerprint)
    end
  end
  self:addZone(zone)
  return zone
end

function System:moveAsteroidField (zone, pos)
  local dx, dy, dz = pos.x - zone.pos.x, pos.y - zone.pos.y, pos.z - zone.pos.z
  zone.pos = pos
  for _, child in ipairs(zone.children or {}) do
    if child.body and not child.deleted then
      local childPos = child:getPos()
      child:setPos(Vec3f(childPos.x + dx, childPos.y + dy, childPos.z + dz))
      refreshStartupFingerprint(child)
    end
  end
  -- Fingerprints include the final world position. Apply tombstones and saved
  -- deposit overlays only after translation, never against the temporary
  -- pre-placement coordinates used to preserve the seeded clumping layout.
  for _, child in ipairs(zone.children or {}) do
    if child.body and not child.deleted then
      if self:isTombstoned(child.stableId, Knowledge.Fingerprint(child)) then
        if child.parent then self:removeChild(child) end
      else
        child:setDepositKey(child.stableId, child.depositFingerprint)
      end
    end
  end
end

-- Spawn a planet.
--
-- `rng` and `origin` are optional. Without them the planet is drawn from the
-- SYSTEM's own shared rng stream, at the system's origin -- which is what
-- generation at boot wants, because that stream is shared with the rest of
-- the world and reordering its draws silently reshuffles every existing
-- world.
--
-- With them, the planet is a pure function of that rng and that origin --
-- which is what a SECTOR wants: each sector has its own planet, drawn from
-- the sector's own seed, so that arriving in a new sector is arriving
-- SOMEWHERE ELSE and not just somewhere with a new name.
function System:spawnPlanet (rng, origin)
  rng = rng or self.rng
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
  if origin then pos = origin + pos end
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

function System.ValidateModuleEntry (entry)
  return type(entry) == 'table' and (entry.type == 'Thruster' or entry.type == 'Turret')
    and type(entry.index) == 'number' and entry.index >= 1 and entry.index % 1 == 0
end

function System:spawnShip (kind, opts)
  opts = opts or {}
  if not ShipArchetypes.Defs[kind] then kind = 'fighter' end
  kind = kind or 'fighter'
  local def = ShipArchetypes.Get(kind)
  local variant = math.max(1, math.floor(opts.variant or 1))
  local cacheKey = kind .. ':v' .. variant .. ':s' .. tostring(opts.seed or 'default')
    .. ':z' .. tostring(opts.scale or def.scale) .. ':Type'
  if not self[cacheKey] then
    local seed = opts.seed or self.rng:get31()
    local generator = Gen.Ship[ShipArchetypes.Generator(kind, variant)]
    assert(generator, 'Unknown ship generator for ' .. kind)
    self[cacheKey] = ShipType(seed, generator, opts.scale or def.scale, {
      kind = kind, classId = def.classId, model = def.model,
    })
  end
  local ship = self[cacheKey]:instantiate(opts.shipId)
  ship.shipKind = kind
  ship.shipVariant = variant
  ship.prototypeSeed = opts.seed or self[cacheKey].seed
  ship:setInventoryCapacity(opts.cargo or def.cargo)
  if opts.pos then
    ship:setPos(opts.pos)
  else
    ship:setPos(self.rng:getDir3():scale(kSystemScale * (1.0 + self.rng:getExp())))
  end
  if opts.shipId and self:isTombstoned(opts.shipId) then
    ship:delete()
    return nil
  end
  self:addChild(ship)

  if type(opts.modules) == 'table' then
    for _, entry in ipairs(opts.modules) do
      if not System.ValidateModuleEntry(entry) then goto continue end
      local module
      if entry.type == 'Thruster' then
        module = Entities.Thruster()
        module:setScale(0.5 * ship:getScale())
      elseif entry.type == 'Turret' then
        module = Entities.Turret()
        module:setScale(2 * ship:getScale())
      end
      if module and not ship:plug(module, entry.index) then module:delete() end
      ::continue::
    end
  else
    while true do
      local thruster = Entities.Thruster()
      thruster:setScale(0.5 * ship:getScale())
      if not ship:plug(thruster) then thruster:delete(); break end
    end
    while true do
      local turret = Entities.Turret()
      turret:setScale(2 * ship:getScale())
      if not ship:plug(turret) then turret:delete(); break end
    end
  end
  return ship
end

function System:spawnStation ()
  local station = Entities.Station(self.rng:get31())
  station.stableId = 'station:main'
  station.shipyard = true
  local p = self.rng:getDisc():scale(kSystemScale)
  station:setPos(Vec3f(p.x, 0, p.y))
  station:setScale(100)
  -- station:setFlow(Item.Silver, self.rng:getUniformRange(-1000, 0))
  station:addMarket()
  station:addTrader()
  station.trader.credits = 500000 -- the trader's own escrow bank
  -- THE AI'S DEMAND BOOK (see buildPlace's note): standing bids the NPC
  -- miners work against.
  for _, item in ipairs(Item.T1) do
    station.trader:addStandingBid(item, Item.Price[item] or 10, 200)
  end
  -- And the shelf's asks for the caravans (a capped AI-buyable view of
  -- what the factory makes and of what miners delivered), plus the
  -- waste admission at the disposal price -- the traders room mirrors
  -- the market, not less.
  for _, out in ipairs(Production.EnergyNuclear.outputs) do
    station.trader:addStandingAsk(out.item, Item.Price[out.item] or 20, 40)
  end
  for _, item in ipairs(Item.T1) do
    station.trader:addStandingAsk(item, Item.Price[item] or 10, 40, 100)
  end
  station.trader:addStandingBid(Item.Waste, Item.Price[Item.Waste], 200)

  -- THE PLANT: the station runs the NUCLEAR recipe. It used to pick a
  -- random production, and that rarely worked out: the SOLAR recipe
  -- eats WASTE, which nobody mines, so the plant stalled forever and
  -- the station's sell side stayed empty. The nuclear recipe eats what
  -- a belt ACTUALLY yields (isotopes + silver), so the miners feed it
  -- by default and the shelf keeps stock.
  station:addFactory()
  station:addProduction(Production.EnergyNuclear)
  station:setName(format('%s %s',
    genName(self.rng),
    Production.EnergyNuclear:getName()))
  -- THE BOOK: the main station trades like the region places do -- it
  -- BUYS the raw commodities the belts yield and SELLS what its own
  -- factory makes. Its book was never seeded: docking at the MAIN
  -- station (the natural first dock) showed an empty market on both
  -- tabs, and the working capital has to exist for the market's
  -- transfers to pay the player. The WASTE bid is the disposal sink.
  station:addCredits(500000)
  -- THE STARTING STOCK (see buildPlace's note): a station opens with a
  -- modest shelf so a player docking in the first minute sees stock.
  for _, item in ipairs(Item.T1) do
    station:addItem(item, 10)
  end
  station:addItem(Item.Energy, 50)
  station:addItem(Item.Waste, 10)
  for _, item in ipairs(Item.T1) do
    station.market:addStandingBuy(station, item, 200, Item.Price[item] or 10)
  end
  station.market:addStandingBuy(station, Item.Waste, 200, Item.Price[Item.Waste])
  -- THE CAPTURED-GAS DEMAND (see buildPlace's note): buy-only books.
  for _, item in ipairs(Item.Gas) do
    station.market:addStandingBuy(station, item, 100, Item.Price[item] or 15)
    station.trader:addStandingBid(item, Item.Price[item] or 15, 100)
  end
  for _, out in ipairs(Production.EnergyNuclear.outputs) do
    station.market:addStandingSell(station, out.item, 200,
      Item.Price[out.item] or 20)
  end
  if self:isTombstoned(station.stableId) then
    station:delete()
    return nil
  end
  self:addChild(station)
  return station
end

return System
