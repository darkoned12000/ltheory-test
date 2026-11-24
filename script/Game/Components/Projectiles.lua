local Entity = require('Game.Entity')
local Pulse = require('Game.Entities.Pulse')

function Entity:addProjectiles ()
  assert(not self.projectiles)
  self.projectiles = {}
  self:register(Event.Update, Entity.updateProjectiles)
  self:register(Event.Update, Entity.updateProjectilesPost)
end

function Entity:addProjectile (source)
  assert(self.projectiles)
  -- Pulse() runs the type initializer (allocates pulse.matrix and registers
  -- destruction); Pulse:new() only allocates from the pool and leaves matrix
  -- null, which crashes the first render in glUniformMatrix4fv.
  local e = Pulse()
  e.source = IncRef(source)
  insert(self.projectiles, e)
  return e
end

function Entity:renderProjectiles (state)
  Pulse.Render(self.projectiles, state)
end

function Entity:updateProjectiles (state)
  Pulse.UpdatePrePhysics(self, self.projectiles, state.dt)
end

function Entity:updateProjectilesPost (state)
  Pulse.UpdatePostPhysics(self, self.projectiles, state.dt)
end
