local Entity = require('Game.Entity')
local Batcher = require('Game.Batcher')
local Material = require('Game.Material')
local Shadow = require('Game.Shadow')
local Frustum = require('Game.Frustum')

function Entity:addVisibleMesh (mesh, material)
  assert(not self.mesh)
  assert(mesh)
  assert(material)
  self.mesh = mesh
  self.material = material
  self:register(Event.Render, Entity.renderVisibleMesh)
end

function Entity:renderVisibleMesh (state)
  if state.pass == 'sunshadow' or state.pass == 'pointshadow' then
    if state.mode == BlendMode.Disabled and Shadow.isInMap(self, state) then
      local shadow = Material.Shadow()
      if not state.shadowActive then shadow:start() end
      shadow:setState(self)
      self.mesh:draw()
      if not state.shadowActive then shadow:stop() end
    end
    return
  end

  if state.mode == BlendMode.Disabled then
    -- Frustum cull. See VisibleLodMesh.lua for why this is opt-in per material:
    -- a mesh whose visible geometry reaches past its collision sphere must not be
    -- culled by that sphere, or it would disappear while still on screen.
    local planes = Frustum.getCurrent()
    if planes and self.material and self.material.cullable and self.body then
      local radius = self.body:getBoundingRadius()
      if radius > 0 then
        local pos = Vec3f()
        self.body:getPos(pos)
        -- See VisibleLodMesh.lua: the collision sphere bounds the base mesh and
        -- the drawn mesh is an LOD of it, so a margin is added before culling.
        if not Frustum.sphereVisible(planes, pos.x, pos.y, pos.z, radius * 1.15) then
          return
        end
      end
    end

    if not (Batcher.isOpen() and Batcher.record(self.material, self.mesh, self, nil, true)) then
      self.material:start()
      self.material:setState(self)
      self.mesh:draw()
      self.material:stop()
    end
  end
end
