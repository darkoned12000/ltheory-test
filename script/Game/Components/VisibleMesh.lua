local Entity = require('Game.Entity')
local Batcher = require('Game.Batcher')

function Entity:addVisibleMesh (mesh, material)
  assert(not self.mesh)
  assert(mesh)
  assert(material)
  self.mesh = mesh
  self.material = material
  self:register(Event.Render, Entity.renderVisibleMesh)
end

function Entity:renderVisibleMesh (state)
  if state.mode == BlendMode.Disabled then
    if not (Batcher.isOpen() and Batcher.record(self.material, self.mesh, self, nil, true)) then
      self.material:start()
      self.material:setState(self)
      self.mesh:draw()
      self.material:stop()
    end
  end
end
