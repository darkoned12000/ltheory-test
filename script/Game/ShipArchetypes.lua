-- Canonical ship archetypes for procedural spawning, cargo, and registry data.

local Archetypes = {}

Archetypes.Order = { 'fighter', 'freighter', 'industrial', 'capital' }

Archetypes.Defs = {
  fighter = {
    name = 'Fighter', description = 'Light patrol and escort hull',
    generator = 'ShipFighter', generators = { 'ShipFighter', 'ShipFighter' },
    scale = 4, cargo = 25, classId = 2, model = 'Fighter',
    health = 2500, shield = 2500, turrets = 2,
    price = 18000, repairFraction = 0.12, repairSeconds = 60,
  },
  freighter = {
    name = 'Freighter', description = 'Long-range cargo hull',
    generator = 'ShipFreighter', generators = { 'ShipFreighter', 'ShipFreighter' },
    scale = 28, cargo = 300, classId = 2, model = 'Freighter',
    health = 20000, shield = 15000, turrets = 1,
    price = 55000, repairFraction = 0.15, repairSeconds = 90,
  },
  industrial = {
    name = 'Industrial', description = 'Mining and utility hull',
    generator = 'ShipIndustrial', generators = { 'ShipIndustrial', 'ShipIndustrial' },
    scale = 36, cargo = 180, classId = 2, model = 'Industrial',
    health = 40000, shield = 25000, turrets = 2,
    price = 95000, repairFraction = 0.18, repairSeconds = 105,
  },
  capital = {
    name = 'Capital', description = 'Heavy combat and fleet hull',
    generator = 'ShipCapital', generators = { 'ShipCapital', 'ShipCapital' },
    scale = 64, cargo = 400, classId = 3, model = 'Capital',
    health = 150000, shield = 50000, turrets = 3,
    price = 280000, repairFraction = 0.20, repairSeconds = 150,
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
