local Entity = require('Game.Entity')
local Material = require('Game.Material')
local GPUParticles = require('Game.Entities.GPUParticles')

local Asteroid
local cache = {}

-- Archetype Pooling: Pre-bake and reuse a fixed set of canonical mesh shapes.
-- Scaling, stretching, and rotating 32 canonical shapes produces infinite
-- visual variety with zero frame hitches during endless sector flight.
local NUM_ARCHETYPES = 32

local function getMesh (seed)
  local rawSeed = math.floor(math.abs(tonumber(seed) or 0))
  local archetypeIndex = (rawSeed % NUM_ARCHETYPES) + 1

  if not cache[archetypeIndex] then
    cache[archetypeIndex] = Gen.Asteroid(archetypeIndex)
  end
  return cache[archetypeIndex]
end

-- Tuning knobs for fragmentation
local minFragmentScale = 0.5
local maxFragments = 4

local rng = RNG.Create(98765)

local function fragment (self, source)
  local root = self:getRoot()
  local currentScale = self:getScale()

  if currentScale > minFragmentScale then
    local n = 2 + rng:getInt(0, maxFragments - 2)
    local center = self:getPos()
    local baseScale = currentScale * 0.5
    local baseVel = self:getVelocity()

    for i = 1, n do
      local childSeed = rng:get31()
      local scale = baseScale * (0.6 + 0.4 * rng:getUniform())
      local child = Asteroid(childSeed, scale)

      local offset = rng:getSphere():scale(self:getRadius() * 0.5)
      child:setPos(center + offset)
      child:setRot(rng:getQuat())
      child:setVelocity(baseVel + rng:getSphere():scale(10.0 * scale))

      -- Debris does not live forever. A fragment that is never destroyed (the
      -- common case: ramming is inert and Pulse rarely hits) used to stay in
      -- the world forever as a permanent rigid body, so a single destroyed rock
      -- left 2-4 bodies behind forever and shooting up a field accumulated
      -- thousands of them. Sweep it out after a short lifetime instead. The
      -- child is still a damageable Asteroid, so an early hit just kills it
      -- sooner and fires its own (smaller) fragmentation.
      child.lifetime = 8.0
      child:register(Event.Update, function (c, ev)
        c.lifetime = c.lifetime - ev.dt
        if c.lifetime <= 0 then c:delete() end
      end)

      root:addChild(child)
    end
  end

  -- Scale particle explosion energy with asteroid size
  local expEnergy = math.min(10.0, math.max(0.5, currentScale))
  GPUParticles.explode(self:getPos(), self:getVelocity(), expEnergy)
end

Asteroid = subclass(Entity, function (self, seed, scale, opts)
  opts = opts or {}
  local mesh = getMesh(seed)
  self:addRigidBody(true, mesh:get(0))
  self:addVisibleLodMesh(mesh, Material.Rock())

  self:setDrag(0.2, 0.2)
  self:setScale(scale)

  if opts.static then
    -- Scenery rock: immovable. setMass(0) makes Bullet's inverse mass zero, so
    -- the body is not integrated, never deactivates, and never drifts -- which
    -- is both what a static field wants and dramatically cheaper than a
    -- thousand dynamic bodies. It is the same idiom planets already use
    -- (Planet.__init: setMass(opts.mass or 0)).
    --
    -- The consequence is that System:handleRamming's `mass > 0` test would
    -- silently exempt these rocks from ramming damage, i.e. you would fly
    -- through the field for free. So a static rock opts IN explicitly with
    -- `ramDamage`, and handleRamming tests `mass > 0 or ramDamage == true`.
    -- That is strictly additive: a body with mass 0 and no flag behaves exactly
    -- as before (planets, moons), and only opted-in rocks change.
    self:setMass(0)
    self.ramDamage = true
  else
    -- Mass scales with volume (radius^3)
    local mass = self:getRadius() ^ 3.0
    self:setMass(mass)
  end

  -- Scale health smoothly across small rocks and giant megastructures
  local hp = math.max(15, math.floor(scale * 15))
  self:addHealth(hp, 0)

  self:register(Event.Destroyed, fragment)
end)

return Asteroid
