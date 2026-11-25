-- Stable structural identity for persistence, routes, and tombstones.
--
-- Entity.id is a process-local allocation counter. It is deliberately never a
-- fallback here: an object without a durable identity must return nil so the
-- caller can skip it rather than persist a key that changes on the next load.

local StableId = {}

local function scalarId (value)
  if type(value) == 'string' then
    if value:find('%S') then return value end
  elseif type(value) == 'number' then
    if value == value and value ~= math.huge and value ~= -math.huge then
      return tostring(value)
    end
  end
  return nil
end

local function prefix (value)
  return type(value) == 'string' and value:find('%S') and value or nil
end

local function methodId (entity, name)
  local method = entity[name]
  if type(method) ~= 'function' then return nil end
  return scalarId(method(entity))
end

local function qualified (kind, value)
  return kind .. ':' .. scalarId(value)
end

local function splitId (seed, index)
  seed, index = scalarId(seed), scalarId(index)
  if seed and index then return seed .. ':' .. index end
  return seed or index
end

-- Most-specific place identity wins when an object carries several scopes.
local structural = {
  { kind = 'place',  getter = 'getPlaceId',  fields = { 'placeId', 'placeKey' },
    seed = 'placeSeed', index = 'placeIndex' },
  { kind = 'region', getter = 'getRegionId', fields = { 'regionId', 'regionKey' },
    seed = 'regionSeed', index = 'regionIndex' },
  { kind = 'sector', getter = 'getSectorId', fields = { 'sectorId', 'sectorKey' },
    seed = 'sectorSeed', index = 'sectorIndex' },
}

-- Existing registry/deposit/NPC identifiers are already durable keys and are
-- returned unchanged. Structural ids are namespaced so equal local indices in
-- different scopes cannot collide.
function StableId.Module (shipId, moduleType, index)
  shipId, moduleType = scalarId(shipId), scalarId(moduleType)
  index = tonumber(index)
  if not shipId or not moduleType or not index or index < 1 or index % 1 ~= 0 then
    return nil
  end
  return string.format('%s:module:%s:%d', shipId, moduleType, index)
end

function StableId.For (entity, fallbackPrefix)
  if type(entity) ~= 'table' then return nil end

  local id = scalarId(entity.stableId)
  if id then return id end
  id = methodId(entity, 'getRegistryId')
  if not id then id = scalarId(entity.registryId) end
  if not id and type(entity.registryInfo) == 'table' then
    id = scalarId(entity.registryInfo.id)
  end
  if id then return id end

  id = scalarId(entity.depositKey)
  if id then return id end

  id = methodId(entity, 'getNpcId')
  if not id then id = scalarId(entity.npcId) end
  if not id and type(entity.npcIdentity) == 'table' then
    id = scalarId(entity.npcIdentity.id)
  end
  if id then return id end

  for _, scope in ipairs(structural) do
    id = methodId(entity, scope.getter)
    if not id then
      for _, field in ipairs(scope.fields) do
        id = scalarId(entity[field])
        if id then break end
      end
    end
    if not id then id = splitId(entity[scope.seed], entity[scope.index]) end
    if id then return qualified(scope.kind, id) end
  end

  -- Bare sector/region/place records carry structural seed/index fields but no
  -- id getter. The caller supplies their kind as fallbackPrefix; ordinary
  -- Entity.id is not used, even when a prefix is provided.
  local kind = prefix(fallbackPrefix)
  if kind then
    id = splitId(entity.seed, entity.index)
    if id then return qualified(kind, id) end
  end

  return nil
end

return StableId
