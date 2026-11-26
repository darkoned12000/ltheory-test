#!/usr/bin/env luajit
-- NPC actor-state save/restore by stable id. The world still regenerates from
-- its seed; this validates the additive actor snapshot and JSON round-trip.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_save%.lua$', '')
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

function subclass (base, ctor)
  local cls = {}
  cls.__index = cls
  setmetatable(cls, {
    __call = function (T, ...)
      local self = base()
      setmetatable(self, cls)
      if ctor then ctor(self, ...) end
      return self
    end,
    __index = base,
  })
  return cls
end

function insert (t, v) t[#t + 1] = v end
function remove (t, v)
  if v == nil then v = t[#t] end
  for i = 1, #t do
    if t[i] == v then t[i] = t[#t]; t[#t] = nil; return end
  end
end

local Event = dofile(root .. '/script/Game/Event.lua')
_G.Event = Event
local Entity = dofile(root .. '/script/Game/Entity.lua')
package.loaded['Game.Entity'] = Entity
for _, name in ipairs({ 'addActions', 'addDispositions' }) do
  Entity[name] = function () end
end
dofile(root .. '/script/Game/Components/Assets.lua')
dofile(root .. '/script/Game/Components/Inventory.lua')
local Player = dofile(root .. '/script/Game/Entities/Player.lua')
local Registry = require('Game.NpcRegistry')
local Json = dofile(root .. '/script/Game/Json.lua')
package.loaded['Game.Json'] = Json
package.loaded['ffi.File'] = {}
package.loaded['ffi.Directory'] = {}
package.loaded['ffi.Tex2D'] = {}
local Credit = { getMass = function () return 0 end, getName = function () return 'Credit' end }
local Ore = { getMass = function () return 4 end, getName = function () return 'Iron Ore' end }
_G.Item = { Credit = Credit, All = function () return { Credit, Ore } end }
_G.Vec3f = function (x, y, z) return { x = x, y = y, z = z } end
_G.Quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
_G.Config = { gen = { nTurrets = 2 } }
package.loaded['Game.Item'] = _G.Item
local SaveGame = dofile(root .. '/script/Game/SaveGame.lua')

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then
    print('ok   - ' .. name .. (detail and ('  -- ' .. detail) or ''))
  else
    failures = failures + 1
    print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or ''))
  end
end

local function systemWith (npc)
  local registry = Registry.Create()
  Registry.register(registry, npc)
  return { npcs = registry, getNpc = function (self, id) return Registry.get(registry, id) end }
end

local original = Player({ isNpc = true, npcId = 'seed:1', organization = 'belt-miners',
  profile = { role = 'miner', caution = 0.25 } })
original:addItem(Credit, 1234)
original.npcProgression = { purchaseSerial = 3 }
original:modOrganizationStanding('belt-miners', 7)
local scanTarget = { stableId = 'asteroidField:1:0:0:0:9', depositFingerprint = 'scan-fp',
  getName = function () return 'Scanned Rock' end }
require('Game.ScannerDB').Record(original:getScannerDB(), scanTarget, 4, 10)
local source = systemWith(original)
source.depositState = { ['rock:1'] = 17, ['rock:2'] = 0 }
source.depositFingerprints = { ['rock:1'] = 'fp1', ['rock:2'] = 'fp2' }
source.captureTombstones = function () return { 'rock:dead', 'ship:1234:1' } end
source.getTime = function () return 1234.5 end
local captureOk, data = pcall(function ()
  return SaveGame.Capture(nil, { seedHex = '0011223344556677', sectorIndex = 3 }, source)
end)
check('capture includes NPC actor state', captureOk and data.npcs and #data.npcs == 1,
  captureOk and tostring(data) or tostring(data))
check('capture uses stable NPC id', data.npcs and data.npcs[1].id == 'seed:1')
check('capture stores credits as a plain number', data.npcs and data.npcs[1].credits == 1234)
check('capture includes persistent deposit amounts', data.deposits and #data.deposits == 2)
check('capture includes deposit fingerprints', data.deposits[1].fingerprint
  and data.deposits[2].fingerprint)
check('capture includes sector index', data.sectorIndex == 3)
check('capture includes pilot scanner knowledge', data.npcs[1].scannerDB
  and #data.npcs[1].scannerDB.contacts == 1)
check('capture includes NPC progression serial', data.npcs[1].progression
  and data.npcs[1].progression.purchaseSerial == 3)
check('capture includes persistent tombstones', data.tombstones and #data.tombstones == 2)
check('capture includes simulation time', data.simTime == 1234.5)

local encoded = Json.Encode(data)
local decoded = Json.Decode(encoded)
check('NPC snapshot survives JSON round-trip', decoded.npcs and decoded.npcs[1].id == 'seed:1'
  and decoded.npcs[1].credits == 1234 and decoded.npcs[1].profile.role == 'miner')

local restored = Player({ isNpc = true, npcId = 'seed:1', organization = 'traders',
  profile = { role = 'trader' } })
restored:addItem(Credit, 9999)
restored.npcProgression = { purchaseSerial = 9 }
local destination = systemWith(restored)
destination.restoreTombstones = function (self, values) self.tombstoneData = values end
SaveGame.Restore(nil, decoded, destination)
check('restore matches NPC by stable id', destination:getNpc('seed:1') == restored)
check('restore replaces credits exactly', restored:getItemCount(Credit) == 1234)
check('restore replaces organization', restored:getOrganization() == 'belt-miners')
check('restore replaces standing', restored:getOrganizationStanding('belt-miners') == 7)
check('restore replaces profile', restored:getNpcProfile().role == 'miner'
  and restored:getNpcProfile().caution == 0.25)
check('restore reinstates NPC progression serial', restored.npcProgression.purchaseSerial == 3)
check('restore reinstates pilot scanner knowledge', restored.scannerDB
  and require('Game.ScannerDB').Count(restored:getScannerDB()) == 1)
check('restore reinstates deposit amounts', destination.depositState
  and destination.depositState['rock:1'] == 17 and destination.depositState['rock:2'] == 0)
check('restore reinstates deposit fingerprints', destination.depositFingerprints
  and destination.depositFingerprints['rock:1'] == 'fp1')
check('restore reinstates tombstones', destination.tombstoneData
  and destination.tombstoneData[1] == 'rock:dead' and destination.tombstoneData[2] == 'ship:1234:1')
check('restore reinstates simulation time', destination.time == 1234.5)

local function fakeShip ()
  return {
    stableId = 'ship:1234:1', shipKind = 'industrial', shipVariant = 1, turretPairs = 3,
    prototypeSeed = 99, inventory = {}, inventoryCapacity = 100, inventoryFree = 100,
    pos = { x = 1, y = 2, z = 3 }, vel = { x = 4, y = 5, z = 6 },
    rot = { x = 0, y = 0, z = 0, w = 1 }, health = 80, healthMax = 100, healthRate = 10,
    charge = 60, chargeMax = 100, chargeRate = 10,
    shield = 40, shieldMax = 50, shieldRate = 5, shieldDelay = 6,
    hasInventory = function () return true end,
    getInventory = function (self) return self.inventory end,
    getInventoryCapacity = function (self) return self.inventoryCapacity end,
    setInventoryCapacity = function (self, value) self.inventoryCapacity = value; self.inventoryFree = value end,
    refreshInventory = function (self) self.inventoryFree = self.inventoryCapacity end,
    addItem = function (self, item, count)
      local mass = count * item:getMass()
      if mass > self.inventoryFree then return false end
      self.inventoryFree = self.inventoryFree - mass
      self.inventory[item] = (self.inventory[item] or 0) + count
      return true
    end,
    hasHealth = function () return true end,
    getHealth = function (self) return self.health end,
    setHealth = function (self, value, max, rate) self.health, self.healthMax, self.healthRate = value, max, rate end,
    hasCharge = function () return true end,
    getCharge = function (self) return self.charge end,
    getChargeMax = function (self) return self.chargeMax end,
    setCharge = function (self, value, max, rate) self.charge, self.chargeMax, self.chargeRate = value, max, rate end,
    hasShield = function () return true end,
    getShield = function (self) return self.shield end,
    getShieldMax = function (self) return self.shieldMax end,
    setShield = function (self, value, max, rate, delay)
      self.shield, self.shieldMax, self.shieldRate, self.shieldDelay = value, max, rate, delay
    end,
    getPos = function (self) return self.pos end,
    setPos = function (self, value) self.pos = value end,
    getVelocity = function (self) return self.vel end,
    setVelocity = function (self, value) self.vel = value end,
    getRot = function (self) return self.rot end,
    setRot = function (self, value) self.rot = value end,
    getScale = function () return 36 end,
    getName = function () return 'Miner One' end,
    setName = function (self, value) self.name = value end,
    getParent = function () return nil end,
    getRoot = function (self) return self.root end,
    getOwner = function (self) return self.owner end,
    credits = 0,
    getCredits = function (self) return self.credits end,
    hasCredits = function (self, count) return self.credits >= count end,
    addCredits = function (self, count) self.credits = self.credits + count end,
    removeCredits = function (self, count) self.credits = self.credits - count end,
    actions = {}, jobState = 3,
    getCurrentAction = function (self) return self.actions[#self.actions] end,
    clearActions = function (self) self.actions = {} end,
  }
end
local ship = fakeShip()
ship.inventory[Ore] = 7
ship.sockets = { { moduleId = 'ship:1234:1:module:Thruster:1', type = 'Thruster',
  typeIndex = 1, child = { equipmentId = 'thruster-mk2' } } }
ship.npcPolicy = require('Game.NpcPolicy').Create(42)
ship.npcSafety = require('Game.NpcSafety').Create()
ship.npcSafety.damage, ship.npcSafety.lastDamageAt = 45, 5
local endpoint = { stableId = 'place:1:region:1' }
local source = { stableId = 'asteroidField:1:0:0:0:1', depositFingerprint = 'ore-fp',
  getName = function () return 'Iron Rock' end,
  hasYield = function () return true end, getYield = function ()
  return { item = Ore }
end }
ship.knownYields, ship.scannedAsteroids = { [source] = true }, { [source] = true }
local job = { src = source, dst = endpoint, itemName = 'Iron Ore', jobState = 3,
  getKind = function () return 'mine' end, getName = function () return 'Mine' end }
ship.job, ship.actions = job, { job }
ship.shipKind, ship.npcRole = 'capital', 'industrial'
ship.npcUpkeepDebt, ship.npcUpkeepElapsed = 123, 456
ship.travelTargetSector, ship.npcServiceNeed = 4, 'shipyard'
ship.npcNextServiceAt, ship.npcNextTravelAt = 500, 400
local shipSnapshot = SaveGame.CaptureShip(ship)
check('ship snapshot captures physical and cargo state', shipSnapshot.id == 'ship:1234:1'
  and shipSnapshot.pos.x == 1 and shipSnapshot.health.value == 80
  and shipSnapshot.charge.value == 60 and shipSnapshot.shield.value == 40
  and shipSnapshot.items[1].count == 7)
check('ship snapshot captures durable module roster, equipment tier, and turret layout',
  shipSnapshot.modules and #shipSnapshot.modules == 1 and shipSnapshot.modules[1].index == 1
  and shipSnapshot.modules[1].equipmentId == 'thruster-mk2' and shipSnapshot.turrets == 3)
local decodedShip = Json.Decode(Json.Encode(shipSnapshot))
check('module roster and equipment survive JSON round-trip', decodedShip.modules
  and decodedShip.modules[1].id == 'ship:1234:1:module:Thruster:1'
  and decodedShip.modules[1].equipmentId == 'thruster-mk2')
check('ship snapshot keeps hull kind separate from NPC role', shipSnapshot.kind == 'capital'
  and shipSnapshot.role == 'industrial')
check('ship snapshot captures policy and active job', shipSnapshot.policy.seed == 42
  and shipSnapshot.job.kind == 'mine' and shipSnapshot.job.state == 3)
check('ship snapshot captures safety and knowledge memory', shipSnapshot.safety.damage == 45
  and shipSnapshot.knowledge[1].key == 'asteroidField:1:0:0:0:1'
  and shipSnapshot.knowledge[1].fingerprint == 'ore-fp')
check('ship snapshot preserves upkeep debt and partial-hour progress',
  shipSnapshot.npcUpkeepDebt == 123 and shipSnapshot.npcUpkeepElapsed == 456)
check('ship snapshot preserves station-service routing and retry state',
  shipSnapshot.travelTargetSector == 4 and shipSnapshot.npcServiceNeed == 'shipyard'
  and shipSnapshot.npcNextServiceAt == 500 and shipSnapshot.npcNextTravelAt == 400)
local restoredShip = fakeShip()
restoredShip.root = { registered = {}, registerKnowledgeShip = function (self, ship)
  self.registered[#self.registered + 1] = ship
end }
SaveGame.RestoreShip(restoredShip, shipSnapshot)
check('ship restore reinstates physical and cargo state', restoredShip.pos.x == 1
  and restoredShip.health == 80 and restoredShip.charge == 60
  and restoredShip.shield == 40 and restoredShip.shieldMax == 50
  and restoredShip.inventory[Ore] == 7)
check('ship restore reinstates policy and pending job', restoredShip.npcPolicy.seed == 42
  and restoredShip.pendingJob.kind == 'mine' and restoredShip.pendingJob.state == 3)
check('ship restore keeps purchased hull kind and NPC role separate',
  restoredShip.shipKind == 'capital' and restoredShip.npcRole == 'industrial')
check('ship restore reinstates safety and structural knowledge', restoredShip.npcSafety.damage == 45
  and restoredShip.knowledge.scans['asteroidField:1:0:0:0:1'].fingerprint == 'ore-fp')
check('ship restore reinstates upkeep debt and partial-hour progress',
  restoredShip.npcUpkeepDebt == 123 and restoredShip.npcUpkeepElapsed == 456)
check('ship restore reinstates station-service routing and retry state',
  restoredShip.travelTargetSector == 4 and restoredShip.npcServiceNeed == 'shipyard'
  and restoredShip.npcNextServiceAt == 500 and restoredShip.npcNextTravelAt == 400)
check('restored ships register for generic knowledge rebinding',
  restoredShip.root.registered[1] == restoredShip)
ship.job = { src = { id = 987 }, dst = endpoint, itemName = 'Iron Ore',
  getKind = function () return 'mine' end, getName = function () return 'Mine' end }
ship.actions = { ship.job }
check('runtime-only job endpoints are not persisted', SaveGame.CaptureShip(ship).job == nil)
ship.job, ship.actions = nil, {}
ship.pendingJob = { kind = 'mine', src = 'asteroidField:1:0:0:0:1', dst = 'place:1:region:1',
  srcFingerprint = 'ore-fp', state = 2 }
check('sector-transit job checkpoints remain in ship snapshots',
  SaveGame.CaptureShip(ship).job == ship.pendingJob)
ship.pendingJob = nil
local transitActor = Player({ isNpc = true, npcId = 'npc:transit', profile = { role = 'industrial' } })
local transitShip = fakeShip()
transitShip.stableId = 'ship:transit'
transitActor:addAsset(transitShip); transitShip.owner = transitActor
transitActor.transit = { destination = 4, fromSector = 1, reason = 'mission', departedAt = 12,
  arrivalPos = { x = 100, y = 200, z = 300 } }
local transitSystem = { npcs = Registry.Create(), npcTransit = { { npc = transitActor, ship = transitShip } } }
local transitSnapshot = SaveGame.CaptureNpcs(transitSystem)
check('actors in sector transit remain in the save roster', #transitSnapshot == 1
  and transitSnapshot[1].id == 'npc:transit' and transitSnapshot[1].transit.destination == 4)

local playerOwner = { scannerDB = require('Game.ScannerDB').Create('player'),
  npcProgression = { purchaseSerial = 7 } }
function playerOwner:getActorId () return 'player' end
function playerOwner:getScannerDB () return self.scannerDB end
ship.owner = playerOwner
ship.credits = 1234
require('Game.ScannerDB').Record(playerOwner:getScannerDB(), source, 4, 10)
local playerData = SaveGame.Capture(ship, { seedHex = '0011223344556677' }, nil)
check('capture includes the human pilot scanner database', playerData.playerScannerDB
  and #playerData.playerScannerDB.contacts == 1)
check('capture preserves purchased player identity and purchase serial',
  playerData.playerShip.id == 'ship:1234:1' and playerData.playerShip.kind == 'capital'
  and playerData.playerShip.purchaseSerial == 7)
local spawnOptions = type(SaveGame.PlayerSpawnOptions) == 'function'
  and SaveGame.PlayerSpawnOptions(playerData) or nil
check('player spawn options rebuild the saved hull and module loadout',
  spawnOptions ~= nil and spawnOptions.kind == 'capital'
  and spawnOptions.shipId == 'ship:1234:1' and spawnOptions.seed == 99
  and spawnOptions.scale == 36 and spawnOptions.cargo == 100 and spawnOptions.turrets == 3
  and spawnOptions.modules[1].equipmentId == 'thruster-mk2',
  spawnOptions and string.format('%s %s %s %s %s', tostring(spawnOptions.kind),
    tostring(spawnOptions.shipId), tostring(spawnOptions.seed), tostring(spawnOptions.scale),
    tostring(spawnOptions.cargo)))
local legacySpawn = type(SaveGame.PlayerSpawnOptions) == 'function'
  and SaveGame.PlayerSpawnOptions({ playerShip = { id = 'ship:legacy', kind = 'capital' } }) or nil
check('legacy player snapshots use the historical turret-pair layout',
  legacySpawn and legacySpawn.turrets == 2)
local restoredOwner = { scannerDB = require('Game.ScannerDB').Create('player') }
function restoredOwner:getActorId () return 'player' end
function restoredOwner:getScannerDB () return self.scannerDB end
local restoredPlayerShip = fakeShip()
restoredPlayerShip.owner = restoredOwner
restoredPlayerShip.credits = 999
playerData.playerShip.dockedAt = 'place:dock'
local dockParent = { hasDockable = function () return true end, addDocked = function (parent, ship)
  parent.dockedShip = ship
end }
local humanSystem = { resolveStableId = function (_, key)
  if key == 'place:dock' then return dockParent end
end }
SaveGame.Restore(restoredPlayerShip, Json.Decode(Json.Encode(playerData)), humanSystem)
check('restore reinstates the human pilot scanner database',
  require('Game.ScannerDB').Count(restoredOwner:getScannerDB()) == 1)
check('human docking state is restored', dockParent.dockedShip == restoredPlayerShip)
check('legacy player cargo rows do not duplicate playerShip cargo',
  restoredPlayerShip.inventory[Ore] == 7)
check('player restore replaces credits exactly instead of adding to them',
  restoredPlayerShip:getCredits() == 1234)
check('player restore reinstates the purchase serial',
  restoredOwner.npcProgression and restoredOwner.npcProgression.purchaseSerial == 7)
local zeroPlayer = fakeShip()
zeroPlayer.credits = 500
SaveGame.Restore(zeroPlayer, { playerCredits = 0 }, nil)
check('zero player credits restore as zero', zeroPlayer:getCredits() == 0)
local malformedSystem = systemWith(restored)
local malformedOk = pcall(function ()
  SaveGame.Restore(nil, { npcs = 42, deposits = 42, tombstones = 42, simTime = 'bad' }, malformedSystem)
end)
check('malformed world and roster payloads fail closed', malformedOk)
local malformedShip = fakeShip()
local malformedShipOk = pcall(function ()
  SaveGame.RestoreShip(malformedShip, { knowledge = 42, safety = 42, job = 42 })
end)
local scalarShipOk = pcall(function () SaveGame.RestoreShip(malformedShip, 42) end)
local malformedFieldsOk = pcall(function ()
  SaveGame.RestoreShip(malformedShip, { pos = 42, health = 42, charge = 42, items = 42 })
  SaveGame.RestoreShip(malformedShip, { pos = {}, vel = {}, rot = {}, health = {}, charge = {} })
end)
local malformedPlayerOk = pcall(function ()
  SaveGame.Restore(fakeShip(), { playerShip = 42, playerPos = {}, playerVel = {},
    playerRot = {}, shipHealth = {}, playerCredits = {}, items = 42 }, nil)
end)
local numericShip = fakeShip()
SaveGame.RestoreShip(numericShip, { pos = {}, vel = {}, rot = {}, health = {}, charge = {} })
check('malformed ship memory payloads fail closed', malformedShipOk
  and next(malformedShip.knowledge.scans) == nil and malformedShip.pendingJob == nil)
check('scalar and malformed ship snapshots fail closed', scalarShipOk and malformedFieldsOk
  and malformedPlayerOk)
check('malformed nested numeric fields do not overwrite valid ship state',
  numericShip.pos.x == 1 and numericShip.vel.x == 4 and numericShip.rot.w == 1
  and numericShip.health == 80 and numericShip.charge == 60)
local generatedRock = { depositKey = 'rock:generated', depositFingerprint = 'generated-fp' }
function generatedRock:setDepositKey (key, fingerprint)
  self.depositKey, self.depositFingerprint = key, fingerprint
end
local depositSystem = { children = { generatedRock }, depositState = {}, depositFingerprints = {} }
SaveGame.RestoreDeposits(depositSystem, {})
check('deposit restore preserves untouched generated fingerprints',
  generatedRock.depositFingerprint == 'generated-fp')
SaveGame.RestoreDeposits(depositSystem, {
  { key = 'rock:generated', remaining = 1, fingerprint = 'stale-fp' },
})
check('stale deposit overlays do not rewrite generated fingerprints',
  generatedRock.depositFingerprint == 'generated-fp')

if failures == 0 then
  print(string.format('npc save: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('npc save: %d/%d checks failed', failures, checks))
  os.exit(1)
end
