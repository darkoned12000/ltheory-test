-- Shared ship movement model.
--
-- The player's fighter is the reference: ~10-unit radius, 500 u/s top speed.
-- Larger hulls are slower and accelerate more ponderously; cargo adds a
-- bounded additional slowdown. ThrustController and job travel estimates both
-- use this module so AI routing and actual motion agree.

local Movement = {}

local REFERENCE_RADIUS = 10.0
local REFERENCE_MASS = 5e4
local REFERENCE_SPEED = 500.0
local REFERENCE_DRAG = 0.75
local SIZE_EXPONENT = 0.5
local MIN_SIZE_FACTOR = 0.05
local MAX_CARGO_SLOWDOWN = 0.35

local function clamp (x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

function Movement.factors (radius, cargoMass, cargoCapacity)
  radius = tonumber(radius) or REFERENCE_RADIUS
  cargoMass = math.max(0, tonumber(cargoMass) or 0)
  cargoCapacity = math.max(0, tonumber(cargoCapacity) or 0)

  local size = clamp((REFERENCE_RADIUS / math.max(radius, 1.0)) ^ SIZE_EXPONENT,
                     MIN_SIZE_FACTOR, 1.0)
  local utilization = cargoCapacity > 0 and clamp(cargoMass / cargoCapacity, 0, 1) or 0
  local load = 1.0 - MAX_CARGO_SLOWDOWN * utilization
  local speed = size * load

  return {
    size = size,
    load = load,
    speed = speed,
    acceleration = speed * speed,
    turn = size * size,
  }
end

function Movement.topSpeed (radius, cargoMass, cargoCapacity)
  return REFERENCE_SPEED * Movement.factors(radius, cargoMass, cargoCapacity).speed
end

function Movement.forceScale (mass, radius, cargoMass, cargoCapacity)
  mass = math.max(1, tonumber(mass) or REFERENCE_MASS)
  return (mass / REFERENCE_MASS)
       * Movement.factors(radius, cargoMass, cargoCapacity).acceleration
end

function Movement.torqueScale (mass, radius, cargoMass, cargoCapacity)
  mass = math.max(1, tonumber(mass) or REFERENCE_MASS)
  radius = math.max(1, tonumber(radius) or REFERENCE_RADIUS)
  local f = Movement.factors(radius, cargoMass, cargoCapacity)
  return (mass / REFERENCE_MASS) * (radius / REFERENCE_RADIUS) ^ 2.0 * f.turn
end

function Movement.linearDrag (radius, cargoMass, cargoCapacity)
  return REFERENCE_DRAG * Movement.factors(radius, cargoMass, cargoCapacity).speed
end

return Movement
