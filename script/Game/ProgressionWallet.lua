-- Unified wallet for ship services. NPC actors keep credits as Item.Credit;
-- the human player's controlling ship uses the Credits component.
local Item = require('Game.Item')
local Credit = Item.Credit
local Wallet = {}

local function resolve (ship, cost)
  local owner = ship and ship.getOwner and ship:getOwner()
  if owner and owner.hasItem and owner:hasItem(Credit, cost) then
    return owner, true
  end
  if ship and ship.hasCredits and ship:hasCredits(cost) then
    return ship, false
  end
  if owner and owner.hasItem then return owner, true end
  return ship, false
end

function Wallet.Has (ship, cost)
  local entity = resolve(ship, cost)
  if not entity then return false end
  local _, item = resolve(ship, cost)
  return item and entity:hasItem(Credit, cost)
    or entity.hasCredits and entity:hasCredits(cost)
    or false
end

function Wallet.Pay (ship, station, cost)
  cost = math.max(0, math.floor(tonumber(cost) or 0))
  if cost == 0 then return { entity = nil, item = false, paid = 0 } end
  local entity, item = resolve(ship, cost)
  if not entity or not (item and entity:hasItem(Credit, cost)
      or entity.hasCredits and entity:hasCredits(cost)) then
    return nil
  end
  if item then
    if not entity:removeItem(Credit, cost) then return nil end
  else
    entity:removeCredits(cost)
  end
  if not station or not station.addItem or not station:addItem(Credit, cost) then
    if item then entity:addItem(Credit, cost) else entity:addCredits(cost) end
    return nil
  end
  return { entity = entity, item = item, paid = cost }
end

function Wallet.Refund (payment, station, amount)
  if not payment then return 0 end
  amount = math.max(0, math.min(math.floor(tonumber(amount) or 0), payment.paid or 0))
  if amount == 0 then return 0 end
  if not station or not station.removeItem or not station:removeItem(Credit, amount) then
    return 0
  end
  if payment.item then
    payment.entity:addItem(Credit, amount)
  else
    payment.entity:addCredits(amount)
  end
  payment.paid = (payment.paid or 0) - amount
  return amount
end

function Wallet.Destination (ship)
  local owner = ship and ship.getOwner and ship:getOwner()
  if owner and owner.hasItem and owner:getItemCount(Credit, 0) > 0 then
    return owner, true
  end
  if ship and ship.hasCredits and ship:hasCredits(0) then return ship, false end
  if owner and owner.hasItem then return owner, true end
  return ship, false
end

function Wallet.Balance (ship)
  local entity, item = Wallet.Destination(ship)
  if not entity then return 0 end
  if item then return entity:getItemCount(Credit) end
  return entity.getCredits and entity:getCredits() or 0
end

function Wallet.CanPay (entity, amount)
  amount = math.max(0, math.floor(tonumber(amount) or 0))
  if not entity then return amount == 0 end
  if entity.hasItem and entity:hasItem(Credit, amount) then return true end
  return entity.hasCredits and entity:hasCredits(amount) or false
end

-- Shipyard payouts (trade-in excess or a future standalone sale) use the
-- station's cash wallet first, then its Credit-item escrow.
function Wallet.Receive (ship, station, amount)
  amount = math.max(0, math.floor(tonumber(amount) or 0))
  if amount == 0 then return true end
  if not station or not Wallet.CanPay(station, amount) then return false end
  local paid = false
  if station.hasCredits and station:hasCredits(amount) then
    station:removeCredits(amount); paid = true
  elseif station.hasItem and station:hasItem(Credit, amount) then
    if not station:removeItem(Credit, amount) then return false end
    paid = true
  end
  if not paid then return false end
  local entity, item = Wallet.Destination(ship)
  if not entity then return false end
  if item then entity:addItem(Credit, amount) else entity:addCredits(amount) end
  return true
end

function Wallet.MoveBalance (fromShip, toShip)
  local entity, item = Wallet.Destination(fromShip)
  if not entity or item or not entity.getCredits then return true end
  local amount = math.max(0, entity:getCredits())
  if amount == 0 then return true end
  entity:removeCredits(amount)
  toShip:addCredits(amount)
  return true
end

return Wallet
