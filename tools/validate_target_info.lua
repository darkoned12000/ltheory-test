#!/usr/bin/env luajit
-- Target-specific information labels and asteroid composition disclosure.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_target_info%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path
local Info = require('Game.TargetInfo')

local failures, checks = 0, 0
local function check (name, ok)
  checks = checks + 1
  if ok then print('ok   - ' .. name) else failures = failures + 1; print('FAIL - ' .. name) end
end

local asteroid = {
  isAsteroid = true, health = 3272, healthMax = 3272,
  getName = function () return 'Entity @ 0x7f76940691d0' end,
  hasYield = function () return true end,
  getYield = function () return { item = { getName = function () return 'Iron Ore' end } } end,
  getYieldRemaining = function () return 17 end,
  getYieldInitial = function () return 60 end,
}
check('asteroid has a readable name', Info.Name(asteroid) == 'Asteroid')
check('unscanned asteroid composition is unknown', Info.Composition(asteroid, nil) == 'Unknown')
check('scanned asteroid reveals mineral composition',
  Info.Composition(asteroid, { tier = 4, yieldIdentified = true, yieldItem = 'Iron Ore' }) == 'Iron Ore')
check('passive close-range contact does not reveal mineral composition',
  Info.Composition(asteroid, { tier = 4, yieldIdentified = false, yieldItem = 'Iron Ore' }) == 'Unknown')
check('asteroid does not show disposition', not Info.HasDisposition(asteroid))
local depositOk, depositText = pcall(function ()
  return Info.Deposit(asteroid, { yieldIdentified = true })
end)
check('scanned asteroid shows remaining deposit', depositOk and depositText == '17 / 60')
asteroid.getYieldRemaining = function () return 0 end
check('depleted asteroid composition is labeled depleted',
  Info.Composition(asteroid, { tier = 4, yieldIdentified = true, yieldItem = 'Iron Ore' }) == 'Depleted')
local depletedOk, depletedText = pcall(function ()
  return Info.Deposit(asteroid, { yieldIdentified = true })
end)
check('depleted asteroid shows depleted remaining amount', depletedOk and depletedText == 'Depleted')

local ship = {
  hasSockets = function () return true end,
  getRegistryName = function (self, full) return full and 'Δ LimTech Freighter Y150' or 'Freighter' end,
}
check('ship uses registry name', Info.Name(ship) == 'Freighter')
check('ship shows disposition', Info.HasDisposition(ship))
check('ship has no asteroid composition', Info.Composition(ship, nil) == nil)

local planet = { isPlanet = true, typeName = 'ice', getName = function () return 'Entity @ 0x1234' end }
check('planet has a readable type name', Info.Name(planet) == 'Ice Planet')
local rawMesh = { getVertexCount = function () return 3 end }
local lodMesh = { get = function (self, index) return index == 0 and rawMesh or nil end }
check('target preview resolves asteroid LOD to raw mesh',
  Info.ResolveMesh({ mesh = lodMesh }) == rawMesh)
local callableGet = setmetatable({}, { __call = function (_, mesh, index)
  return index == 0 and rawMesh or nil
end })
local callableLod = setmetatable({}, { __index = function () return callableGet end })
check('target preview accepts callable non-function LOD accessors',
  Info.ResolveMesh({ mesh = callableLod }) == rawMesh)
local ffi = require('ffi')
ffi.cdef [[ typedef struct Mesh { int dummy; } Mesh; ]]
local nativeMesh = ffi.new('struct Mesh')
local nativeOk, nativeResolved = pcall(function () return Info.ResolveMesh({ mesh = nativeMesh }) end)
check('raw FFI mesh does not crash preview resolution',
  nativeOk and nativeResolved == nativeMesh)
local ship = { getPos = function () return { x = 0, y = 0, z = 0 } end,
  getRadius = function () return 10 end }
local closeRock = { getPos = function () return { x = 347, y = 0, z = 0 } end,
  getRadius = function () return 252 end }
local gapOk, gap = pcall(function () return Info.SurfaceGap(closeRock, ship) end)
check('target info exposes surface gap separately from center distance',
  gapOk and gap == 85)

if failures == 0 then
  print(string.format('target info: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('target info: %d/%d checks failed', failures, checks))
  os.exit(1)
end
