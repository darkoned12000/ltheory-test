-- Pure NPC progression policy. Costs are derived from the same commodity price
-- anchors as the live economy; decisions never mutate ships or actors.

local Item = require('Game.Item')
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

local function credits (value)
  return math.max(0, math.ceil(nonnegative(value) - 1e-9))
end

local function anchor (item, fallback)
  local prices = Item.Price
  return prices and nonnegative(finite(prices[item], fallback)) or fallback
end

local function machineParts ()
  return anchor(Item.MachineParts, 24)
end

local function electronics ()
  return anchor(Item.Electronics, 30)
end

local function weaponComponents ()
  return anchor(Item.WeaponComponents, 45)
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
  if kind == 'freighter' then return credits(600 * machineParts()) end
  if kind == 'industrial' then return credits(800 * weaponComponents()) end
  if kind == 'capital' then return credits(2000 * electronics()) end
  return credits(100 * machineParts())
end

-- Upkeep is 0.1% of the current hull's purchase value per simulated hour.
function Progression.Upkeep (ship, elapsed)
  local hours = nonnegative(elapsed) / 3600
  local kind = type(ship) == 'table' and roleShips[ship.shipKind] and ship.shipKind or nil
  return credits(Progression.ShipCost(ship, kind) * 0.001 * hours)
end

function Progression.RepairCost (ship)
  if type(ship) ~= 'table' or not ship.hasHealth or not ship:hasHealth() then return 0 end
  local maximum = nonnegative(ship.healthMax)
  local missing = math.max(0, maximum - nonnegative(ship.health))
  return credits(missing * machineParts() / 4)
end

function Progression.RepairRate (ship)
  if type(ship) ~= 'table' or not ship.hasHealth or not ship:hasHealth() then return 0 end
  return nonnegative(ship.healthMax) / 60
end

function Progression.RefitCost (ship, moduleType, upkeepElapsed)
  moduleType = moduleType or Progression.PreferredModule(Progression.Role(ship))
  local base
  if moduleType == SocketType.Thruster then
    base = 4 * machineParts()
  elseif moduleType == SocketType.Turret then
    base = 6 * electronics()
  else
    return 0
  end
  return credits(base) + Progression.Upkeep(ship, upkeepElapsed)
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

local function hasPreferredModule (ship, moduleType)
  local sockets = ship.getSockets and ship:getSockets() or ship.sockets
  if type(sockets) ~= 'table' then return false, false end
  local matching = false
  for _, socket in ipairs(sockets) do
    if socket.type == moduleType then
      matching = true
      if socket.child and not socket.child.deleted then return true, true end
    end
  end
  return matching, false
end

function Progression.NeedsRefit (ship, available)
  if type(ship) ~= 'table' or not ship.hasHealth or not ship:hasHealth() then return false end
  local maximum = nonnegative(ship.healthMax)
  if maximum <= 0 or ship.health < maximum * REFIT_HEALTH then return false end
  local moduleType = Progression.PreferredModule(Progression.Role(ship))
  local matching, occupied = hasPreferredModule(ship, moduleType)
  if not matching or occupied then return false end
  local cost = Progression.RefitCost(ship, moduleType)
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
