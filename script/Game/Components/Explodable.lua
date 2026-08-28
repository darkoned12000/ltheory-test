local Entity = require('Game.Entity')
local GPUParticles = require('Game.Entities.GPUParticles')

local rng = RNG.Create(1231)

--[[ Ship destruction: one scale-boosted GPU particle burst replaces the eight
  legacy Explosion billboards this used to spawn. ]]
local function explode (self, source)
  if self:getOwner() then self:getOwner():removeAsset(self) end
  GPUParticles.explode(
    self:getPos(),
    self:getVelocity(),
    max(self:getScale() * 2, 4))
  self:clearActions()
end

function Entity:addExplodable ()
  assert(not self.explodable)
  self.explodable = true
  self:register(Event.Destroyed, explode)
end

function Entity:hasExplodable ()
  return self.explodable ~= nil
end
