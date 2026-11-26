local Entity = require('Game.Entity')

-- A regenerating damage buffer in front of hull health. Health.damage calls
-- absorbShieldDamage before applying hull damage, so load order does not matter.
function Entity:addShield (max, rate, delay)
  assert(not self.shield)
  assert(max and max > 0)
  self.shield = max
  self.shieldMax = max
  self.shieldRate = math.max(0, rate or 0)
  self.shieldDelay = math.max(0, delay or 0)
  self.shieldRegenDelay = 0
  self:register(Event.Update, Entity.updateShield)
end

function Entity:hasShield ()
  return self.shield ~= nil
end

function Entity:getShield ()
  assert(self.shield)
  return self.shield
end

function Entity:getShieldMax ()
  assert(self.shield)
  return self.shieldMax
end

function Entity:getShieldNormalized ()
  assert(self.shield)
  return self.shieldMax > 0 and self.shield / self.shieldMax or 0
end

function Entity:setShield (value, max, rate, delay)
  assert(self.shield)
  self.shield = math.max(0, math.min(value, max))
  self.shieldMax = max
  self.shieldRate = math.max(0, rate or 0)
  self.shieldDelay = math.max(0, delay or 0)
  self.shieldRegenDelay = 0
end

function Entity:absorbShieldDamage (amount)
  if not self.shield or self.shield <= 0 then return amount end
  local absorbed = math.min(self.shield, amount)
  self.shield = self.shield - absorbed
  self.shieldRegenDelay = self.shieldDelay
  return amount - absorbed
end

function Entity:updateShield (state)
  if not self.shield or self:isDestroyed() then return end
  local elapsed = math.max(0, state.dt)
  if self.shieldRegenDelay > 0 then
    local delayUsed = math.min(self.shieldRegenDelay, elapsed)
    self.shieldRegenDelay = self.shieldRegenDelay - delayUsed
    elapsed = elapsed - delayUsed
  end
  if elapsed > 0 then
    self.shield = math.min(self.shieldMax, self.shield + self.shieldRate * elapsed)
  end
end
