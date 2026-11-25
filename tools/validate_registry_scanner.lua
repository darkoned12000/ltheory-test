#!/usr/bin/env luajit
-- Registry + Scanner Database foundation from the design specification.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_registry_scanner%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

function class (ctor)
  local cls = {}
  cls.__index = cls
  setmetatable(cls, { __call = function (T, ...)
    local self = {}
    setmetatable(self, cls)
    if ctor then ctor(self, ...) end
    return self
  end })
  return cls
end

local Event = dofile(root .. '/script/Game/Event.lua')
_G.Event = Event
local Entity = dofile(root .. '/script/Game/Entity.lua')
package.loaded['Game.Entity'] = Entity
dofile(root .. '/script/Game/Components/RegistryInfo.lua')
local Registry = require('Game.Registry')
local ScannerDB = require('Game.ScannerDB')

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. detail) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or '')) end
end

check('registry defines four asset classes', #Registry.Classes == 4)
check('capital class is strategic', Registry.Classes[3].icon == '▼' and Registry.Classes[3].massMultiplier == 4)
check('station class is sovereign', Registry.Classes[4].icon == '⬢' and Registry.Classes[4].massMultiplier == 20)
check('material tiers define mass multipliers', Registry.MaterialTiers[1].massMultiplier == 1
  and Registry.MaterialTiers[4].massMultiplier == 64)

local ship = Entity()
ship:addRegistryInfo({ id = 'ship:seed:1', classId = 3, manufacturer = 'LimTech',
  model = 'Capital', year = 150, materialTier = 2 })
check('registry id is stable metadata', ship:getRegistryId() == 'ship:seed:1')
check('registry full name follows protocol', ship:getRegistryName(true) == '▼ LimTech Capital Y150')
check('combat name shows model only', ship:getRegistryName(false) == 'Capital')
check('registry mass multiplier combines class and tier', ship:getRegistryMassMultiplier() == 16)

check('T4 starts at 200m', ScannerDB.TierForRange(200) == 4)
check('T3 starts at 201m', ScannerDB.TierForRange(201) == 3)
check('T2 starts at 2km', ScannerDB.TierForRange(2001) == 2)
check('T1 starts at 10km', ScannerDB.TierForRange(10001) == 1)
check('contacts beyond 50km are unresolved', ScannerDB.TierForRange(50001) == nil)

local db = ScannerDB.Create('player')
local contact = ScannerDB.Record(db, ship, 1, 10, { x = 1, y = 2, z = 3 })
check('scanner database records stable contact', ScannerDB.Get(db, 'ship:seed:1') == contact)
check('new contact begins at T1', contact.tier == 1 and contact.icon == '▼')
ScannerDB.Record(db, ship, 4, 20, { x = 4, y = 5, z = 6 })
check('higher resolution upgrades existing contact', contact.tier == 4
  and contact.firstSeen == 10 and contact.lastSeen == 20 and contact.position.x == 4)
check('scanner database count is unique', ScannerDB.Count(db) == 1)
check('different pilots have separate databases', ScannerDB.Count(ScannerDB.Create('npc:a')) == 0)
local ore = { id = 3, stableId = 'asteroidField:1:0:0:0:1',
  depositFingerprint = 'ore-fp-1', isAsteroid = true,
  getName = function () return 'Ore Rock' end,
  hasYield = function () return true end,
  getYield = function () return { item = { getName = function () return 'Iron Ore' end } } end }
local planet = { id = 4, isPlanet = true, getName = function () return 'Planet' end }
local vessel = { id = 5, getName = function () return 'Vessel' end,
  hasSockets = function () return true end }
local oreContact = ScannerDB.Record(db, ore, 4, 30)
check('ore contacts have ore frequency class', oreContact.signal == 'ore')
check('passive ore contact does not identify its yield',
  oreContact.yieldIdentified ~= true and oreContact.yieldItem == nil)
ScannerDB.Record(db, ore, 4, 31, nil, true)
check('completed resource scan identifies its yield',
  oreContact.yieldIdentified == true and oreContact.yieldItem == 'Iron Ore')
check('planet contacts have planet frequency class', ScannerDB.Record(db, planet, 4, 30).signal == 'planet')
check('ship contacts have ship frequency class', ScannerDB.Record(db, vessel, 4, 30).signal == 'ship')
check('asteroid contact uses structural key', ScannerDB.Get(db, 'asteroidField:1:0:0:0:1') == oreContact)
local captureOk, snapshot = pcall(function () return ScannerDB.Capture(db) end)
check('scanner database is serializable', captureOk and snapshot and #snapshot.contacts == 2)
local restoredDb = ScannerDB.Create('player')
local restoreOk = pcall(function () ScannerDB.Restore(restoredDb, snapshot) end)
check('scanner database restores contacts and yield knowledge', restoreOk
  and ScannerDB.Count(restoredDb) == 2
  and ScannerDB.Get(restoredDb, 'asteroidField:1:0:0:0:1').yieldItem == 'Iron Ore')
check('entity lookup uses the structural scanner key', ScannerDB.ContactFor(db, ore) == oreContact)
local replacedOre = { stableId = ore.stableId, depositFingerprint = 'ore-fp-2',
  isAsteroid = true, getName = function () return 'Replacement' end,
  hasYield = function () return true end }
check('entity lookup rejects a replaced asteroid fingerprint',
  ScannerDB.ContactFor(db, replacedOre) == nil)
local runtime = { id = 99, getName = function () return 'Runtime' end }
ScannerDB.Record(db, runtime, 4, 40)
check('runtime contacts are excluded from persistence', #ScannerDB.Capture(db).contacts == 2)
local malformedDb = ScannerDB.Create('player')
local malformedOk = pcall(function ()
  ScannerDB.Restore(malformedDb, { ownerId = 'player', contacts = {
    42, { key = 'runtime:1' }, { key = 'ship:duplicate', tier = 1 },
    { key = 'ship:duplicate', tier = 4 },
  } })
end)
check('malformed and duplicate scanner contacts are handled safely', malformedOk
  and ScannerDB.Count(malformedDb) == 1
  and ScannerDB.Get(malformedDb, 'ship:duplicate').tier == 4)
local wrongOwner = ScannerDB.Create('npc:other')
ScannerDB.Restore(wrongOwner, snapshot)
check('scanner payload cannot override another owner', ScannerDB.Count(wrongOwner) == 0)
local isolated = ScannerDB.Create('player')
ScannerDB.Restore(isolated, snapshot)
local savedContact = ScannerDB.Get(isolated, 'ship:seed:1')
savedContact.position.x = 999
local payloadContact
for _, entry in ipairs(snapshot.contacts) do
  if entry.key == 'ship:seed:1' then payloadContact = entry end
end
check('restored scanner positions do not alias payload tables',
  payloadContact and payloadContact.position.x ~= 999)
for i = 1, 20 do ScannerDB.AddLog(isolated, 'ship:seed:1', 'log' .. i, i) end
check('scanner logs remain bounded', #savedContact.logs == 16)
local hud = io.open(root .. '/script/Game/Controls/HUD.lua'):read('*a')
local panel = io.open(root .. '/script/Game/GUI/NpcInfoPanel.lua'):read('*a')
check('HUD radar uses structural scanner lookup', hud:find('ScannerDB.ContactFor', 1, true)
  and hud:find('ScannerDB.Key', 1, true) and not hud:find("('entity:' .. tostring(entity.id))", 1, true))
check('NPC info uses fingerprint-aware scanner lookup', panel:find('ScannerDB.ContactFor', 1, true)
  and not panel:find("('entity:' .. tostring(e.id))", 1, true))
local unfingerprintedOre = { stableId = 'asteroidField:1:0:0:0:9', isAsteroid = true,
  getName = function () return 'Legacy Ore' end, hasYield = function () return true end,
  getYield = function () return { item = { getName = function () return 'Iron Ore' end } } end }
local legacyDb = ScannerDB.Create('player')
ScannerDB.Record(legacyDb, unfingerprintedOre, 4, 10, nil, true)
check('unfingerprinted asteroid contacts fail closed', ScannerDB.ContactFor(legacyDb, unfingerprintedOre) == nil)
check('unfingerprinted asteroid contacts are not persisted', #ScannerDB.Capture(legacyDb).contacts == 0)

if failures == 0 then
  print(string.format('registry/scanner: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('registry/scanner: %d/%d checks failed', failures, checks))
  os.exit(1)
end
