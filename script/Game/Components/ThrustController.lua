local Entity     = require('Game.Entity')
local SocketType = require('Game.SocketKind')

local thrustMult        = 1
local thrustForwardMax  = 8e6 * thrustMult
local thrustBackwardMax = 2e6 * thrustMult
local thrustRightMax    = 8e6 * thrustMult
local thrustUpMax       = 2e6 * thrustMult
local thrustPitchMax    = 1e7 * thrustMult
local thrustYawMax      = 1e7 * thrustMult
local thrustRollMax     = 2e7 * thrustMult

--------------------------------------------------------------------------------

local ThrustController = class(function (self)
  self:clear()
end)

function ThrustController:clear ()
  self.forward     = 0
  self.right       = 0
  self.up          = 0
  self.yaw         = 0
  self.pitch       = 0
  self.roll        = 0
  self.boost       = 0
  self.currentVol  = nil
  self.engineTimer = 0
end

function ThrustController:setThrust (forward, right, up, yaw, pitch, roll, boost)
  self.forward = forward
  self.right   = right
  self.up      = up
  self.yaw     = yaw
  self.pitch   = pitch
  self.roll    = roll
  self.boost   = boost
end

function ThrustController:update (e, dt)
  local boost = 0.0
  if e:discharge(dt * self.boost * Config.game.boostCost) then
    boost = self.boost
  end

  local mult = 1.0 + 2.0 * boost

  if abs(self.forward) > 1e-6 then
    local maxThrust = (self.forward > 0) and thrustForwardMax or thrustBackwardMax
    e:applyForce(e:getForward():scale(self.forward * maxThrust * mult))
  end

  if abs(self.right) > 1e-6 then
    e:applyForce(e:getRight():scale(self.right * thrustRightMax))
  end

  if abs(self.up) > 1e-6 then
    e:applyForce(e:getUp():scale(self.up * thrustUpMax))
  end

  if max(max(abs(self.pitch), abs(self.yaw)), abs(self.roll)) > 1e-6 then
    e:applyTorqueLocal(Vec3f(
      self.pitch * thrustPitchMax,
      -self.yaw * thrustYawMax,
      -self.roll * thrustRollMax))
  end

  for thruster in e:iterSocketsByType(SocketType.Thruster) do
    thruster.activationT = self.forward
    thruster.boostT      = boost
  end

  -- Engine audio: one looping 3D voice per ship, driven by thrust output
  if not self.engineSound then
    local sfx = Config.audio.sfx.engine
    self.engineSound = Sound.Load(sfx.sound, true, true)

    -- Fix: Use sfx.maxDist (or default 1000) instead of 0 maxDistance
    local minDist = sfx.minDist or 10.0
    local maxDist = sfx.maxDist or 1000.0
    self.engineSound:set3DMinMaxDistance(minDist, maxDist)

    self.engineSfxVolume = sfx.volume or 1.0
    self.engineSound:play()
  end

  local active = max(abs(self.forward), max(abs(self.right), abs(self.up)))
  local targetVol = self.engineSfxVolume * (0.45 + 0.45 * active + 0.35 * boost)

  -- Smooth volume transitions using an Exponential Moving Average (EMA) to eliminate zipper noise
  self.currentVol = self.currentVol and (self.currentVol + (targetVol - self.currentVol) * math.min(1.0, dt * 15.0)) or targetVol
  self.engineSound:setVolume(self.currentVol)

  -- Throttle pitch sweeps to ~6.6 Hz so miniaudio's resampler stays smooth
  self.engineTimer = (self.engineTimer or 0) + dt
  if self.engineTimer > 0.15 then
    self.engineTimer = 0
    self.engineSound:setPitch(0.9 + 0.25 * active + 0.3 * boost)
  end

  self.engineSound:set3DPos(e:getPos(), e:getVelocity())
end

--------------------------------------------------------------------------------

local function killThrust (self)
  for thruster in self:iterSocketsByType(SocketType.Thruster) do
    thruster.activationT = 0
    thruster.boostT      = 0
  end
  if self.thrustController and self.thrustController.engineSound then
    self.thrustController.engineSound:free()
    self.thrustController.engineSound = nil
  end
end

function Entity:addThrustController ()
  assert(not self.thrustController)
  self.thrustController = ThrustController()
  self:register(Event.Update, Entity.updateThrustController)
  self:register(Event.Destroyed, killThrust)
end

function Entity:getThrustController ()
  assert(self.thrustController)
  return self.thrustController
end

function Entity:hasThrustController ()
  return self.thrustController ~= nil
end

function Entity:updateThrustController (state)
  if self:isDestroyed() then return end
  self.thrustController:update(self, state.dt)
end

--------------------------------------------------------------------------------
