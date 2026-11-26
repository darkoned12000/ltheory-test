#!/usr/bin/env luajit
-- Collision avoidance is an explicit, temporary action over a committed route.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_avoid%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

function class (ctor)
  local cls = {}; cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end
function subclass (base, ctor)
  local cls = {}; cls.__index = cls
  return setmetatable(cls, { __index = base, __call = function (T, ...)
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end
_G.max, _G.min = math.max, math.min
_G.Config = { game = { npcAvoidance = true, npcAvoidanceHorizon = 3,
  npcAvoidanceRadiusScale = 1.25, npcAvoidancePadding = 20,
  npcPerceptionRange = 1000, npcPerceptionInterval = 0.25 } }
_G.PHX = { Math = { ExpMap1Signed = function (x) return x end } }

local Vec = {}; Vec.__index = Vec
local function vec (x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, Vec) end
_G.Vec3f = vec
function Vec.__add (a, b) return vec(a.x+b.x, a.y+b.y, a.z+b.z) end
function Vec.__sub (a, b) return vec(a.x-b.x, a.y-b.y, a.z-b.z) end
function Vec:length () return math.sqrt(self.x*self.x + self.y*self.y + self.z*self.z) end
function Vec:normalize ()
  local n = self:length(); assert(n > 1e-9)
  return vec(self.x/n, self.y/n, self.z/n)
end
function Vec:scale (s) return vec(self.x*s, self.y*s, self.z*s) end
function Vec:dot (b) return self.x*b.x + self.y*b.y + self.z*b.z end
function Vec:cross (b) return vec(self.y*b.z-self.z*b.y, self.z*b.x-self.x*b.z, self.x*b.y-self.y*b.x) end

local Action = dofile(root .. '/script/Game/Action.lua')
package.loaded['Game.Action'] = Action

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name)
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end

local avoidLoaded, Avoid = pcall(require, 'Game.Actions.Avoid')
check('Avoid action module loads', avoidLoaded)
if not avoidLoaded then os.exit(1) end

local rootWorld = { children = {}, time = 1, getTime = function (self) return self.time end }
local owner = { isNpc = function () return true end }
local ship = {
  parent = rootWorld, pos = vec(), velocity = vec(), stableId = 'ship:avoider',
  actions = {}, controller = { clear = function () end },
  body = { getPos = function (self, out)
    out.x, out.y, out.z = self.entity.pos.x, self.entity.pos.y, self.entity.pos.z
  end, getBoundingRadius = function () return 10 end },
  getRoot = function () return rootWorld end,
  getPos = function (self) return self.pos end,
  getVelocity = function (self) return self.velocity end,
  getTopSpeed = function () return 300 end,
  getRadius = function () return 10 end,
  getForward = function () return vec(1, 0, 0) end,
  getRight = function () return vec(0, 0, 1) end,
  getUp = function () return vec(0, 1, 0) end,
  getOwner = function () return owner end,
  getThrustController = function (self) return self.controller end,
}
function ship:getCurrentAction () return self.actions[#self.actions] end
function ship:pushAction (action)
  self.actions[#self.actions + 1] = action
  if action.onStart then action:onStart(self) end
end
function ship:popAction ()
  local action = table.remove(self.actions)
  if action and action.onStop then action:onStop(self) end
end
ship.body.entity = ship

local obstacle = {
  parent = rootWorld, pos = vec(300, 0, 0), velocity = vec(),
  body = { getPos = function (self, out)
    out.x, out.y, out.z = self.entity.pos.x, self.entity.pos.y, self.entity.pos.z
  end, getBoundingRadius = function () return 20 end },
  getPos = function (self) return self.pos end,
  getVelocity = function (self) return self.velocity end,
  getRadius = function () return 20 end,
}
obstacle.body.entity = obstacle
rootWorld.children = { ship, obstacle }

local route = Action()
ship.actions[1] = route
route:flyToward(ship, vec(1000, 0, 0), vec(1, 0, 0), vec(0, 1, 0))
local avoid = ship:getCurrentAction()
check('imminent collision pushes one Avoid action over the route',
  avoid and avoid ~= route and avoid.getName and avoid:getName():sub(1, 5) == 'Avoid')
check('Avoid retains obstacle identity and route underneath',
  avoid and avoid.obstacle == obstacle and ship.actions[1] == route and #ship.actions == 2)

if avoid and avoid.onUpdateActive then avoid:onUpdateActive(ship, 0.016) end
check('Avoid steers through its lateral waypoint without stacking another Avoid',
  #ship.actions == 2 and avoid.waypointPos ~= nil)

if avoid and avoid.getWaypoint then ship.pos = avoid:getWaypoint(ship) end
if avoid and avoid.onUpdateActive then avoid:onUpdateActive(ship, 0.016) end
check('Avoid pops after clearing the obstacle so the original route resumes',
  #ship.actions == 1 and ship:getCurrentAction() == route and ship.npcAvoidanceState == nil)
local oncoming = {
  parent = rootWorld, pos = vec(300, 0, 0), velocity = vec(-100, 0, 0),
  isAlive = function () return true end,
  hasSockets = function () return true end,
  socketSpeedMax = 1000,
  body = { getPos = function (self, out)
    out.x, out.y, out.z = self.entity.pos.x, self.entity.pos.y, self.entity.pos.z
  end, getBoundingRadius = function () return 20 end },
  getPos = function (self) return self.pos end,
  getVelocity = function (self) return self.velocity end,
  getRadius = function () return 20 end,
}
oncoming.body.entity = oncoming
rootWorld.children = { ship, oncoming }
rootWorld.time = 2
ship.pos, ship.velocity = vec(), vec()
route:flyToward(ship, vec(1000, 0, 0), vec(1, 0, 0), vec(0, 1, 0))
check('Avoid responds to an oncoming NPC ship', ship:getCurrentAction() ~= route
  and ship:getCurrentAction().obstacle == oncoming)
local activeAvoid = ship:getCurrentAction()
local avoidanceState = ship.npcAvoidanceState
route:flyToward(ship, vec(2000, 0, 0), vec(1, 0, 0), vec(0, 1, 0))
check('Avoid does not overwrite its active avoidance state on its own steering',
  ship.npcAvoidanceState == avoidanceState
    and ship:getCurrentAction() == activeAvoid
    and #ship.actions == 2)

if failures == 0 then
  print(string.format('npc avoid: %d checks passed', checks)); os.exit(0)
else
  print(string.format('npc avoid: %d/%d checks failed', failures, checks)); os.exit(1)
end
