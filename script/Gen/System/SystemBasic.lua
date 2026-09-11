local Generator       = require('Gen.Generator')
local SystemGenerator = require('Gen.SystemGenerator')
local Asteroid        = require('Game.Entities.Asteroid')
local Planet          = require('Game.Entities.Planet')
local Station         = require('Game.Entities.Station')
local System          = require('Game.Entities.System')

local sqrt = math.sqrt  -- Localize math reference to fix nil global bug
local kSystemScale = 5000.0

--[[----------------------------------------------------------------------------
  Generates a basic solar system with starfields, stations on the ecliptic
  plane, deep-space asteroid fields, and planets with ring systems.
----------------------------------------------------------------------------]]--
local function generateSystemBasic (seed)
  local self = SystemGenerator(seed)
  local rng  = self.rng

  -- 1. Deep Space Asteroid Fields (3D Volume Distribution)
  do
    for i = 1, Config.gen.nFields do
      -- Distribute fields radially around the system origin
      local dist = kSystemScale * (math.min(rng:getExp(), 3.0) ^ (1.0 / 3.0))
      local center = rng:getDir3():scale(dist) + Config.gen.origin
      self:addAsteroidField(center, Config.gen.nFieldSize(rng))
    end
  end

  -- 2. Space Stations (2D Ecliptic Plane: Y = 0)
  do
    for i = 1, Config.gen.nStations do
      local e = Station(rng:get31())
      local dir = rng:getDir2()
      e:setScale(100.0)
      e:setPos(Vec3f(dir.x, 0, dir.y):scale(kSystemScale))
      e:modPos(Config.gen.origin)
      self:add(e)
    end
  end

  -- 3. Planets & Planetary Ring Belts
  do
    for i = 1, Config.gen.nPlanets do
      local e = Planet(rng:get31())
      local dir = rng:getDir2()
      e:setScale(Config.gen.scalePlanet)

      -- Position planets along the ecliptic disk with square-root radial spacing
      local orbitalDist = e:getScale() + kSystemScale * (0.25 + 0.75 * sqrt(rng:getUniform()))
      e:setPos(Vec3f(dir.x, 0, dir.y):scale(orbitalDist))
      e:modPos(Config.gen.origin)
      self:add(e)

      -- Generate planetary asteroid belts around the planet
      local center = e:getPos()
      local rc = 2.00 * e:getRadius()  -- Belt center distance
      local rw = 0.20 * e:getRadius()  -- Belt width

      for j = 1, Config.gen.nBeltSize(rng) do
        local r = rc + rng:getUniformRange(-rw, rw) * (0.5 + 0.5 * rng:getExp())
        local h = 0.1 * rw * rng:getGaussian()  -- Vertical height dispersion
        local beltDir = rng:getDir2()

        -- Clamp ring rock sizes (3.0m to 25.0m) to prevent planet clipping
        local expVal = math.min(rng:getExp(), 2.0)
        local scale  = 3.0 * (1.0 + expVal ^ 1.5)

        local e2 = Asteroid(rng:get31(), scale)
        e2:setPos(center + Vec3f(r * beltDir.x, h, r * beltDir.y))
        e2:setRot(rng:getQuat())
        self:add(e2)
      end
    end
  end

  return self:finalize()
end

Generator.Add('System', 1.0, generateSystemBasic)
