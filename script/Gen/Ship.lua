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

-- Proven heavy-hull topology with role-specific aspect and predictable radius.
-- Profiles are applied before finalize so normals/AO and the collision sphere
-- are generated from the final silhouette.
function Ship.ShipFreighter (seed, res)
  local rng = RNG.Create(seed)
  local result = ShipCapital.Sausage(rng, { aspect = { 0.85, 0.85, 1.35 }, radius = 3 })
  rng:free()
  return result
end

function Ship.ShipIndustrial (seed, res)
  local rng = RNG.Create(seed)
  local result = ShipCapital.Sausage(rng, { aspect = { 1.15, 1.0, 0.95 }, radius = 3 })
  rng:free()
  return result
end

return Ship
