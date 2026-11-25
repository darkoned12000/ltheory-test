#!/usr/bin/env luajit
-- Heavy-hull profile shaping before finalize: aspect + predictable base radius.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_ship_generator_profile%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path
for _, name in ipairs({
  'Gen.ShapeLib.Shape', 'Gen.ShapeLib.BasicShapes', 'Gen.ShapeLib.RandomShapes',
  'Gen.ShipLib.ShipWarps', 'Gen.ShipLib.ShipDetail', 'Gen.ShipLib.ShipCapitalHull',
  'Gen.ShipLib.ShipCapitalCockpit', 'Gen.ShapeLib.Warp', 'Gen.MathUtil',
  'Gen.ShapeLib.Parametric',
}) do package.loaded[name] = {} end
local Capital = dofile(root .. '/script/Gen/ShipCapital.lua')

local failures, checks = 0, 0
local function check (name, ok)
  checks = checks + 1
  if ok then print('ok   - ' .. name) else failures = failures + 1; print('FAIL - ' .. name) end
end

local shape = { scales = {}, centered = false }
function shape:scale (x, y, z) self.scales[#self.scales + 1] = { x, y, z }; return self end
function shape:center () self.centered = true; return self end
function shape:getAABB ()
  return { lower = { x = -2, y = -1, z = -3 }, upper = { x = 2, y = 1, z = 3 } }
end
local ok, result = pcall(function ()
  return Capital.ApplyProfile(shape, { aspect = { 0.85, 0.85, 1.35 }, radius = 3 })
end)
check('heavy hull profile can be applied', ok and result == shape, tostring(result))
check('profile applies aspect before finalize', shape.scales[1]
  and shape.scales[1][1] == 0.85 and shape.scales[1][3] == 1.35)
check('profile centers before normalization', shape.centered)
check('profile normalizes to requested base radius', shape.scales[2]
  and math.abs(shape.scales[2][1] - 3 / (math.sqrt(56) / 2)) < 1e-6)

if failures == 0 then
  print(string.format('ship generator profile: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('ship generator profile: %d/%d checks failed', failures, checks))
  os.exit(1)
end
