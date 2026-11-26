#!/usr/bin/env luajit
-- Capital prototype scale must reach the live rigid body before radius/mass
-- are derived. The C rigid body is the only mocked boundary in this test.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_capital_ship%.lua$', '')
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
_G.exp = math.exp
_G.Profiler = { Begin = function () end, End = function () end }

local Event = dofile(root .. '/script/Game/Event.lua')
_G.Event = Event
local Entity = dofile(root .. '/script/Game/Entity.lua')
package.loaded['Game.Entity'] = Entity
dofile(root .. '/script/Game/Components/Actions.lua')
dofile(root .. '/script/Game/Components/RigidBody.lua')
dofile(root .. '/script/Game/Components/RegistryInfo.lua')

-- Components unrelated to scale/mass construction are inert boundaries.
for _, name in ipairs({ 'addCapacitor', 'addChildren', 'addExplodable',
  'addInventory', 'addSockets', 'addVisibleMesh', 'addThrustController' }) do
  Entity[name] = function () end
end
function Entity:addHealth (max, rate)
  self.health, self.healthMax, self.healthRate = max, max, rate
end
function Entity:addShield (max, rate, delay)
  self.shield, self.shieldMax = max, max
  self.shieldRate, self.shieldDelay = rate, delay
end
package.loaded['Game.Material'] = { Metal = function () return {} end }

local function makeBody ()
  local body = { scale = 1, baseRadius = 10 }
  function body:setScale (scale) self.scale = scale end
  function body:getScale () return self.scale end
  function body:getBoundingRadius () return self.baseRadius * self.scale end
  function body:setMass (mass) self.mass = mass end
  function body:getMass () return self.mass end
  function body:setDrag () end
  return body
end
_G.RigidBody = { CreateSphereFromMesh = function () return makeBody() end }

local Ship = dofile(root .. '/script/Game/Entities/Ship.lua')

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

local capital = Ship({ mesh = {}, scale = 64, sockets = {}, health = 150000, shield = 50000 })
check('capital prototype scale reaches live body', capital:getScale() == 64,
  string.format('scale=%s', tostring(capital:getScale())))
check('capital radius includes prototype scale', capital:getRadius() == 640,
  string.format('radius=%s', tostring(capital:getRadius())))
check('capital mass is derived from scaled radius', capital:getMass() == 50 * 640^3,
  string.format('mass=%s', tostring(capital:getMass())))
check('capital hull has capital-scale health', capital.healthMax >= 150000
  and capital.health == capital.healthMax,
  string.format('health=%s', tostring(capital.healthMax)))
check('capital hull has a capital-scale shield', capital.shieldMax >= 50000
  and capital.shield == capital.shieldMax,
  string.format('shield=%s', tostring(capital.shieldMax)))

local fighter = Ship({ mesh = {}, scale = 4, sockets = {} })
check('fighter prototype scale also reaches live body', fighter:getScale() == 4)
local armoredFighter = Ship({ mesh = {}, scale = 4, sockets = {}, health = 250 })
check('explicit prototype health overrides the hull-size default',
  armoredFighter.healthMax == 250 and armoredFighter.health == 250)
check('fighter mass is derived from scaled radius', fighter:getMass() == 50 * 40^3)
local proto = { seed = 42, mesh = {}, scale = 64, sockets = {} }
local capitalA, capitalB = Ship(proto, 1), Ship(proto, 2)
check('ship instances get unique stable registry ids', capitalA:getRegistryId() ~= capitalB:getRegistryId())
local planned = Ship(proto, 3, 'ship:1234:1')
check('planned NPC ship id overrides prototype serial id',
  planned:getRegistryId() == 'ship:1234:1' and planned.stableId == 'ship:1234:1')
check('capital registry class is strategic', capitalA:getRegistryClass().id == 3)
local freighter = Ship({ seed = 43, mesh = {}, scale = 28, sockets = {},
  classId = 2, model = 'Freighter' })
check('prototype registry model overrides scale inference', freighter:getRegistryName(false) == 'Freighter'
  and freighter:getRegistryClass().id == 2)

if failures == 0 then
  print(string.format('capital ship: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('capital ship: %d/%d checks failed', failures, checks))
  os.exit(1)
end
