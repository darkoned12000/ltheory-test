-- Pure self-preservation policy for one ship. Think feeds it simulation time,
-- normalized hull, and attributed damage; Flee executes the decision.

local StableId = require('Game.StableId')
local Item = require('Game.Item')
local SocketType = require('Game.SocketKind')
local ShipEquipment = require('Game.ShipEquipment')
local Safety = {}

local function timestamp (value)
  value = tonumber(value)
  if value and value == value and value ~= math.huge and value ~= -math.huge and value >= 0 then
    return value
  end
  return -math.huge
end

local function persistentSource (value)
  return type(value) == 'string' and value ~= '' and value:sub(1, 8) ~= 'runtime:' and value or nil
end

local function clamp (value, lo, hi)
  return math.max(lo, math.min(hi, value))
end

local DAMAGE_WINDOW = 8.0
local HEAVY_DAMAGE = 25.0
local LOW_HULL = 0.35
local CRITICAL_HULL = 0.15
local RETREAT_COOLDOWN = 20.0
local RETREAT_DURATION = 6.0

-- Retreat is gated by role, not just an absolute damage number. A capital can
-- ignore fighter fire until its own hull is actually in danger; a freighter
-- carrying cargo should leave much earlier. `engageHull` is the point at which
-- accumulated burst damage is enough to break contact; `overmatch` is how much
-- stronger the attacker must be before an undamaged hull still withdraws.
local ROLE_PROFILES = {
  fighter    = { lowHull = 0.38, engageHull = 0.70, damageFraction = 0.25, overmatch = 1.5 },
  freighter  = { lowHull = 0.55, engageHull = 0.90, damageFraction = 0.20, overmatch = 0.9 },
  industrial = { lowHull = 0.50, engageHull = 0.85, damageFraction = 0.25, overmatch = 1.0 },
  capital    = { lowHull = 0.25, engageHull = 0.50, damageFraction = 0.25, overmatch = 2.5 },
}

function Safety.Profile (ship)
  local role = type(ship) == 'table' and (ship.npcRole or ship.shipKind) or nil
  return ROLE_PROFILES[role] or ROLE_PROFILES.fighter
end

local combatant, combatPower

function Safety.Create ()
  return {
    lastDamageAt = -math.huge,
    damage = 0,
    source = nil,
    lastFledAt = -math.huge,
    cooldownUntil = -math.huge,
    lastThreatAt = -math.huge,
    retaliationTarget = nil,
    retaliationUntil = -math.huge,
  }
end

function Safety.Capture (state)
  local sourceKey = state.source and StableId.For(state.source) or state.sourceKey
  return {
    lastDamageAt = state.lastDamageAt > -math.huge and state.lastDamageAt or nil,
    damage = state.damage or 0,
    sourceKey = persistentSource(sourceKey),
    lastFledAt = state.lastFledAt and state.lastFledAt > -math.huge and state.lastFledAt or nil,
    cooldownUntil = state.cooldownUntil > -math.huge and state.cooldownUntil or nil,
    lastThreatAt = state.lastThreatAt and state.lastThreatAt > -math.huge
      and state.lastThreatAt or nil,
  }
end

function Safety.Restore (state, data)
  data = type(data) == 'table' and data or {}
  state.lastDamageAt = timestamp(data.lastDamageAt)
  local damage = tonumber(data.damage)
  state.damage = damage and damage == damage and damage ~= math.huge
    and damage ~= -math.huge and math.max(0, damage) or 0
  state.sourceKey = persistentSource(data.sourceKey)
  state.source = nil
  state.cooldownUntil = timestamp(data.cooldownUntil)
  state.retaliationTarget = nil
  state.retaliationUntil = timestamp(data.retaliationUntil)
  state.lastFledAt = timestamp(data.lastFledAt)
  if state.lastFledAt == -math.huge and state.cooldownUntil > -math.huge then
    state.lastFledAt = math.max(0, state.cooldownUntil - RETREAT_COOLDOWN)
  end
  state.lastThreatAt = timestamp(data.lastThreatAt)
end

function Safety.recordDamage (state, amount, source, now)
  now = now or 0
  if now - state.lastDamageAt > DAMAGE_WINDOW then state.damage = 0 end
  state.damage = state.damage + math.max(0, tonumber(amount) or 0)
  state.lastDamageAt = now
  if source then
    state.source = source
    state.sourceKey = StableId.For(source)
  end
  return state.damage
end

function Safety.CargoValue (ship)
  if not (ship and ship.hasInventory and ship:hasInventory()
      and ship.getInventory) then return 0 end
  local inventory = ship:getInventory()
  if type(inventory) ~= 'table' then return 0 end
  local value = 0
  for item, amount in pairs(inventory) do
    if item ~= Item.Credit then
      local unitPrice = Item.Price and tonumber(Item.Price[item])
      if not unitPrice and item and item.getMass then unitPrice = item:getMass() * 10 end
      value = value + math.max(0, tonumber(amount) or 0) * math.max(0, unitPrice or 0)
    end
  end
  return value
end

function Safety.shouldFlee (state, hullOrShip, now, cargoValue, riskTolerance)
  now = now or 0
  local ship = type(hullOrShip) == 'table' and hullOrShip or nil
  local hull
  if ship then
    hull = ship.getHealthNormalized and tonumber(ship:getHealthNormalized())
      or ship.health and ship.healthMax and ship.health / ship.healthMax
      or 1
  else
    hull = tonumber(hullOrShip) or 1
  end
  hull = clamp(hull, 0, 1)
  cargoValue = math.max(0, tonumber(cargoValue) or 0)
  riskTolerance = clamp(tonumber(riskTolerance) or 0.5, 0, 1)
  local cargoValueReference = math.max(1,
    tonumber(Config.game and Config.game.npcCargoProtectionValue) or 10000)
  local cargoRisk = clamp(cargoValue / cargoValueReference, 0, 1)

  local profile = ship and Safety.Profile(ship) or {
    lowHull = LOW_HULL, engageHull = 1, damageFraction = 0, overmatch = 1,
  }
  local maximum = ship and math.max(1, tonumber(ship.healthMax) or 100) or 100
  local lowHullThreshold = clamp(profile.lowHull + cargoRisk * 0.12
    + (0.5 - riskTolerance) * 0.1, 0.15, 0.65)
  local engageHull = clamp(profile.engageHull + cargoRisk * 0.1
    - riskTolerance * 0.05, 0.2, 1)
  local recent = now - state.lastDamageAt <= DAMAGE_WINDOW and state.damage or 0
  local damageThreshold = ship and math.max(HEAVY_DAMAGE * 0.5,
    maximum * profile.damageFraction) or HEAVY_DAMAGE
  damageThreshold = damageThreshold
    * (1 + 0.4 * (riskTolerance - 0.5) - 0.5 * cargoRisk)

  local overmatched = false
  if ship and state.source then
    local ownPower, sourcePower = combatPower(ship), combatPower(state.source)
    overmatched = sourcePower > ownPower * profile.overmatch
  end

  if now < state.cooldownUntil then
    local lastFledAt = state.lastFledAt or (state.cooldownUntil - RETREAT_COOLDOWN)
    return hull <= CRITICAL_HULL
      or (state.lastDamageAt > lastFledAt and recent >= damageThreshold
          and (overmatched or hull <= engageHull or not combatant(ship)))
  end
  if hull <= lowHullThreshold then return true end
  if recent < damageThreshold then return false end
  return overmatched or hull <= engageHull or not combatant(ship)
end

combatant = function (entity)
  if not entity then return false end
  if entity.isAlive and not entity:isAlive() then return false end
  if entity.hasSockets and not entity:hasSockets() then return false end
  return (tonumber(entity.socketSpeedMax) or 0) > 0
end

Safety.IsCombatant = combatant

local function turretCount (entity)
  if entity.turretCount then return math.max(0, tonumber(entity.turretCount) or 0) end
  local count = 0
  if entity.getSockets then
    for _, socket in ipairs(entity:getSockets() or {}) do
      if socket.type == SocketType.Turret and socket.child and not socket.child.deleted then
        count = count + 1
      end
    end
  elseif entity.iterSocketsByType then
    for _ in entity:iterSocketsByType(SocketType.Turret) do count = count + 1 end
  end
  if count == 0 and (tonumber(entity.socketSpeedMax) or 0) > 0 then count = 1 end
  return count
end

combatPower = function (entity)
  if not combatant(entity) then return 0 end
  local maximum = math.max(1, tonumber(entity.healthMax) or 100)
  local hull = entity.getHealthNormalized and entity:getHealthNormalized()
    or maximum > 0 and (tonumber(entity.health) or maximum) / maximum or 1
  local guns = math.max(1, turretCount(entity))
  local dps = ShipEquipment.WeaponDps(entity)
  if dps <= 0 then dps = guns * 40 * 10 end
  local gunEquivalent = dps / (40 * 10)
  local speedFactor = clamp((tonumber(entity.socketSpeedMax) or 600) / 600, 0.25, 1.5)
  local rangeFactor = clamp((tonumber(entity.socketRangeMax) or 1000) / 1000, 0.25, 1.5)
  local weapon = (0.5 + 0.5 * gunEquivalent) * speedFactor * rangeFactor
  local charge = entity.hasCharge and entity:hasCharge() and entity.getChargeNormalized
    and clamp(tonumber(entity:getChargeNormalized()) or 1, 0, 1) or 1
  local shield = entity.hasShield and entity:hasShield() and entity.getShield
    and math.max(0, tonumber(entity:getShield()) or 0) or 0
  local effectiveHull = maximum * clamp(tonumber(hull) or 1, 0, 1) + shield
  return effectiveHull * weapon * (0.5 + 0.5 * charge)
end

Safety.CombatPower = combatPower

function Safety.HopelessFight (ship, target, nearbyAllies)
  if not combatant(target) then return false end
  local ownPower, targetPower = combatPower(ship), combatPower(target)
  if ownPower <= 0 then return true end
  local support = 1 + clamp(tonumber(nearbyAllies) or 0, 0, 4) * 0.7
  return ownPower * support < targetPower * 0.3
end

function Safety.beginFlee (state, now)
  state.lastFledAt = now or 0
  state.cooldownUntil = state.lastFledAt + RETREAT_COOLDOWN
  return true
end

Safety.duration = RETREAT_DURATION
Safety.cooldown = RETREAT_COOLDOWN

return Safety
