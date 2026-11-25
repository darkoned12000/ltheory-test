#!/usr/bin/env luajit
-- NPC resource-discovery loop: approach unscanned rocks, run the scanner, store
-- discoveries, and only then consider mining jobs from known yields.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_scanning%.lua$', '')
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
function format (f, ...) return string.format(f, ...) end
table.clear = table.clear or function (t) for k in pairs(t) do t[k] = nil end end
_G.Profiler = { Begin = function () end, End = function () end }
_G.Config = { debug = { damageLog = false }, game = { scanRange = 2000 } }
_G.max, _G.min = math.max, math.min

local Event = dofile(root .. '/script/Game/Event.lua')
_G.Event = Event
local Entity = dofile(root .. '/script/Game/Entity.lua')
package.loaded['Game.Entity'] = Entity
for _, name in ipairs({ 'Actions', 'Assets', 'Children', 'Dispositions', 'Health', 'Inventory', 'Owner' }) do
  dofile(root .. '/script/Game/Components/' .. name .. '.lua')
end
local Player = dofile(root .. '/script/Game/Entities/Player.lua')
local Action = class(function () end)
function Action:onStart () end
function Action:onStop () end
function Action:onUpdateActive () end
function Action:onUpdatePassive () end
function Action:flyToward () end
package.loaded['Game.Action'] = Action
package.loaded['Game.Seed'] = { rng = function ()
  return { managed = function (self) return self end,
    choose = function (self, list) return list[2] end,
    getUniformRange = function () return 7 end }
end }
package.loaded['Game.Entities.ScanEffect'] = function (source, target)
  local effect = Entity()
  effect.source, effect.target, effect.active, effect.result = source, target, true, nil
  return effect
end
local MoveTo = dofile(root .. '/script/Game/Actions/MoveTo.lua')
local Scan = dofile(root .. '/script/Game/Actions/Scan.lua')
_G.requireAll = function ()
  return { MoveTo = function (target, range) return MoveTo(target, range) end,
    Scan = function (target, duration) return Scan(target, duration) end,
    Attack = function () return {} end, Flee = function () return {} end }
end
local Think = dofile(root .. '/script/Game/Actions/Think.lua')

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. detail) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or '')) end
end

local empty = { id = 1, isAsteroid = true, hasYield = function () return false end,
  isDestroyed = function () return false end, getName = function () return 'Empty' end }
local rich = { id = 2, isAsteroid = true, hasYield = function () return true end,
  getYield = function () return { item = { getName = function () return 'Iron Ore' end } } end,
  isDestroyed = function () return false end, getName = function () return 'Rich' end }
local world = {
  now = 0, asteroids = { empty, rich }, jobs = {},
  hasEconomy = function () return true end,
  getEconomy = function (self) return { jobs = self.jobs } end,
  getTime = function (self) return self.now end,
  findScanTarget = function (self, scanner)
    for _, rock in ipairs(self.asteroids) do
      if not (scanner.scannedAsteroids or {})[rock] then return rock end
    end
    return nil
  end,
}
local npc = Player({ isNpc = true, npcId = 'npc:scan', organization = 'belt-miners' })
local ship = Entity()
ship:addActions()
ship:addChildren()
ship:addHealth(100, 0)
npc:addAsset(ship)
function ship:getRoot () return world end
function ship:getPos () return { x = 0, y = 0, z = 0 } end
function ship:getForward () return { x = 0, y = 0, z = -1 } end
function ship:getUp () return { x = 0, y = 1, z = 0 } end
function ship:getRadius () return 10 end
ship.socketRangeMin = 1000

local think = Think()
think:onUpdateActive(npc, 0)
check('idle miner approaches an unscanned rock', #ship.actions == 2
  and ship.actions[1]:getName():sub(1, 4) == 'Scan'
  and ship.actions[2]:getName():sub(1, 6) == 'MoveTo')
ship:popAction()
local scan = ship:getCurrentAction()
scan:onUpdateActive(ship, 7)
check('empty scan is remembered as failure', scan.result == false and ship.scannedAsteroids[empty])
scan:onUpdateActive(ship, 1)
think:onUpdateActive(npc, 0)
check('miner advances to the next unscanned rock', #ship.actions == 2
  and ship.actions[1].target == rich)
ship:popAction()
scan = ship:getCurrentAction()
scan:onUpdateActive(ship, 7)
check('rich scan records a known yield', scan.result == true and ship.knownYields[rich])
scan:onUpdateActive(ship, 1)

local function job (key, source)
  return {
    src = source,
    getKey = function () return key end,
    getKind = function () return 'mine' end,
    getPayout = function () return 100 end,
    getTravelTime = function () return 10 end,
    isKnown = function (self, asset) return asset.knownYields[self.src] == true end,
    clone = function (self) return job(key, source) end,
    onStart = function () end,
    onStop = function () end,
  }
end
world.jobs = { job('mine:empty', empty), job('mine:rich', rich) }
think:onUpdateActive(npc, 0)
check('mining policy ignores undiscovered yields', ship:getCurrentAction():getKey() == 'mine:rich')
local ScannerDB = require('Game.ScannerDB')
local db = npc:getScannerDB()
check('scans populate the pilot scanner database', ScannerDB.Count(db) == 2)
check('scanner database retains resolved yield data',
  ScannerDB.Get(db, 'entity:2').yieldItem == 'Iron Ore' and #ScannerDB.Get(db, 'entity:2').logs == 1)

if failures == 0 then
  print(string.format('npc scanning: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('npc scanning: %d/%d checks failed', failures, checks))
  os.exit(1)
end
