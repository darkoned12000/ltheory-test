#!/usr/bin/env luajit
-- Docking must park a ship safely and keep detached physics bodies inert.

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
function insert (t, v) t[#t + 1] = v end
function remove (t, v)
  if v == nil then v = t[#t] end
  for i = 1, #t do
    if t[i] == v then t[i] = t[#t]; t[#t] = nil; return end
  end
end
function format (f, ...) return string.format(f, ...) end
function max (a, b) return math.max(a, b) end
function min (a, b) return math.min(a, b) end
function abs (a) return math.abs(a) end
function ptrToKey (p) return tostring(p) end
_G.EconomyRegistry = { unregister = function () end }
_G.Profiler = { Begin = function () end, End = function () end }
_G.Config = { game = { boostCost = 0 }, audio = { sfxVolume = 0,
  sfx = { engine = { sound = 'engine', volume = 0, minDist = 1, maxDist = 10 } } } }
_G.Sound = { Load = function ()
  return { set3DMinMaxDistance = function () end, play = function () end,
    setVolume = function () end, setPitch = function () end,
    set3DPos = function () end, free = function () end }
end }

local Vec = {}
Vec.__index = Vec
local function vec (x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, Vec) end
_G.Vec3f = vec
function Vec.__sub (a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
function Vec:scale (s) return vec(self.x * s, self.y * s, self.z * s) end
function Vec:muls (s) return self:scale(s) end
function Vec:length () return math.sqrt(self.x*self.x + self.y*self.y + self.z*self.z) end
function Vec:dot (b) return self.x*b.x + self.y*b.y + self.z*b.z end

local Event = dofile(root .. 'script/Game/Event.lua')
_G.Event = Event
local Entity = dofile(root .. 'script/Game/Entity.lua')
package.loaded['Game.Entity'] = Entity
local Action = class(function () end)
function Action:onStart () end
function Action:onStop () end
function Action:onUpdateActive () end
function Action:onUpdatePassive () end
package.loaded['Game.Action'] = Action
dofile(root .. 'script/Game/Components/Actions.lua')
local DockAt = dofile(root .. 'script/Game/Actions/DockAt.lua')
local Undock = dofile(root .. 'script/Game/Actions/Undock.lua')
package.loaded['Game.SocketKind'] = { Thruster = 1, Turret = 2 }
package.loaded['Game.ShipMovement'] = {
  forceScale = function () return 1 end,
  torqueScale = function () return 1 end,
  linearDrag = function () return 1 end,
}
local body = {}
_G.RigidBody = { CreateSphereFromMesh = function () return body end }
dofile(root .. 'script/Game/Components/Children.lua')
dofile(root .. 'script/Game/Components/RigidBody.lua')
dofile(root .. 'script/Game/Components/Dockable.lua')
dofile(root .. 'script/Game/Components/ThrustController.lua')

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. detail) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or '')) end
end

local world = { added = 0, removed = 0 }
function world:addRigidBody () self.added = self.added + 1 end
function world:removeRigidBody () self.removed = self.removed + 1 end

local system = Entity()
system:addChildren()
system.physics = world
local station = Entity()
station:addChildren()
station:addDockable()
station.pos, station.radius, station.up = vec(0, 0, 0), 800, vec(0, 1, 0)
station.body = {}
function station:getPos () return self.pos end
function station:getRadius () return self.radius end
function station:getUp () return self.up end
function station:getForward () return vec(1, 0, 0) end
function station:getName () return 'Station' end
system:addChild(station)

local ship = Entity()
ship.pos, ship.radius, ship.velocity = vec(80, 0, 0), 10, vec(5, 0, 0)
ship.forceApplications, ship.torqueApplications = 0, 0
ship:addRigidBody(true, {})
ship:addThrustController()
function ship:getPos () return self.pos end
function ship:setPos (p) self.pos = p end
function ship:getRadius () return self.radius end
function ship:getVelocity () return self.velocity end
function ship:setVelocity (v) self.velocity = v end
function ship:getMass () return 1000 end
function ship:hasInventory () return false end
function ship:discharge () return false end
function ship:setDrag () end
function ship:getForward () return vec(1, 0, 0) end
function ship:getRight () return vec(0, 0, -1) end
function ship:getUp () return vec(0, 1, 0) end
function ship:getRot () return { mulV = function (_, v) return v end } end
function ship:applyForce () self.forceApplications = self.forceApplications + 1 end
function ship:applyTorqueLocal () self.torqueApplications = self.torqueApplications + 1 end
function ship:iterSocketsByType () return function () return nil end end
function ship:isDestroyed () return false end
system:addChild(ship)
check('ship enters world physics once', world.added == 1 and world.removed == 0)

ship:getThrustController().forward = 1
station:addDocked(ship)
check('docking removes the body from world physics', world.removed == 1 and world.added == 1)
check('docking clears stale thrust controls', ship:getThrustController().forward == 0)
check('docking parks the ship outside the station collider',
  (ship:getPos() - station:getPos()):length() - ship.radius - station.radius >= 250)
check('docking zeros incoming velocity', ship:getVelocity():length() == 0)

for _ = 1, 60 do ship:updateThrustController({ dt = 1 / 60 }) end
check('docked ship cannot accumulate detached force', ship.forceApplications == 0)
check('docked ship cannot accumulate detached torque', ship.torqueApplications == 0)

station:removeDocked(ship)
check('undocking re-adds the body exactly once', world.added == 2 and world.removed == 1)
check('undocking restores the system parent', ship:getParent() == system)
check('undocking leaves a safe stationary berth',
  (ship:getPos() - station:getPos()):length() - ship.radius - station.radius >= 250
  and ship:getVelocity():length() == 0)
check('undocking leaves controls clear', ship:getThrustController().forward == 0)
ship:getThrustController().forward = 1
ship:updateThrustController({ dt = 1 / 60 })
check('undocked ship accepts thrust again', ship.forceApplications == 1)

ship:addActions()
local dockPos = station:getPos() - station:getUp():scale(1.25 * station:getRadius() + ship:getRadius())
ship:setPos(dockPos)
ship:pushAction(DockAt(station))
ship:updateActions({ dt = 1 / 60 })
local staleStation = Entity()
staleStation:addChildren()
staleStation:addDockable()
function staleStation:getName () return 'Stale station' end
function staleStation:getPos () return vec(0, 0, 0) end
function staleStation:getRadius () return 800 end
function staleStation:getUp () return vec(0, 1, 0) end
function staleStation:getForward () return vec(1, 0, 0) end
local staleShip = Entity()
staleShip:addActions()
staleShip:addRigidBody(true, {})
staleShip:addThrustController()
function staleShip:getPos () return vec(0, 0, 0) end
function staleShip:getRadius () return 10 end
local staleDock = DockAt(staleStation)
staleShip:pushAction(staleDock)
local staleOk = pcall(function () staleDock:onUpdateActive(staleShip, 0) end)
check('DockAt safely aborts when its target body is gone', staleOk and staleShip:isIdle())
check('DockAt action completes and parents the ship', ship:getParent() == station and ship:isIdle(),
  string.format('atStation=%s actions=%d current=%s', tostring(ship:getParent() == station), #ship.actions,
    tostring(ship.actions[1] and ship.actions[1].getName and ship.actions[1]:getName())))
ship:pushAction(Undock())
ship:pushAction(Undock())
ship:updateActions({ dt = 1 / 60 })
ship:updateActions({ dt = 1 / 60 })
check('duplicate Undock actions are safe and leave an idle stack',
  ship:getParent() == system and ship:isIdle())

if failures == 0 then
  print(string.format('docking: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('docking: %d/%d checks failed', failures, checks))
  os.exit(1)
end
