local Entity = require('Game.Entity')
local Material = require('Game.Material')

local Ship = subclass(Entity, function (self, proto)
  self:addActions()
  self:addCapacitor(100, 10)
  self:addChildren()
  self:addExplodable()
  self:addHealth(100, 10)
  self:addInventory(100)
  -- TODO : This will create a duplicate BSP because proto & RigidBody do not
  --        share the same BSP cache. Need unified cache.
  self:addRigidBody(true, proto.mesh)
  self:addSockets()
  self:addVisibleMesh(proto.mesh, Material.Metal())
  self:addThrustController()

  -- TODO : Suggestive that JS-style prototype objects + 'clone' would work
  --        better for ShipType et al
  for type, elems in pairs(proto.sockets) do
    for i, pos in ipairs(elems) do
      self:addSocket(type, pos, true)
    end
  end

  self:setDrag(0.75, 4.0)

  local mass = 50.0 * (self:getRadius() ^ 3.0)
  self:setMass(mass)
end)

-- The ship's top speed in units per second, under full thrust.
--
-- TODO : Calculate true top speed based on max thrust & drag factor
--
-- It is what the JOBS use to decide how long a trip takes (2x the distance
-- over the top speed), so it has to agree with what the thrusters actually
-- do -- see ThrustController's thrust constants, which are what set it.
function Ship:getTopSpeed ()
  return 500
end

-- Targeting for NPC caps (docs/npcwork.md): the ship queries the system for
-- its caps (system:npcTargets) and the HUD calls these from ShipBindings
-- (TargetNearestNpc, CycleNpcTarget, TargetNearestThreat).

function Ship:getNpcs ()
  local sys = self:getParent()
  if not sys or not sys.npcTargets then return {} end
  return sys:npcTargets(self)
end

function Ship:targetNearestNpc ()
  local nps = self:getNpcs()
  if #nps == 0 then return end
  local p = self:getPos()
  local best, bd = nil, math.huge
  for _, e in ipairs(nps) do
    local d = (e:getPos() - p):length()
    if d < bd then bd, best = d, e end
  end
  if best then self:setTarget(best) end
end

function Ship:cycleNpcTarget ()
  local nps = self:getNpcs()
  if #nps == 0 then return end
  local cur = self:getTarget()
  local idx = -1
  for i, e in ipairs(nps) do
    if e == cur then idx = i; break end
  end
  if idx <= 0 then self:targetNearestNpc() return end
  self:setTarget(nps[(idx % #nps) + 1])
end

-- Nearest cap with a hostile (negative) disposition toward the player, else
-- the nearest cap (all caps are neutral today -- see Dispositions).
function Ship:targetNearestThreat ()
  local nps = self:getNpcs()
  if #nps == 0 then return end
  local p = self:getPos()
  local best, bd = nil, math.huge
  for _, e in ipairs(nps) do
    if e:getOwnerDisposition(self) < 0.0 then
      local d = (e:getPos() - p):length()
      if d < bd then bd, best = d, e end
    end
  end
  if not best then self:targetNearestNpc() end
end

return Ship
