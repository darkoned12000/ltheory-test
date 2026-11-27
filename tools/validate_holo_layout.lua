#!/usr/bin/env luajit
-- Holo layout/camera contracts. GL-free and deterministic.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_holo_layout%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end

local loaded, Layout = pcall(require, 'UI.HoloLayout')
check('HoloLayout module loads', loaded, Layout)
if not loaded then os.exit(1) end

local vx, vy, vsx, vsy = 0, 0, 1920, 1080
math.randomseed(24681357)
local maxError, validSamples = 0, 0
for _ = 1, 2000 do
  local cam = {
    x = math.random() * 1000 - 500,
    y = math.random() * 1000 - 500,
    zoom = 0.25 + math.random() * 4.25,
    pitch = -1.1 + math.random() * 2.2,
    yaw = -math.pi + math.random() * math.pi * 2,
    fovDist = 900,
  }
  local x, y = math.random() * 2000 - 1000, math.random() * 2000 - 1000
  local sx, sy = Layout.project(cam, x, y, 0, vx, vy, vsx, vsy)
  if sx then
    validSamples = validSamples + 1
    local rx, ry = Layout.unproject(cam, sx, sy, vx, vy, vsx, vsy)
    local ok = rx ~= nil and math.abs(rx - x) < 1e-6 and math.abs(ry - y) < 1e-6
    if ok then
      maxError = math.max(maxError, math.abs(rx - x), math.abs(ry - y))
    else
      failures = failures + 1; break
    end
  end
end
check('projection and inversion round-trip under tilt/yaw/zoom',
  validSamples >= 1500 and maxError < 1e-6,
  string.format('%d visible samples, max error %.3g', validSamples, maxError))

local cam = { x = 100, y = -50, zoom = 1.7, pitch = 0.4, yaw = 0.8, fovDist = 900 }
local wx, wy = 321, -123
local sx, sy = Layout.project(cam, wx, wy, 0, vx, vy, vsx, vsy)
check('tilted pan preserves the grabbed world point',
  Layout.pan(cam, sx, sy, sx + 120, sy - 75, vx, vy, vsx, vsy))
local sx2, sy2 = Layout.project(cam, wx, wy, 0, vx, vy, vsx, vsy)
check('tilted pan anchor stays under the cursor',
  math.abs(sx2 - (sx + 120)) < 1e-6 and math.abs(sy2 - (sy - 75)) < 1e-6)

check('projected radius uses the same zoom convention as positions',
  Layout.projectRadius({ zoom = 2 }, 10, 0.5) == 10)
check('near-plane projection is rejected',
  Layout.project({ zoom = 1, pitch = 0, yaw = 0, fovDist = 40 }, 0, 0, -1,
    vx, vy, vsx, vsy) == nil)
check('degenerate unprojection is rejected',
  Layout.unproject({ x = 0, y = 0, zoom = 1, pitch = math.pi * 0.5,
    yaw = 0, fovDist = 900 }, vx + vsx * 0.5, vy + vsy * 0.5,
    vx, vy, vsx, vsy) == nil)

local extreme = { x = 0, y = 0, zoom = 1, pitch = 1.15, yaw = 0, fovDist = 900 }
check('unprojection rejects arbitrary screen rays behind the near plane',
  Layout.unproject(extreme, 640, 810, 0, 0, 1280, 800) == nil)
check('unprojection enforces the same minimum depth as projection',
  Layout.unproject({ x = 0, y = 0, zoom = 1, pitch = 0, yaw = 0, fovDist = 30 },
    640, 400, 0, 0, 1280, 800) == nil)
check('unprojection rejects near-horizon rays at maximum tilt',
  Layout.unproject(extreme, 640, 800, 0, 0, 1280, 800) == nil)
local panCam = { x = 0, y = 0, zoom = 1, pitch = 1.15, yaw = 0, fovDist = 900 }
check('pan rejects a drag into the near-horizon exclusion band',
  Layout.pan(panCam, 640, 400, 640, 800, 0, 0, 1280, 800) == false
    and panCam.x == 0 and panCam.y == 0)
check('unprojection rejects non-finite screen coordinates',
  Layout.unproject(extreme, 0 / 0, 400, 0, 0, 1280, 800) == nil)

local function layout (mode, n)
  local nodes = {}
  for i = 1, n do nodes[i] = { id = tostring(i), x = i, y = i } end
  Layout.apply(mode, nodes)
  return nodes
end

for _, mode in ipairs({ 'radial', 'cardinal', 'rectilinear', 'spiral' }) do
  local a, b = layout(mode, 25), layout(mode, 25)
  local same = true
  for i = 1, 25 do
    if a[i].tx ~= b[i].tx or a[i].ty ~= b[i].ty or a[i].tz ~= b[i].tz then same = false end
  end
  check(mode .. ' layout is deterministic', same)
end

local radial = layout('radial', 100)
local minDistance, unique = math.huge, true
for i = 1, #radial do
  for j = i + 1, #radial do
    local dx, dy = radial[i].tx - radial[j].tx, radial[i].ty - radial[j].ty
    local d = math.sqrt(dx * dx + dy * dy)
    minDistance = math.min(minDistance, d)
    if d < 1e-6 then unique = false end
  end
end
check('large radial layouts use separated multi-ring positions',
  unique and minDistance > 20, string.format('100 nodes, min distance %.2f', minDistance))

local logical = layout('spatial', 8)
local collapsed = true
for i = 1, #logical do
  if math.abs(logical[i].tx) > 1e-6 or math.abs(logical[i].ty) > 1e-6 then collapsed = false end
end
check('spatial layout falls back instead of collapsing logical nodes', not collapsed)

local previewPoints = {}
for i = 1, 40 do previewPoints[i] = { x = i, y = i * 0.5, z = -i } end
local preview = Layout.previewOffsets({ layout = 'spatial', points = previewPoints }, 12)
check('preview offsets enforce their point budget', #preview == 12)
local preview2 = Layout.previewOffsets({ layout = 'spatial', points = previewPoints }, 12)
local previewSame = true
for i = 1, #preview do
  if preview[i].dx ~= preview2[i].dx or preview[i].dy ~= preview2[i].dy
     or preview[i].dz ~= preview2[i].dz then previewSame = false end
end
check('preview offsets are deterministic', previewSame)

if failures == 0 then
  print(string.format('holo layout: %d checks passed', checks)); os.exit(0)
end
print(string.format('holo layout: %d/%d checks failed', failures, checks)); os.exit(1)
