#!/usr/bin/env luajit
-- Resource scanner visual contract: rotating green sweep, red failure, and
-- world-space beam geometry.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_scan_effect%.lua$', '')
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
local Entity = class(function () end)
function Entity:register () end
package.loaded['Game.Entity'] = Entity
_G.Event = { Render = 1, Update = 2 }
_G.Preload = { Add = function () end }
_G.Gen = { Primitive = { Billboard = function () return {} end } }
_G.Cache = { Shader = function () return {} end }
local Effect = dofile(root .. '/script/Game/Entities/ScanEffect.lua')

local Vec = {}
Vec.__index = Vec
local function vec (x, y, z) return setmetatable({ x = x, y = y, z = z }, Vec) end
function Vec.__sub (a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
function Vec.__add (a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
function Vec.__unm (a) return vec(-a.x, -a.y, -a.z) end
function Vec:length () return math.sqrt(self.x*self.x + self.y*self.y + self.z*self.z) end
function Vec:normalize ()
  local len = self:length()
  if len < 1e-6 then return vec(0, 0, 0) end
  return vec(self.x / len, self.y / len, self.z / len)
end
function Vec:scale (s) return vec(self.x * s, self.y * s, self.z * s) end

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. detail) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or '')) end
end

local constructOk = pcall(function () return Effect({}, {}) end)
check('scan effect entity constructs', constructOk)
local source = {
  getPos = function () return vec(0, 0, 0) end,
  getForward = function () return vec(0, 0, -1) end,
  getRight = function () return vec(1, 0, 0) end,
  getUp = function () return vec(0, 1, 0) end,
  getRadius = function () return 10 end,
  isDestroyed = function () return false end,
}
local target = {
  getPos = function () return vec(0, 0, -100) end,
  getRadius = function () return 5 end,
  isDestroyed = function () return false end,
}
local p0 = Effect.GetPose(source, target, 0, 0)
local p1 = Effect.GetPose(source, target, 1, 0)
local p0later = Effect.GetPose(source, target, 0, 1)
check('scanner uses separated rotating emitters', p0 and p1
  and math.abs(p0.start.x - 4.5) < 1e-6 and math.abs(p1.start.y - 4.5) < 1e-6)
check('scanner sweep rotates over time', p0later and math.abs(p0later.start.x - p0.start.x) > 0.1)
check('scanner beams penetrate the target surface for visible contact', p0 and p0.finish.z == -96.75)
local renderPose = Effect.GetRenderPose(source, target, 0, 0)
check('scanner billboard extends from ship toward target', renderPose
  and renderPose.position.z == -10.5 and renderPose.direction.z < -0.99)
local scanning = Effect.GetColor(nil)
local failed = Effect.GetColor(false)
local found = Effect.GetColor(true)
check('scanning color is green', scanning[2] > scanning[1] and scanning[2] > scanning[3])
check('failure color is red', failed[1] > failed[2] and failed[1] > failed[3])
check('success color is bright green', found[2] >= scanning[2])

if failures == 0 then
  print(string.format('scan effect: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('scan effect: %d/%d checks failed', failures, checks))
  os.exit(1)
end
