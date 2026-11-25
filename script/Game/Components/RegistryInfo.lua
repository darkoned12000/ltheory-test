local Entity = require('Game.Entity')
local Registry = require('Game.Registry')

function Entity:addRegistryInfo (opts)
  assert(not self.registryInfo)
  opts = opts or {}
  local class = Registry.GetClass(opts.classId or 2)
  local tier = Registry.GetMaterialTier(opts.materialTier or 1)
  assert(class and tier)
  self.registryInfo = {
    id = opts.id or Registry.NewId('entity', self.id, 1),
    classId = class.id,
    manufacturer = opts.manufacturer or 'Unknown',
    model = opts.model or 'Asset',
    year = opts.year or 0,
    materialTier = tier.id,
  }
end

function Entity:hasRegistryInfo ()
  return self.registryInfo ~= nil
end

function Entity:getRegistryId ()
  return self.registryInfo and self.registryInfo.id
end

function Entity:getRegistryInfo ()
  return self.registryInfo
end

function Entity:getRegistryClass ()
  return self.registryInfo and Registry.GetClass(self.registryInfo.classId)
end

function Entity:getRegistryName (full)
  local info = self.registryInfo
  if not info then return self.getName and self:getName() or '' end
  if not full then return info.model end
  local class = Registry.GetClass(info.classId)
  return class.icon .. ' ' .. info.manufacturer .. ' ' .. info.model .. ' Y' .. info.year
end

function Entity:getRegistryMassMultiplier ()
  local info = self.registryInfo
  if not info then return 1 end
  return Registry.GetClass(info.classId).massMultiplier
       * Registry.GetMaterialTier(info.materialTier).massMultiplier
end
