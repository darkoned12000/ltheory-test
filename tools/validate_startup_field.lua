#!/usr/bin/env luajit
-- The demo's nearby ore field must honor its requested world position.

local root = (io.popen('pwd'):read('*l') or '.') .. '/'
package.path = root .. 'script/?.lua;' .. package.path

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
  local cls = class()
  cls.__index = cls
  return setmetatable(cls, { __index = base, __call = function (T, ...)
    local self = setmetatable({}, T)
    if ctor then ctor(self, ...) end
    return self
  end })
end
function format (f, ...) return string.format(f, ...) end
function insert (t, v) t[#t + 1] = v end

local Vec = {}
Vec.__index = Vec
local function vec (x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, Vec) end
_G.Vec3f = vec
function Vec.__add (a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
function Vec:scale (s) return vec(self.x * s, self.y * s, self.z * s) end

package.loaded['Game.Entity'] = class()
for _, name in ipairs({ 'Game.Entities.Dust', 'Game.Entities.Nebula', 'Game.Frustum',
  'Game.Content', 'Game.Production', 'Game.ShipArchetypes', 'Game.Communication',
  'Game.Directives', 'Game.NpcPopulation', 'Game.NpcRegistry', 'Game.NameGen' }) do
  package.loaded[name] = {}
end
package.loaded['Game.NameGen'] = { genName = function () return 'Test Field' end }
local ore = { getName = function () return 'Copper Ore' end }
_G.Item = { T1 = { ore } }
package.loaded['Game.Item'] = Item
_G.kSystemScale = 10000
_G.genName = function () return 'Test Field' end

local Zone = class(function (self, name)
  self.name, self.children = name, {}
end)
function Zone:add (child) self.children[#self.children + 1] = child end
function Zone:getPos () return self.pos end
local Asteroid = class(function (self)
  self.yields = 0
  self.body = {}
end)
function Asteroid:setPos (p) self.pos = p end
function Asteroid:setScale (s) self.scale = s end
function Asteroid:setRot () end
function Asteroid:addYield () self.yields = self.yields + 1 end
function Asteroid:setDepositKey (key) self.depositKey = key end
function Asteroid:getPos () return self.pos end
_G.Entities = { Zone = Zone, Asteroid = Asteroid }

local serial = 0
local rng = {}
function rng:getDir3 () return vec(0, 0, -1) end
function rng:getExp () return 1 end
function rng:getQuat () return {} end
function rng:get31 () serial = serial + 1; return serial end
function rng:choose (values) return values[1] end

local ffi = require('ffi')
ffi.cdef [[
  typedef struct RigidBody { int dummy; } RigidBody;
  typedef struct Collision { void* body0; void* body1; int index; int count; } Collision;
]]
local System = dofile(root .. 'script/Game/Entities/System.lua')
local world = { rng = rng, children = {}, zones = {} }
function world:addChild (child) insert(self.children, child) end
function world:addZone (zone) insert(self.zones, zone) end
local requested = vec(1200, -340, -5600)
local zone = System.spawnAsteroidField(world, 5, 5, requested)

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name)
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or '')) end
end
check('startup field creates the requested asteroid count', #world.children == 5)
check('startup field honors the requested position', world.zones[1].pos == requested)
check('first asteroid anchors the requested field position', world.children[1].pos == requested)
local yielded = 0
for _, rock in ipairs(world.children) do if rock.yields > 0 then yielded = yielded + 1 end end
check('startup field creates the requested ore count', yielded == 5)
check('startup field returns its zone for later placement', zone == world.zones[1])
local recentered = vec(-900, 2200, 4300)
local moveOk, moveErr = pcall(function () System.moveAsteroidField(world, zone, recentered) end)
check('startup field can be recentered after ship placement', moveOk and zone.pos == recentered,
  moveErr or string.format('pos=(%s,%s,%s) target=(%s,%s,%s)',
    tostring(zone.pos.x), tostring(zone.pos.y), tostring(zone.pos.z),
    tostring(recentered.x), tostring(recentered.y), tostring(recentered.z)))
local firstPos = world.children[1].pos
local firstError = math.sqrt((firstPos.x - recentered.x)^2
  + (firstPos.y - recentered.y)^2 + (firstPos.z - recentered.z)^2)
check('recentering moves every asteroid with the field', firstError < 1e-6)

if failures == 0 then
  print(string.format('startup field: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('startup field: %d/%d checks failed', failures, checks))
  os.exit(1)
end
