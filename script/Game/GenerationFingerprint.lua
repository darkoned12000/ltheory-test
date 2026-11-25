-- Deterministic provenance for generated asteroids. Streaming/render policy is
-- deliberately excluded; changing which rock occupies a slot changes its ID.

local Fingerprint = {}

local function part (value)
  value = tostring(value or '')
  return #value .. ':' .. value
end

function Fingerprint.Physical (fields)
  local order = {
    'generator', 'worldSeed', 'sectorSeed', 'scope', 'cx', 'cy', 'cz', 'slot',
    'chunkSize', 'perChunk', 'rockScale', 'oreChance', 'seed', 'scale', 'x', 'y', 'z',
  }
  local out = { 'asteroid-rock-v1' }
  for i = 1, #order do
    out[#out + 1] = part(fields[order[i]])
    out[#out + 1] = '|'
  end
  return table.concat(out)
end

function Fingerprint.Deposit (physical, itemName, yieldSize, initial)
  return 'asteroid-deposit-v1|' .. part(physical) .. '|' .. part(itemName) .. '|'
    .. part(yieldSize) .. '|' .. part(initial)
end

return Fingerprint
