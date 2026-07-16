--[[
  Asteroid entity
  ----------------------------------------------------------------------------
  Asteroids are the primary destructible prop in the game. This file shows the
  whole "lifecycle" of a destroyable object in Limit Theory's Lua gameplay
  layer:

    1. Build a mesh + rigid body + visible mesh (standard entity setup).
    2. Give it health via `addHealth` so the damage system can hurt it.
    3. Register an `Event.Destroyed` handler (`fragment`) that spawns smaller
       child asteroids + an explosion burst when it dies.

  How destruction flows (important mental model):
    * Something calls `entity:damage(amount, source)` (see Health.lua).
    * When health hits 0, Health.lua fires `Event.Destroyed(source)`.
    * Every handler registered for that event runs. Our `fragment` handler
      spawns the debris. The System then sweeps the dead entity out of the
      world (see System.lua `sweepDestroyed`) so it stops colliding.

  To make YOUR OWN destructible object, copy this pattern:
    self:addHealth(hp, 0)                 -- 0 = no health regen
    self:register(Event.Destroyed, function (self, source) ... end)
]]

local Entity = require('Game.Entity')
local Material = require('Game.Material')
local Explosion = require('Game.Entities.Explosion')

-- NOTE: `Asteroid` is forward-declared here (rather than `local Asteroid = ...`)
-- because the `fragment` closure below needs to spawn NEW asteroids. The
-- variable is assigned at the bottom of the file via `subclass`.
local Asteroid
local cache = {}

-- Asteroid meshes are generated procedurally from a seed and cached, so two
-- asteroids with the same seed share one mesh (cheap). `Gen.Asteroid(seed)`
-- returns a LodMesh; `mesh:get(0)` is the highest-detail level used for physics.
local function getMesh (seed)
  local seed = tonumber(seed) % 1
  if not cache[seed] then
    cache[seed] = Gen.Asteroid(seed)
  end
  return cache[seed]
end

-- Tuning knobs for fragmentation. A destroyed asteroid breaks into between
-- 2 and `maxFragments` smaller asteroids, but ONLY if it is bigger than
-- `minFragmentScale` (otherwise it just explodes into dust with no children).
local minFragmentScale = 0.5
local maxFragments = 4

-- Dedicated RNG so asteroid break-up is deterministic per-run and does not
-- disturb gameplay RNG streams.
local rng = RNG.Create(98765)

-- Event.Destroyed handler: called the moment an asteroid's health reaches 0.
-- `source` is whatever dealt the killing blow (a Pulse projectile, another
-- asteroid that rammed it, etc.) -- currently unused but handy for scoring.
local function fragment (self, source)
  -- The "root" is the System (top of the entity tree). Children added here
  -- become real, simulated objects in the world.
  local root = self:getRoot()

  -- Big enough to shatter? Spawn smaller asteroids (the "break up").
  if self:getScale() > minFragmentScale then
    -- 2..maxFragments child asteroids
    local n = 2 + rng:getInt(0, maxFragments - 2)
    local center = self:getPos()
    local baseScale = self:getScale() * 0.5        -- children are half size
    local baseVel = self:getVelocity()             -- inherit parent momentum

    for i = 1, n do
      local seed = rng:get31()
      -- slight random size variation so fragments don't look identical
      local scale = baseScale * (0.6 + 0.4 * rng:getUniform())
      local child = Asteroid(seed, scale)
      -- place each fragment just outside the parent's surface, randomly
      local offset = rng:getSphere():scale(self:getRadius() * 0.5)
      child:setPos(center + offset)
      child:setRot(rng:getQuat())
      -- give it a random outward kick (requires RigidBody_SetLinearVelocity,
      -- exposed in Lua as Entity:setVelocity)
      child:setVelocity(baseVel + rng:getSphere():scale(10.0 * scale))
      root:addChild(child)
    end
  end

  -- Always spawn a debris/dust burst: a few short-lived Explosion billboards
  -- that fade out on their own (see Explosion.lua, which deletes itself after
  -- ~10s). This is the visible "pop" when something dies.
  for i = 1, 6 do
    local p = self:getPos() + rng:getSphere():scale(4.0 * self:getScale())
    local v = self:getVelocity()
    root:addChild(Explosion(p, v, 0.0))
  end
end

-- Asteroid constructor. `seed` drives the procedural shape; `scale` is the
-- size multiplier (also used for health + mass).
Asteroid = subclass(Entity, function (self, seed, scale)
  -- Build the collision + render geometry
  local mesh = getMesh(seed)
  self:addRigidBody(true, mesh:get(0))          -- true = this body is a collider
  self:addVisibleLodMesh(mesh, Material.Rock())

  self:setDrag(0.2, 0.2)
  self:setScale(scale)

  -- Mass drives how the asteroid reacts to forces/collisions. Using the
  -- bounding radius^3 keeps big rocks heavy and small ones light.
  local mass = self:getRadius() ^ 3.0
  self:setMass(mass)

  -- Make the asteroid destructible. Health is intentionally small (scale * 10)
  -- so a few weapon hits or one good ram actually destroys it. The second
  -- argument (rate = 0) means no passive health regeneration.
  -- TIP: raise this number to make asteroids tankier, or lower it for glass.
  self:addHealth(math.max(15, math.floor(scale * 10)), 0)

  -- Hook up the fragmentation + explosion burst on death.
  self:register(Event.Destroyed, fragment)
end)

return Asteroid
