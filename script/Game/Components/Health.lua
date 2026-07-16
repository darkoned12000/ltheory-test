local Entity = require('Game.Entity')

--[[
  Health component
  ----------------------------------------------------------------------------
  Mixin-style component: any Entity can call `self:addHealth(max, rate)` to
  become damageable. Once health exists:

    * `entity:damage(amount, source)` reduces health and, at 0, fires
      `Event.Destroyed(source)`. That event is what lets asteroids fragment
      (see Asteroid.lua) and ships explode (see Explodable.lua).
    * `Entity.Damaged` is fired on EVERY hit (handy for hit-flashes / sounds).

  The damage event is the ONLY way objects in this game "die". Projectiles
  (Pulse.lua) and ramming (System.handleRamming) both just call :damage().
]]

function Entity:addHealth (max, rate)
  assert(not self.health)
  assert(max)
  assert(rate)
  self.health = max
  self.healthMax = max
  self.healthRate = rate
  self:register(Event.Update, Entity.updateHealth)
end

function Entity:damage (amount, source)
  assert(self.health)
  if self.health <= 0 then return end          -- already dead, ignore further hits
  self.health = max(0, self.health - amount)
  -- Flip `Config.debug.damageLog` to true in Config.App.lua to print every hit
  -- to the console (great for verifying which entity is taking damage).
  if Config.debug.damageLog then
    printf('[DAMAGE] entity#%d took %.1f dmg (src=%s) -> %d/%d%s',
      self.id,
      amount,
      tostring(source and source.id or 'nil'),
      self.health, self.healthMax,
      self.health <= 0 and ' DESTROYED' or '')
  end
  self:send(Event.Damaged(amount, source))
  if self.health <= 0 then
    -- Death! Every Event.Destroyed handler now runs (e.g. asteroid fragmenting).
    self:send(Event.Destroyed(source))
  end
end

function Entity:getHealth ()
  assert(self.health)
  return self.health
end

function Entity:getHealthNormalized ()
  assert(self.health)
  return self.health / self.healthMax          -- 1.0 = full, 0.0 = dead (for bars)
end

function Entity:getHealthPercent ()
  assert(self.health)
  return 100.0 * self.health / self.healthMax
end

function Entity:hasHealth ()
  return self.health ~= nil
end

-- WARNING : Note the subtlety that isAlive and isDestroyed are NOT
--           complementary! An asteroid is not alive, but neither has it been
--           destroyed. Both 'alive' and 'destroyed' require health to be true.

function Entity:isAlive ()
  return self.health and self.health > 0
end

function Entity:isDestroyed ()
  return self.health and self.health <= 0
end

function Entity:setHealth (value, max, rate)
  assert(self.health)
  self.health = value
  self.healthMax = max
  self.healthRate = rate
end

function Entity:updateHealth (state)
  if self:isDestroyed() then return end
  -- Passive regeneration (rate is 0 for asteroids/ships, so this is a no-op
  -- unless you give something a positive rate in addHealth).
  self.health = min(self.healthMax, self.health + state.dt * self.healthRate)
end
