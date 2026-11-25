-- Structural route identity. Runtime IDs are session-only fallbacks and are
-- deliberately prefixed so persistence can exclude them.

local StableId = require('Game.StableId')
local RouteKey = {}

function RouteKey.Entity (entity)
  local id = StableId.For(entity)
  if id then return id end
  return entity and entity.id and ('runtime:' .. tostring(entity.id)) or nil
end

function RouteKey.IsPersistent (key)
  return type(key) == 'string' and key:sub(1, 8) ~= 'runtime:'
end

local function part (value)
  value = tostring(value or '')
  return #value .. ':' .. value
end

function RouteKey.Encode (kind, src, dst, item)
  return 'v1|' .. part(kind) .. '|' .. part(src) .. '|' .. part(dst) .. '|' .. part(item)
end

return RouteKey
