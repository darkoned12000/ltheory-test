local Entity = require('Game.Entity')
local Batcher = require('Game.Batcher')

function Entity:addVisibleLodMesh (mesh, material)
  assert(not self.mesh)
  assert(mesh)
  assert(material)
  self.mesh = mesh
  self.material = material
  self:register(Event.Render, Entity.renderVisibleLodMesh)
end

function Entity:renderVisibleLodMesh (state)
  if state.mode == BlendMode.Disabled then
    local lod = state.eye:distanceSquared(self:getPos()) / (self:getScale() ^ 2.0)
    if Batcher.isOpen() then
      Batcher.record(self.material, self.mesh, self, lod, false)
    else
      self.material:start()
      self.material:setState(self)
      self.mesh:draw(lod)
      self.material:stop()
    end
  end
end
