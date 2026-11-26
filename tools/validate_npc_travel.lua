#!/usr/bin/env luajit
-- NPC gate routing and normal-speed travel contract.

local root = (io.popen('pwd'):read('*l') or '.') .. '/'
package.path = root .. 'script/?.lua;' .. package.path

function class (ctor)
  local cls = {}; cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end
function subclass (base, ctor)
  local cls = class(); cls.__index = cls
  return setmetatable(cls, { __index = base, __call = function (T, ...)
    local self = base(); setmetatable(self, T); if ctor then ctor(self, ...) end; return self
  end })
end
function format (f, ...) return string.format(f, ...) end
_G.max, _G.min = math.max, math.min
_G.PHX = { Math = { ExpMap1Signed = function (x) return x end } }

local Vec = {}; Vec.__index = Vec
local function vec (x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, Vec) end
_G.Vec3f = vec
function Vec.__sub (a, b) return vec(a.x-b.x, a.y-b.y, a.z-b.z) end
function Vec.__add (a, b) return vec(a.x+b.x, a.y+b.y, a.z+b.z) end
function Vec:length () return math.sqrt(self.x*self.x + self.y*self.y + self.z*self.z) end
function Vec:normalize ()
  local n = self:length()
  assert(n > 1e-12, 'Attempting to normalize vector with near-zero length')
  return self:scale(1/n)
end
function Vec:scale (s) return vec(self.x*s, self.y*s, self.z*s) end
function Vec:dot (b) return self.x*b.x + self.y*b.y + self.z*b.z end
function Vec:cross (b) return vec(self.y*b.z-self.z*b.y, self.z*b.x-self.x*b.z, self.x*b.y-self.y*b.x) end

local Action = dofile(root .. 'script/Game/Action.lua')
package.loaded['Game.Action'] = Action
local NpcTravel = require('Game.NpcTravel')
local TravelTo = require('Game.Actions.TravelTo')
local NpcLog = require('Game.NpcLog')

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. detail) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or '')) end
end

local sectors = {
  { index = 0, neighbours = { 1, 3 }, hasStation = true, hasShipyard = false },
  { index = 1, neighbours = { 0, 2 }, hasStation = true, hasShipyard = true },
  { index = 2, neighbours = { 1 }, hasStation = true, hasShipyard = false },
  { index = 3, neighbours = { 0 }, hasStation = false, hasShipyard = false },
}
local function gate (id, partner, distance)
  return { stableId = id, partnerSector = partner, distance = distance, pos = vec(distance, 0, 0),
    isWormhole = true, DOCK_RANGE = 100,
    getPartnerSector = function (self) return self.partnerSector end,
    getPartnerPos = function () return vec(10000, 0, 0) end,
    getName = function (self) return self.stableId end,
    getPos = function (self) return self.pos end,
    getRadius = function () return 100 end,
    getParent = function () return {} end,
  }
end
local direct, wrong, nextHop = gate('gate:0:1', 1, 800), gate('gate:0:3', 3, 100), gate('gate:0:1b', 1, 500)
local world = { sectors = sectors, sectorIndex = 0, gates = { direct, wrong, nextHop },
  children = {}, time = 0, getTime = function (self) return self.time end }
local route = NpcTravel.Route(world, 0, 2)
check('gate routing finds the correct first hop', route[1] == 1 and route[2] == 2)
local chooser = { getPos = function () return vec(0, 0, 0) end,
  getMinDistance = function (_, gate) return gate.distance end }
local selected = NpcTravel.SelectGate(world, chooser, 2)
check('NPC selects the wormhole toward its destination sector', selected == nextHop)
selected = NpcTravel.SelectGate(world, chooser, nil)
check('without a mission NPC chooses the nearest gate', selected == wrong)
check('unreachable mission sectors do not select a random gate',
  NpcTravel.SelectGate(world, chooser, 99) == nil)
check('service routing finds the nearest sector with a shipyard',
  type(NpcTravel.ServiceSector) == 'function'
  and NpcTravel.ServiceSector(world, true) == 1)
world.sectorIndex = 3
check('stationless sectors route to the nearest station sector',
  type(NpcTravel.ServiceSector) == 'function'
  and NpcTravel.ServiceSector(world, false) == 0)
world.sectorIndex = 0
local distance, speed, eta = NpcTravel.NormalEta({ getPos = function () return vec(0, 0, 0) end,
  getTopSpeed = function () return 500 end }, direct)
check('travel ETA uses normal thrust speed', distance == 700 and speed == 500 and eta == 1.4)
local bodyShip = { body = {}, getPos = function () return vec(0, 0, 0) end,
  getMinDistance = function (_, target) assert(target.body, 'bodyless wormhole reached RigidBody distance') end }
local safeOk, safeDistance = pcall(function () return NpcTravel.Distance(bodyShip, direct) end)
check('bodyless wormhole distance uses the safe surface fallback', safeOk and safeDistance == 700)

_G.Config = { game = { aiUsesBoost = false, npcAvoidance = true, npcLog = true, npcLogInterval = 5 } }
local transits = 0
local ship = {
  pos = vec(), velocity = vec(), distance = 1000, popped = false,
  controller = { forward = 0, right = 0, up = 0, yaw = 0, pitch = 0, roll = 0, boost = 0 },
  getPos = function (self) return self.pos end,
  getVelocity = function (self) return self.velocity end,
  getForward = function () return vec(0, 0, 1) end,
  getRight = function () return vec(1, 0, 0) end,
  getUp = function () return vec(0, 1, 0) end,
  getMinDistance = function (_, target) assert(target.body, 'bodyless wormhole reached RigidBody distance') end,
  getTopSpeed = function () return 500 end,
  getThrustController = function (self) return self.controller end,
  getOwner = function () return { isNpc = function () return true end, getNpcId = function () return 'npc:test' end } end,
  getRoot = function () return world end,
  popAction = function (self) self.popped = true end,
}
world.beginNpcTransit = function () transits = transits + 1 end
ship.controller.boost = 1 -- a live setting change must not leave AI boost latched
local travel = TravelTo(direct, 'test')
travel:onUpdateActive(ship, 0.016)
check('gate approach uses normal thrust without automatic boost', ship.controller.forward ~= 0
  and ship.controller.boost == 0, string.format('forward=%s boost=%s', tostring(ship.controller.forward), tostring(ship.controller.boost)))
local obstacle = {
  pos = vec(150, 0, 0), velocity = vec(), parent = world,
  body = {
    getPos = function (self, out) out.x, out.y, out.z = self.entity.pos.x, self.entity.pos.y, self.entity.pos.z end,
    getBoundingRadius = function () return 20 end,
  },
  getPos = function (self) return self.pos end,
  getVelocity = function (self) return self.velocity end,
  getRadius = function () return 20 end,
}
obstacle.body.entity = obstacle
ship.parent = world
ship.getRight = function () return vec(0, 0, 1) end
world.children = { ship, obstacle }
world.time = 1
travel:flyToward(ship, vec(1000, 0, 0), vec(1, 0, 0), ship:getUp())
local firstAvoidance = ship.controller.right
check('NPC steering diverts around a nearby body in its path',
  math.abs(ship.controller.right) > 1e-6,
  string.format('right=%s', tostring(ship.controller.right)))
obstacle.velocity = vec(0, 0, 150)
world.time = 1.1
travel:flyToward(ship, vec(1000, 0, 0), vec(1, 0, 0), ship:getUp())
check('NPC holds its avoidance side while the obstacle is still alongside',
  ship.controller.right * firstAvoidance > 1e-6,
  string.format('first=%s next=%s', tostring(firstAvoidance), tostring(ship.controller.right)))
obstacle.pos = vec(150, 1000, 0)
obstacle.velocity = vec()
travel:flyToward(ship, vec(1000, 0, 0), vec(1, 0, 0), ship:getUp())
check('NPC steering keeps a clear path unchanged',
  math.abs(ship.controller.right) < 1e-6,
  string.format('right=%s', tostring(ship.controller.right)))
obstacle.pos = vec(150, 0, 0)
obstacle.velocity = vec()
world.time = 1.2
Action.flyToward({ avoidTarget = true, target = obstacle }, ship,
  vec(1000, 0, 0), vec(1, 0, 0), ship:getUp())
check('docking steering can approach its intended berth target',
  math.abs(ship.controller.right) < 1e-6,
  string.format('right=%s', tostring(ship.controller.right)))
world.children = {}
ship.parent = nil
ship.getRight = function () return vec(1, 0, 0) end
ship.velocity = vec(2, 0, 0)
ship.getForward = function () return vec(1, 0, 0) end
local steerOk, steerErr = pcall(function ()
  travel:flyToward(ship, vec(1, 0, 0), ship:getForward(), ship:getUp())
end)
check('lead compensation handles exact course/heading cancellation',
  steerOk and ship.controller.forward ~= nil, steerErr)
ship.velocity = vec()
ship.getForward = function () return vec(0, 0, 1) end
direct.pos = vec(50, 0, 0)
ship.distance = 50
travel:onUpdateActive(ship, 0.016)
check('gate arrival enters NPC transit instead of changing the player sector',
  ship.popped and transits == 1 and world.sectorIndex == 0)

local lines = {}
_G.printf = function (text, ...) lines[#lines+1] = string.format(text, ...) end
ship.actions = { travel }
ship.current = travel
ship.getCurrentAction = function () return ship.current end
ship.getHealthNormalized = function () return 0.8 end
ship.getCredits = function () return 1234 end
NpcLog.Status(ship, world, 10)
local status = table.concat(lines, '\n')
check('NPC status log reports action speed and ETA', status:find('speed=', 1, true)
  and status:find('top=', 1, true) and status:find('eta=', 1, true))

if failures == 0 then
  print(string.format('npc travel: %d checks passed', checks)); os.exit(0)
else
  print(string.format('npc travel: %d/%d checks failed', failures, checks)); os.exit(1)
end
