local Entity = require('Game.Entity')

function Entity:addLight (r, g, b)
  assert(not self.light)
  self.light = Vec3f(r, g, b)
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
