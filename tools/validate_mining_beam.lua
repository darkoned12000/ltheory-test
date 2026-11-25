#!/usr/bin/env luajit
-- Mining beam world-space geometry. Rendering dependencies are stubbed; the
-- production pose calculation is exercised directly.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_mining_beam%.lua$', '')
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
_G.Event = { Render = 1 }
_G.Preload = { Add = function () end }
_G.Gen = { Primitive = { Billboard = function () return {} end } }
_G.Cache = { Shader = function () return {} end }
_G.ShaderVarCache = function () return {} end

local Beam = dofile(root .. '/script/Game/Entities/MiningBeam.lua')

local Vec = {}
Vec.__index = Vec
local function vec (x, y, z) return setmetatable({ x = x, y = y, z = z }, Vec) end
function Vec.__sub (a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
function Vec.__unm (a) return vec(-a.x, -a.y, -a.z) end
function Vec.__add (a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
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

local constructOk, constructErr = pcall(function () return Beam({}, {}) end)
check('mining beam entity constructs', constructOk, tostring(constructErr))

local source = {
  getPos = function () return vec(0, 0, 0) end,
  getForward = function () return vec(0, 0, -1) end,
  getRight = function () return vec(1, 0, 0) end,
  getUp = function () return vec(0, 1, 0) end,
  getRadius = function () return 10 end,
  isAlive = function () return true end,
}
local target = {
  getPos = function () return vec(0, 0, -100) end,
  getRadius = function () return 5 end,
  isAlive = function () return true end,
}
local pose = Beam.GetPose(source, target)
check('beam starts at the ship nose', pose and pose.start.z == -10.5)
check('beam penetrates the asteroid surface for visible contact', pose and pose.finish.z == -96.75)
check('beam midpoint and length are correct', pose and pose.mid.z == -53.625
  and math.abs(pose.length - 86.25) < 1e-6)
check('beam direction points from ship to rock', pose and pose.dir.z == -1)
local renderPose = Beam.GetRenderPose(source, target, 1)
check('billboard renders from ship toward rock', renderPose
  and renderPose.position.z == -10.5 and renderPose.direction.z == -1)
local leftPose = Beam.GetPose(source, target, 0)
local rightPose = Beam.GetPose(source, target, 2)
check('mining uses separated emitters', leftPose and rightPose
  and leftPose.start.x < 0 and rightPose.start.x > 0)
check('mining beams converge on one contact area', leftPose and rightPose
  and math.abs(leftPose.finish.x) < 0.5 and math.abs(rightPose.finish.x) < 0.5)
target.getPos = function () return vec(0, 0, 0) end
check('coincident ship/target has no invalid beam', Beam.GetPose(source, target) == nil)
target.getPos = function () return vec(0, 0, -100) end
target.isDestroyed = function () return true end
check('destroyed target has no beam', Beam.GetPose(source, target) == nil)
local goodColor = Beam.GetColor(1)
local badColor = Beam.GetColor(0)
check('accurate mining beam is blue', goodColor[3] > goodColor[1] and goodColor[3] > goodColor[2])
check('failed mining beam is red', badColor[1] > badColor[2] and badColor[1] > badColor[3])

if failures == 0 then
  print(string.format('mining beam: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('mining beam: %d/%d checks failed', failures, checks))
  os.exit(1)
end
