-- Per-pilot scanner database. Contacts use the same structural keys as save
-- data and retain the highest resolution achieved for one generated object.

local Radar = require('Game.Radar')
local StableId = require('Game.StableId')
local ScannerDB = {}

local LOG_LIMIT = 16

local function finite (value, fallback)
  value = tonumber(value)
  if value and value == value and value ~= math.huge and value ~= -math.huge then
    return value
  end
  return fallback
end

local function position (value)
  if type(value) ~= 'table' then return nil end
  local x, y, z = finite(value.x), finite(value.y), finite(value.z)
  if not x or not y or not z then return nil end
  return { x = x, y = y, z = z }
end

local function fingerprint (entity)
  local value = entity and (entity.depositFingerprint or entity.generationFingerprint)
  if type(value) == 'string' and value ~= '' then return value end
  return nil
end

local function compatible (a, b)
  if a == nil or b == nil then return a == b end
  return a == b
end

local function displayName (entity)
  if type(entity.getRegistryName) == 'function' then return entity:getRegistryName(true) end
  if type(entity.getName) == 'function' then return entity:getName() end
  return 'Unknown'
end

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

function ScannerDB.Key (entity)
  if type(entity) ~= 'table' then return nil end
  return StableId.For(entity) or (entity.id and ('runtime:' .. tostring(entity.id)) or nil)
end

function ScannerDB.Record (db, entity, tier, now, pos, yieldIdentified)
  local key = ScannerDB.Key(entity)
  if not key then return nil end
  local fp = fingerprint(entity)
  local contact = db.contacts[key]
  if contact and not compatible(contact.fingerprint, fp) then
    for i = #db.order, 1, -1 do
      if db.order[i] == contact then table.remove(db.order, i); break end
    end
    contact = nil
  end
  if not contact then
    local class = entity.getRegistryClass and entity:getRegistryClass()
    contact = {
      key = key,
      name = displayName(entity),
      model = entity.registryInfo and entity.registryInfo.model or displayName(entity),
      classId = class and class.id,
      icon = class and class.icon,
      tier = 0,
      firstSeen = finite(now, 0),
      lastSeen = finite(now, 0),
      position = position(pos),
      fingerprint = fp,
      yieldIdentified = false,
      signal = Radar.SignalFor(entity),
      logs = {},
    }
    db.contacts[key] = contact
    db.order[#db.order + 1] = contact
  end
  contact.tier = math.max(contact.tier, math.floor(finite(tier, 0)))
  contact.tier = math.max(0, math.min(4, contact.tier))
  contact.lastSeen = math.max(contact.lastSeen, finite(now, 0))
  if pos then contact.position = position(pos) end
  if yieldIdentified and entity.hasYield and entity:hasYield() and entity.getYield then
    contact.yieldIdentified = true
    contact.yieldItem = entity:getYield().item:getName()
  end
  return contact
end

function ScannerDB.Get (db, key)
  return db.contacts[key]
end

function ScannerDB.ContactFor (db, entity)
  local key = ScannerDB.Key(entity)
  local contact = key and db.contacts[key]
  local fp = fingerprint(entity)
  if entity.isAsteroid and not fp then return nil end
  if contact and compatible(contact.fingerprint, fp) then return contact end
  return nil
end

function ScannerDB.Contacts (db)
  return db.order
end

function ScannerDB.Count (db)
  return #db.order
end

function ScannerDB.Capture (db)
  local contacts = {}
  for _, contact in ipairs(db.order) do
    local asteroid = contact.signal == 'ore' or contact.signal == 'asteroid'
      or contact.key:match('^asteroidField:') or contact.key:match('^startup:')
    if type(contact.key) == 'string' and contact.key ~= ''
       and contact.key:sub(1, 8) ~= 'runtime:' and (not asteroid or contact.fingerprint) then
      local logs = {}
      for i = 1, math.min(#(contact.logs or {}), LOG_LIMIT) do
        local log = contact.logs[i]
        if type(log) == 'table' then
          logs[#logs + 1] = { time = finite(log.time, 0), text = tostring(log.text or '') }
        end
      end
      contacts[#contacts + 1] = {
        key = contact.key, name = contact.name, model = contact.model,
        classId = contact.classId, icon = contact.icon, tier = contact.tier,
        firstSeen = contact.firstSeen, lastSeen = contact.lastSeen,
        position = position(contact.position), fingerprint = contact.fingerprint,
        yieldIdentified = contact.yieldIdentified == true,
        yieldItem = contact.yieldItem, signal = contact.signal, logs = logs,
      }
    end
  end
  table.sort(contacts, function (a, b) return a.key < b.key end)
  return { ownerId = db.ownerId, contacts = contacts }
end

function ScannerDB.Restore (db, data)
  db.contacts, db.order = {}, {}
  if type(data) ~= 'table' or type(data.contacts) ~= 'table' then return end
  if data.ownerId ~= nil and data.ownerId ~= db.ownerId then return end
  local restored = {}
  for _, entry in ipairs(data.contacts) do
    if type(entry) == 'table' and type(entry.key) == 'string' and entry.key ~= ''
       and entry.key:sub(1, 8) ~= 'runtime:' then
      local firstSeen = math.max(0, finite(entry.firstSeen, 0))
      local lastSeen = math.max(firstSeen, finite(entry.lastSeen, firstSeen))
      local logs = {}
      local savedLogs = type(entry.logs) == 'table' and entry.logs or {}
      for i = 1, math.min(#savedLogs, LOG_LIMIT) do
        local log = savedLogs[i]
        if type(log) == 'table' then
          logs[#logs + 1] = { time = finite(log.time, 0), text = tostring(log.text or '') }
        end
      end
      local identified = entry.yieldIdentified == true and type(entry.yieldItem) == 'string'
      restored[entry.key] = {
        key = entry.key, name = tostring(entry.name or 'Unknown'),
        model = tostring(entry.model or entry.name or 'Unknown'),
        classId = entry.classId, icon = entry.icon,
        tier = math.max(0, math.min(4, math.floor(finite(entry.tier, 0)))),
        firstSeen = firstSeen, lastSeen = lastSeen,
        position = position(entry.position),
        fingerprint = fingerprint({ depositFingerprint = entry.fingerprint }),
        yieldIdentified = identified, yieldItem = identified and entry.yieldItem or nil,
        signal = entry.signal, logs = logs,
      }
    end
  end
  local keys = {}
  for key in pairs(restored) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local contact = restored[key]
    db.contacts[key] = contact
    db.order[#db.order + 1] = contact
  end
end

function ScannerDB.AddLog (db, key, text, now)
  local contact = db.contacts[key]
  if not contact then return false end
  contact.logs = contact.logs or {}
  contact.logs[#contact.logs + 1] = { time = finite(now, 0), text = tostring(text or '') }
  if #contact.logs > LOG_LIMIT then table.remove(contact.logs, 1) end
  return true
end

return ScannerDB
