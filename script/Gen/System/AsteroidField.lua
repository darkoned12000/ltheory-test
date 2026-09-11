local SystemGenerator = require('Gen.SystemGenerator')
local Asteroid        = require('Game.Entities.Asteroid')
local Zone            = require('Game.Entities.Zone')

-- Clustering tuning constants
local kExpFactor  = 0.75  -- Falloff exponent for cluster dispersal
local kFieldScale = 750   -- Average distance between adjacent cluster nodes

--[[----------------------------------------------------------------------------
  Spawns an organic asteroid field around `center` with `count` asteroids.
  Uses preferential attachment (sampling existing zone members) to build
  clumped, filamentary rock structures instead of simple uniform spheres.
----------------------------------------------------------------------------]]--
function SystemGenerator:addAsteroidField (center, count)
  local rng = self.rng
  local zone = Zone('Asteroid Field')

  for i = 1, count do
    -- Clamp exponential scale to keep rocks between 7.0m and 45.0m
    local expVal = math.min(rng:getExp(), 2.5)
    local scale  = 7.0 * (1.0 + expVal ^ 1.8)

    -- Deterministic seed for procedural mesh generation
    local e = Asteroid(rng:get31(), scale)

    if i == 1 then
      -- First rock anchors the center of the zone
      e:setPos(center)
    else
      -- Subsequent rocks pick a random neighbor in the zone to clump around
      local parent = zone:sample(rng)
      e:setPos(parent and parent:getPos() or center)
    end

    -- Offset outward along a random 3D vector
    local offsetDist = kFieldScale * (math.min(rng:getExp(), 3.0) ^ kExpFactor)
    e:modPos(rng:getDir3():scale(offsetDist))
    e:setRot(rng:getQuat())

    self:add(e)
    zone:add(e)
  end

  self:addZone(zone)
end
