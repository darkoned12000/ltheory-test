-- Pure NPC progression policy. Costs come from the canonical hull/equipment
-- catalog; decisions never mutate ships or actors.

local ShipArchetypes = require('Game.ShipArchetypes')
local ShipEquipment = require('Game.ShipEquipment')
local SocketType = require('Game.SocketKind')

local Progression = {}

local REPAIR_HEALTH = 0.35
local REFIT_HEALTH = 0.35
local SHIP_RESERVE_MULTIPLE = 2

local roleShips = {
  fighter = 'fighter',
  freighter = 'freighter',
  industrial = 'industrial',
  capital = 'capital',
  -- Design-role aliases remain deterministic before richer NPC roles exist.
  escort = 'fighter',
  patrol = 'fighter',
  miner = 'industrial',
  trader = 'freighter',
}

local function finite (value, fallback)
  value = tonumber(value)
  if value and value == value and value ~= math.huge and value ~= -math.huge then
    return value
  end
  return fallback
end

local function nonnegative (value)
  return math.max(0, finite(value, 0))
end

local function clamp01 (value)
  return math.max(0, math.min(1, value))
end

local function credits (value)
  return math.max(0, math.ceil(nonnegative(value) - 1e-9))
end

function Progression.Role (ship)
  if type(ship) ~= 'table' then return 'fighter' end
  local role = ship.npcRole
  if not role and ship.getOwner then
    local owner = ship:getOwner()
    role = owner and owner.getNpcProfile and owner:getNpcProfile()
    role = type(role) == 'table' and role.role or nil
  end
  if roleShips[role] then return role end
  return roleShips[ship.shipKind] and ship.shipKind or 'fighter'
end

function Progression.PreferredShipKind (role)
  return roleShips[role] or 'fighter'
end

function Progression.PreferredModule (role)
  local kind = Progression.PreferredShipKind(role)
  if kind == 'freighter' or kind == 'industrial' then return SocketType.Thruster end
  return SocketType.Turret
end

function Progression.ShipCost (ship, kind)
  kind = kind or Progression.PreferredShipKind(Progression.Role(ship))
  return credits(ShipArchetypes.Get(kind).price)
end

-- Upkeep is 0.02% of the current hull's purchase value per simulated hour.
function Progression.Upkeep (ship, elapsed)
  local hours = nonnegative(elapsed) / 3600
  local kind = type(ship) == 'table' and roleShips[ship.shipKind] and ship.shipKind or nil
  return credits(Progression.ShipCost(ship, kind) * 0.0002 * hours)
end

function Progression.RepairCost (ship)
  if type(ship) ~= 'table' or not ship.hasHealth or not ship:hasHealth() then return 0 end
  local def = ShipArchetypes.Get(ship.shipKind)
  local maximum = nonnegative(ship.healthMax)
  local missing = math.max(0, maximum - nonnegative(ship.health))
  if ship.hasShield and ship:hasShield() then
    local shieldMax = nonnegative(ship:getShieldMax())
    maximum = maximum + shieldMax
    missing = missing + math.max(0, shieldMax - nonnegative(ship:getShield()))
  end
  if maximum <= 0 then return 0 end
  return credits(def.price * def.repairFraction * missing / maximum)
end

function Progression.RepairRate (ship)
  if type(ship) ~= 'table' or not ship.hasHealth or not ship:hasHealth() then return 0 end
  local def = ShipArchetypes.Get(ship.shipKind)
  local rate = nonnegative(ship.healthMax)
  if ship.hasShield and ship:hasShield() then
    rate = math.max(rate, nonnegative(ship:getShieldMax()))
  end
  return rate / def.repairSeconds
end

function Progression.RefitCost (ship, moduleType, upkeepElapsed, equipmentId)
  moduleType = moduleType or Progression.PreferredModule(Progression.Role(ship))
  equipmentId = equipmentId or ShipEquipment.DefaultId(moduleType)
  local def = ShipEquipment.Get(equipmentId)
  if not def or def.type ~= moduleType then return 0 end
  return credits(def.cost) + Progression.Upkeep(ship, upkeepElapsed)
end

function Progression.TradeInValue (ship)
  if type(ship) ~= 'table' or not ShipArchetypes.Defs[ship.shipKind] then return 0 end
  local def = ShipArchetypes.Get(ship.shipKind)
  local maximum = math.max(1, nonnegative(ship.healthMax))
  local condition = clamp01(nonnegative(ship.health) / maximum)
  if ship.hasShield and ship:hasShield() then
    local shieldMax = nonnegative(ship:getShieldMax())
    if shieldMax > 0 then
      condition = (condition + clamp01(nonnegative(ship:getShield()) / shieldMax)) * 0.5
    end
  end
  return credits(def.price * 0.35 * condition)
end

function Progression.PurchaseQuote (ship, kind, tradeIn)
  if not ShipArchetypes.Defs[kind] then return nil end
  local price = Progression.ShipCost(ship, kind)
  local trade = tradeIn and Progression.TradeInValue(ship) or 0
  return {
    kind = kind, price = price, tradeIn = trade,
    due = math.max(0, price - trade), excess = math.max(0, trade - price),
  }
end

function Progression.CanAfford (available, cost, reserve)
  return nonnegative(available) >= nonnegative(cost) + nonnegative(reserve)
end

function Progression.NeedsRepair (ship, available)
  if type(ship) ~= 'table' or not ship.hasHealth or not ship:hasHealth() then return false end
  local maximum = nonnegative(ship.healthMax)
  if maximum <= 0 or ship.health >= maximum * REPAIR_HEALTH then return false end
  local cost = Progression.RepairCost(ship)
  return cost > 0 and Progression.CanAfford(available, cost, Progression.Upkeep(ship, 3600))
end

function Progression.NextEquipment (ship, moduleType)
  moduleType = moduleType or Progression.PreferredModule(Progression.Role(ship))
  local sockets = ship and (ship.getSockets and ship:getSockets() or ship.sockets)
  if type(sockets) ~= 'table' then return nil end
  local matching = false
  local lowestTier, lowestId = math.huge, nil
  for _, socket in ipairs(sockets) do
    if socket.type == moduleType then
      matching = true
      local child = socket.child
      if not child or child.deleted then return ShipEquipment.DefaultId(moduleType) end
      local id = ShipEquipment.Get(child.equipmentId) and child.equipmentId
        or ShipEquipment.DefaultId(moduleType)
      local tier = ShipEquipment.TierOf(child)
      if tier < lowestTier then lowestTier, lowestId = tier, id end
    end
  end
  if not matching then return nil end
  return ShipEquipment.NextId(lowestId)
end

function Progression.NeedsRefit (ship, available)
  if type(ship) ~= 'table' or not ship.hasHealth or not ship:hasHealth() then return false end
  local maximum = nonnegative(ship.healthMax)
  if maximum <= 0 or ship.health < maximum * REFIT_HEALTH then return false end
  local moduleType = Progression.PreferredModule(Progression.Role(ship))
  local equipmentId = Progression.NextEquipment(ship, moduleType)
  if not equipmentId then return false end
  local cost = Progression.RefitCost(ship, moduleType, nil, equipmentId)
  return cost > 0 and Progression.CanAfford(available, cost, Progression.Upkeep(ship, 3600))
end

function Progression.UpgradeShipKind (ship)
  if type(ship) ~= 'table' or not roleShips[ship.shipKind] or ship.shipKind == 'capital' then
    return nil
  end
  local preferred = Progression.PreferredShipKind(Progression.Role(ship))
  if ship.shipKind ~= preferred then return preferred end
  if ship.shipKind ~= 'capital' then return 'capital' end
  return nil
end

function Progression.NeedsShip (ship, available)
  if type(ship) ~= 'table' or not ship.hasHealth or not ship:hasHealth() or not ship:isAlive() then
    return false
  end
  local kind = Progression.UpgradeShipKind(ship)
  if not kind then return false end
  local cost = Progression.ShipCost(ship, kind)
  return cost > 0 and Progression.CanAfford(available, cost, cost * SHIP_RESERVE_MULTIPLE)
end

return Progression
