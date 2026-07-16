local ffi = require('ffi')
local Entity = require('Game.Entity')
local Dust = require('Game.Entities.Dust')
local Nebula = require('Game.Entities.Nebula')
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
end)

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

  Tuning:
    * raise rammingMinSpeed to ignore gentle nudges (no damage on bump)
    * raise the multiplier to make crashes more lethal
  Note this runs AFTER physics:update, so it reads the contacts from this step.
]]
local rammingCollision = ffi.new('Collision')
local rammingMinSpeed = 25.0

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
      local v0 = e0:getVelocity()
      local v1 = e1:getVelocity()
      local relSpeed = v0:distance(v1)
      if relSpeed > rammingMinSpeed then
        -- Damage scales with how far above the threshold the impact was.
        -- `e.health` is nil for non-damageable objects (e.g. Zones), so the
        -- `if e.health` guard skips them safely.
        local dmg = (relSpeed - rammingMinSpeed) * 2.0
        if e0.health then e0:damage(dmg, e1) end
        if e1.health then e1:damage(dmg, e0) end
      end
    end
  end
end

-- Helpers For Testing ---------------------------------------------------------

local Item = require('Game.Item')

local kInventory = 100
local kStartCredits = 1000000
local kSystemScale = 10000

local cons = Distribution()
cons:add('b', 1.5)
cons:add('c', 2.8)
cons:add('d', 4.3)
cons:add('f', 2.2)
cons:add('g', 2.0)
cons:add('h', 6.1)
cons:add('j', 0.2)
cons:add('k', 0.8)
cons:add('l', 4.0)
cons:add('m', 2.4)
cons:add('n', 6.7)
cons:add('p', 1.9)
cons:add('q', 0.1)
cons:add('r', 6.0)
cons:add('s', 6.3)
cons:add('t', 9.1)
cons:add('v', 1.0)
cons:add('w', 2.4)
cons:add('x', 0.2)
cons:add('z', 0.1)

cons:add('ll', 0.4)
cons:add('ss', 0.6)
cons:add('tt', 0.9)
cons:add('ff', 0.2)
cons:add('rr', 0.6)
cons:add('nn', 0.6)
cons:add('pp', 0.2)
cons:add('cc', 0.3)

local vowels = Distribution()
vowels:add('a',  8.2)
vowels:add('e', 12.7)
vowels:add('i',  7.0)
vowels:add('o',  7.5)
vowels:add('u',  2.8)
vowels:add('y',  2.0)

vowels:add('ee',  1.2)
vowels:add('oo',  0.7)

local function genName (rng)
  local name = {}
  for i = 1, rng:getInt(2, 5) do
    insert(name, cons:sample(rng))
    insert(name, vowels:sample(rng))
  end
  name[1] = name[1]:upper()
  name = join(name)
  return name
end

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
  zone.pos = rng:getDir3():scale(0.0 * kSystemScale * (1 + rng:getExp()))

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
  local pos = rng:getDir3():scale(kSystemScale * (1.0 + rng:getExp()))
  local scale = 1e5 * rng:getErlang(2)
  planet:setPos(pos)
  planet:setScale(scale)
  self:addChild(planet)
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
