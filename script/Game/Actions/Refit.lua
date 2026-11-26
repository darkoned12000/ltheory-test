-- Refit(target, moduleType, opts). opts.equipment selects a canonical module
-- tier; opts may also select a slot, replace an occupied slot, reserve temporary
-- cargo clearance, and pay upkeep for upkeepElapsed seconds. Modules use
-- Ship:plug and retain their SocketObj's durable id.

local Action = require('Game.Action')
local DockAt = require('Game.Actions.DockAt')
local Item = require('Game.Item')
local Progression = require('Game.NpcProgression')
local StableId = require('Game.StableId')
local ShipEquipment = require('Game.ShipEquipment')
local DockService = require('Game.DockService')
local Wallet = require('Game.ProgressionWallet')
local SocketType = require('Game.SocketKind')

local Credit = Item.Credit
local Refit = subclass(Action, function (self, target, moduleType, opts)
  self.isDockService = true
  self.target = target
  self.moduleType = moduleType
  self.opts = opts or {}
  self.result = nil
end)

function Refit:clone ()
  local opts = {}
  for key, value in pairs(self.opts) do opts[key] = value end
  return Refit(self.target, self.moduleType, opts)
end

function Refit:getName ()
  local name = self.equipmentId and ShipEquipment.Label(self.equipmentId)
    or tostring(self.moduleType or 'preferred')
  return format('Refit %s at %s', name, self.target:getName())
end

local function valid (ship, target)
  return ship and not ship.deleted and ship.isAlive and ship:isAlive()
    and target and not target.deleted and target.shipyard
    and (not target.isAlive or target:isAlive())
    and target.hasDockable and target:hasDockable()
end

function Refit:stopDockAction (ship)
  if self.dockAction and ship:getCurrentAction() == self.dockAction then ship:popAction() end
end

function Refit:fail (ship, reason)
  if self.result then return end
  self.result = 'failed'
  DockService.DelayRetry(ship)
  printf('[NPC PROGRESSION] refit fail ship=%s reason=%s', tostring(ship.stableId or ship.id), reason)
end

function Refit:chooseSocket (ship, moduleType)
  local sockets = ship.getSockets and ship:getSockets() or ship.sockets
  if type(sockets) ~= 'table' then return nil, 'ship has no sockets' end
  local occupied, occupiedTier
  local matching = false
  for _, socket in ipairs(sockets) do
    local index = tonumber(socket.typeIndex)
    if socket.type == moduleType and index and index >= 1 and index % 1 == 0
       and (self.opts.slot == nil or index == self.opts.slot) then
      matching = true
      if socket.child == nil then return socket, false end
      if self.opts.replace then
        local tier = ShipEquipment.TierOf(socket.child)
        if not occupied or tier < occupiedTier then occupied, occupiedTier = socket, tier end
      end
    end
  end
  if occupied then return occupied, true end
  return nil, matching and 'matching sockets occupied' or 'no matching socket'
end

function Refit:createModule (ship, moduleType, equipmentId)
  local factory
  if moduleType == SocketType.Thruster then
    factory = require('Game.Entities.Thruster')
  elseif moduleType == SocketType.Turret then
    factory = require('Game.Entities.Turret')
  end
  if type(factory) ~= 'function' then return nil, 'module factory unavailable' end
  local ok, module = pcall(factory)
  if not ok or type(module) ~= 'table' then return nil, 'module construction failed' end
  if not ShipEquipment.Apply(module, equipmentId) then
    module:delete(); return nil, 'unsupported equipment definition'
  end
  if module.setScale then
    local scale = moduleType == SocketType.Thruster and 0.5 * ship:getScale() or 2 * ship:getScale()
    local scaled = pcall(function () module:setScale(scale) end)
    if not scaled then module:delete(); return nil, 'module scaling failed' end
  end
  return module
end

function Refit:restore (ship, socket, previous, module)
  if socket.child == module then
    socket.child = nil
    if module.getParent and module:getParent() == ship then
      pcall(function () ship:detach(module) end)
    end
    if module.delete then module:delete() end
  end
  if previous and not previous.deleted then
    socket.child = nil
    local ok = pcall(function () return ship:plug(previous, socket.typeIndex) end)
    if not ok or socket.child ~= previous then
      -- Last-resort restoration uses the same SocketObj attachment contract.
      -- This path is only for a fixture/engine attach failure, not a normal refit.
      if previous.getParent and previous:getParent() == ship then
        pcall(function () ship:detach(previous) end)
      end
      pcall(function () ship:attach(previous, socket.pos, Quat.Identity()) end)
      socket.child = previous
      previous.moduleType, previous.moduleIndex = socket.type, socket.typeIndex
    end
  end
  self:refreshSocketStats(ship)
end

function Refit:refreshSocketStats (ship)
  if ship.socketRangeMin == nil then return end
  local rangeMin, rangeMax, speedMin, speedMax = 1e6, 0, 1e6, 0
  for _, socket in ipairs(ship:getSockets()) do
    local child = socket.child
    if socket.type == SocketType.Turret and child and not child.deleted then
      rangeMin = math.min(rangeMin, child.projRange or 0)
      rangeMax = math.max(rangeMax, child.projRange or 0)
      speedMin = math.min(speedMin, child.projSpeed or 0)
      speedMax = math.max(speedMax, child.projSpeed or 0)
    end
  end
  ship.socketRangeMin, ship.socketRangeMax = rangeMin, rangeMax
  ship.socketSpeedMin, ship.socketSpeedMax = speedMin, speedMax
end

function Refit:perform (ship)
  if not self.target.addItem or not self.target.removeItem then
    self:fail(ship, 'station cannot accept credits')
    return
  end

  local moduleType = self.moduleType or Progression.PreferredModule(Progression.Role(ship))
  if moduleType ~= SocketType.Thruster and moduleType ~= SocketType.Turret then
    self:fail(ship, 'unsupported module type')
    return
  end
  local equipmentId = self.opts.equipment or self.opts.equipmentId
    or ShipEquipment.DefaultId(moduleType)
  local equipment = ShipEquipment.Get(equipmentId)
  if not equipment or equipment.type ~= moduleType then
    self:fail(ship, 'unsupported equipment definition')
    return
  end
  self.moduleType, self.equipmentId = moduleType, equipmentId

  local socket, replacing = self:chooseSocket(ship, moduleType)
  if not socket then self:fail(ship, replacing); return end
  if type(ship.stableId) ~= 'string' or ship.stableId == '' then
    self:fail(ship, 'ship has no durable id')
    return
  end
  if type(socket.moduleId) ~= 'string' or socket.moduleId == '' then
    socket.moduleId = StableId.Module(ship.stableId, socket.type, socket.typeIndex)
  end
  if not socket.moduleId then self:fail(ship, 'socket has no durable id'); return end

  local clearance = math.max(0, tonumber(self.opts.cargo) or 0)
  if ship:getInventoryFree() < clearance then self:fail(ship, 'insufficient cargo clearance'); return end

  local cost = Progression.RefitCost(ship, moduleType, self.opts.upkeepElapsed, equipmentId)
  if not Wallet.Has(ship, cost) then self:fail(ship, 'insufficient credits'); return end

  local module, err = self:createModule(ship, moduleType, equipmentId)
  if not module then self:fail(ship, err); return end
  local previous = replacing and socket.child or nil
  if previous then
    socket.child = nil
    local detached = pcall(function () ship:detach(previous) end)
    if not detached then
      socket.child = previous
      module:delete()
      self:fail(ship, 'old module detach failed')
      return
    end
  end

  local plugged, plugErr = pcall(function () return ship:plug(module, socket.typeIndex) end)
  if not plugged or not plugErr or socket.child ~= module or module.stableId ~= socket.moduleId then
    self:restore(ship, socket, previous, module)
    self:fail(ship, 'module plug failed')
    return
  end
  self:refreshSocketStats(ship)

  local payment = Wallet.Pay(ship, self.target, cost)
  if not payment then
    self:restore(ship, socket, previous, module)
    self:fail(ship, 'credit payment failed')
    return
  end
  if previous then previous:delete() end
  self:refreshSocketStats(ship)

  self.cost = cost
  self.module = module
  self.socket = socket
  self.result = 'completed'
  DockService.ClearRetry(ship)
  printf('[NPC PROGRESSION] refit complete ship=%s station=%s type=%s slot=%d id=%s cost=%d',
    tostring(ship.stableId), tostring(self.target.stableId or self.target.id), equipmentId,
    socket.typeIndex, tostring(module.stableId), cost)
  ship:popAction()
end

function Refit:onUpdatePassive (ship)
  if self.result then return end
  if not valid(ship, self.target) then
    self:fail(ship, 'dead or invalid station')
    self:stopDockAction(ship)
  end
end

function Refit:onUpdateActive (ship)
  if self.result then ship:popAction(); return end
  if not valid(ship, self.target) then
    self:fail(ship, 'dead or invalid station')
    self:stopDockAction(ship)
    ship:popAction()
    return
  end
  if ship:getParent() ~= self.target then
    if ship:getCurrentAction() ~= self.dockAction then
      self.dockAction = DockAt(self.target)
      ship:pushAction(self.dockAction)
    end
    return
  end
  self:perform(ship)
  if self.result == 'failed' and ship:getCurrentAction() == self then ship:popAction() end
end

return Refit
