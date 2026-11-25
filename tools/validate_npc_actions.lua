#!/usr/bin/env luajit
-- NPC actions must use real propulsion and dt-invariant work even if the old
-- instantJobs debug flag is left enabled.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_actions%.lua$', '')
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
function format (f, ...) return string.format(f, ...) end
_G.min = math.min
_G.Config = {
  debug = { instantJobs = true, jobSpeed = 10000 },
  game = {
    miningDurations = { ['Test Ore'] = 5, ['Rare Ore'] = 15 },
    miningRange = 250, miningSpeedTolerance = 3, miningAlignment = 0.85,
    miningAccuracyDrain = 1,
  },
}

local Action = class(function () end)
function Action:onStart () end
function Action:onStop () end
function Action:onUpdateActive () end
function Action:onUpdatePassive () end
function Action:flyToward (e, pos, forward, up)
  e.steeredTo = pos
  e.steeredForward = forward
  e.steeredUp = up
end
package.loaded['Game.Action'] = Action
package.loaded['Game.Seed'] = { rng = function ()
  return { managed = function (self) return self end,
    getUniform = function () return 0.5 end,
    getSphere = function () return { x = 0.2, y = 0.4, z = -0.8 } end }
end }
local sparksEmitted = 0
local emittedRecords = {}
package.loaded['Game.Entities.GPUParticles'] = {
  newRecord = function () return {} end,
  emit = function (record)
    sparksEmitted = sparksEmitted + 1
    emittedRecords[#emittedRecords + 1] = record
  end,
}
package.loaded['Game.Entities.MiningBeam'] = function (source, target)
  return { source = source, target = target, active = true, accuracy = 1,
    setAccuracy = function (self, value) self.accuracy = value end }
end

local Vec = {}
Vec.__index = Vec
local function vec (x, y, z) return setmetatable({ x = x, y = y, z = z }, Vec) end
function Vec.__sub (a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
function Vec.__unm (a) return vec(-a.x, -a.y, -a.z) end
function Vec.__add (a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
function Vec:length () return math.sqrt(self.x*self.x + self.y*self.y + self.z*self.z) end
function Vec:normalize ()
  local len = self:length()
  if len < 1e-6 then return vec(0, 0, 0) end
  return vec(self.x / len, self.y / len, self.z / len)
end
function Vec:scale (s) return vec(self.x * s, self.y * s, self.z * s) end
function Vec:dot (b) return self.x*b.x + self.y*b.y + self.z*b.z end
function Vec:muls (s) return self:scale(s) end

local MoveTo = dofile(root .. '/script/Game/Actions/MoveTo.lua')
local DockAt = dofile(root .. '/script/Game/Actions/DockAt.lua')
local MineAt = dofile(root .. '/script/Game/Actions/MineAt.lua')

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

local target = {
  getName = function () return 'Rock' end,
  getPos = function () return vec(1000, 0, 0) end,
  getRadius = function () return 10 end,
  getForward = function () return vec(0, 0, -1) end,
  getUp = function () return vec(0, 1, 0) end,
  addDocked = function () end,
}
local ship = {
  teleports = 0,
  getPos = function () return vec(0, 0, 0) end,
  setPos = function (self) self.teleports = self.teleports + 1 end,
  getMinDistance = function () return 1000 end,
  getRadius = function () return 10 end,
  getForward = function () return vec(1, 0, 0) end,
  getUp = function () return vec(0, 1, 0) end,
}
MoveTo(target, 100):onUpdateActive(ship, 1 / 60)
check('MoveTo uses propulsion instead of teleporting', ship.teleports == 0 and ship.steeredTo ~= nil)
ship.teleports = 0
ship.steeredTo = nil
DockAt(target):onUpdateActive(ship, 1 / 60)
check('DockAt uses propulsion instead of teleporting', ship.teleports == 0 and ship.steeredTo ~= nil)

local item = { getMass = function () return 1 end, getName = function () return 'Test Ore' end }
local yield = { item = item, size = 1 }
local asteroid = {
  remaining = 100,
  hasYield = function (self) return self.remaining > 0 end,
  getYieldRemaining = function (self) return self.remaining end,
  consumeYield = function (self, count)
    local taken = math.min(count, self.remaining)
    self.remaining = self.remaining - taken
    return taken
  end,
  getYield = function () return yield end,
  getName = function () return 'Ore Rock' end,
  getPos = function () return vec(0, 0, -100) end,
  getRadius = function () return 5 end,
}
local function miner (dt, frames, initialCargo)
  local e = { cargo = initialCargo or 0, popped = false }
  function e:addItem (wanted, count)
    if self.cargo + count > 100 then return false end
    self.cargo = self.cargo + count
    return true
  end
  function e:getInventoryCapacity () return 100 end
  function e:getInventoryFree () return 100 - self.cargo end
  function e:popAction () self.popped = true end
  local action = MineAt(asteroid)
  for _ = 1, frames do action:onUpdateActive(e, dt) end
  return e, action
end
local at60 = miner(1 / 60, 60)
local at30 = miner(1 / 30, 30)
check('mining rate is dt-invariant', at60.cargo == 20 and at30.cargo == 20,
  string.format('60fps=%d 30fps=%d', at60.cargo, at30.cargo))
local rareItem = { getMass = function () return 1 end, getName = function () return 'Rare Ore' end }
yield.item = rareItem
local rare = miner(1 / 60, 60)
check('rare resources take longer to extract', rare.cargo == 6,
  string.format('rare units after 1s=%d', rare.cargo))
yield.item = item

local partialShip, partialAction = miner(1 / 60, 300, 80)
check('mining progress uses remaining cargo capacity',
  partialAction.maxCount == 20 and partialAction.extracted == 20
  and partialAction:getProgress() == 1,
  string.format('max=%d extracted=%d progress=%.2f',
    partialAction.maxCount or -1, partialAction.extracted, partialAction:getProgress()))

asteroid.remaining = 5
local depositShip, depositAction = miner(1 / 60, 300, 0)
check('mining stops at the remaining deposit rather than cargo capacity',
  depositShip.cargo == 5 and depositAction.extracted == 5
  and depositAction.maxCount == 5 and depositShip.popped,
  string.format('cargo=%d extracted=%d max=%d remaining=%d',
    depositShip.cargo, depositAction.extracted, depositAction.maxCount or -1, asteroid.remaining))
check('fully mined deposit is exhausted', asteroid.remaining == 0)
asteroid.remaining = 100

local effectShip = {
  cargo = 0, children = {}, popped = false,
  addItem = function (self, wanted, count) self.cargo = self.cargo + count; return true end,
  addChild = function (self, child) self.children[#self.children + 1] = child end,
  removeChild = function (self, child)
    for i = 1, #self.children do
      if self.children[i] == child then table.remove(self.children, i); return end
    end
  end,
  popAction = function (self)
    self.popped = true
    if self.current then self.current:onStop(self) end
  end,
  getCurrentAction = function (self) return self.current end,
  getPos = function () return vec(0, 0, 0) end,
  getForward = function () return vec(0, 0, -1) end,
  getRadius = function () return 10 end,
}
local effectAction = MineAt(asteroid)
local startOk = pcall(function () effectAction:onStart(effectShip) end)
check('mining attaches a world-space beam', startOk and #effectShip.children == 1)
effectShip.current = { getName = function () return 'Flee' end }
effectAction:onUpdatePassive(effectShip, 0.1)
check('preempted mining hides its beam', effectShip.children[1]
  and effectShip.children[1].active == false)
effectShip.current = effectAction
effectAction:onUpdateActive(effectShip, 0.1)
check('active mining emits visible sparks', sparksEmitted > 0)
local hasFlash = false
for _, record in ipairs(emittedRecords) do
  if record.size and record.size >= 15 and record.life and record.life <= 0.2 then hasFlash = true end
end
check('mining emits a hot contact flash', hasFlash)
local stopOk = pcall(function () effectAction:onStop(effectShip) end)
check('stopping mining removes its beam', stopOk and #effectShip.children == 0)

local fullShip = {
  cargo = 100, popped = false,
  addItem = function () return false end,
  popAction = function (self) self.popped = true end,
}
MineAt(asteroid):onUpdateActive(fullShip, 1)
check('full cargo finishes the mining action', fullShip.popped)
local farShip = {
  popped = false,
  getMinDistance = function () return 999 end,
  addItem = function () return true end,
  popAction = function (self) self.popped = true end,
}
MineAt(asteroid, 250):onUpdateActive(farShip, 0.1)
check('mining stops when target leaves range', farShip.popped)

effectShip.popped = false
effectShip.getSpeed = function () return 10 end
effectShip.getForward = function () return vec(0, 0, 1) end
effectShip.getMinDistance = function () return 100 end
local inaccurate = MineAt(asteroid, 250)
inaccurate:onStart(effectShip)
effectShip.current = inaccurate
inaccurate:onUpdateActive(effectShip, 1)
check('moving or misaligned extraction fails accuracy', inaccurate.result == false
  and effectShip.children[1].accuracy == 0)
inaccurate:onUpdateActive(effectShip, 1)
check('failed extraction cleans up after red feedback', effectShip.popped and #effectShip.children == 0)

if failures == 0 then
  print(string.format('npc actions: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('npc actions: %d/%d checks failed', failures, checks))
  os.exit(1)
end
