#!/usr/bin/env luajit
-- Phase 1 authoritative roster reconciliation and last-ship actor death.

local root = (io.popen('pwd'):read('*l') or '.') .. '/'
package.path = root .. 'script/?.lua;' .. package.path
function class (ctor)
  local cls = {}; cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end
function subclass (base, ctor)
  local cls = class(); cls.__index = cls
  return setmetatable(cls, { __index = base, __call = function (T, ...)
    local self = base(); setmetatable(self, T); if ctor then ctor(self, ...) end; return self
  end })
end
function insert (t, v) t[#t + 1] = v end
function remove (t, v)
  for i = 1, #t do if t[i] == v then t[i] = t[#t]; t[#t] = nil; return end end
end
function format (f, ...) return string.format(f, ...) end
local Event = dofile(root .. 'script/Game/Event.lua'); _G.Event = Event
local Entity = dofile(root .. 'script/Game/Entity.lua'); package.loaded['Game.Entity'] = Entity
package.loaded['Game.EconomyRegistry'] = { unregister = function () end }
for _, name in ipairs({ 'Actions', 'Assets', 'Children', 'Dispositions', 'Inventory', 'Owner' }) do
  dofile(root .. 'script/Game/Components/' .. name .. '.lua')
end
local Player = dofile(root .. 'script/Game/Entities/Player.lua')
local Registry = require('Game.NpcRegistry')
local Json = dofile(root .. 'script/Game/Json.lua'); package.loaded['Game.Json'] = Json
package.loaded['ffi.File'] = {}; package.loaded['ffi.Directory'] = {}; package.loaded['ffi.Tex2D'] = {}
local Credit = { getMass = function () return 0 end, getName = function () return 'Credit' end }
_G.Item = { Credit = Credit, All = function () return { Credit } end }; package.loaded['Game.Item'] = Item
_G.Vec3f = function (x, y, z) return { x = x, y = y, z = z } end
_G.Quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
local SaveGame = dofile(root .. 'script/Game/SaveGame.lua')
for _, name in ipairs({ 'Game.Entities.Dust', 'Game.Entities.Nebula', 'Game.Frustum',
  'Game.Content', 'Game.Production', 'Game.ShipArchetypes', 'Game.Communication',
  'Game.Directives', 'Game.NpcPopulation', 'Game.NameGen' }) do
  package.loaded[name] = {}
end
local ffi = require('ffi')
ffi.cdef [[
  typedef struct RigidBody { int dummy; } RigidBody;
  typedef struct Collision { void* body0; void* body1; int index; int count; } Collision;
]]
local System = dofile(root .. 'script/Game/Entities/System.lua')

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name)
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or '')) end
end

local function makeShip (id)
  local ship = Entity()
  ship.stableId = id
  ship.inventory, ship.inventoryCapacity, ship.inventoryFree = {}, 100, 100
  ship.pos, ship.vel, ship.rot = Vec3f(), Vec3f(), Quat(0, 0, 0, 1)
  ship.actions = {}
  function ship:hasInventory () return true end
  function ship:getInventory () return self.inventory end
  function ship:getInventoryCapacity () return self.inventoryCapacity end
  function ship:setInventoryCapacity (v) self.inventoryCapacity, self.inventoryFree = v, v end
  function ship:refreshInventory () end
  function ship:addItem (item, count) self.inventory[item] = count; return true end
  function ship:clearActions () self.actions = {} end
  function ship:getPos () return self.pos end
  function ship:setPos (v) self.pos = v end
  function ship:getVelocity () return self.vel end
  function ship:setVelocity (v) self.vel = v end
  function ship:getRot () return self.rot end
  function ship:setRot (v) self.rot = v end
  function ship:hasHealth () return false end
  function ship:hasCharge () return false end
  function ship:getParent () return nil end
  function ship:getName () return 'Saved Ship' end
  function ship:setName (v) self.name = v end
  function ship:getScale () return 4 end
  return ship
end

local system = setmetatable({ npcs = Registry.Create(), stableIndex = {}, dead = {}, deadFingerprints = {},
  npcPopulationActors = {} }, System)
function system:getNpc (id) return Registry.get(self.npcs, id) end
function system:isTombstoned (id) return self.dead[id] == true end
function system:markTombstone (id, fingerprint)
  self.dead[id] = true
  self.deadFingerprints[id] = fingerprint
end
function system:resolveStableId (id) return self.stableIndex[id] end
function system:unregisterLightEntity () end
function system:despawnNPCPopulation ()
  self.npcs = Registry.Create(); self.stableIndex = {}; self.npcPopulationActors = {}
end
function system:spawnAI (_, opts)
  local npc = Player({ isNpc = true, npcId = opts.npcId, profile = opts.profile,
    organization = opts.organization })
  npc.stableId = opts.npcId
  Registry.register(self.npcs, npc); self.stableIndex[opts.npcId] = npc
  npc:addItem(Credit, 100)
  return npc
end
function system:spawnShip (_, opts)
  local ship = makeShip(opts.shipId)
  ship:setOwner(self:getNpc(opts.ownerId))
  self.stableIndex[opts.shipId] = ship
  return ship
end

local extra = system:spawnAI(0, { npcId = 'npc:extra', profile = { role = 'fighter' } })
system.npcPopulationActors = { extra }
system.dead['npc:dead'] = true
local data = { npcs = {
  { id = 'npc:dead', profile = { role = 'fighter' }, assetCount = 1 },
  { id = 'npc:saved', profile = { role = 'industrial' }, organization = 'belt-miners',
    credits = 77, assetCount = 1, primaryShip = 'ship:saved', ships = {
      { id = 'ship:saved', kind = 'industrial', capacity = 100,
        pos = { x = 12, y = 34, z = 56 }, items = {} },
    } },
} }
-- SaveGame sets owner after spawn, so provide a no-owner path for this fixture.
function system:spawnShip (_, opts)
  self.lastSpawnOpts = opts
  local ship = makeShip(opts.shipId)
  self.stableIndex[opts.shipId] = ship
  return ship
end
SaveGame.RestoreNpcs(system, data)
check('saved roster removes fresh extras', system:getNpc('npc:extra') == nil)
check('tombstoned actor stays retired', system:getNpc('npc:dead') == nil)
check('saved actor is recreated by stable id', system:getNpc('npc:saved') ~= nil)
check('saved ship is recreated and restored', system:resolveStableId('ship:saved')
  and system:resolveStableId('ship:saved').pos.x == 12)
check('NPC restore supplies a temporary position instead of advancing world RNG',
  system.lastSpawnOpts and system.lastSpawnOpts.pos
  and system.lastSpawnOpts.pos.x == 0 and system.lastSpawnOpts.pos.y == 0
  and system.lastSpawnOpts.pos.z == 0)
check('saved primary ship is controlling', system:getNpc('npc:saved'):getControlling()
  == system:resolveStableId('ship:saved'))
check('restored roster is registered for sector cleanup', #system.npcPopulationActors == 1
  and system.npcPopulationActors[1] == system:getNpc('npc:saved'))

local actor = system:getNpc('npc:saved')
local ship = system:resolveStableId('ship:saved')
ship.destroyedOwner = actor
actor:removeAsset(ship) -- Explodable runs before the System death hook in production.
local deathOk, deathErr = pcall(function () system:recordDestroyed(ship) end)
check('last-ship death retires the actor', deathOk and system.dead['ship:saved']
  and system.dead['npc:saved'] and actor.deleted,
  string.format('ok=%s ship=%s actor=%s deleted=%s assets=%d owner=%s',
    tostring(deathOk), tostring(system.dead['ship:saved']), tostring(system.dead['npc:saved']),
    tostring(actor.deleted), #actor:getAssets(), tostring(ship.destroyedOwner) .. ' err=' .. tostring(deathErr)))

local Knowledge = require('Game.Knowledge')
local knowledgeShip = makeShip('ship:knowledge')
knowledgeShip.knowledge = Knowledge.Create()
Knowledge.Restore(knowledgeShip.knowledge, {
  { key = 'asteroidField:7:0:0:0:1', fingerprint = 'knowledge-fp', yieldIdentified = true },
})
local knowledgeRock = { stableId = 'asteroidField:7:0:0:0:1',
  depositFingerprint = 'knowledge-fp', hasYield = function () return true end }
system.sectorSeed = 7
system.stableIndex[knowledgeRock.stableId] = knowledgeRock
system:registerKnowledgeShip(knowledgeShip)
system:rebindKnowledge()
check('system rebinds saved knowledge for any registered ship',
  Knowledge.Known(knowledgeShip.knowledge, knowledgeRock))
system.stableIndex[knowledgeRock.stableId] = nil
system:rebindKnowledge()
check('stream unload drops object caches but retains durable knowledge',
  next(knowledgeShip.knownYields) == nil and knowledgeShip.knowledge.scans[knowledgeRock.stableId] ~= nil)
local rematerialized = { stableId = knowledgeRock.stableId,
  depositFingerprint = 'knowledge-fp', hasYield = function () return true end }
system.stableIndex[rematerialized.stableId] = rematerialized
system:rebindKnowledge()
check('system rebinds knowledge after stream rematerialization',
  Knowledge.Known(knowledgeShip.knowledge, rematerialized))
system:unregisterKnowledgeShip(knowledgeShip)
check('destroyed ships leave the knowledge rebind registry',
  not (system.knowledgeShips and system.knowledgeShips[knowledgeShip]))
system:registerKnowledgeShip(knowledgeShip)
local reparentOk = pcall(function () system:handleChildRemoved({ child = knowledgeShip }) end)
check('docking reparents keep ships in the knowledge registry', reparentOk
  and system.knowledgeShips[knowledgeShip])
knowledgeShip.deleted = true
local deleteOk = pcall(function () system:handleChildRemoved({ child = knowledgeShip }) end)
check('deleted ships leave the knowledge registry on removal', deleteOk
  and not system.knowledgeShips[knowledgeShip])
local destroyedRock = { stableId = 'rock:fingerprint', generationFingerprint = 'physical-fp',
  depositFingerprint = 'deposit-fp' }
system:recordDestroyed(destroyedRock)
check('asteroid tombstones use the deposit-aware fingerprint',
  system.deadFingerprints['rock:fingerprint'] == 'deposit-fp')

SaveGame.RestoreNpcs(system, { npcs = {
  { id = '12345', profile = { role = 'fighter' }, assetCount = 1 },
} })
local legacyActor = system:getNpc('12345')
local legacyShip = legacyActor and legacyActor:getControlling()
check('legacy actor fallback ship ids cannot collide with actor ids', legacyActor and legacyShip
  and legacyShip.stableId == 'ship:12345' and system.stableIndex['12345'] == legacyActor
  and system.stableIndex['ship:12345'] == legacyShip)
local dock = { hasDockable = function () return true end, addDocked = function (_, ship)
  system.stableIndex[ship.stableId] = nil -- docking reparents out of the direct-child index
end }
system.stableIndex['place:dock'] = dock
SaveGame.RestoreNpcs(system, { npcs = {
  { id = 'npc:docked', profile = { role = 'fighter' }, primaryShip = 'ship:docked', ships = {
    { id = 'ship:docked', kind = 'fighter', dockedAt = 'place:dock' },
  } },
} })
local dockedActor = system:getNpc('npc:docked')
check('docked saved ships remain their actor controlling ship', dockedActor
  and dockedActor:getControlling() and dockedActor:getControlling().stableId == 'ship:docked')
check('module restore rejects malformed slot entries',
  not System.ValidateModuleEntry(42) and not System.ValidateModuleEntry({ type = 'Turret', index = 0 })
  and not System.ValidateModuleEntry({ type = 'Turret', index = 1.5 })
  and System.ValidateModuleEntry({ type = 'Turret', index = 1 }))
local Tombstones = require('Game.Tombstones')
local reservedStore = Tombstones.Create()
local reservedSystem = setmetatable({ tombstones = reservedStore }, System)
reservedSystem:restoreTombstones({ 'ship:player', { key = 'rock:ok', fingerprint = 'fp' } })
check('reserved player ship tombstones are rejected on restore',
  not reservedStore:Has('ship:player') and reservedStore:Has('rock:ok'))
check('reserved player ship cannot be tombstoned at runtime',
  not reservedSystem:markTombstone('ship:player') and not reservedStore:Has('ship:player'))

local traveller = system:spawnAI(0, { npcId = 'npc:traveller', profile = { role = 'industrial' } })
local travellerShip = system:spawnShip('industrial', { shipId = 'ship:traveller' })
travellerShip:setOwner(traveller)
traveller:setControlling(travellerShip)
traveller:addItem(Credit, 777)
local checkpointSrc = { stableId = 'asteroidField:7:0:0:0:1', depositFingerprint = 'ore-fp',
  hasYield = function () return true end }
local checkpointDst = { stableId = 'place:destination' }
travellerShip.job = { src = checkpointSrc, dst = checkpointDst, itemName = 'Ore',
  getKind = function () return 'mine' end, getName = function () return 'Mine' end }
travellerShip.actions = { travellerShip.job }
travellerShip.jobState = 2
travellerShip.parent = system
system.npcPopulationActors = { traveller }
system.npcTransit, system.sectorIndex = {}, 0
system.getTime = function () return 25 end
system.registerCommunicator = function () end
system.addPlayer = function () end
system.addChild = function (self, child) child.parent = self end
system.removeChild = function (self, child, keepOwner)
  if not keepOwner and child.getOwner then
    local owner = child:getOwner()
    if owner then owner:removeAsset(child) end
  end
  child.parent = nil
end
traveller.getParent = function (self) return self.parent end
travellerShip.getParent = function (self) return self.parent end
local gate = { getPartnerSector = function () return 2 end,
  getPartnerPos = function () return { x = 9000, y = 0, z = 0 } end,
  getName = function () return 'Gate to sector 2' end }
travellerShip.npcServiceNeed = 'shipyard'
local began = system:beginNpcTransit(traveller, travellerShip, gate, 'station-service')
check('gate approach detaches NPC into persistent sector transit', began
  and traveller.parent == nil and travellerShip.parent == nil and not traveller.deleted
  and not travellerShip.deleted and #system.npcTransit == 1)
check('transit preserves actor ownership of the ship', travellerShip:getOwner() == traveller
  and #traveller:getAssets() == 1)
check('transit checkpoints the committed job before detaching',
  traveller:getItemCount(Credit) == 877 and travellerShip.pendingJob
  and travellerShip.pendingJob.kind == 'mine' and travellerShip.pendingJob.state == 2,
  string.format('credits=%s actions=%s pending=%s', tostring(traveller:getItemCount(Credit)),
    tostring(#travellerShip.actions), tostring(travellerShip.pendingJob)))
system.stableIndex[checkpointSrc.stableId], system.stableIndex[checkpointDst.stableId] = checkpointSrc, checkpointDst
system.sectorIndex = 2
local restoredCount = system:restoreNpcTransit(2)
check('destination entry restores the same NPC ship and job checkpoint', restoredCount == 1
  and traveller.parent == system and travellerShip.parent == system
  and system:getNpc('npc:traveller') == traveller and traveller:getControlling() == travellerShip
  and travellerShip.pendingJob and travellerShip.pendingJob.kind == 'mine'
  and #travellerShip.actions == 0 and traveller.transit == nil
  and traveller.npcNextTravelAt == system:getTime())
check('transit actor is excluded from duplicate roster spawning',
  system.npcPopulationActors[1] == traveller)
system.sectorIndex = 0
SaveGame.RestoreNpcs(system, { npcs = {
  { id = 'npc:saved-transit', profile = { role = 'industrial' }, credits = 77,
    primaryShip = 'ship:saved-transit', transit = { destination = 3, fromSector = 0,
      reason = 'mission', departedAt = 5, arrivalPos = { x = 1, y = 2, z = 3 } },
    ships = { { id = 'ship:saved-transit', kind = 'industrial' } } },
} })
local savedTransit = system:getNpc('npc:saved-transit')
check('save restore places travelling NPCs back into transit', savedTransit
  and savedTransit.parent == nil and savedTransit.transit
  and savedTransit.transit.destination == 3 and #system.npcTransit == 1)
check('transit actors are not left in the active despawn roster',
  not system.npcPopulationActors[1] or system.npcPopulationActors[1] ~= savedTransit)
local held = system:spawnAI(0, { npcId = 'npc:held', profile = { role = 'freighter' } })
local heldShip = system:spawnShip('freighter', { shipId = 'ship:held' })
heldShip.pos = { x = 1, y = 2, z = 3 }
heldShip:setOwner(held); held:setControlling(heldShip)
system.npcPopulationActors = { held }
system.sectorIndex = 2
local heldCount = system:holdNPCPopulation(2)
check('sector changes stream local NPCs out instead of deleting them', heldCount == 1
  and held.parent == nil and heldShip.parent == nil and held.transit.reason == 'sector-hold',
  string.format('count=%s parent=%s shipParent=%s transit=%s', tostring(heldCount),
    tostring(held.parent), tostring(heldShip.parent), tostring(held.transit)))
system.sectorIndex = 0
system:restoreNpcTransit(2)
check('returning to a sector restores held NPC identity and wealth',
  held.parent == system and heldShip.parent == system and system:getNpc('npc:held') == held
  and held.transit == nil)

if failures == 0 then
  print(string.format('phase1 roster: %d checks passed', checks)); os.exit(0)
else
  print(string.format('phase1 roster: %d/%d checks failed', failures, checks)); os.exit(1)
end
