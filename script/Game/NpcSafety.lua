-- Pure self-preservation policy for one ship. Think feeds it simulation time,
-- normalized hull, and attributed damage; Flee executes the decision.

local Safety = {}

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
  }
end

function Safety.recordDamage (state, amount, source, now)
  now = now or 0
  if now - state.lastDamageAt > DAMAGE_WINDOW then state.damage = 0 end
  state.damage = state.damage + math.max(0, tonumber(amount) or 0)
  state.lastDamageAt = now
  state.source = source or state.source
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
