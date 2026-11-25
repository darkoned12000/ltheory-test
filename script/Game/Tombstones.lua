-- Bounded persistent keys for deterministic entities that must not respawn.

local Tombstones = {}
Tombstones.__index = Tombstones

function Tombstones.Create (limit)
  return setmetatable({
    keys = {},
    fingerprints = {},
    order = {},
    limit = math.max(1, math.floor(limit or 2048)),
  }, Tombstones)
end

function Tombstones:Has (key)
  return type(key) == 'string' and self.keys[key] == true
end

function Tombstones:Count ()
  return #self.order
end

function Tombstones:Mark (key, fingerprint)
  if type(key) ~= 'string' or key == '' then return false end
  if self.keys[key] then
    if fingerprint ~= nil then self.fingerprints[key] = fingerprint end
    return false
  end
  self.keys[key] = true
  if fingerprint ~= nil then self.fingerprints[key] = fingerprint end
  self.order[#self.order + 1] = key
  while #self.order > self.limit do
    local oldest = table.remove(self.order, 1)
    self.keys[oldest] = nil
    self.fingerprints[oldest] = nil
  end
  return true
end

function Tombstones:Matches (key, fingerprint)
  if not self:Has(key) or fingerprint == nil then return false end
  return self.fingerprints[key] == fingerprint
end

function Tombstones:Capture ()
  local out = {}
  for i = 1, #self.order do
    local key = self.order[i]
    out[i] = self.fingerprints[key] and { key = key, fingerprint = self.fingerprints[key] } or key
  end
  return out
end

function Tombstones:Restore (data)
  self.keys, self.fingerprints, self.order = {}, {}, {}
  if type(data) ~= 'table' then return end
  for _, entry in ipairs(data) do
    if type(entry) == 'string' then
      self:Mark(entry)
    elseif type(entry) == 'table' and type(entry.key) == 'string' then
      self:Mark(entry.key, entry.fingerprint)
    end
  end
end

return Tombstones
