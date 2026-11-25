#!/usr/bin/env luajit
-- Real Think/Mine/Transport assignment contract: pooled templates must be
-- cloned, routes need stable keys, and completed/cancelled jobs update policy.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_jobs%.lua$', '')
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
function Flow (item, rate, location)
  return { item = item, rate = rate, location = location }
end
table.clear = table.clear or function (t)
  for k in pairs(t) do t[k] = nil end
end
_G.Profiler = { Begin = function () end, End = function () end }
_G.Config = { debug = { damageLog = false } }
_G.max = math.max
_G.min = math.min

local Event = dofile(root .. '/script/Game/Event.lua')
_G.Event = Event
local Entity = dofile(root .. '/script/Game/Entity.lua')
package.loaded['Game.Entity'] = Entity
dofile(root .. '/script/Game/Components/Actions.lua')
dofile(root .. '/script/Game/Components/Owner.lua')
dofile(root .. '/script/Game/Components/Health.lua')

local Action = class(function () end)
function Action:clone () error('base clone') end
function Action:onStart () end
function Action:onStop () end
function Action:onUpdateActive () end
function Action:onUpdatePassive () end
package.loaded['Game.Action'] = Action
local Flee = dofile(root .. '/script/Game/Actions/Flee.lua')
package.loaded['Game.Seed'] = { rng = function ()
  return { managed = function (self) return self end,
    choose = function (self, list) return list[1] end }
end }
_G.requireAll = function ()
  return { MoveTo = function () return { onStart = function () end, onStop = function () end,
    getName = function () return 'MoveTo' end } end, MineAt = function () return {} end,
    DockAt = function () return {} end, Undock = function () return {} end,
    Stop = function () return {} end,
    Patrol = function () return { getName = function () return 'Patrol' end,
      onStart = function () end, onStop = function () end } end,
    Scan = function () return { getName = function () return 'Scan' end,
      onStart = function () end, onStop = function () end } end,
    Flee = function (source, duration) return Flee(source, duration) end }
end

local Job = dofile(root .. '/script/Game/Job.lua')
package.loaded['Game.Job'] = Job
local Mine = dofile(root .. '/script/Game/Jobs/Mine.lua')
local Transport = dofile(root .. '/script/Game/Jobs/Transport.lua')
local Think = dofile(root .. '/script/Game/Actions/Think.lua')

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

local item = { getMass = function () return 1 end, getName = function () return 'Ore' end }
local trader = {
  getSellToPrice = function () return 500 end,
  computeTrade = function () return 10, 500 end,
}
local function endpoint (id, distance)
  return {
    id = id,
    getName = function () return 'Point' .. id end,
    getDistance = function () return distance end,
    getTrader = function () return trader end,
    getYield = function () return { item = item } end,
    hasYield = function (self) return not self.empty end,
  }
end

local source, dest = endpoint(11, 20), endpoint(22, 20)
local mine, transport = Mine(source, dest), Transport(source, dest, item)
local mineOk, mineKey = pcall(function () return mine:getKey() end)
local transportOk, transportKey = pcall(function () return transport:getKey() end)
check('mine route has a stable structural key', mineOk and mineKey == 'mine:11:22:Ore', tostring(mineKey))
check('transport route has a stable structural key', transportOk and transportKey == 'transport:11:22:Ore', tostring(transportKey))
local knownAsset = { knownYields = { [source] = true } }
check('known live yield is minable', mine:isKnown(knownAsset))
source.deleted = true
check('deleted yield is not minable', not mine:isKnown(knownAsset))
source.deleted = nil
source.empty = true
check('depleted yield is not minable', not mine:isKnown(knownAsset))
source.empty = nil

local rootEntity = {
  jobs = { mine },
  now = 0,
  hasEconomy = function () return true end,
  getEconomy = function (self) return { jobs = self.jobs } end,
  getTime = function (self) return self.now end,
  getPatrolCenter = function () return { x = 0, y = 0, z = 0 } end,
  findScanTarget = function () return {} end,
}
local function asset (id)
  local e = Entity()
  e:addActions()
  e:addHealth(100, 0)
  e.assetId = id
  e.knownYields = { [source] = true }
  e.owner = { getNpcId = function () return 'npc:test' end }
  function e:getRoot () return rootEntity end
  function e:getInventoryCapacity () return 10 end
  function e:getTopSpeed () return 10 end
  return e
end

local a = asset(1)
local think = Think()
think:manageAsset(a)
local assigned = a:getCurrentAction()
check('Think assigns a cloned mine action', assigned ~= nil and assigned ~= mine)
check('asset remembers the exact active clone', a.job == assigned)
mine.src = endpoint(99, 20)
check('pooled mine retargeting cannot mutate active route', assigned.src.id == 11)
mine.src = source

local policyOk, policy = pcall(function () return think:getPolicy(a) end)
check('policy is retained per asset', policyOk and policy ~= nil and think:getPolicy(a) == policy)
rootEntity.now = 10
local finishOk, finishErr = pcall(function () assigned:finish(a, 'completed') end)
check('job can finish through its real action stack', finishOk, tostring(finishErr))
check('completion records policy outcome', policyOk and policy.routes[mine:getKey()]
  and policy.routes[mine:getKey()].completed == 1)
check('completed job leaves an idle action stack', a:isIdle(), 'actions=' .. #a.actions)
think:manageAsset(a)
check('completed route is not immediately reassigned', a:isIdle())

local b = asset(2)
think:manageAsset(b)
b:popAction()
local policyBOk, policyB = pcall(function () return think:getPolicy(b) end)
check('cancellation is recorded distinctly', policyBOk and policyB and policyB.routes[mine:getKey()]
  and policyB.routes[mine:getKey()].cancelled == 1)
check('cancelled action is not left on the stack', b:isIdle(), 'actions=' .. #b.actions)

local c = asset(3)
think:manageAsset(c)
local mineRun = c:getCurrentAction()
c.jobState = 6
mineRun:onUpdateActive(c, 0)
local minePolicy = think:getPolicy(c)
check('mine terminal state reports completion', minePolicy.routes[mine:getKey()].completed == 1)
check('mine terminal state clears ship job state', c.jobState == nil)

rootEntity.jobs = { transport }
local d = asset(4)
think:manageAsset(d)
local transportRun = d:getCurrentAction()
d.jobState = 6
d.tradeCount = 10
transportRun:onUpdateActive(d, 0)
local transportPolicy = think:getPolicy(d)
check('transport terminal state reports completion', transportPolicy.routes[transport:getKey()].completed == 1)
check('transport terminal state clears ship job state', d.jobState == nil and d.tradeCount == nil)

local victim = asset(5)
think:manageAsset(victim)
local protectedJob = victim:getCurrentAction()
local brain = { iterAssets = function ()
  local done = false
  return function ()
    if done then return nil end
    done = true
    return victim
  end
end }
think:onUpdateActive(brain, 0)
victim:damage(30, { id = 999 })
local safetyOk, safetyErr = pcall(function () think:onUpdateActive(brain, 0) end)
check('Think runs damage safety without errors', safetyOk, tostring(safetyErr))
check('damage temporarily preempts the active job', #victim.actions == 2
  and victim.actions[1] == protectedJob and victim.actions[2]:getName() == 'Flee')
think:onUpdateActive(brain, 0)
check('safety does not stack duplicate retreats', #victim.actions == 2)
victim:popAction()
check('job resumes after retreat', victim:getCurrentAction() == protectedJob)

local freighter = asset(6)
freighter.npcRole = 'freighter'
rootEntity.jobs = { mine }
think:manageAsset(freighter)
check('freighters reject mining jobs', freighter:isIdle())
rootEntity.jobs = { transport }
think:manageAsset(freighter)
check('freighters accept transport jobs', freighter:getCurrentAction() ~= nil
  and freighter:getCurrentAction():getKey() == transport:getKey())
local fighter = asset(7)
fighter.npcRole = 'fighter'
rootEntity.jobs = { transport }
think:manageAsset(fighter)
check('fighters reject economy transport jobs', fighter:isIdle())
think:managePatrol(fighter)
check('idle fighters take patrol jobs', fighter:getCurrentAction():getName() == 'Patrol')
local scanningFighter = asset(8)
scanningFighter.npcRole = 'fighter'
scanningFighter.knownYields = {}
think:manageScan(scanningFighter)
check('fighters never enter resource scanning', scanningFighter:isIdle())

if failures == 0 then
  print(string.format('npc jobs: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('npc jobs: %d/%d checks failed', failures, checks))
  os.exit(1)
end
