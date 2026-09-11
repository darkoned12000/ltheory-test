local ShipFighter = require('Gen.ShipFighter')
local ShipCapital = require('Gen.ShipCapital')

local Ship = {}

function Ship.ShipFighter (seed, res)
  local rng = RNG.Create(seed)
  Profiler.Begin('Gen.ShipFighter.Standard')
  local result = ShipFighter.Standard(rng)
  Profiler.End()
  rng:free()
  return result
end

function Ship.ShipCapital (seed, res)
  local rng = RNG.Create(seed)
  local result = ShipCapital.Sausage(rng)
  rng:free()
  return result
end

return Ship
