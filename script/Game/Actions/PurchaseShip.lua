-- PurchaseShip(target, opts) buys a role hull at a docked shipyard. opts accepts
-- kind, seed, and an optional explicit shipId. Credits remain in the actor's
-- Item.Credit inventory; cargo moves to the new hull. Success leaves it docked
-- and controlling, retires only the old ship, and records a purchase serial for
-- the next stable id (the parent integration may persist that serial).

local Action = require('Game.Action')
local DockAt = require('Game.Actions.DockAt')
local Item = require('Game.Item')
local Progression = require('Game.NpcProgression')
local ShipArchetypes = require('Game.ShipArchetypes')
local StableId = require('Game.StableId')

local Credit = Item.Credit
local PurchaseShip = subclass(Action, function (self, target, opts)
  self.target = target
  self.opts = opts or {}
  self.result = nil
  self.charged = false
  self.stationPaid = false
end)

function PurchaseShip:clone ()
  local opts = {}
  for key, value in pairs(self.opts) do opts[key] = value end
  return PurchaseShip(self.target, opts)
end

function PurchaseShip:getName ()
  return format('PurchaseShip at %s', self.target:getName())
end

local function valid (ship, target)
  local shipyard = target and (target.shipyard
    or (target.hasMarket and target:hasMarket()) or (target.hasTrader and target:hasTrader()))
  return ship and not ship.deleted and ship.isAlive and ship:isAlive()
    and target and not target.deleted and (not target.isAlive or target:isAlive())
    and target.hasDockable and target:hasDockable() and shipyard
end

function PurchaseShip:stopDockAction (ship)
  if self.dockAction and ship:getCurrentAction() == self.dockAction then ship:popAction() end
end

function PurchaseShip:fail (ship, reason)
  self.result = 'failed'
  printf('[NPC PROGRESSION] purchase fail ship=%s reason=%s', tostring(ship.stableId or ship.id), reason)
end

function PurchaseShip:refundCredits ()
  if self.charged then
    self.owner:addItem(Credit, self.cost)
    self.charged = false
  end
  if self.stationPaid then
    if self.target.removeItem then self.target:removeItem(Credit, self.cost) end
    self.stationPaid = false
  end
end

function PurchaseShip:dispose (newShip)
  if not newShip then return end
  newShip:clearActions()
  newShip:delete()
  local parent = newShip:getParent()
  if parent then parent:removeChild(newShip) end
  local root = self.root
  if root and root.stableIndex and root.stableIndex[newShip.stableId] == newShip then
    root.stableIndex[newShip.stableId] = nil
  end
end

function PurchaseShip:restoreCargo (oldShip, moved)
  for _, entry in ipairs(moved) do
    -- Rollback must not replace the original failure with a second hard error.
    pcall(function () entry.ship:removeItem(entry.item, entry.count) end)
    oldShip:addItem(entry.item, entry.count)
  end
end

function PurchaseShip:abort (oldShip, newShip, moved, reason)
  if newShip then
    self:restoreCargo(oldShip, moved)
    if newShip:getOwner() == self.owner then newShip:setOwner(nil) end
    self:dispose(newShip)
  end
  self:refundCredits()
  self:fail(oldShip, reason)
  oldShip:popAction()
end

local function cargoMass (ship)
  local mass = 0
  for item, count in pairs(ship:getInventory()) do
    mass = mass + math.max(0, count) * item:getMass()
  end
  return mass
end

function PurchaseShip:nextShipId (oldShip, owner)
  if self.opts.shipId ~= nil then
    local id = self.opts.shipId
    if type(id) ~= 'string' or id == '' or id == oldShip.stableId
       or (self.root.resolveStableId and self.root:resolveStableId(id))
       or (self.root.isTombstoned and self.root:isTombstoned(id)) then
      return nil
    end
    return id, (owner.npcProgression and owner.npcProgression.purchaseSerial or 0) + 1
  end

  local actorId = StableId.For(owner) or (owner.getActorId and owner:getActorId()) or 'player'
  local serial = (owner.npcProgression and owner.npcProgression.purchaseSerial or 0) + 1
  while true do
    local id = string.format('ship:%s:purchase:%d', tostring(actorId), serial)
    local occupied = self.root.resolveStableId and self.root:resolveStableId(id)
    if not occupied and owner.iterAssets then
      for asset in owner:iterAssets() do
        if asset.stableId == id then occupied = asset; break end
      end
    end
    if id ~= oldShip.stableId and not occupied
       and not (self.root.isTombstoned and self.root:isTombstoned(id)) then
      return id, serial
    end
    serial = serial + 1
  end
end

function PurchaseShip:transferCargo (oldShip, newShip)
  local items = {}
  for item, count in pairs(oldShip:getInventory()) do
    if count > 0 then items[#items + 1] = { item = item, count = count } end
  end
  table.sort(items, function (a, b) return a.item:getName() < b.item:getName() end)

  local moved = {}
  for _, entry in ipairs(items) do
    if not newShip:addItem(entry.item, entry.count) then return false, moved end
    if not oldShip:removeItem(entry.item, entry.count) then return false, moved end
    moved[#moved + 1] = { ship = newShip, item = entry.item, count = entry.count }
  end
  return true, moved
end

function PurchaseShip:retire (oldShip, newShip, owner)
  -- clearActions also removes this action, so completion must not pop again.
  oldShip:clearActions()
  local parent = oldShip:getParent()
  if parent and parent.hasDockable and parent:hasDockable() then parent:removeDocked(oldShip) end
  if oldShip:getOwner() == owner then oldShip:setOwner(nil) end
  oldShip:delete()
  parent = oldShip:getParent()
  if parent then parent:removeChild(oldShip) end
  if self.root.stableIndex and self.root.stableIndex[oldShip.stableId] == oldShip then
    self.root.stableIndex[oldShip.stableId] = nil
  end
  if self.root.markTombstone and oldShip.stableId then self.root:markTombstone(oldShip.stableId) end

  owner:setControlling(newShip)
  owner.npcProgression = owner.npcProgression or {}
  owner.npcProgression.purchaseSerial = self.purchaseSerial
  newShip.npcRole = oldShip.npcRole or Progression.Role(oldShip)
  newShip.npcPolicy, newShip.npcSafety = oldShip.npcPolicy, oldShip.npcSafety
  newShip.knowledge = oldShip.knowledge
  newShip.knownYields, newShip.scannedAsteroids = oldShip.knownYields, oldShip.scannedAsteroids
  newShip.afterProgression = oldShip.afterProgression
  newShip.npcUpkeepElapsed, newShip.npcUpkeepDebt = oldShip.npcUpkeepElapsed, oldShip.npcUpkeepDebt
  newShip.npcNextTravelAt, newShip.npcLastLogAt = oldShip.npcNextTravelAt, oldShip.npcLastLogAt
  if self.root.unregisterKnowledgeShip then self.root:unregisterKnowledgeShip(oldShip) end
  if self.root.registerKnowledgeShip then self.root:registerKnowledgeShip(newShip) end
  self.retired = true
end

function PurchaseShip:perform (oldShip)
  local owner = oldShip:getOwner()
  local root = oldShip:getRoot()
  if not owner or not owner.hasItem or not owner.removeItem or not owner.addItem then
    self:fail(oldShip, 'missing actor inventory'); oldShip:popAction(); return
  end
  if not root or type(root.spawnShip) ~= 'function' then
    self:fail(oldShip, 'root cannot spawn ships'); oldShip:popAction(); return
  end
  if not self.target.addItem or not self.target.removeItem then
    self:fail(oldShip, 'station cannot accept credits'); oldShip:popAction(); return
  end

  local kind = self.opts.kind or Progression.PreferredShipKind(Progression.Role(oldShip))
  if not ShipArchetypes.Defs[kind] then
    self:fail(oldShip, 'unsupported ship kind'); oldShip:popAction(); return
  end
  local cost = Progression.ShipCost(oldShip, kind)
  if not owner:hasItem(Credit, cost) then
    self:fail(oldShip, 'insufficient credits'); oldShip:popAction(); return
  end

  local mass = cargoMass(oldShip)
  if mass > ShipArchetypes.Get(kind).cargo + 1e-9 then
    self:fail(oldShip, 'cargo exceeds new ship capacity'); oldShip:popAction(); return
  end

  self.owner, self.root, self.cost = owner, root, cost
  local shipId, serial = self:nextShipId(oldShip, owner)
  if not shipId then self:fail(oldShip, 'no available stable ship id'); oldShip:popAction(); return end

  self.purchaseSerial = serial
  if not owner:removeItem(Credit, cost) then
    self:fail(oldShip, 'credit payment failed'); oldShip:popAction(); return
  end
  self.charged = true

  local spawned, newShip = pcall(function ()
    return root:spawnShip(kind, {
      shipId = shipId,
      seed = self.opts.seed or oldShip.prototypeSeed,
      pos = oldShip:getPos(),
    })
  end)
  if not spawned or type(newShip) ~= 'table' or newShip.deleted or newShip == oldShip
     or newShip.stableId ~= shipId or not newShip.addItem or not newShip.setOwner then
    -- A spawn implementation may have attached the hull before throwing.
    local partial = root.resolveStableId and root:resolveStableId(shipId)
    if type(partial) == 'table' and partial ~= oldShip then newShip = partial end
    self:abort(oldShip, type(newShip) == 'table' and newShip or nil, {}, 'ship spawn failed')
    return
  end
  self.newShip = newShip

  local docked = pcall(function () self.target:addDocked(newShip) end)
  if not docked then self:abort(oldShip, newShip, {}, 'new ship docking failed'); return end

  if cargoMass(oldShip) > newShip:getInventoryCapacity() + 1e-9 then
    self:abort(oldShip, newShip, {}, 'spawned cargo capacity is insufficient'); return
  end
  local transferred, moved = self:transferCargo(oldShip, newShip)
  if not transferred then self:abort(oldShip, newShip, moved, 'cargo transfer failed'); return end

  newShip:setOwner(owner)
  if not self.target:addItem(Credit, cost) then
    self:abort(oldShip, newShip, moved, 'station payment failed'); return
  end
  self.stationPaid = true
  self.charged = false -- payment is now settled; finalization cannot fail normally

  self:retire(oldShip, newShip, owner)
  self.result = 'completed'
  printf('[NPC PROGRESSION] purchase complete actor=%s old=%s new=%s kind=%s cost=%d cargo=%.1f',
    tostring(owner.getNpcId and owner:getNpcId() or StableId.For(owner)), tostring(oldShip.stableId),
    tostring(newShip.stableId), kind, cost, mass)
end

function PurchaseShip:onUpdatePassive (ship)
  if self.result then return end
  if not valid(ship, self.target) then
    self:fail(ship, 'dead, undockable, or not a shipyard')
    self:stopDockAction(ship)
  end
end

function PurchaseShip:onUpdateActive (ship)
  if self.result then ship:popAction(); return end
  if not valid(ship, self.target) then
    self:fail(ship, 'dead, undockable, or not a shipyard')
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
end

return PurchaseShip
