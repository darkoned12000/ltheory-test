local Action = require('Game.Action')
local Seed = require('Game.Seed')
local TargetValidity = require('Game.Actions.TargetValidity')

local nextId = 0

local Attack = subclass(Action, function (self, target)
  self.target = target
  -- See MoveTo: per-instance stream instead of one shared clock-seeded one, so
  -- an NPC's re-target jitter does not depend on what the other NPCs drew.
  nextId = nextId + 1
  self.rng = Seed.rng('action.attack', nextId):managed()
end)

function Attack:clone ()
  local clone = Attack(self.target)
  clone.protected, clone.leash = self.protected, self.leash
  return clone
end

function Attack:getName ()
  return 'Attack ' .. (self.target and self.target.getName
    and self.target:getName() or 'target')
end

function Attack:onStart (e)
  if not TargetValidity.Usable(self.target) then return end
  self.radiusMin = 2.0 * self.target:getRadius() + e:getRadius()
  self.radiusMax = e.socketRangeMin
  self.timer = 0
  self.dist = 0
end

local kVelFactor = 0.0

function Attack:onUpdateActive (e, dt)
  local target = self.target
  if not TargetValidity.Usable(target) then
    e:popAction()
    return
  end
  if self.protected and not TargetValidity.Usable(self.protected) then
    e:popAction()
    return
  end
  if self.protected and self.leash
     and (target:getPos() - self.protected:getPos()):length() > self.leash then
    e:popAction()
    return
  end

  e:setTarget(target)

  self.timer = self.timer - dt
  if self.timer <= 0 or self.dist < e:getSpeed() then
    self.offset = self.rng:getDir3()
    self.offset:iscale(Math.Sign(self.offset:dot(e:getPos() - self.target:getPos())))
    self.timer = self.rng:getUniformRange(5, 10)
    self.radius = Math.Lerp(
      self.radiusMin,
      self.radiusMax,
      self.rng:getUniformRange(0, 1) ^ 2.0)
  end

  local targetPos =
      target:getPos() + self.offset:scale(self.radius) +
      target:getVelocity():scale(kVelFactor)

  local course = targetPos - e:getPos()
  local dist = course:length()
  self.dist = dist
  -- Point-blank targets can coincide with the attacker (or with the chosen
  -- orbit offset). Keep the attack action alive for weapons, but do not try to
  -- steer toward a zero-length direction.
  if dist < 1e-6 then return end
  local forward = course:scale(1 / dist)
  local yawPitch = e:getForward():cross(forward)
  local roll     = e:getUp():cross(target:getUp())

  self:flyToward(e, targetPos, forward, target:getUp())
end

function Attack:onStop (e)
  if e.getTarget and e:getTarget() == self.target then e:setTarget(nil) end
end

function Attack:onUpdatePassive (e, dt)
  -- A temporary preemption such as Flee must suppress weapons from the lower
  -- stacked Attack; otherwise the ship keeps fighting while retreating.
  local current = e.getCurrentAction and e:getCurrentAction()
  if current and current ~= self then return end
  if not TargetValidity.Usable(self.target) then return end
  local toTarget = self.target:getPos() - e:getPos()
  local distance = toTarget:length()
  if distance < 1e-6 then return end
  local align = toTarget:scale(1 / distance):dot(e:getForward())
  if align < 0.25 then return end
  local firing = Config.game.aiFire(dt, self.rng)
  local SocketType = require('Game.SocketKind')
for turret in e:iterSocketsByType(SocketType.Turret) do
    local solution = turret:aimAtTarget(self.target, self.target:getPos())
    if firing and solution then turret:fire() end
  end
end

return Attack
