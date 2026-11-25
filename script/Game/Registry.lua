-- Data-driven asset classes and material tiers from the design specification.

local Registry = {}

Registry.Classes = {
  { id = 1, icon = '○', name = 'Support',    massMultiplier = 0.5 },
  { id = 2, icon = 'Δ', name = 'Industrial', massMultiplier = 1.0 },
  { id = 3, icon = '▼', name = 'Strategic',  massMultiplier = 4.0 },
  { id = 4, icon = '⬢', name = 'Sovereign',  massMultiplier = 20.0 },
}

Registry.MaterialTiers = {
  { id = 1, name = 'T1 Base',      massMultiplier = 1 },
  { id = 2, name = 'T2 Refined',   massMultiplier = 4 },
  { id = 3, name = 'T3 Precision', massMultiplier = 16 },
  { id = 4, name = 'T4 Exotic',    massMultiplier = 64 },
}

function Registry.NewId (prefix, seed, serial)
  return tostring(prefix) .. ':' .. tostring(seed) .. ':' .. tostring(serial)
end

function Registry.GetClass (id)
  return Registry.Classes[id]
end

function Registry.GetMaterialTier (id)
  return Registry.MaterialTiers[id]
end

return Registry
