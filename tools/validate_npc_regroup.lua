#!/usr/bin/env luajit
-- Regroup action approaches an ally at a collision-safe standoff and cleans up.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_regroup%.lua$', '')
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
function format (f, ...) return string.format(f, ...) end
_G.Config = { game = { npcRegroupDistance = 1000, npcRegroupTimeout = 10 } }

local Vec = {}; Vec.__index = Vec
local function vec (x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, Vec) end
_G.Vec3f = vec
function Vec.__add (a, b) return vec(a.x+b.x, a.y+b.y, a.z+b.z) end
function Vec.__sub (a, b) return vec(a.x-b.x, a.y-b.y, a.z-b.z) end
function Vec:length () return math.sqrt(self.x*self.x + self.y*self.y + self.z*self.z) end
function Vec:normalize ()
  local n = self:length()
  assert(n > 1e-9)
  return vec(self.x/n, self.y/n, self.z/n)
end
function Vec:scale (s) return vec(self.x*s, self.y*s, self.z*s) end

local Action = class(function () end)
function Action:flyToward (ship, pos, forward, up)
  ship.steeredTo, ship.steeredForward, ship.steeredUp = pos, forward, up
end
function Action:onStart () end
function Action:onStop () end
package.loaded['Game.Action'] = Action

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name)
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end
local regroupLoaded, Regroup = pcall(dofile, root .. '/script/Game/Actions/Regroup.lua')
check('Regroup action module loads', regroupLoaded)
if not regroupLoaded then os.exit(1) end

local leader = {
  pos = vec(0, 0, 0), stableId = 'ship:leader',
  isAlive = function () return true end,
  getPos = function (self) return self.pos end,
  getName = function () return 'Leader' end,
  getRadius = function () return 100 end,
  getForward = function () return vec(0, 0, -1) end,
  getUp = function () return vec(0, 1, 0) end,
}
local ship = {
  pos = vec(5000, 0, 0), stableId = 'ship:follower',
  npcNeedsRegroup = true, actions = {},
  getPos = function (self) return self.pos end,
  getRadius = function () return 50 end,
  getForward = function () return vec(0, 0, -1) end,
  getUp = function () return vec(0, 1, 0) end,
  getRight = function () return vec(1, 0, 0) end,
  getThrustController = function () return { clear = function () end } end,
  popAction = function (self) self.popped = (self.popped or 0) + 1 end,
}
local action = Regroup(leader, 1000, 10)
action:onUpdateActive(ship, 0.1)
check('regroup steers to a standoff point instead of the ally collider',
  ship.steeredTo and math.abs(ship.steeredTo:length() - 1000) < 1e-6)
check('regroup remains active while outside join distance', not ship.popped)

ship.pos = vec(900, 0, 0)
action:onUpdateActive(ship, 0.1)
check('regroup completes within join distance and clears the request',
  ship.popped == 1 and ship.npcNeedsRegroup == false)

local timeoutShip = { npcNeedsRegroup = true, popAction = function (self) self.popped = true end }
local timeoutAction = Regroup(leader, 1000, 0.1)
timeoutAction:onUpdateActive(timeoutShip, 0.2)
check('regroup times out without retaining an endless goal',
  timeoutShip.popped and timeoutShip.npcNeedsRegroup == false)

if failures == 0 then
  print(string.format('npc regroup: %d checks passed', checks)); os.exit(0)
else
  print(string.format('npc regroup: %d/%d checks failed', failures, checks)); os.exit(1)
end
