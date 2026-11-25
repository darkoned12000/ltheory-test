local Entity = require('Game.Entity')
local ScannerDB = require('Game.ScannerDB')

local Player = subclass(Entity, function (self, opts)
  opts = opts or {}
  self:addActions()
  self:addAssets()
  self:addDispositions()
  self:addInventory(0)
  self.controlling = nil
  self.scannerDB = nil
  self.npcIdentity = opts.isNpc and {
    id = opts.npcId,
    profile = opts.profile or {},
  } or nil
  self.organization = opts.organization
  self.organizationStanding = {}
  if self.organization then
    self.organizationStanding[self.organization] = opts.standing or 0
  end
end)

function Player:isNpc ()
  return self.npcIdentity ~= nil
end

function Player:getNpcId ()
  return self.npcIdentity and self.npcIdentity.id
end

function Player:getNpcProfile ()
  return self.npcIdentity and self.npcIdentity.profile
end

function Player:setNpcProfile (profile)
  assert(self.npcIdentity)
  self.npcIdentity.profile = profile or {}
end

function Player:getScannerDB ()
  if not self.scannerDB then self.scannerDB = ScannerDB.Create(self:getActorId()) end
  return self.scannerDB
end

function Player:getActorId ()
  return self:getNpcId() or 'player'
end

function Player:getOrganization ()
  return self.organization
end

function Player:setOrganization (id)
  self.organization = id
  if id and self.organizationStanding[id] == nil then
    self.organizationStanding[id] = 0
  end
end

function Player:hasOrganization (id)
  return self.organization == id
end

function Player:sharesOrganization (other)
  return self.organization ~= nil and other and other.getOrganization
     and self.organization == other:getOrganization()
end

function Player:getOrganizationStanding (id)
  return self.organizationStanding[id] or 0
end

function Player:setOrganizationStanding (id, amount)
  self.organizationStanding[id] = tonumber(amount) or 0
end

function Player:modOrganizationStanding (id, amount)
  self.organizationStanding[id] = self:getOrganizationStanding(id) + amount
end

function Player:getPrimaryShip ()
  local controlled = self.controlling
  if controlled and controlled.isAlive and controlled:isAlive() then return controlled end
  for asset in self:iterAssets() do
    if asset.isAlive and asset:isAlive() then return asset end
  end
  return nil
end

function Player:getControlling ()
  return self.controlling
end

function Player:getRoot ()
  if not self.controlling then return nil end
  return self.controlling:getRoot()
end

function Player:setControlling (target)
  self.controlling = target
end

return Player
