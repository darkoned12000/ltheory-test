-- Canonical ship archetypes for procedural spawning, cargo, and registry data.

local Archetypes = {}

Archetypes.Defs = {
  fighter = {
    name = 'Fighter', generator = 'ShipFighter', generators = { 'ShipFighter', 'ShipFighter' },
    scale = 4, cargo = 25, classId = 2, model = 'Fighter',
  },
  freighter = {
    name = 'Freighter', generator = 'ShipFreighter', generators = { 'ShipFreighter', 'ShipFreighter' },
    scale = 28, cargo = 300, classId = 2, model = 'Freighter',
  },
  industrial = {
    name = 'Industrial', generator = 'ShipIndustrial', generators = { 'ShipIndustrial', 'ShipIndustrial' },
    scale = 36, cargo = 180, classId = 2, model = 'Industrial',
  },
  capital = {
    name = 'Capital', generator = 'ShipCapital', generators = { 'ShipCapital', 'ShipCapital' },
    scale = 64, cargo = 400, classId = 3, model = 'Capital',
  },
}

function Archetypes.Get (kind)
  return Archetypes.Defs[kind] or Archetypes.Defs.fighter
end

function Archetypes.Generator (kind, variant)
  local def = Archetypes.Get(kind)
  return def.generators[((variant or 1) - 1) % #def.generators + 1]
end

return Archetypes
