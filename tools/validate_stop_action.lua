#!/usr/bin/env luajit
-- Active braking action used before mining. It must null all thrust and only
-- finish once the ship is below the configured stop speed.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_stop_action%.lua$', '')
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
_G.Config = { game = { miningStopSpeed = 2 } }

local Action = class(function () end)
function Action:onStart () end
function Action:onStop () end
function Action:onUpdateActive () end
function Action:onUpdatePassive () end
package.loaded['Game.Action'] = Action
local Stop = dofile(root .. '/script/Game/Actions/Stop.lua')

local Vec = {}
Vec.__index = Vec
local function vec (x, y, z) return setmetatable({ x = x, y = y, z = z }, Vec) end
function Vec:dot (b) return self.x*b.x + self.y*b.y + self.z*b.z end
function Vec:length () return math.sqrt(self.x*self.x + self.y*self.y + self.z*self.z) end

local failures, checks = 0, 0
local function check (name, ok)
  checks = checks + 1
  if ok then print('ok   - ' .. name) else failures = failures + 1; print('FAIL - ' .. name) end
end

local controller = { forward = 1, right = 1, up = 1, boost = 1 }
function controller:clear ()
  self.forward, self.right, self.up, self.boost = 0, 0, 0, 0
end
local ship = {
  velocity = vec(10, 0, 0), popped = false,
  getVelocity = function (self) return self.velocity end,
  getForward = function () return vec(1, 0, 0) end,
  getRight = function () return vec(0, 1, 0) end,
  getUp = function () return vec(0, 0, 1) end,
  getThrustController = function () return controller end,
  popAction = function (self) self.popped = true end,
}
local stop = Stop()
stop:onUpdateActive(ship, 0.1)
check('braking applies reverse thrust', controller.forward < 0 and controller.right == 0)
check('braking does not finish while moving', not ship.popped)
ship.velocity = vec(0.5, 0, 0)
stop:onUpdateActive(ship, 0.1)
check('braking clears thrust at rest', controller.forward == 0 and controller.boost == 0)
check('braking finishes below stop speed', ship.popped)
check('Stop clone is independent', stop:clone() ~= stop)

if failures == 0 then
  print(string.format('stop action: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('stop action: %d/%d checks failed', failures, checks))
  os.exit(1)
end
