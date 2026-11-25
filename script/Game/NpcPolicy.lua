-- Per-ship NPC job policy: route-aware utility, memory, and cooldowns.
--
-- This module is deliberately independent of Entity/Engine state. Think owns
-- one instance per asset and feeds it immutable economy job templates; the
-- selected template is cloned before execution.

local Policy = {}

local COMPLETED_COOLDOWN = 120.0
local CANCELLED_COOLDOWN = 30.0
local FAILED_COOLDOWN = 60.0
local MIN_TRAVEL_TIME = 1.0

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

-- Small, stable personality weight. Different NPCs diversify without making
-- route preference more important than profit and travel time.
function Policy.preference (policy, kind, key)
  local kindWeight = 0.9 + 0.2 * unit(policy.seed, 'kind:' .. tostring(kind))
  if not key then return kindWeight end
  local routeWeight = 0.8 + 0.4 * unit(policy.seed, 'route:' .. tostring(key))
  return kindWeight * routeWeight
end

function Policy.score (job, asset, policy, now)
  local payout = math.max(0, tonumber(job:getPayout(asset)) or 0)
  local travel = math.max(MIN_TRAVEL_TIME, tonumber(job:getTravelTime(asset)) or MIN_TRAVEL_TIME)
  local key = job:getKey()
  local route = policy.routes[key]
  local runs = route and route.runs or 0
  local novelty = (route and 1.0 or 1.15) / (1.0 + 0.5 * runs)
  return (payout / travel) * Policy.preference(policy, job:getKind(), key) * novelty
end

function Policy.canAssign (policy, job, now)
  local route = policy.routes[job:getKey()]
  return not route or (route.cooldownUntil or 0) <= (now or 0)
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
