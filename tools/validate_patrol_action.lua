#!/usr/bin/env luajit
-- Fighter patrol action: physical waypoint flight with deterministic variation.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_patrol_action%.lua$', '')
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
function format (f, ...) return string.format(f, ...) end

local Action = class(function () end)
function Action:onStart () end
function Action:onStop () end
function Action:onUpdateActive () end
function Action:onUpdatePassive () end
function Action:flyToward (e, pos) e.steeredTo = pos end
package.loaded['Game.Action'] = Action
package.loaded['Game.Seed'] = { rng = function ()
  local n = 0
  return { managed = function (self) return self end,
    getSphere = function ()
      n = n + 1
      local x = n % 2 == 1 and 1 or -1
      return { x = x, y = 0, z = 0, scale = function (self, s)
        return { x = self.x*s, y = self.y*s, z = self.z*s }
      end }
    end }
end }
local Patrol = dofile(root .. '/script/Game/Actions/Patrol.lua')

local failures, checks = 0, 0
local function check (name, ok)
  checks = checks + 1
  if ok then print('ok   - ' .. name) else failures = failures + 1; print('FAIL - ' .. name) end
end

local Vec = {}
Vec.__index = Vec
local function vec (x, y, z) return setmetatable({ x = x, y = y, z = z }, Vec) end
function Vec.__add (a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
function Vec.__sub (a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
function Vec:length () return math.sqrt(self.x*self.x + self.y*self.y + self.z*self.z) end
local center = vec(100, 0, 100)
local ship = {
  getPos = function () return vec(0, 0, 0) end,
  getForward = function () return vec(0, 0, -1) end,
  getUp = function () return vec(0, 1, 0) end,
}
local patrol = Patrol(center, 2000)
patrol:onStart(ship)
patrol:onUpdateActive(ship, 0.1)
check('patrol steers toward a waypoint', ship.steeredTo ~= nil)
check('patrol waypoint remains near its center', math.abs(ship.steeredTo.x - 100) <= 2000
  and math.abs(ship.steeredTo.z - 100) <= 2000)
local first = ship.steeredTo
ship.getPos = function () return first end
patrol:onUpdateActive(ship, 0.1)
check('arriving selects another patrol waypoint', patrol.waypoint ~= first)
patrol:onUpdateActive(ship, 0.1)
check('patrol steers toward the new waypoint', ship.steeredTo ~= first)
check('patrol clone is independent', patrol:clone() ~= patrol)

if failures == 0 then
  print(string.format('patrol action: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('patrol action: %d/%d checks failed', failures, checks))
  os.exit(1)
end
