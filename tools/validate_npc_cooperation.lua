#!/usr/bin/env luajit
-- Cooperative defense contract: organization membership, shared directives,
-- capacity/expiry, and clean Attack cloning. No Engine/GL required.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_cooperation%.lua$', '')
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
table.clear = table.clear or function (t)
  for k in pairs(t) do t[k] = nil end
end

local Event = dofile(root .. '/script/Game/Event.lua')
_G.Event = Event
_G.Profiler = { Begin = function () end, End = function () end }
_G.Config = { debug = { damageLog = false }, game = { commRange = 20000 } }
_G.max = math.max
_G.min = math.min
local Entity = dofile(root .. '/script/Game/Entity.lua')
package.loaded['Game.Entity'] = Entity
for _, name in ipairs({ 'Actions', 'Assets', 'Dispositions', 'Health', 'Inventory', 'Owner', 'Shield' }) do
  dofile(root .. '/script/Game/Components/' .. name .. '.lua')
end
local Player = dofile(root .. '/script/Game/Entities/Player.lua')
local Directives = require('Game.Directives')
local Communication = require('Game.Communication')
local Safety = require('Game.NpcSafety')

local Action = class(function () end)
function Action:onStart () end
function Action:onStop () end
function Action:onUpdateActive () end
function Action:onUpdatePassive () end
package.loaded['Game.Action'] = Action
package.loaded['Game.Seed'] = { rng = function ()
  return { managed = function (self) return self end,
    choose = function () return nil end }
end }
local Attack = dofile(root .. '/script/Game/Actions/Attack.lua')
local Flee = dofile(root .. '/script/Game/Actions/Flee.lua')
local Defend = dofile(root .. '/script/Game/Actions/Defend.lua')
_G.requireAll = function ()
  return {
    Attack = function (target) return Attack(target) end,
    Flee = function (source, duration) return Flee(source, duration) end,
    Defend = function (protected, target, directive) return Defend(protected, target, directive) end,
    Regroup = function (leader, distance, timeout)
      return { kind = 'Regroup', leader = leader, distance = distance, timeout = timeout,
        getName = function () return 'Regroup' end,
        onStart = function () end, onStop = function () end }
    end,
    Repair = function (station)
      return { kind = 'Repair', target = station,
        getName = function () return 'Repair at ' .. station:getName() end,
        onStart = function () end, onStop = function () end }
    end,
    Undock = function ()
      return { kind = 'Undock', getName = function () return 'Undock' end,
        onStart = function () end, onStop = function () end }
    end,
  }
end
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

local alice = Player({ isNpc = true, npcId = 'npc:a', organization = 'belt-miners' })
local bob = Player({ isNpc = true, npcId = 'npc:b', organization = 'belt-miners' })
local outsider = Player({ isNpc = true, npcId = 'npc:c', organization = 'traders' })
check('NPC exposes stable actor id', alice:getActorId() == 'npc:a')
check('organization members recognize each other', alice:sharesOrganization(bob))
check('different organizations do not share', not alice:sharesOrganization(outsider))
alice:modOrganizationStanding('belt-miners', 2)
check('organization standing is mutable', alice:getOrganizationStanding('belt-miners') == 2)

local target = { isAlive = function () return true end, getName = function () return 'Raider' end }
local manager = Directives.Create()
local directive = Directives.create(manager, alice, 'defend', target, {
  organizationId = 'belt-miners', capacity = 2, now = 10, expiresAt = 70,
})
check('directive is created open', directive.status == 'open')
check('nonmember cannot accept', not Directives.accept(manager, directive.id, outsider))
check('first member can accept', Directives.accept(manager, directive.id, alice))
check('duplicate acceptance is idempotent', Directives.accept(manager, directive.id, alice)
  and directive.memberCount == 1)
check('second member can accept', Directives.accept(manager, directive.id, bob)
  and directive.memberCount == 2)
check('both members share one objective', Directives.activeFor(manager, alice) == directive
  and Directives.activeFor(manager, bob) == directive)
local third = Player({ isNpc = true, npcId = 'npc:d', organization = 'belt-miners' })
check('directive capacity is enforced', not Directives.accept(manager, directive.id, third))
check('completion succeeds once', Directives.complete(manager, directive.id, alice)
  and not Directives.complete(manager, directive.id, bob))
check('completion grants standing once', alice:getOrganizationStanding('belt-miners') == 3)

local expired = Directives.create(manager, alice, 'defend', target, {
  organizationId = 'belt-miners', now = 20, expiresAt = 21,
})
Directives.accept(manager, expired.id, alice)
Directives.update(manager, 22)
check('expired directive fails and clears active state', expired.status == 'failed'
  and Directives.activeFor(manager, alice) == nil)

local killed = Directives.create(manager, alice, 'defend', target, {
  organizationId = 'belt-miners', now = 30, expiresAt = 100,
})
Directives.accept(manager, killed.id, alice)
target.isAlive = function () return false end
Directives.update(manager, 31)
check('target death fails directive', killed.status == 'failed')
Directives.update(manager, 32)
check('terminal directives are pruned from the shared manager',
  not manager.byId[killed.id] and not manager.byId[expired.id]
    and not manager.byId[directive.id])
local visibleTerminal = 0
for _, entry in ipairs(manager.list) do
  if entry.status == 'completed' or entry.status == 'failed' then
    visibleTerminal = visibleTerminal + 1
  end
end
check('directive list contains no terminal entries', visibleTerminal == 0)

local released = Directives.create(manager, alice, 'defend', target, {
  organizationId = 'belt-miners', now = 32, expiresAt = 100,
})
Directives.accept(manager, released.id, alice)
local releaseOk = Directives.release and Directives.release(manager, released.id, alice)
check('an NPC can release a hopeless directive for another defender',
  releaseOk and released.status == 'open' and released.memberCount == 0
    and Directives.activeFor(manager, alice) == nil)

local a1, a2 = Attack(target), Attack(target)
check('Attack clone is independent', a1:clone() ~= a1 and a1:clone() ~= a2)
check('Attack clone retains target', a1:clone().target == target)

local liveTarget = {
  healthMax = 100, socketSpeedMax = 1000,
  isAlive = function () return true end,
  hasSockets = function () return true end,
  getHealthNormalized = function () return 1 end,
  getName = function () return 'Live Raider' end,
  getRadius = function () return 20 end,
}
local world = {
  directives = Directives.Create(), now = 40,
  hasEconomy = function () return true end,
  getEconomy = function () return { jobs = {} } end,
  getTime = function (self) return self.now end,
}
local function cooperativeAsset (owner)
  local e = Entity()
  e:addActions()
  e:addHealth(100, 0)
  owner:addAsset(e)
  e.parent = world
  function e:getRoot () return world end
  function e:getPos () return self.pos or { x = 0, y = 0, z = 0 } end
  function e:getRadius () return 10 end
  e.socketRangeMin = 1000
  e.socketSpeedMax = 1000
  return e
end
local shipA, shipB = cooperativeAsset(alice), cooperativeAsset(bob)
local thinkA, thinkB = Think(), Think()
local cancelledJob = {
  getKey = function () return 'mine:stale:A:B:Iron' end,
  src = { deleted = true },
  getName = function () return 'Stale mine' end,
}
shipA.job = cancelledJob
local cancellationPolicy = thinkA:getPolicy(shipA)
thinkA:manageJobValidity(shipA)
check('invalid jobs record an outcome so their route enters cooldown',
  not cancellationPolicy.canAssign(cancellationPolicy, cancelledJob, world.now))
shipA.job = nil
local hitOwner = Player({ isNpc = true, npcId = 'npc:hit', organization = 'belt-miners' })
local hitShip = cooperativeAsset(hitOwner)
local hitThink = Think()
local hitJob = { getName = function () return 'Haul ore' end,
  onStart = function () end, onStop = function () end }
hitShip:pushAction(hitJob)
hitThink:getSafety(hitShip)
hitShip:damage(40, liveTarget)
check('a heavy first hit immediately pushes Flee before the next AI tick',
  hitShip:getCurrentAction() and hitShip:getCurrentAction():getName() == 'Flee'
    and hitShip.actions[1] == hitJob)
local fighterOwner = Player({ isNpc = true, npcId = 'npc:fighter', organization = 'belt-miners' })
local fighter = cooperativeAsset(fighterOwner)
fighter.npcRole = 'fighter'
fighter.socketSpeedMax = 1000
local fighterThink = Think()
fighterThink:getSafety(fighter)
local attacker = {
  isAlive = function () return true end,
  hasSockets = function () return true end,
  socketSpeedMax = 1000,
  getPos = function () return { x = 0, y = 0, z = 0 } end,
  getRadius = function () return 10 end,
  getName = function () return 'Player fighter' end,
}
fighter:damage(5, attacker)
local retaliationFn = fighterThink.manageRetaliation
local retaliationOk = retaliationFn and pcall(function () retaliationFn(fighterThink, fighter) end)
check('a combat-capable NPC fights back after taking light damage',
  retaliationOk and fighter:getCurrentAction() and fighter:getCurrentAction().target == attacker)
local capitalOwner = Player({ isNpc = true, npcId = 'npc:capital',
  organization = 'belt-miners' })
local capital = cooperativeAsset(capitalOwner)
capital.npcRole = 'capital'
capital.socketSpeedMax = 1000
capital.turretCount = 6
capital:setHealth(150000, 150000, 0)
capital:addShield(50000, 1000, 6)
local capitalThink = Think()
capitalThink:getSafety(capital)
capital:damage(40, attacker)
check('a capital does not flee from a single fighter hit',
  not capital.getCurrentAction or not capital:getCurrentAction()
    or capital:getCurrentAction():getName() ~= 'Flee')
local capitalRetaliation = capitalThink.manageRetaliation
local capitalOk = capitalRetaliation and pcall(function () capitalRetaliation(capitalThink, capital) end)
check('a capital returns fighter fire instead of retreating', capitalOk
  and capital:getCurrentAction() and capital:getCurrentAction().target == attacker)
local shared = Directives.create(world.directives, alice, 'defend', liveTarget, {
  organizationId = 'belt-miners', capacity = 2, now = 40, expiresAt = 100,
})
thinkA:onUpdateActive(alice, 0)
thinkB:onUpdateActive(bob, 0)
check('first NPC accepts shared defense', shared.members[alice:getActorId()] == alice)
check('second NPC accepts shared defense', shared.members[bob:getActorId()] == bob)
local actionA, actionB = shipA:getCurrentAction(), shipB:getCurrentAction()
check('each NPC executes a distinct Defend action', actionA ~= nil
  and actionB ~= nil and actionA ~= actionB)
check('both Defend actions share the directive target', actionA and actionB
  and actionA.target == liveTarget and actionB.target == liveTarget)
shipA:clearActions()
local activeJob = {
  getName = function () return 'Transport committed' end,
  onStart = function () end,
  onStop = function () end,
}
shipA.job = activeJob
shipA:pushAction(activeJob)
thinkA:manageDirective(shipA)
check('real defense directive preempts a running job',
  shipA:getCurrentAction() and shipA:getCurrentAction().target == liveTarget
    and shipA:getCurrentAction().protected == shipA)
check('defense leaves the interrupted job stacked for resumption',
  shipA.actions[1] == activeJob and #shipA.actions == 2)
shipA:clearActions()
shipA:pushAction(activeJob)
local avoidAction = { directive = shared, onStart = function () end,
  onStop = function () end,
  getName = function () return 'Avoid rock' end }
shipA:pushAction(avoidAction)
thinkA:manageDirective(shipA)
check('an active Avoid does not receive a duplicate Defend action',
  #shipA.actions == 2 and shipA:getCurrentAction() == avoidAction)
shipA:clearActions()
shipA.job = nil

local Vec = {}
Vec.__index = Vec
local function pos (x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, Vec) end
function Vec.__sub (a, b) return pos(a.x-b.x, a.y-b.y, a.z-b.z) end
function Vec:dot (b) return self.x*b.x + self.y*b.y + self.z*b.z end
shipA.getPos = function () return pos(0, 0, 0) end
shipB.getPos = function () return pos(5000, 0, 0) end
world.npcTargets = function (_, exclude)
  local out = {}
  if shipB ~= exclude then out[1] = shipB end
  return out
end
shipA.npcNeedsRegroup = true
shipA.job = activeJob
shipA:pushAction(activeJob)
local regroupFn = thinkA.manageRegroup
local regroupOk = regroupFn and pcall(function () regroupFn(thinkA, shipA) end)
check('retreat aftermath preempts a job to regroup with a nearby ally',
  regroupOk and shipA:getCurrentAction() and shipA:getCurrentAction().kind == 'Regroup')
check('regroup keeps the interrupted job below its action',
  shipA.actions[1] == activeJob and #shipA.actions == 2)
shipA:clearActions()
shipA.job = nil
shipA.npcNeedsRegroup = nil

local weakOwner = Player({ isNpc = true, npcId = 'npc:weak', organization = 'belt-miners' })
local weakShip = cooperativeAsset(weakOwner)
weakShip.socketSpeedMax = 1000
local weakJob = { getName = function () return 'Mine weak ship' end,
  onStart = function () end, onStop = function () end }
weakShip.job = weakJob
weakShip:pushAction(weakJob)
local boss = {
  healthMax = 1000, socketSpeedMax = 1000,
  isAlive = function () return true end,
  hasSockets = function () return true end,
  getHealthNormalized = function () return 1 end,
  getName = function () return 'Capital Raider' end,
}
local weakDirective = Directives.create(world.directives, alice, 'defend', boss, {
  organizationId = 'belt-miners', capacity = 2, protected = weakShip,
  now = world.now, expiresAt = world.now + 60,
})
local wingmen = { weakShip }
for i = 1, 4 do
  local civilianOwner = Player({ isNpc = true, npcId = 'npc:civilian:' .. i,
    organization = 'belt-miners' })
  local civilian = cooperativeAsset(civilianOwner)
  civilian.socketSpeedMax = 0
  wingmen[#wingmen + 1] = civilian
end
world.npcTargets = function (_, exclude)
  local out = {}
  for _, candidate in ipairs(wingmen) do
    if candidate ~= exclude then out[#out + 1] = candidate end
  end
  return out
end
local weakThink = Think()
weakThink:manageDirective(weakShip)
check('non-combatant allies do not make a hopeless fight look viable',
  weakDirective.memberCount == 0 and weakShip:getCurrentAction() == weakJob)
for i = 2, #wingmen do wingmen[i].socketSpeedMax = 1000 end
weakThink:manageDirective(weakShip)
check('nearby armed allies make the same defense assignment viable',
  weakDirective.memberCount == 1 and weakShip:getCurrentAction()
    and weakShip:getCurrentAction().target == boss
    and weakShip.actions[1] == weakJob and #weakShip.actions == 2)
for i = 2, #wingmen do wingmen[i].socketSpeedMax = 0 end
weakThink:manageDirective(weakShip)
check('a defender withdraws from a fight that becomes hopeless',
  weakDirective.memberCount == 0 and #weakShip.actions == 1
    and weakShip:getCurrentAction() == weakJob)

local Item = require('Game.Item')
local repairWorld = { now = 80, npcStations = {},
  getTime = function (self) return self.now end }
local repairOwner = Player({ isNpc = true, npcId = 'npc:repair', organization = 'belt-miners' })
repairOwner:addItem(Item.Credit, 100000)
local repairShip = cooperativeAsset(repairOwner)
repairShip.parent = repairWorld
repairShip.getRoot = function () return repairWorld end
repairShip.getMinDistance = function () return 100 end
repairShip.health = 20
repairShip.healthMax = 100
local repairStation = {
  parent = repairWorld,
  getName = function () return 'Repair Dock' end,
  hasDockable = function () return true end,
  hasMarket = function () return true end,
  addItem = function () return true end,
  removeItem = function () return true end,
}
repairWorld.npcStations = { repairStation }
local committedHaul = {
  getName = function () return 'Transport cargo' end,
  onStart = function () end,
  onStop = function () end,
}
repairShip.job = committedHaul
repairShip:pushAction(committedHaul)
local repairThink = Think()
repairThink:manageProgression(repairShip)
check('critical hull repair preempts an active job',
  repairShip:getCurrentAction() and repairShip:getCurrentAction().kind == 'Repair'
    and repairShip.actions[1] == committedHaul)
repairShip:popAction()
repairShip.parent = repairStation
repairThink:manageDockExit(repairShip)
check('undocking resumes the committed job after repair',
  repairShip:getCurrentAction() and repairShip:getCurrentAction().kind == 'Undock'
    and repairShip.actions[1] == committedHaul)
repairShip:clearActions()
repairShip.job = nil

local cargoItem = Item('Phase3 Test Cargo', 1)
Item.Price = Item.Price or {}
Item.Price[cargoItem] = 1000
shipA:addInventory(100)
shipA:addItem(cargoItem, 20)
shipA:setHealth(70, 100, 0)
shipA:clearActions()
local committedJob = {
  getName = function () return 'Mine committed cargo' end,
  onStart = function () end,
  onStop = function () end,
}
shipA:pushAction(committedJob)
local safetyState = thinkA:getSafety(shipA)
Safety.recordDamage(safetyState, 40, liveTarget, world.now)
thinkA:manageSafety(shipA)
check('valuable cargo triggers retreat before hull is critical',
  shipA:getCurrentAction() and shipA:getCurrentAction():getName() == 'Flee')
check('retreat preserves the committed job underneath',
  shipA.actions[1] == committedJob and #shipA.actions == 2)
shipA:clearActions()

local messengerA = Player({ isNpc = true, npcId = 'npc:x', organization = 'belt-miners' })
local messengerB = Player({ isNpc = true, npcId = 'npc:y', organization = 'belt-miners' })
local commWorld = {
  directives = Directives.Create(), comms = Communication.Create(), now = 50,
  hasEconomy = function () return true end,
  getEconomy = function () return { jobs = {} } end,
  getTime = function (self) return self.now end,
}
Communication.register(commWorld.comms, messengerA)
Communication.register(commWorld.comms, messengerB)
local Pos = {}
Pos.__index = Pos
local function pos (x) return setmetatable({ x = x, y = 0, z = 0 }, Pos) end
function Pos.__sub (a, b) return pos(a.x - b.x) end
function Pos:length () return math.abs(self.x) end
local function commAsset (owner, position)
  local e = Entity()
  e:addActions()
  e:addHealth(100, 0)
  owner:addAsset(e)
  function e:getRoot () return commWorld end
  function e:getPos () return position end
  function e:getRadius () return 10 end
  e.socketRangeMin = 1000
  e.socketSpeedMax = 1000
  return e
end
local messengerShipA = commAsset(messengerA, pos(0))
local messengerShip = commAsset(messengerB, pos(100))
local thinkA, thinkB = Think(), Think()
thinkA:onUpdateActive(messengerA, 0)
messengerShipA:damage(30, liveTarget)
thinkB:onUpdateActive(messengerB, 0)
check('received threat becomes a shared defense directive',
  Directives.activeFor(commWorld.directives, messengerB) ~= nil)
local receivedDirective = Directives.activeFor(commWorld.directives, messengerB)
check('defense directive records the ship that was attacked',
  receivedDirective and receivedDirective.protected == messengerShipA)
check('threat recipient executes defense', messengerShip:getCurrentAction() ~= nil
  and messengerShip:getCurrentAction().target == liveTarget
  and messengerShip:getCurrentAction().protected == messengerShipA)

if failures == 0 then
  print(string.format('npc cooperation: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('npc cooperation: %d/%d checks failed', failures, checks))
  os.exit(1)
end
