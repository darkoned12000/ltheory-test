local Entity     = require('Game.Entity')
local SocketType = require('Game.SocketKind')
local Movement   = require('Game.ShipMovement')
local ShipEquipment = require('Game.ShipEquipment')

-- The thrusters, and the SPEED they buy.
--
-- The top speed is not a cap: the ship is created with no friction, so the
-- only thing limiting it is the ship's own linear damping (0.75/s, so 75% of
-- the velocity is lost every second). The equilibrium is therefore
-- thrust / (damping * mass), and the mass is a constant for a given ship --
-- so the thrust IS the top speed, linearly.
--
-- 8e6 bought about 203 u/s in practice -- MEASURED, by holding full thrust
-- and watching the speed settle, and it was NOT the 100 that
-- `Ship:getTopSpeed` claimed. The two never agreed: the top speed is set by
-- the thrust against the ship's linear damping, and the hardcoded 100 in
-- getTopSpeed was a guess that the jobs' travel times were then based on.
--
-- The sector is 120 km across, so at 203 u/s crossing it took TEN MINUTES
-- and the nearest region was four -- which is not a place you can play in,
-- it is a map you can look at. The sector's size is a design decision and
-- this is the other half of it: 1.9e7 buys 500 u/s (measured), so a region is
-- a minute away and the sector is two.
--
-- The torques go up by the same factor as the thrust, 2.46x. The ship's
-- turning circle is v/omega, so scaling the speed and the turn
-- acceleration together keeps the circle the same size in ship-lengths:
-- a 500 u/s ship that turns like the old 203 u/s one, rather than one
-- that takes two and a half times as much room to turn.
--
-- The boost multiplies the thrust by 2 (it used to be 3), so 500 becomes
-- 1000. The boost's energy cost is scaled to match, so its efficiency per
-- unit of energy is unchanged.
local thrustMult        = 1
local thrustForwardMax  = 1.9e7 * thrustMult
local thrustBackwardMax = 4.75e6 * thrustMult
local thrustRightMax    = 1.9e7 * thrustMult
local thrustUpMax       = 4.75e6 * thrustMult
local thrustPitchMax    = 2.46e7 * thrustMult
local thrustYawMax      = 2.46e7 * thrustMult
local thrustRollMax     = 4.92e7 * thrustMult

-- The thrust at full boost, as a MULTIPLE of the base thrust. 2 = the boost
-- doubles the speed, so 500 becomes 1000.
local boostMult = 2.0

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
  local parent = e.getParent and e:getParent()
  if parent and ((parent.hasDockable and parent:hasDockable()) or not parent.physics) then
    self:clear()
    if self.engineSound then self.engineSound:setVolume(0) end
    return
  end
  local boost = 0.0
  if e:discharge(dt * self.boost * Config.game.boostCost) then
    boost = self.boost
  end

  local mult = 1.0 + (boostMult - 1.0) * boost

  -- The constants above were tuned for the player's ~5e4-mass, ~10-unit
  -- fighter. Capital hulls are much larger and their mass grows with volume;
  -- using the same fixed force would leave them effectively immobile. The
  -- shared movement model also reduces top speed and turn rate with hull size
  -- and cargo load, so capitals behave like large ships rather than fighters.
  local mass = e:getMass()
  local radius = e:getRadius()
  local cargo = e:hasInventory() and (e:getInventoryCapacity() - e:getInventoryFree()) or 0
  local capacity = e:hasInventory() and e:getInventoryCapacity() or 0
  local equipment = ShipEquipment.ThrustFactors(e)
  local forceScale = Movement.forceScale(mass, radius, cargo, capacity) * equipment.thrust
  local torqueScale = Movement.torqueScale(mass, radius, cargo, capacity) * equipment.turn
  e:setDrag(Movement.linearDrag(radius, cargo, capacity), 4.0)

  if abs(self.forward) > 1e-6 then
    local maxThrust = (self.forward > 0) and thrustForwardMax or thrustBackwardMax
    e:applyForce(e:getForward():scale(self.forward * maxThrust * mult * forceScale))
  end

  if abs(self.right) > 1e-6 then
    e:applyForce(e:getRight():scale(self.right * thrustRightMax * forceScale))
  end

  if abs(self.up) > 1e-6 then
    e:applyForce(e:getUp():scale(self.up * thrustUpMax * forceScale))
  end

  if max(max(abs(self.pitch), abs(self.yaw)), abs(self.roll)) > 1e-6 then
    e:applyTorqueLocal(Vec3f(
      self.pitch * thrustPitchMax * torqueScale,
      -self.yaw * thrustYawMax * torqueScale,
      -self.roll * thrustRollMax * torqueScale))
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
  -- The SFX master gain is re-read every frame, so the engine loop follows
  -- the SETTINGS screen's Effects slider live (see Config.audio.sfxVolume).
  local targetVol = self.engineSfxVolume * (Config.audio.sfxVolume or 1)
                    * (0.45 + 0.45 * active + 0.35 * boost)

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

function Entity:shutdownThrustController ()
  if not self.thrustController then return false end
  killThrust(self)
  return true
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
