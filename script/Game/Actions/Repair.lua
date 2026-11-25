-- Repair(target) approaches with DockAt, charges the actor once at the berth,
-- and heals over ordinary simulation dt. Completion leaves the ship docked;
-- cancellation refunds the unperformed portion of the prepaid repair.

local Action = require('Game.Action')
local DockAt = require('Game.Actions.DockAt')
local Item = require('Game.Item')
local Progression = require('Game.NpcProgression')

local Credit = Item.Credit
local Repair = subclass(Action, function (self, target)
  self.target = target
  self.result = nil
  self.paid = false
  self.elapsed = 0
  self.nextLogProgress = 0.25
end)

function Repair:clone ()
  return Repair(self.target)
end

function Repair:getName ()
  return format('Repair at %s', self.target:getName())
end

local function valid (ship, target)
  return ship and not ship.deleted and ship.isAlive and ship:isAlive()
    and target and not target.deleted and (not target.isAlive or target:isAlive())
    and target.hasDockable and target:hasDockable()
end

function Repair:stopDockAction (ship)
  if self.dockAction and ship:getCurrentAction() == self.dockAction then
    ship:popAction()
  end
end

function Repair:refund (ship)
  if not self.paid then return end
  local refund = self.cost
  if self.initialMissing and self.initialMissing > 0 then
    local restored = math.max(0, math.min(self.initialMissing, ship.health - self.startHealth))
    local earned = math.ceil(restored * self.cost / self.initialMissing - 1e-9)
    refund = math.max(0, self.cost - earned)
  end
  self.paid = false
  self.refunded = refund
  if refund > 0 then
    if self.target.removeItem then self.target:removeItem(Credit, refund) end
    if self.owner and self.owner.addItem then self.owner:addItem(Credit, refund) end
  end
end

function Repair:cancel (ship, reason)
  if self.result then return end
  self:refund(ship)
  self.result = 'cancelled'
  printf('[NPC PROGRESSION] repair cancel ship=%s reason=%s refund=%d',
    tostring(ship.stableId or ship.id), reason, self.refunded or 0)
end

function Repair:fail (ship, reason)
  if self.result then return end
  self.result = 'failed'
  printf('[NPC PROGRESSION] repair fail ship=%s reason=%s',
    tostring(ship.stableId or ship.id), reason)
end

function Repair:onUpdatePassive (ship)
  if self.result then return end
  if not valid(ship, self.target) then
    self:cancel(ship, 'dead or invalid station')
    self:stopDockAction(ship)
  elseif self.paid and ship:getParent() ~= self.target then
    self:cancel(ship, 'undocked')
    self:stopDockAction(ship)
  end
end

function Repair:begin (ship)
  local owner = ship:getOwner()
  if not owner or not owner.hasItem or not owner.removeItem or not owner.addItem then
    self:fail(ship, 'missing actor inventory')
    return false
  end
  if not self.target.addItem or not self.target.removeItem then
    self:fail(ship, 'station cannot accept credits')
    return false
  end

  local missing = math.max(0, ship.healthMax - ship.health)
  if missing <= 1e-9 then
    self.result = 'completed'
    printf('[NPC PROGRESSION] repair complete ship=%s hull=full', tostring(ship.stableId or ship.id))
    return false
  end

  local cost = Progression.RepairCost(ship)
  if not owner:hasItem(Credit, cost) then
    self:fail(ship, 'insufficient credits')
    return false
  end
  if not owner:removeItem(Credit, cost) then
    self:fail(ship, 'credit payment failed')
    return false
  end
  if not self.target:addItem(Credit, cost) then
    owner:addItem(Credit, cost)
    self:fail(ship, 'station payment failed')
    return false
  end

  self.owner = owner
  self.cost = cost
  self.paid = true
  self.startHealth = ship.health
  self.initialMissing = missing
  self.rate = Progression.RepairRate(ship)
  printf('[NPC PROGRESSION] repair start ship=%s station=%s hull=%.1f/%.1f cost=%d',
    tostring(ship.stableId or ship.id), tostring(self.target.stableId or self.target.id),
    ship.health, ship.healthMax, cost)
  return true
end

function Repair:getProgress ()
  if not self.initialMissing or self.initialMissing <= 0 then return 0 end
  local current = self.currentHealth or self.startHealth or 0
  return math.max(0, math.min(1, (current - (self.startHealth or current)) / self.initialMissing))
end

function Repair:onUpdateActive (ship, dt)
  if self.result then ship:popAction(); return end
  if not valid(ship, self.target) then
    self:cancel(ship, 'dead or invalid station')
    self:stopDockAction(ship)
    ship:popAction()
    return
  end

  if not self.paid then
    if ship:getParent() ~= self.target then
      -- DockAt is the existing normal-speed approach. Repair stays underneath
      -- and performs no work until the reparent has actually completed.
      if ship:getCurrentAction() ~= self.dockAction then
        self.dockAction = DockAt(self.target)
        ship:pushAction(self.dockAction)
      end
      return
    end
    if not self:begin(ship) then ship:popAction(); return end
  elseif ship:getParent() ~= self.target then
    self:cancel(ship, 'undocked')
    ship:popAction()
    return
  end

  dt = math.max(0, tonumber(dt) or 0)
  self.elapsed = self.elapsed + dt
  self.currentHealth = math.min(ship.healthMax, ship.health + self.rate * dt)
  ship:setHealth(self.currentHealth, ship.healthMax, ship.healthRate or 0)

  if self.currentHealth >= ship.healthMax - 1e-9 then
    self:refund(ship)
    self.result = 'completed'
    printf('[NPC PROGRESSION] repair complete ship=%s hull=%.1f/%.1f elapsed=%.2f cost=%d',
      tostring(ship.stableId or ship.id), ship.health, ship.healthMax, self.elapsed, self.cost - (self.refunded or 0))
    ship:popAction()
    return
  end

  local progress = self:getProgress()
  while progress >= self.nextLogProgress do
    printf('[NPC PROGRESSION] repair progress ship=%s percent=%d hull=%.1f/%.1f',
      tostring(ship.stableId or ship.id), math.floor(self.nextLogProgress * 100), ship.health, ship.healthMax)
    self.nextLogProgress = self.nextLogProgress + 0.25
  end
end

function Repair:onStop (ship)
  if self.paid then self:cancel(ship, 'action stopped') end
end

return Repair
