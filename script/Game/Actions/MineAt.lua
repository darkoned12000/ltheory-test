local Action = require('Game.Action')
local GPUParticles = require('Game.Entities.GPUParticles')
local MiningBeam = require('Game.Entities.MiningBeam')
local Seed = require('Game.Seed')

local nextId = 0
local SPARK_INTERVAL = 0.05

local MineAt = subclass(Action, function (self, target, range)
  assert(target:hasYield())
  self.target = target
  self.range = range or (Config.game and Config.game.miningRange) or 250
  self.accumulator = 0
  self.sparkTimer = 0
  self.accuracy = 1
  self.result = nil
  self.resultTime = 0
  self.extracted = 0
  nextId = nextId + 1
  self.rng = Seed.rng('action.mineat', nextId):managed()
end)

function MineAt:clone ()
  return MineAt(self.target, self.range)
end

function MineAt:getName ()
  return format('MineAt @ %s', self.target:getName())
end

function MineAt:onStart (e)
  self.beam = MiningBeam(e, self.target)
  e:addChild(self.beam)
end

function MineAt:onStop (e)
  if self.beam then
    e:removeChild(self.beam)
    self.beam = nil
  end
end

function MineAt:onUpdatePassive (e)
  if self.beam then self.beam.active = e:getCurrentAction() == self end
end

function MineAt:emitSparks (e, dt)
  if not self.beam then return end
  self.sparkTimer = self.sparkTimer + dt
  while self.sparkTimer >= SPARK_INTERVAL do
    self.sparkTimer = self.sparkTimer - SPARK_INTERVAL
    local targetPos = self.target:getPos()
    local towardShip = (e:getPos() - targetPos):normalize()
    local pos = targetPos + towardShip:scale(self.target:getRadius())
    local scatter = self.rng:getSphere()
    local speed = 4.0 + 10.0 * self.rng:getUniform()
    local record = GPUParticles.newRecord()
    record.x, record.y, record.z = pos.x, pos.y, pos.z
    record.vx = towardShip.x * speed + scatter.x * speed
    record.vy = towardShip.y * speed + scatter.y * speed
    record.vz = towardShip.z * speed + scatter.z * speed
    record.size = 3.0 + 5.0 * self.rng:getUniform()
    record.r, record.g, record.b = 0.25, 0.55, 1.8
    record.life = 0.25 + 0.4 * self.rng:getUniform()
    GPUParticles.emit(record)

    local flash = GPUParticles.newRecord()
    flash.x, flash.y, flash.z = pos.x, pos.y, pos.z
    flash.vx, flash.vy, flash.vz = 0, 0, 0
    flash.size = 18.0 + 8.0 * self.rng:getUniform()
    flash.r, flash.g, flash.b = 0.35, 0.45, 2.0
    flash.life = 0.12
    GPUParticles.emit(flash)
  end
end

function MineAt:updateAccuracy (e, dt)
  local speed = e.getSpeed and e:getSpeed() or 0
  local alignment = 1
  if e.getForward then
    local toTarget = (self.target:getPos() - e:getPos()):normalize()
    alignment = e:getForward():dot(toTarget)
  end
  local speedTolerance = (Config.game and Config.game.miningSpeedTolerance) or 3
  local minAlignment = (Config.game and Config.game.miningAlignment) or 0.85
  local drain = (Config.game and Config.game.miningAccuracyDrain) or 0.35
  if speed <= speedTolerance and alignment >= minAlignment then
    self.accuracy = math.min(1, self.accuracy + dt * 0.05)
  else
    self.accuracy = math.max(0, self.accuracy - dt * drain)
  end
  if self.beam then self.beam:setAccuracy(self.accuracy) end
  if self.accuracy <= 0 then
    self.result = false
    self.resultTime = 0
  end
end

function MineAt:onUpdateActive (e, dt)
  if self.result ~= nil then
    self.resultTime = self.resultTime + dt
    if self.resultTime >= 1 then e:popAction() end
    return
  end
  if self.beam then self.beam.active = true end
  if self.target.deleted or (self.target.isDestroyed and self.target:isDestroyed()) then
    e:popAction()
    return
  end
  if e.getMinDistance and e:getMinDistance(self.target) > self.range then
    e:popAction()
    return
  end
  self:updateAccuracy(e, dt)
  if self.result ~= nil then return end
  self:emitSparks(e, dt)
  local yield = self.target:getYield()
  local item = yield.item
  local duration = (Config.game.miningDurations and Config.game.miningDurations[item:getName()]) or 8
  if not self.maxCount then
    local capacity = e.getInventoryCapacity and e:getInventoryCapacity() or 100
    local free = e.getInventoryFree and e:getInventoryFree() or capacity
    local mass = math.max(1e-6, item:getMass())
    local cargoCount = math.floor(free / mass)
    local remaining = self.target.getYieldRemaining and self.target:getYieldRemaining() or cargoCount
    self.maxCount = math.min(cargoCount, remaining)
    self.rateCount = cargoCount
    if self.maxCount <= 0 then
      e:popAction()
      return
    end
  end
  local rate = (self.rateCount / duration) * yield.size
  self.accumulator = self.accumulator + dt * rate
  while self.accumulator >= 1.0 - 1e-9 and self.extracted < self.maxCount do
    if not e:addItem(item, 1) then
      e:popAction()
      return
    end
    if self.target.consumeYield then
      local taken = self.target:consumeYield(1)
      if taken < 1 then
        e:popAction()
        return
      end
    end
    self.accumulator = self.accumulator - 1
    self.extracted = self.extracted + 1
  end
  if self.extracted >= self.maxCount then
    e:popAction()
    return
  end
end

function MineAt:getProgress ()
  return self.maxCount and (self.extracted / self.maxCount) or 0
end

return MineAt
