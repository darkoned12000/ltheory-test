-- Per-ship NPC job policy: route-aware utility, memory, and cooldowns.
--
-- This module is deliberately independent of Entity/Engine state. Think owns
-- one instance per asset and feeds it immutable economy job templates; the
-- selected template is cloned before execution.

local RouteKey = require('Game.RouteKey')
local Policy = {}

local COMPLETED_COOLDOWN = 120.0
local CANCELLED_COOLDOWN = 30.0
local FAILED_COOLDOWN = 60.0
local MIN_TRAVEL_TIME = 1.0
local ROLE_DUTY = {
  fighter = { patrol = 0.9, defend = 1.0 },
  freighter = { transport = 0.9, patrol = 0.25 },
  industrial = { mine = 0.9, transport = 0.55 },
  capital = { defend = 0.75, mine = 0.5, transport = 0.45, patrol = 0.4 },
}

local function hash (value)
  -- Keep every multiplication below 2^53 so Lua's double arithmetic is exact.
  -- A 32-bit FNV multiplier would lose the low bits after a few characters.
  local h = 2166136261 % 2147483647
  if type(value) == 'string' then
    for i = 1, #value do
      h = (h * 33 + value:byte(i)) % 2147483647
    end
  else
    h = (h * 33 + math.floor(tonumber(value) or 0)) % 2147483647
  end
  return h
end

local function unit (seed, tag)
  return (hash(tostring(seed) .. ':' .. tag) % 1000003) / 1000003
end

function Policy.Create (seed)
  return setmetatable({
    seed = seed or 0,
    routes = {},
  }, { __index = Policy })
end

local function clamp (value, lo, hi)
  return math.max(lo, math.min(hi, value))
end

function Policy.Personality (policy)
  if policy._personality then return policy._personality end
  local seed = policy.seed or 0
  policy._personality = {
    profitFocus = unit(seed, 'personality:profit'),
    riskTolerance = unit(seed, 'personality:risk'),
    dutyFocus = unit(seed, 'personality:duty'),
    sociability = unit(seed, 'personality:social'),
    commitment = unit(seed, 'personality:commitment'),
  }
  return policy._personality
end

-- Small, stable personality weight. Different NPCs diversify without making
-- route preference more important than profit and travel time.
function Policy.preference (policy, kind, key)
  local kindWeight = 0.9 + 0.2 * unit(policy.seed, 'kind:' .. tostring(kind))
  if not key then return kindWeight end
  local routeWeight = 0.8 + 0.4 * unit(policy.seed, 'route:' .. tostring(key))
  return kindWeight * routeWeight
end

local function healthFraction (asset)
  if asset.getHealthNormalized then
    return clamp(tonumber(asset:getHealthNormalized()) or 1, 0, 1)
  end
  local maximum = tonumber(asset.healthMax)
  if maximum and maximum > 0 then
    return clamp((tonumber(asset.health) or maximum) / maximum, 0, 1)
  end
  return 1
end

local function chargeFraction (asset)
  if asset.hasCharge and asset:hasCharge() and asset.getChargeNormalized then
    return clamp(tonumber(asset:getChargeNormalized()) or 1, 0, 1)
  end
  return 1
end

local function cargoFraction (asset)
  if not (asset.hasInventory and asset:hasInventory()
      and asset.getInventoryCapacity and asset.getInventoryFree) then
    return 0
  end
  local capacity = tonumber(asset:getInventoryCapacity()) or 0
  if capacity <= 0 then return 0 end
  local free = tonumber(asset:getInventoryFree()) or capacity
  return clamp(1 - free / capacity, 0, 1)
end

local function jobRisk (job, asset)
  local value = job.getRisk and job:getRisk(asset) or job.risk
  if value == nil then
    local kind = job:getKind()
    value = kind == 'mine' and 0.35
      or kind == 'transport' and 0.2
      or kind == 'patrol' and 0.45
      or 0.1
  end
  return clamp(tonumber(value) or 0, 0, 1)
end

local function dutyValue (job, asset, owner)
  local duty = job.getDuty and job:getDuty(asset) or job.duty or asset.npcDuty or 0
  local roleDuty = ROLE_DUTY[asset.npcRole]
  if roleDuty then duty = math.max(duty, roleDuty[job:getKind()] or 0) end
  local organization = job.organizationId or (job.getOrganizationId and job:getOrganizationId())
  if organization and owner and owner.hasOrganization and owner:hasOrganization(organization) then
    local standing = owner.getOrganizationStanding
      and owner:getOrganizationStanding(organization) or 0
    duty = math.max(duty, 0.5 + clamp((tonumber(standing) or 0) / 10, 0, 0.5))
  end
  return clamp(tonumber(duty) or 0, 0, 1)
end

local function relationshipValue (job, owner, asset)
  local value = job.getRelationship and job:getRelationship(asset)
  if value ~= nil then return clamp(tonumber(value) or 0, -1, 1) end
  if not owner then return 0 end
  local endpoints = {}
  if job.src then endpoints[#endpoints + 1] = job.src end
  if job.dst then endpoints[#endpoints + 1] = job.dst end
  for _, endpoint in ipairs(endpoints) do
    local other = endpoint and endpoint.getOwner and endpoint:getOwner()
    if other and other ~= owner then
      if owner.sharesOrganization and owner:sharesOrganization(other) then return 1 end
      if owner.getDisposition then
        local disposition = tonumber(owner:getDisposition(other))
        if disposition then return clamp(disposition, -1, 1) end
      end
    end
  end
  return 0
end

function Policy.score (job, asset, policy, now)
  local payout = math.max(0, tonumber(job:getPayout(asset)) or 0)
  local travel = math.max(MIN_TRAVEL_TIME, tonumber(job:getTravelTime(asset)) or MIN_TRAVEL_TIME)
  local key = job:getKey()
  local route = policy.routes[key]
  local runs = route and route.runs or 0
  local novelty = (route and 1.0 or 1.15) / (1.0 + 0.5 * runs)
  local personality = Policy.Personality(policy)
  local profitExponent = 0.85 + 0.3 * personality.profitFocus
  local travelExponent = 1.15 - 0.3 * personality.profitFocus
  local utility = (payout > 0 and payout ^ profitExponent or 0)
    / (travel ^ travelExponent)

  local risk = jobRisk(job, asset)
  local hull = healthFraction(asset)
  local riskWeight = 0.35 + 0.55 * (1 - personality.riskTolerance)
  local safetyFactor = 1 - risk * (1 - hull) * riskWeight

  local kind = job:getKind()
  local cargo = cargoFraction(asset)
  local cargoFactor = kind == 'mine' and (1 - 0.75 * cargo)
    or kind == 'transport' and (0.85 + 0.4 * cargo)
    or 1

  local energyDemand = job.getEnergyDemand and job:getEnergyDemand(asset)
    or job.energyDemand or ((kind == 'patrol' or kind == 'defend' or kind == 'attack')
      and 0.7 or 0.2)
  local energyFactor = 1 - clamp(tonumber(energyDemand) or 0, 0, 1)
    * (1 - chargeFraction(asset)) * 0.45

  local owner = asset.getOwner and asset:getOwner()
  local duty = dutyValue(job, asset, owner)
  local dutyFactor = 1 + duty * personality.dutyFocus * 0.5
  local relation = relationshipValue(job, owner, asset)
  local relationFactor = 1 + relation * personality.sociability * 0.2
  local commitmentFactor = asset.job and asset.job.getKey
      and asset.job:getKey() == key and (1 + 0.25 * personality.commitment) or 1

  return utility * Policy.preference(policy, kind, key) * novelty
    * safetyFactor * cargoFactor * energyFactor
    * dutyFactor * relationFactor * commitmentFactor
end

function Policy.canAssign (policy, job, now)
  local route = policy.routes[job:getKey()]
  return not route or (route.cooldownUntil or 0) <= (now or 0)
end

function Policy.Capture (policy)
  local routes = {}
  for key, route in pairs(policy.routes or {}) do
    if RouteKey.IsPersistent(key) then
      routes[#routes + 1] = {
        key = key,
        runs = route.runs or 0,
        completed = route.completed or 0,
        failed = route.failed or 0,
        cancelled = route.cancelled or 0,
        lastOutcome = route.lastOutcome,
        lastOutcomeAt = route.lastOutcomeAt or 0,
        cooldownUntil = route.cooldownUntil or 0,
      }
    end
  end
  table.sort(routes, function (a, b) return a.key < b.key end)
  return { seed = policy.seed or 0, routes = routes }
end

local function finite (value, fallback)
  value = tonumber(value)
  if value and value == value and value ~= math.huge and value ~= -math.huge then
    return value
  end
  return fallback
end

local function count (value)
  return math.max(0, math.floor(finite(value, 0)))
end

function Policy.Restore (policy, data)
  data = type(data) == 'table' and data or {}
  local seed = data.seed
  if type(seed) == 'string' or (type(seed) == 'number' and finite(seed) ~= nil) then
    policy.seed = seed
  else
    policy.seed = 0
  end
  policy._personality = nil
  policy.routes = {}
  local routes = type(data.routes) == 'table' and data.routes or {}
  for _, entry in ipairs(routes) do
    if type(entry) == 'table' and type(entry.key) == 'string'
       and RouteKey.IsPersistent(entry.key) then
      policy.routes[entry.key] = {
        runs = count(entry.runs),
        completed = count(entry.completed),
        failed = count(entry.failed),
        cancelled = count(entry.cancelled),
        lastOutcome = type(entry.lastOutcome) == 'string' and entry.lastOutcome or nil,
        lastOutcomeAt = finite(entry.lastOutcomeAt, 0),
        cooldownUntil = finite(entry.cooldownUntil, 0),
      }
    end
  end
end

function Policy.recordOutcome (policy, job, outcome, now)
  local key = job:getKey()
  local route = policy.routes[key]
  if not route then
    route = { runs = 0, completed = 0, failed = 0, cancelled = 0 }
    policy.routes[key] = route
  end

  route.runs = route.runs + 1
  route.lastOutcome = outcome
  route.lastOutcomeAt = now or 0
  if outcome == 'completed' then
    route.completed = route.completed + 1
    route.cooldownUntil = (now or 0) + COMPLETED_COOLDOWN
  elseif outcome == 'cancelled' then
    route.cancelled = route.cancelled + 1
    route.cooldownUntil = (now or 0) + CANCELLED_COOLDOWN
  else
    route.failed = route.failed + 1
    route.cooldownUntil = (now or 0) + FAILED_COOLDOWN
  end
  return route
end

return Policy
