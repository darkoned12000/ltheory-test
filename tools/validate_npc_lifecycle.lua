#!/usr/bin/env luajit
-- NPC System lifecycle validator. Uses production Entity/Player/System/Ship
-- composition and components; stubs only physics/GPU/audio boundaries.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_lifecycle%.lua$', '')
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
  for i = 1, #t do
    if t[i] == v then t[i] = t[#t]; t[#t] = nil; return end
  end
end
function format (f, ...) return string.format(f, ...) end
function printf (...) end
local function contains (t, v)
  for i = 1, #t do if t[i] == v then return true end end
  return false
end
_G.Profiler = { Begin = function () end, End = function () end }
_G.Config = { debug = { damageLog = false } }
_G.max = math.max
_G.min = math.min
table.clear = table.clear or function (t)
  for k in pairs(t) do t[k] = nil end
end

local ffi = require('ffi')
ffi.cdef [[
  typedef struct RigidBody { int dummy; } RigidBody;
  typedef struct Collision { void* body0; void* body1; int index; int count; } Collision;
]]

local Event = dofile(root .. '/script/Game/Event.lua')
_G.Event = Event
local Entity = dofile(root .. '/script/Game/Entity.lua')
package.loaded['Game.Entity'] = Entity

_G.requireAll = function (name)
  if name == 'Game.Jobs' then return {} end
  return {}
end
package.loaded['Game.Entities.GPUParticles'] = { explode = function () end }

-- Real components used by the fixtures.
for _, name in ipairs({
  'Actions', 'Assets', 'Children', 'Dispositions', 'Economy', 'Explodable',
  'Health', 'Inventory', 'Name', 'Owner', 'Target',
}) do
  dofile(root .. '/script/Game/Components/' .. name .. '.lua')
end

package.loaded['Game.Entities.Dust'] = {}
package.loaded['Game.Entities.Nebula'] = {}
package.loaded['Game.Frustum'] = {}
package.loaded['Game.Content'] = {}
package.loaded['Game.Production'] = {}
package.loaded['Game.Material'] = {}

local Credit = { getMass = function () return 0 end, getName = function () return 'Credit' end }
_G.Item = { Credit = Credit }
package.loaded['Game.Item'] = _G.Item

local Player = dofile(root .. '/script/Game/Entities/Player.lua')
package.loaded['Game.Entities.Player'] = Player
local Ship = dofile(root .. '/script/Game/Entities/Ship.lua')
package.loaded['Game.Entities.Ship'] = Ship

local NameGen = { npcShipName = function () return 'Test NPC' end }
_G.NameGen = NameGen
package.loaded['Game.NameGen'] = NameGen
local Think = { onStart = function () end, onStop = function () end,
  onUpdatePassive = function () end, onUpdateActive = function () end,
  getName = function () return 'Think' end }
_G.Actions = { Think = function () return Think end }
package.loaded['Game.Actions'] = _G.Actions

_G.Entities = { Player = Player }
_G.EconomyRegistry = { unregister = function () end }

local System = dofile(root .. '/script/Game/Entities/System.lua')
local Registry = require('Game.NpcRegistry')
local Tombstones = require('Game.Tombstones')
local Directives = require('Game.Directives')
local Communication = require('Game.Communication')
local Population = require('Game.NpcPopulation')

local Vec = {}
Vec.__index = Vec
local function vec (x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, Vec) end
_G.Vec3f = vec
function Vec.__sub (a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
function Vec.__add (a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
function Vec:scale (s) return vec(self.x * s, self.y * s, self.z * s) end
function Vec:length () return math.sqrt(self.x*self.x + self.y*self.y + self.z*self.z) end
function Vec:distance (b) return (self - b):length() end

local function makeShip (pos)
  local e = setmetatable({}, Ship)
  e.id = 1
  e.handlers = {}
  e.pos = pos or vec()
  e.body = {}
  e:addActions()
  e:addHealth(100, 0)
  e:addExplodable()
  e:addInventory(100)
  e:addDispositions()
  function e:getPos () return self.pos end
  function e:setPos (p) self.pos = p end
  function e:getVelocity () return vec() end
  function e:getRadius () return 10 end
  function e:getScale () return 1 end
  return e
end

local function makeSystem (seed)
  local s = setmetatable({}, System)
  s.id = 1
  s.handlers = {}
  s:addChildren()
  s.players = {}
  s.npcs = Registry.Create()
  s.directives = Directives.Create()
  s.comms = Communication.Create()
  s.npcSerial = 0
  s.seed = seed or 1234
  s.time = 0
  s.tombstones = Tombstones.Create()
  s.economy = { parent = s }
  s.hasEconomy = function () return true end
  s.flows = {}
  s.physics = {
    update = function () end,
    getNextCollision = function () return false end,
  }
  s.rng = { get31 = function () return 77 end }
  s.spawnedKinds = {}
  s.spawnShip = function (self, kind)
    self.spawnedKinds[#self.spawnedKinds + 1] = kind
    local e = makeShip()
    self:addChild(e)
    return e
  end
  return s
end

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

local sys = makeSystem()
local brain = sys:spawnAI(2)
check('spawnAI creates an explicit NPC brain', brain:isNpc() == true)
check('NPC has a stable seeded id', brain:getNpcId() == '1234:1')
check('NPC joins the default cooperative organization', brain:getOrganization() == 'belt-miners')
check('NPC brain is parented to system', brain:getParent() == sys)
check('NPC brain is in players list', sys.players[1] == brain)
check('NPC registry contains one actor', Registry.count(sys.npcs) == 1)
check('registry lookup returns brain', Registry.get(sys.npcs, brain:getNpcId()) == brain)
check('NPC is registered for communication', Communication.count(sys.comms) == 1)
check('NPC owns two ships', #brain:getAssets() == 2)
check('NPC uses the shared System economy', brain.economy == nil and sys.economy.parent == sys)
check('NPC starts with credit item', brain:getItemCount(Credit) > 0)
check('NPC has Think action', brain:getCurrentAction() ~= nil)

local brain2 = sys:spawnAI(1)
check('second spawnAI gets a distinct id', brain2:getNpcId() == '1234:2')
check('registry contains two actors', Registry.count(sys.npcs) == 2)
check('both NPCs are registered for communication', Communication.count(sys.comms) == 2)

local human = Player()
local humanShip = makeShip(vec(0, 0, 0))
humanShip:setOwner(human)
sys:addChild(humanShip)
local all = sys:npcTargets(nil)
local onlyNpc = true
for _, e in ipairs(all) do
  if not (e:getOwner() and e:getOwner():isNpc()) then onlyNpc = false end
end
check('npcTargets excludes human-owned ships', onlyNpc and #all == 3)
check('npcTargets excludes querying ship', #sys:npcTargets(humanShip) == 3)

local nearest = makeShip(vec(5, 0, 0))
nearest:setOwner(brain)
sys:addChild(nearest)
humanShip:targetNearestNpc()
check('nearest NPC targeting ignores human ship', humanShip:getTarget() ~= humanShip)
local cycle = humanShip:getTarget()
humanShip:cycleNpcTarget()
check('cycle changes to another valid target', humanShip:getTarget() ~= cycle)

local genericOwner = Entity()
genericOwner:addAssets()
local genericShip = makeShip(vec(15, 0, 0))
genericShip:setOwner(genericOwner)
sys:addChild(genericShip)
local targetQueryOk, targetQuery = pcall(function () return sys:npcTargets(nil) end)
check('non-Player owners are ignored safely', targetQueryOk and not contains(targetQuery, genericShip))

local dead = brain:getAssets()[1]
dead:damage(1000, humanShip)
check('destroyed ship detaches from owner immediately', dead:getOwner() == nil)
check('destroyed ship is excluded from targets', not contains(sys:npcTargets(nil), dead))

local deleted = brain:getAssets()[1]
deleted:delete()
check('deleted ship detaches from owner', deleted:getOwner() == nil)

local lockTarget = makeShip(vec(20, 0, 0))
lockTarget:setOwner(brain2)
sys:addChild(lockTarget)
humanShip:setTarget(lockTarget)
lockTarget:damage(1000, humanShip)
check('target lock clears immediately on destruction', humanShip:getTarget() == nil)

local removable = makeShip(vec(30, 0, 0))
removable:setOwner(brain2)
sys:addChild(removable)
sys:removeChild(removable)
sys:broadcast(Event.Update(0))
check('live world removal detaches owner assets', removable:getOwner() == nil)

local station = Entity()
station:addChildren()
sys:addChild(station)
local docked = makeShip(vec(40, 0, 0))
docked:setOwner(brain2)
sys:addChild(docked)
station:addChild(docked)
sys:broadcast(Event.Update(0))
check('docking reparenting preserves ownership', docked:getOwner() == brain2 and docked:getParent() == station)
docked:delete()
sys:sweepDestroyed()
check('deleted docked ship is swept from nested parent', docked:getParent() == nil)
check('deleted docked ship detaches ownership', docked:getOwner() == nil)

local defenseTarget = makeShip(vec(50, 0, 0))
sys:addChild(defenseTarget)
local directiveOk, directive = pcall(function ()
  return sys:createDefendDirective(brain2, defenseTarget, { capacity = 2, expiresAt = 100 })
end)
check('System creates shared defense directives', directiveOk and directive ~= nil)
defenseTarget:damage(1000, humanShip)
sys:update(0)
check('System update fails directives whose target died', directiveOk and directive.status == 'failed')

local scanner = brain2:getAssets()[1]
scanner.scannedAsteroids = {}
local scanRockA = makeShip(vec(100, 0, 0))
scanRockA.isAsteroid = true
sys:addChild(scanRockA)
local scanRockB = makeShip(vec(200, 0, 0))
scanRockB.isAsteroid = true
sys:addChild(scanRockB)
local findOk, foundRock = pcall(function () return sys:findScanTarget(scanner) end)
check('System finds an unscanned asteroid', findOk and foundRock == scanRockA)
scanner.scannedAsteroids[scanRockA] = true
local skipOk, skipRock = pcall(function () return sys:findScanTarget(scanner) end)
check('System skips already scanned asteroids', skipOk and skipRock == scanRockB)

local brainTicks, systemTicks = 0, 0
brain:register(Event.Update, function () brainTicks = brainTicks + 1 end)
sys:register(Event.Update, function () systemTicks = systemTicks + 1 end)
sys:update(0.5)
check('NPC brain receives one update per frame', brainTicks == 1,
  string.format('ticks=%d', brainTicks))
check('System receives one update per frame', systemTicks == 1,
  string.format('ticks=%d', systemTicks))
local timeOk, now = pcall(function () return sys:getTime() end)
check('System advances one simulation clock', timeOk and now == 0.5, tostring(now))
check('communication uses the System clock', sys.comms.time == 0.5)

brain:delete()
sys:sweepDestroyed()
sys:send(Event.Broadcast(Event.Update(0)))
check('deleted brain leaves players list', not contains(sys.players, brain))
check('deleted brain leaves NPC registry', Registry.get(sys.npcs, brain:getNpcId()) == nil)
check('deleted brain leaves communication registry', Communication.count(sys.comms) == 1)
check('other NPC survives brain removal', Registry.get(sys.npcs, brain2:getNpcId()) == brain2)

local populated = sys:spawnNPCPopulation(1234, { center = vec(0, 0, 0), radius = 5000 })
local roleCounts, shipTypes = {}, {}
for _, npc in ipairs(populated) do
  local ship = npc:getAssets()[1]
  roleCounts[ship.npcRole] = (roleCounts[ship.npcRole] or 0) + 1
  check('population ship has one explicit role owner', ship:getOwner() == npc)
end
for _, kind in ipairs(sys.spawnedKinds) do shipTypes[kind] = true end
check('population spawns the planned number of actors', #populated == 8)
for role, wanted in pairs(Population.DefaultMix) do
  check('population count matches role mix: ' .. role, roleCounts[role] == wanted)
end
check('population uses multiple procedural ship types', shipTypes.fighter and shipTypes.capital)
check('population positions ships near the requested center',
  (function ()
    for _, npc in ipairs(populated) do
      if npc:getAssets()[1]:getPos():length() > 5000 then return false end
    end
    return true
  end)())
local firstIds = {}
for _, npc in ipairs(populated) do firstIds[#firstIds + 1] = npc:getNpcId() end
local replaced = sys:spawnNPCPopulation(1234, { center = vec(0, 0, 0), radius = 5000 })
check('repopulation reconciles instead of duplicating actors', #replaced == 8
  and Registry.count(sys.npcs) == 9 and #sys.players == 9)
local sameIds = #replaced == #firstIds
for i = 1, math.min(#replaced, #firstIds) do
  if replaced[i]:getNpcId() ~= firstIds[i] then sameIds = false end
end
check('repopulation uses the same deterministic actor ids', sameIds)
local despawnOk, removed = pcall(function () return sys:despawnNPCPopulation() end)
check('population can be explicitly despawned', despawnOk and removed == 8)
check('despawn clears actor and communication registries', Registry.count(sys.npcs) == 1
  and Communication.count(sys.comms) == 1)

local destroyedShip = makeShip()
destroyedShip.stableId = 'ship:destroyed'
sys:addChild(destroyedShip)
destroyedShip.health = 0
sys:sweepDestroyed()
check('actual ship death records a tombstone', sys:isTombstoned('ship:destroyed')
  and destroyedShip:getParent() == nil)
local unloadedShip = makeShip()
unloadedShip.stableId = 'ship:unloaded'
sys:addChild(unloadedShip)
unloadedShip:delete()
sys:sweepDestroyed()
check('ordinary unload does not record a tombstone', not sys:isTombstoned('ship:unloaded'))

if failures == 0 then
  print(string.format('npc lifecycle: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('npc lifecycle: %d/%d checks failed', failures, checks))
  os.exit(1)
end
