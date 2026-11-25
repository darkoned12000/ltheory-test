local Entity = require('Game.Entity')
local Material = require('Game.Material')
local Movement = require('Game.ShipMovement')
local Registry = require('Game.Registry')
local StableId = require('Game.StableId')
local Targeting = require('Game.Targeting')
local Knowledge = require('Game.Knowledge')

local Ship = subclass(Entity, function (self, proto, instanceSerial, stableId)
  self:addActions()
  self:addCapacitor(100, 10)
  self:addChildren()
  self:addExplodable()
  self:addHealth(100, 10)
  self:addInventory(100)
  -- TODO : This will create a duplicate BSP because proto & RigidBody do not
  --        share the same BSP cache. Need unified cache.
  self:addRigidBody(true, proto.mesh)
  -- ShipType.scale is part of the prototype, not just preview metadata. Apply
  -- it before sockets, collision radius, visible matrix, and mass are derived.
  self:setScale(proto.scale or 1)
  self:addSockets()
  self:addVisibleMesh(proto.mesh, Material.Metal())
  self:addThrustController()
  self.stableId = stableId or Registry.NewId('ship', proto.seed or self.id, instanceSerial or 1)
  self:addRegistryInfo({
    id = self.stableId,
    classId = proto.classId or ((proto.scale or 1) >= 32 and 3 or 2),
    manufacturer = 'LimTech',
    model = proto.model or ((proto.scale or 1) >= 32 and 'Capital' or 'Fighter'),
    year = 150,
    materialTier = 2,
  })

  -- TODO : Suggestive that JS-style prototype objects + 'clone' would work
  --        better for ShipType et al
  for type, elems in pairs(proto.sockets) do
    for i, pos in ipairs(elems) do
      self:addSocket(type, pos, true, i, StableId.Module(self.stableId, type, i))
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
  local cargo = self:hasInventory() and (self:getInventoryCapacity() - self:getInventoryFree()) or 0
  return Movement.topSpeed(self:getRadius(), cargo, self:getInventoryCapacity())
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
function Ship:getScanStatus (target)
  if not self:isIdle() then return 'busy' end
  if not target or not target.body then return 'no target' end
  if not (target.isAsteroid or target:hasYield()) then return 'invalid target' end
  self.knowledge = self.knowledge or Knowledge.Create()
  self.scannedAsteroids = self.knowledge.scannedAsteroids
  if Knowledge.Scanned(self.knowledge, target) then return 'already scanned' end
  local range = (Config.game and Config.game.scanRange) or 2000
  if self:getMinDistance(target) > range then return 'out of range' end
  return 'ready'
end

function Ship:scanTarget (target)
  local status = self:getScanStatus(target)
  if status ~= 'ready' then return false, status end
  local Scan = require('Game.Actions.Scan')
  self:pushAction(Scan(target))
  return true
end

function Ship:scanForResources ()
  local target = self:getTarget()
  self.knowledge = self.knowledge or Knowledge.Create()
  self.scannedAsteroids = self.knowledge.scannedAsteroids
  if not target or not (target.isAsteroid or (target.hasYield and target:hasYield()))
     or Knowledge.Scanned(self.knowledge, target) then
    local root = self:getRoot()
    local range = (Config.game and Config.game.scanRange) or 2000
    target = root and root.findScanTarget and root:findScanTarget(self, range)
  end
  return self:scanTarget(target)
end

function Ship:getMiningStatus (target)
  if not Targeting.IsTargetable(target) or not target.hasYield or not target:hasYield() then
    return 'no minable target'
  end
  local current = self:getCurrentAction()
  if current and current.target == target and current.getName
     and current:getName():sub(1, 6) == 'MineAt' then
    return 'mining'
  end
  if current then return 'busy' end
  local range = (Config.game and Config.game.miningRange) or 250
  if self:getMinDistance(target) > range then return 'approach' end
  if self.getForward and target.getPos then
    local dx = target:getPos().x - self:getPos().x
    local dy = target:getPos().y - self:getPos().y
    local dz = target:getPos().z - self:getPos().z
    local length = math.sqrt(dx*dx + dy*dy + dz*dz)
    local forward = self:getForward()
    local alignment = length > 1e-6
      and (forward.x*dx + forward.y*dy + forward.z*dz) / length or 1
    if alignment < ((Config.game and Config.game.miningAlignment) or 0.85) then
      return 'align'
    end
  end
  if self.hasInventory and self:hasInventory() and self.getInventoryFree then
    local mass = target:getYield().item:getMass()
    if self:getInventoryFree() < mass then return 'cargo full' end
  end
  local speed = self.getSpeed and self:getSpeed() or 0
  local tolerance = (Config.game and Config.game.miningSpeedTolerance) or 3
  if speed > tolerance then return 'stop' end
  return 'ready'
end

function Ship:mineTarget (target)
  local status = self:getMiningStatus(target)
  if status == 'mining' then return true end
  if status ~= 'ready' and status ~= 'stop' then return false, status end
  local range = (Config.game and Config.game.miningRange) or 250
  local MineAt = require('Game.Actions.MineAt')
  local Stop = require('Game.Actions.Stop')
  -- MineAt stays underneath the active brake; its beam is hidden until Stop
  -- pops and the hull is genuinely stationary.
  self:pushAction(MineAt(target, range))
  self:pushAction(Stop())
  return true
end

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

function Ship:delete ()
  local owner = self:getOwner()
  if owner then owner:removeAsset(self) end
  Entity.delete(self)
end

return Ship
