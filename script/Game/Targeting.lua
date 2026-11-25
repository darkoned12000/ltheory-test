-- Generic target eligibility shared by the HUD and player actions. Live ships
-- and minable asteroids are targetable; destroyed, deleted, and bodyless
-- entities are not.

local Targeting = {}

function Targeting.UsesMouseAim (device)
  return device == DeviceType.Mouse or device == DeviceType.Keyboard
end

function Targeting.RaySphereDistance (ox, oy, oz, dx, dy, dz, cx, cy, cz, radius)
  if radius <= 0 then return nil end
  local px, py, pz = ox - cx, oy - cy, oz - cz
  local b = px*dx + py*dy + pz*dz
  local c = px*px + py*py + pz*pz - radius*radius
  if c <= 0 then return 0 end
  local h = b*b - c
  if h < 0 then return nil end
  local t = -b - math.sqrt(h)
  if t < 0 then t = -b + math.sqrt(h) end
  if t < 0 then return nil end
  return t
end

function Targeting.SurfaceGap (entity, ship)
  if not entity or not ship then return nil end
  if ship.getMinDistance and entity.body then return ship:getMinDistance(entity) end
  local ep = entity.getPos and entity:getPos()
  local sp = ship.getPos and ship:getPos()
  if not ep or not sp then return nil end
  local dx, dy, dz = ep.x - sp.x, ep.y - sp.y, ep.z - sp.z
  local radius = (entity.getRadius and entity:getRadius() or 0)
    + (ship.getRadius and ship:getRadius() or 0)
  return math.max(0, math.sqrt(dx*dx + dy*dy + dz*dz) - radius)
end

function Targeting.IsTargetable (entity)
  if not entity or not entity.body or entity.deleted then return false end
  if entity.isDestroyed and entity:isDestroyed() then return false end
  if entity.isAlive and entity:isAlive() then return true end
  if entity.isPlanet then return true end
  return entity.hasYield and entity:hasYield() or false
end

function Targeting.ScreenScore (x, y, bx, by, bw, bh, aim, pad)
  pad = pad or 12
  if aim.x < bx - pad or aim.x > bx + bw + pad
     or aim.y < by - pad or aim.y > by + bh + pad then
    return nil
  end
  local dx, dy = aim.x - x, aim.y - y
  return dx*dx + dy*dy
end

return Targeting
