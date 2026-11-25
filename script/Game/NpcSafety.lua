-- Pure self-preservation policy for one ship. Think feeds it simulation time,
-- normalized hull, and attributed damage; Flee executes the decision.

local StableId = require('Game.StableId')
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

local DAMAGE_WINDOW = 8.0
local HEAVY_DAMAGE = 25.0
local LOW_HULL = 0.35
local RETREAT_COOLDOWN = 20.0
local RETREAT_DURATION = 6.0

function Safety.Create ()
  return {
    lastDamageAt = -math.huge,
    damage = 0,
    source = nil,
    cooldownUntil = -math.huge,
    lastThreatAt = -math.huge,
  }
end

function Safety.Capture (state)
  local sourceKey = state.source and StableId.For(state.source) or state.sourceKey
  return {
    lastDamageAt = state.lastDamageAt > -math.huge and state.lastDamageAt or nil,
    damage = state.damage or 0,
    sourceKey = persistentSource(sourceKey),
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

function Safety.shouldFlee (state, hull, now)
  now = now or 0
  if now < state.cooldownUntil then return false end
  if hull <= LOW_HULL then return true end
  local recent = now - state.lastDamageAt <= DAMAGE_WINDOW and state.damage or 0
  return recent >= HEAVY_DAMAGE
end

function Safety.beginFlee (state, now)
  state.cooldownUntil = (now or 0) + RETREAT_COOLDOWN
  return true
end

Safety.duration = RETREAT_DURATION
Safety.cooldown = RETREAT_COOLDOWN

return Safety
