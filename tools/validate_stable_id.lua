#!/usr/bin/env luajit
-- Stable structural identity contract. Runs the real helper and identity APIs
-- without GL/Engine; a runtime Entity.id must never become a persistent key.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_stable_id%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. root .. '/libphx/script/?.lua;' .. package.path

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

local function finish ()
  if failures == 0 then
    print(string.format('stable id: %d checks passed', checks))
    os.exit(0)
  end
  print(string.format('stable id: %d/%d checks failed', failures, checks))
  os.exit(1)
end

local loaded, StableId = pcall(require, 'Game.StableId')
check('StableId module loads', loaded, tostring(StableId))
if not loaded then finish() end

-- Minimal engine globals used by the real Entity/component classes.
function class (ctor)
  local cls = {}
  cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = setmetatable({}, T)
    if ctor then ctor(self, ...) end
    return self
  end })
end

function subclass (base, ctor)
  local cls = {}
  cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = base()
    setmetatable(self, T)
    if ctor then ctor(self, ...) end
    return self
  end, __index = base })
end

function insert (t, v) t[#t + 1] = v end
function remove (t, v)
  for i = 1, #t do
    if t[i] == v then t[i] = t[#t]; t[#t] = nil; return end
  end
end

local Event = dofile(root .. '/script/Game/Event.lua')
_G.Event = Event
local Entity = dofile(root .. '/script/Game/Entity.lua')
package.loaded['Game.Entity'] = Entity

dofile(root .. '/script/Game/Components/RegistryInfo.lua')
dofile(root .. '/script/Game/Components/Yield.lua')
dofile(root .. '/script/Game/Components/Actions.lua')
dofile(root .. '/script/Game/Components/Assets.lua')
dofile(root .. '/script/Game/Components/Dispositions.lua')
dofile(root .. '/script/Game/Components/Inventory.lua')
local Player = dofile(root .. '/script/Game/Entities/Player.lua')

local Region = require('Game.Region').Region
local SectorGraph = require('Game.SectorGraph')

check('nil entity has no stable id', StableId.For(nil, 'entity') == nil)
check('explicit stable id wins over registry metadata',
  StableId.For({ stableId = 'place:explicit', registryInfo = { id = 'ship:other' } }) == 'place:explicit')
local moduleOk, moduleId = pcall(function () return StableId.Module('ship:1', 'Thruster', 1) end)
check('module id is derived from ship, type, and slot', moduleOk
  and moduleId == 'ship:1:module:Thruster:1')
check('module id distinguishes type and slot', moduleOk
  and StableId.Module('ship:1', 'Turret', 1) ~= moduleId
  and StableId.Module('ship:1', 'Thruster', 2) ~= moduleId)
check('non-entity value has no stable id', StableId.For(17, 'entity') == nil)

local runtimeOnly = Entity()
check('runtime entity id is rejected', StableId.For(runtimeOnly) == nil)
check('fallback prefix cannot launder a runtime entity id',
  StableId.For(runtimeOnly, 'entity') == nil)
local opaque = newproxy(true)
local opaqueOk, opaqueId = pcall(StableId.For, opaque, 'entity')
check('opaque runtime pointer is rejected safely', opaqueOk and opaqueId == nil)

local registered = Entity()
registered:addRegistryInfo({ id = 'ship:9001:2' })
check('real RegistryInfo id is returned unchanged',
  StableId.For(registered) == 'ship:9001:2')

local item = { getName = function () return 'Iron Ore' end, getMass = function () return 4 end }
local deposit = Entity()
deposit:addYield(item, 1, 25)
deposit:setDepositKey('asteroids:12345:0:0:0:1')
check('real Yield depositKey is returned unchanged',
  StableId.For(deposit) == 'asteroids:12345:0:0:0:1')

local npc = Player({ isNpc = true, npcId = '12345:3' })
check('real NPC id is returned unchanged', StableId.For(npc) == '12345:3')
local human = Player()
check('human actor fallback is not a persistent identity',
  StableId.For(human) == nil and human:getActorId() == 'player')

local both = Entity()
both:addRegistryInfo({ id = 'ship:77:1' })
both:addYield(item, 1, 10)
both:setDepositKey('deposit:77')
check('registry id takes precedence over deposit key',
  StableId.For(both) == 'ship:77:1')

local npcDeposit = Player({ isNpc = true, npcId = '12345:4' })
npcDeposit:addYield(item, 1, 10)
npcDeposit:setDepositKey('deposit:78')
check('deposit key takes precedence over NPC id',
  StableId.For(npcDeposit) == 'deposit:78')

local emptyRegistry = Entity()
emptyRegistry:addRegistryInfo({ id = '' })
emptyRegistry:addYield(item, 1, 10)
emptyRegistry:setDepositKey('deposit:79')
check('empty registry id falls through to deposit key',
  StableId.For(emptyRegistry) == 'deposit:79')

local malformedRegistry = Entity()
malformedRegistry:addRegistryInfo({ id = {} })
malformedRegistry:addYield(item, 1, 10)
malformedRegistry:setDepositKey('deposit:80')
check('non-scalar registry id is rejected',
  StableId.For(malformedRegistry) == 'deposit:80')

check('identity fields must be callable methods',
  StableId.For({ getRegistryId = 'not a function', depositKey = 'deposit:81' }) == 'deposit:81')

check('explicit sector id is namespaced', StableId.For({ sectorId = 0 }) == 'sector:0')
check('sector id getter is supported',
  StableId.For({ getSectorId = function () return 12 end }) == 'sector:12')
check('explicit region id is namespaced',
  StableId.For({ getRegionId = function () return 7 end }) == 'region:7')
check('known structural kind wins over fallback prefix',
  StableId.For({ getRegionId = function () return 7 end }, 'location') == 'region:7')
check('fallback prefix namespaces a bare structural record',
  StableId.For({ seed = 123, index = 4 }, 'location') == 'location:123:4')
check('explicit place id is namespaced', StableId.For({ placeId = 'dock-a' }) == 'place:dock-a')
check('most specific place identity wins',
  StableId.For({ sectorId = 1, regionId = 2, placeId = 3 }) == 'place:3')
check('split sector identity includes seed and index',
  StableId.For({ sectorSeed = 12345, sectorIndex = 0 }) == 'sector:12345:0')

local region = Region.place(12345, { x = 0, y = 0, z = 0 }, 1000)[1]
check('real region record gets a structural id',
  StableId.For(region, 'region') == 'region:12345:1')
local sector = SectorGraph.layout(12345, 60000)[1]
check('real sector record gets a structural id',
  StableId.For(sector, 'sector') == 'sector:12345:0')
check('index-only structural record is supported',
  StableId.For({ index = 4 }, 'place') == 'place:4')
check('bare record needs a structural prefix',
  StableId.For({ seed = 12345, index = 1 }) == nil)

check('empty structural ids are rejected',
  StableId.For({ sectorId = '', regionId = {}, placeId = '   ' }) == nil)
check('blank fallback prefix uses the structural kind',
  StableId.For({ sectorId = 5 }, '   ') == 'sector:5')

finish()
