-- Target-specific display helpers shared by the HUD and Target Info panel.

local TargetInfo = {}

function TargetInfo.Name (entity)
  if not entity then return '' end
  if entity.isAsteroid then return 'Asteroid' end
  if entity.isPlanet then
    local kind = tostring(entity.typeName or 'Planet')
    return kind:sub(1, 1):upper() .. kind:sub(2) .. ' Planet'
  end
  if entity.getRegistryName then
    local name = entity:getRegistryName(false)
    if name and name ~= '' then return name end
  end
  if entity.getName then
    local name = entity:getName()
    if name and not name:find('Entity @', 1, true) then return name end
  end
  if entity.hasSockets and entity:hasSockets() then return 'Ship' end
  if entity.hasDockable and entity:hasDockable() then return 'Station' end
  return 'Object'
end

function TargetInfo.Composition (entity, contact)
  if not entity or not entity.isAsteroid then return nil end
  if contact and contact.tier >= 4 and contact.yieldIdentified and contact.yieldItem then
    if entity.getYieldRemaining and entity:getYieldRemaining() <= 0 then return 'Depleted' end
    return contact.yieldItem
  end
  return 'Unknown'
end

function TargetInfo.Deposit (entity, contact)
  if not entity or not entity.isAsteroid or not contact or not contact.yieldIdentified then
    return nil
  end
  local remaining = entity.getYieldRemaining and entity:getYieldRemaining() or 0
  if remaining <= 0 then return 'Depleted' end
  local initial = entity.getYieldInitial and entity:getYieldInitial() or remaining
  return string.format('%d / %d', remaining, initial)
end

function TargetInfo.HasDisposition (entity)
  return entity and not entity.isAsteroid and not entity.isPlanet
end

function TargetInfo.SurfaceGap (entity, ship)
  return require('Game.Targeting').SurfaceGap(entity, ship)
end

function TargetInfo.ResolveMesh (entity)
  local mesh = entity and entity.mesh
  if mesh then
    -- LOD meshes are Lua wrappers with :get(), but a raw Mesh is FFI cdata:
    -- reading a nonexistent cdata field throws instead of returning nil.
    local ok, lod = pcall(function ()
      local get = mesh.get
      if get then return get(mesh, 0) end
    end)
    if ok and lod then return lod end
  end
  return mesh
end

return TargetInfo
