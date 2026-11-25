#!/usr/bin/env luajit
-- Close-range target brackets must stay centered and finite when bounding-box
-- corners cross the near plane.

local root = (io.popen('pwd'):read('*l') or '.') .. '/'
package.path = root .. 'script/?.lua;' .. package.path
function class (ctor)
  local cls = {}; cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end
local function vec (x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
_G.Vec3f = vec
_G.Vec4f = vec
_G.Vec2f = vec
_G.Matrix = { Identity = function () return {} end }
_G.Quat = { Identity = function () return {} end }
_G.Settings = { get = function () return 1 end }
local Camera = dofile(root .. 'script/Util/Camera.lua')

local basis = { mulDir = function (_, v) return v end }
local camera = setmetatable({ sx = 1000, sy = 800, zNear = 0.1, mViewInv = basis }, Camera)
function camera:worldToView (v) return vec(v.x, v.y, -v.z) end
function camera:viewToNDC (v)
  local w = -v.z
  return vec(v.x / w, v.y / w, 0), w >= 0 and 1 or -1
end
function camera:ndcToScreen (v) return vec((v.x + 1) * 500, (1 - v.y) * 400, 0) end

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name)
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or '')) end
end

local entity = { getPos = function () return vec(0, 0, -100) end,
  getRadius = function () return 20 end }
local ok, x, y, w, h = pcall(function () return camera:entityToScreenSphere(entity) end)
check('camera exposes stable sphere bracket projection', ok)
if ok then
  check('distant bracket is centered on the projected sphere',
    math.abs(x + w * 0.5 - 500) < 1e-6 and math.abs(y + h * 0.5 - 400) < 1e-6)
  entity.getPos = function () return vec(0, 0, -25) end
  x, y, w, h = camera:entityToScreenSphere(entity)
  local finite = x == x and y == y and w == w and h == h and w > 0 and h > 0
  check('close bracket stays finite when box corners would cross near plane', finite)
  check('close bracket remains centered instead of drifting',
    math.abs(x + w * 0.5 - 500) < 1e-6 and math.abs(y + h * 0.5 - 400) < 1e-6)
end

if failures == 0 then
  print(string.format('camera bracket: %d checks passed', checks)); os.exit(0)
else
  print(string.format('camera bracket: %d/%d checks failed', failures, checks)); os.exit(1)
end
