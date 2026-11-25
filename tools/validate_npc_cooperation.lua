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
for _, name in ipairs({ 'Actions', 'Assets', 'Dispositions', 'Health', 'Inventory', 'Owner' }) do
  dofile(root .. '/script/Game/Components/' .. name .. '.lua')
end
local Player = dofile(root .. '/script/Game/Entities/Player.lua')
local Directives = require('Game.Directives')
local Communication = require('Game.Communication')

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
_G.requireAll = function ()
  return { Attack = function (target) return Attack(target) end }
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

local a1, a2 = Attack(target), Attack(target)
check('Attack clone is independent', a1:clone() ~= a1 and a1:clone() ~= a2)
check('Attack clone retains target', a1:clone().target == target)

local liveTarget = {
  isAlive = function () return true end,
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
  function e:getRoot () return world end
  function e:getRadius () return 10 end
  e.socketRangeMin = 1000
  return e
end
local shipA, shipB = cooperativeAsset(alice), cooperativeAsset(bob)
local thinkA, thinkB = Think(), Think()
local shared = Directives.create(world.directives, alice, 'defend', liveTarget, {
  organizationId = 'belt-miners', capacity = 2, now = 40, expiresAt = 100,
})
thinkA:onUpdateActive(alice, 0)
thinkB:onUpdateActive(bob, 0)
check('first NPC accepts shared defense', shared.members[alice:getActorId()] == alice)
check('second NPC accepts shared defense', shared.members[bob:getActorId()] == bob)
local actionA, actionB = shipA:getCurrentAction(), shipB:getCurrentAction()
check('each NPC executes a distinct Attack action', actionA ~= nil
  and actionB ~= nil and actionA ~= actionB)
check('both Attack actions share the directive target', actionA and actionB
  and actionA.target == liveTarget and actionB.target == liveTarget)

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
check('threat recipient executes defense', messengerShip:getCurrentAction() ~= nil
  and messengerShip:getCurrentAction().target == liveTarget)

if failures == 0 then
  print(string.format('npc cooperation: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('npc cooperation: %d/%d checks failed', failures, checks))
  os.exit(1)
end
