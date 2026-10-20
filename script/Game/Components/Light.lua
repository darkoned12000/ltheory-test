local Entity = require('Game.Entity')

function Entity:addLight (r, g, b)
  assert(not self.light)
  self.light = Vec3f(r, g, b)
  -- If this is already a direct System child, register immediately. Lights
  -- added before parenting are picked up by System's ChildAdded handler.
  local root = self:getRoot()
  if self.parent == root and root.registerLightEntity then
    root:registerLightEntity(self)
  end
end

function Entity:getLight ()
  assert(self.light)
  return self.light
end

function Entity:hasLight ()
  return self.light ~= nil
end

function Entity:setLight (r, g, b)
  if not self.light then self:addLight(r, g, b) end
  self.light.x = r
  self.light.y = g
  self.light.z = b
end
