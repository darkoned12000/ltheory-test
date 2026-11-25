-- Per-pilot scanner database. Contacts are keyed by stable registry id when
-- available and retain the highest resolution achieved.

local Radar = require('Game.Radar')
local ScannerDB = {}

local LOG_LIMIT = 16

function ScannerDB.Create (ownerId)
  return { ownerId = ownerId, contacts = {}, order = {} }
end

function ScannerDB.TierForRange (distance)
  if distance <= 200 then return 4 end
  if distance <= 2000 then return 3 end
  if distance <= 10000 then return 2 end
  if distance <= 50000 then return 1 end
  return nil
end

function ScannerDB.Record (db, entity, tier, now, position, yieldIdentified)
  local key = entity.getRegistryId and entity:getRegistryId() or ('entity:' .. tostring(entity.id))
  local contact = db.contacts[key]
  if not contact then
    local class = entity.getRegistryClass and entity:getRegistryClass()
    contact = {
      key = key,
      name = entity.getRegistryName and entity:getRegistryName(true) or entity:getName(),
      model = entity.registryInfo and entity.registryInfo.model or entity:getName(),
      classId = class and class.id,
      icon = class and class.icon,
      tier = 0,
      firstSeen = now or 0,
      lastSeen = now or 0,
      position = position and { x = position.x, y = position.y, z = position.z } or nil,
      yieldIdentified = false,
      signal = Radar.SignalFor(entity),
      logs = {},
    }
    db.contacts[key] = contact
    db.order[#db.order + 1] = contact
  end
  contact.tier = math.max(contact.tier, tier or 0)
  contact.lastSeen = math.max(contact.lastSeen, now or 0)
  if position then
    contact.position = { x = position.x, y = position.y, z = position.z }
  end
  if yieldIdentified and entity.hasYield and entity:hasYield() then
    contact.yieldIdentified = true
    contact.yieldItem = entity:getYield().item:getName()
  end
  return contact
end

function ScannerDB.Get (db, key)
  return db.contacts[key]
end

function ScannerDB.Contacts (db)
  return db.order
end

function ScannerDB.Count (db)
  return #db.order
end

function ScannerDB.AddLog (db, key, text, now)
  local contact = db.contacts[key]
  if not contact then return false end
  contact.logs[#contact.logs + 1] = { time = now or 0, text = text }
  if #contact.logs > LOG_LIMIT then table.remove(contact.logs, 1) end
  return true
end

return ScannerDB
