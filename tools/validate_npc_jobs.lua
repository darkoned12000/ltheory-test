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
    Stop = function () return { getName = function () return 'Stop' end,
      onStart = function () end, onStop = function () end } end,
    Patrol = function () return { getName = function () return 'Patrol' end,
      onStart = function () end, onStop = function () end } end,
    Scan = function () return { getName = function () return 'Scan' end,
      onStart = function () end, onStop = function () end } end,
    TravelTo = function (gate) return { gate = gate, getName = function () return 'TravelTo' end,
      onStart = function () end, onStop = function () end } end,
    Repair = function (station) return { target = station, getName = function () return 'Repair' end,
      onStart = function () end, onStop = function () end } end,
    Refit = function (station) return { target = station, getName = function () return 'Refit' end,
      onStart = function () end, onStop = function () end } end,
    PurchaseShip = function (station) return { target = station, getName = function () return 'PurchaseShip' end,
      onStart = function () end, onStop = function () end } end,
    Undock = function () return { getName = function () return 'Undock' end,
      onStart = function () end, onStop = function () end } end,
    Flee = function (source, duration) return Flee(source, duration) end }
end

local item = { getMass = function () return 1 end, getName = function () return 'Ore' end }
local creditItem = { getMass = function () return 0 end, getName = function () return 'Credit' end }
package.loaded['Game.Item'] = { Credit = creditItem, All = function () return { item, creditItem } end }

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
    stableId = 'entity:' .. id,
  }
end

local source, dest = endpoint(11, 20), endpoint(22, 20)
source.depositFingerprint = 'source-fp'
local Knowledge = require('Game.Knowledge')
local mine, transport = Mine(source, dest), Transport(source, dest, item)
local mineOk, mineKey = pcall(function () return mine:getKey() end)
local transportOk, transportKey = pcall(function () return transport:getKey() end)
check('mine route has a structural key', mineOk and type(mineKey) == 'string', tostring(mineKey))
check('transport route has a structural key', transportOk and type(transportKey) == 'string', tostring(transportKey))
local recreatedSource, recreatedDest = endpoint(999, 20), endpoint(888, 20)
recreatedSource.stableId, recreatedDest.stableId = source.stableId, dest.stableId
check('mine route key survives endpoint recreation', Mine(recreatedSource, recreatedDest):getKey() == mineKey)
check('transport route key survives endpoint recreation',
  Transport(recreatedSource, recreatedDest, item):getKey() == transportKey)
check('mine and transport route keys differ', mineKey ~= transportKey)
local knownAsset = { knowledge = Knowledge.FromLegacy({ [source] = true }, { [source] = true }) }
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
  e.knowledge = Knowledge.FromLegacy({ [source] = true }, { [source] = true })
  e.knownYields, e.scannedAsteroids = e.knowledge.knownYields, e.knowledge.scannedAsteroids
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
local originalMineKey = mine:getKey()
mine.src = endpoint(99, 20)
check('pooled mine retargeting refreshes route identity', mine:getKey() ~= originalMineKey)
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
local checkpointAsset = asset(16)
think:manageAsset(checkpointAsset)
local checkpointPolicy = think:getPolicy(checkpointAsset)
checkpointAsset.npcJobCheckpoint = true
checkpointAsset:clearActions()
checkpointAsset.npcJobCheckpoint = false
check('sector checkpointing does not record a cancelled job',
  checkpointAsset:isIdle() and checkpointAsset.job
  and checkpointPolicy.routes[mine:getKey()] == nil)

local knownSource = endpoint(77, 20)
knownSource.stableId, knownSource.depositFingerprint = 'rock:known', 'source-fp'
rootEntity.resolveStableId = function (_, key)
  if key == 'entity:11' then return source end
  if key == 'rock:known' then return knownSource end
  if key == 'entity:22' then return dest end
end
rootEntity.isTombstoned = function () return false end
a.actions = {}
a.pendingJob = { kind = 'mine', src = 'entity:11', dst = 'entity:22', item = 'Ore',
  srcFingerprint = 'source-fp', state = 3, action = 'Stop' }
think:restorePendingJob(a)
check('pending mine job rebinds stable endpoints', a.job and a.job.src == source
  and a.job.dst == dest and a.pendingJob == nil)
check('pending job restores its braking subaction', a.jobState == 2
  and a:getCurrentAction():getName() == 'Stop')
a:clearActions()
a.knowledge = Knowledge.Create()
Knowledge.Restore(a.knowledge, {
  { key = 'rock:known', fingerprint = 'source-fp', yieldIdentified = true },
  { key = 'rock:unloaded', fingerprint = 'unloaded-fp', yieldIdentified = true },
})
a.knownYields, a.scannedAsteroids = a.knowledge.knownYields, a.knowledge.scannedAsteroids
Knowledge.Rebind(a.knowledge, function (key) return rootEntity:resolveStableId(key) end,
  function (key) return rootEntity:isTombstoned(key) end, 7)
check('known yields rebind to regenerated rocks', Knowledge.Known(a.knowledge, knownSource))
check('unloaded knowledge remains retryable without a busy flag',
  a.knowledge.scans['rock:unloaded'] ~= nil and a.pendingKnowledge == nil)

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
local pendingVictim = asset(6)
pendingVictim.pendingJob = { kind = 'mine', src = 'runtime:99', dst = 'entity:22' }
local pendingBrain = { iterAssets = function ()
  local done = false
  return function ()
    if done then return nil end
    done = true
    return pendingVictim
  end
end }
think:onUpdateActive(pendingBrain, 0)
check('safety handler installs while job data is pending', pendingVictim.npcSafetyHandler == true)
pendingVictim:damage(30, source)
check('damage is recorded while job data is pending', pendingVictim.npcSafety.damage == 30)
think:onUpdateActive(pendingBrain, 0)
check('safety still flees while job data is pending', pendingVictim:getCurrentAction()
  and pendingVictim:getCurrentAction():getName() == 'Flee')
check('runtime-only pending jobs are discarded', pendingVictim.pendingJob == nil)
local staleJobAsset = asset(7)
staleJobAsset.pendingJob = { kind = 'mine', src = 'entity:11', dst = 'entity:22',
  srcFingerprint = 'old-source-fp', item = 'Ore', state = 1 }
think:restorePendingJob(staleJobAsset)
check('pending jobs reject changed source fingerprints', staleJobAsset.pendingJob == nil
  and staleJobAsset.job == nil)
local legacyJobAsset = asset(8)
legacyJobAsset.pendingJob = { kind = 'mine', src = 'entity:11', dst = 'entity:22',
  item = 'Ore', state = 1 }
think:restorePendingJob(legacyJobAsset)
check('pending mine jobs without generation fingerprints fail closed',
  legacyJobAsset.pendingJob == nil and legacyJobAsset.job == nil)
local displayJobAsset = asset(9)
displayJobAsset.pendingJob = { kind = 'mine', src = 'entity:11', dst = 'entity:22',
  srcFingerprint = 'source-fp', item = 'Ore', state = 2, action = 'MoveTo Rock',
  actionTarget = 'entity:11' }
think:restorePendingJob(displayJobAsset)
check('display-named subactions restore their target', displayJobAsset:getCurrentAction()
  and displayJobAsset:getCurrentAction():getName() == 'MoveTo')
local retreatJobAsset = asset(10)
retreatJobAsset:setHealth(20, 100, 0)
retreatJobAsset.pendingJob = { kind = 'mine', src = 'entity:11', dst = 'entity:22',
  srcFingerprint = 'source-fp', item = 'Ore', state = 2, action = 'Stop' }
local retreatBrain = { iterAssets = function ()
  local done = false
  return function ()
    if done then return nil end
    done = true
    return retreatJobAsset
  end
end }
think:onUpdateActive(retreatBrain, 0)
check('restored jobs remain below an active safety retreat', retreatJobAsset.job
  and retreatJobAsset:getCurrentAction():getName() == 'Flee'
  and retreatJobAsset.actions[1] == retreatJobAsset.job)
local transportAsset = asset(11)
transportAsset.pendingJob = { kind = 'transport', src = 'entity:11', dst = 'entity:22',
  item = 'Ore', state = 2, action = 'Transport' }
think:restorePendingJob(transportAsset)
check('current job action does not repeat its completed synchronous stage',
  transportAsset.job and transportAsset.jobState == 2 and transportAsset.pendingJob == nil)
local travelAsset = asset(12)
travelAsset.npcRole, travelAsset.npcNextTravelAt, travelAsset.travelTargetSector = 'industrial', 0, 2
rootEntity.sectors = { { index = 0, neighbours = { 1 } }, { index = 1, neighbours = { 0, 2 } },
  { index = 2, neighbours = { 1 } } }
rootEntity.sectorIndex = 0
local correctGate = { stableId = 'gate:0:1', getName = function () return 'Correct Gate' end,
  getPartnerSector = function () return 1 end, getPos = function () return { x = 1, y = 0, z = 0 } end }
rootEntity.gates = { correctGate }
think:manageTravel(travelAsset)
check('Think sends idle NPCs toward the correct wormhole', travelAsset:getCurrentAction()
  and travelAsset:getCurrentAction().gate == correctGate)
local patrolTravelAsset = asset(14)
patrolTravelAsset.npcRole, patrolTravelAsset.npcNextTravelAt = 'fighter', 0
patrolTravelAsset.travelTargetSector = 2
patrolTravelAsset:pushAction({ getName = function () return 'Patrol' end,
  onStart = function () end, onStop = function () end })
think:manageTravel(patrolTravelAsset)
check('due travel interrupts a fighter patrol instead of waiting forever',
  patrolTravelAsset:getCurrentAction() and patrolTravelAsset:getCurrentAction().gate == correctGate)
local patient = asset(15)
patient.npcRole, patient.npcNextTravelAt = 'fighter', 1000
local patientPatrol = { getName = function () return 'Patrol' end,
  onStart = function () end, onStop = function () end }
patient:pushAction(patientPatrol)
think:manageTravel(patient)
check('patrol remains active while no higher-priority goal is due',
  patient:getCurrentAction() == patientPatrol)
rootEntity.sectors, rootEntity.gates, rootEntity.sectorIndex = nil, nil, nil
local progressionStation = { getName = function () return 'Yard' end,
  hasDockable = function () return true end, hasMarket = function () return true end,
  getPos = function () return { x = 0, y = 0, z = 0 } end,
  addItem = function () return true end, removeItem = function () return true end }
rootEntity.children = { progressionStation }
local progressionOwner = { credits = 10000 }
function progressionOwner:getItemCount (item) return item == creditItem and self.credits or 0 end
function progressionOwner:hasItem (item, count) return item == creditItem and self.credits >= count end
function progressionOwner:removeItem (item, count)
  if item ~= creditItem or self.credits < count then return false end
  self.credits = self.credits - count; return true
end
function progressionOwner:addItem (item, count)
  if item == creditItem then self.credits = self.credits + count; return true end
  return false
end
local progressionAsset = asset(13)
progressionAsset.owner, progressionAsset.shipKind = progressionOwner, 'fighter'
progressionAsset.health, progressionAsset.healthMax = 20, 100
think:manageProgression(progressionAsset)
check('Think prioritizes repair when hull and credits require it',
  progressionAsset:getCurrentAction() and progressionAsset:getCurrentAction():getName() == 'Repair')
progressionAsset.actions, progressionAsset.parent = {}, progressionStation
progressionAsset.afterProgression = 'undock'
think:manageDockExit(progressionAsset)
check('progression completion schedules a normal undock', progressionAsset:getCurrentAction()
  and progressionAsset:getCurrentAction():getName() == 'Undock')
progressionAsset.actions = {}
think:manageUpkeep(progressionAsset, 3600)
check('upkeep accrues and charges in simulation hours', progressionOwner.credits == 9996
  and progressionAsset.npcUpkeepElapsed == 0)

progressionOwner.credits = 100000
local serviceAsset = asset(17)
serviceAsset.shipKind, serviceAsset.npcRole = 'fighter', 'fighter'
serviceAsset.owner = progressionOwner
serviceAsset.getSockets = function () return {
  { type = 'Turret', typeIndex = 1, child = { equipmentId = 'turret-mk1', equipmentTier = 1 } },
} end
rootEntity.sectors = {
  { index = 0, neighbours = { 1 }, hasStation = true, hasShipyard = false },
  { index = 1, neighbours = { 0 }, hasStation = true, hasShipyard = true },
}
rootEntity.sectorIndex, rootEntity.gates = 0, { correctGate }
rootEntity.npcStations = { progressionStation }
think:manageProgression(serviceAsset)
check('ordinary market docks are not selected for shipyard refits',
  serviceAsset:isIdle() and serviceAsset.travelTargetSector == 1
  and serviceAsset.npcServiceNeed == 'shipyard')
think:manageTravel(serviceAsset)
check('NPC without a local shipyard travels toward a sector that has one',
  serviceAsset:getCurrentAction() and serviceAsset:getCurrentAction().gate == correctGate)

serviceAsset.actions = {}
serviceAsset.travelTargetSector, serviceAsset.npcServiceNeed = nil, nil
progressionStation.shipyard = true
think:manageProgression(serviceAsset)
check('a capable local shipyard receives the refit job',
  serviceAsset:getCurrentAction() and serviceAsset:getCurrentAction():getName() == 'Refit'
  and serviceAsset:getCurrentAction().target == progressionStation)

local stranded = asset(18)
stranded.shipKind, stranded.npcRole, stranded.owner = 'fighter', 'fighter', progressionOwner
stranded.health, stranded.healthMax = 20, 100
rootEntity.npcStations = {}
think:manageProgression(stranded)
check('NPC needing repairs with no local station routes to a station sector',
  stranded:isIdle() and stranded.travelTargetSector == 1
  and stranded.npcServiceNeed == 'station')
stranded.npcNextServiceAt = rootEntity.now + 60
stranded.travelTargetSector, stranded.npcServiceNeed = nil, nil
think:manageProgression(stranded)
check('failed service retries respect a cooldown', stranded:isIdle()
  and stranded.travelTargetSector == nil)
local cargoCarrier = asset(19)
cargoCarrier.owner = progressionOwner
cargoCarrier.hasInventory = function () return true end
cargoCarrier.getInventory = function () return { [item] = 1 } end
think:manageProgression(cargoCarrier)
check('NPC carrying goods with no local market routes to a station sector',
  cargoCarrier:isIdle() and cargoCarrier.travelTargetSector == 1
  and cargoCarrier.npcServiceNeed == 'station')
rootEntity.children = nil
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
