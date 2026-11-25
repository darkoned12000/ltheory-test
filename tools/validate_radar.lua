#!/usr/bin/env luajit
-- Pure radar projection and scanner-spectrum math.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_radar%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path
local Radar = require('Game.Radar')

local Vec = {}
Vec.__index = Vec
local function vec (x, y, z) return setmetatable({ x = x, y = y, z = z }, Vec) end
function Vec:dot (b) return self.x*b.x + self.y*b.y + self.z*b.z end

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. detail) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or '')) end
end

local right, forward = vec(1, 0, 0), vec(0, 0, -1)
local blip = Radar.Blip(vec(0, 0, -1000), right, forward, 50000, 80)
check('radar places forward contacts above center', blip and math.abs(blip.x) < 1e-6
  and blip.y < 0)
local side = Radar.Blip(vec(1000, 0, 0), right, forward, 50000, 80)
check('radar places starboard contacts right', side and side.x > 0 and math.abs(side.y) < 1e-6)
check('radar rejects contacts beyond range', Radar.Blip(vec(60000, 0, 0), right, forward, 50000, 80) == nil)
local edge = Radar.Blip(vec(50000, 0, 0), right, forward, 50000, 80)
check('radar clamps range edge to circumference', edge and math.abs(edge.x - 80) < 1e-6)

local origin = vec(0, 0, 0)
local contacts = {
  { key = 'contact:a', position = { x = 0, y = 0, z = -1000 }, tier = 4 },
  { key = 'contact:b', position = { x = 20000, y = 0, z = 0 }, tier = 1 },
}
local spectrum = Radar.Spectrum(contacts, origin, 10, 64)
check('spectrum has requested bar count', #spectrum == 64)
local peak, floorValue, bounded = 0, 1, true
for _, value in ipairs(spectrum) do
  peak = math.max(peak, value)
  floorValue = math.min(floorValue, value)
  if value < 0 or value > 1 then bounded = false end
end
check('spectrum values stay bounded', bounded)
check('resolved contact creates a visible peak', peak > floorValue + 0.1,
  string.format('peak=%.3f floor=%.3f', peak, floorValue))
local again = Radar.Spectrum(contacts, origin, 10, 64)
local same = true
for i = 1, #spectrum do if spectrum[i] ~= again[i] then same = false end end
check('spectrum is deterministic for fixed contacts/time', same)
local behind = { { key = 'behind', signal = 'ship', tier = 4,
  position = { x = 0, y = 0, z = 1000 } } }
local behindValues = Radar.Spectrum(behind, origin, 10, 32, vec(0, 0, -1), 0.7)
local behindPeak, behindFloor = 0, 1
for _, value in ipairs(behindValues) do
  behindPeak = math.max(behindPeak, value); behindFloor = math.min(behindFloor, value)
end
check('spectrum ignores contacts outside the forward sensor cone',
  behindPeak - behindFloor < 0.05)
local bandOk, starBand = pcall(function () return Radar.SignalBand('star') end)
check('object classes have distinct scanner frequency bands', bandOk
  and starBand > Radar.SignalBand('ore') and starBand > Radar.SignalBand('ship'))
check('radar scale is bounded', Radar.ClampScale(0.1) == 0.5
  and Radar.ClampScale(3) == 2 and Radar.ClampScale(1) == 1)
check('radar hit testing supports UI interaction', Radar.Contains(100, 100, 50, 120, 100)
  and not Radar.Contains(100, 100, 50, 200, 100))
check('radar category filters default visible', Radar.ShowSignal('ore', nil)
  and Radar.ShowSignal('ship', nil))
check('radar category filters can hide object types',
  not Radar.ShowSignal('ore', { asteroids = false, ships = true })
  and Radar.ShowSignal('ship', { asteroids = false, ships = true }))
local rangeOk, rangeLabel = pcall(function () return Radar.FormatRange(37500) end)
check('radar formats ring distances for display', rangeOk and rangeLabel == '37.5 km')
local yieldedRock = { isAsteroid = true, hasYield = function () return true end }
local barrenRock = { isAsteroid = true, hasYield = function () return false end }
local signalOk1, yieldedSignal = pcall(function () return Radar.SignalFor(yieldedRock) end)
local signalOk2, barrenSignal = pcall(function () return Radar.SignalFor(barrenRock) end)
check('yielded asteroid has ore signal', signalOk1 and yieldedSignal == 'ore')
check('barren asteroid has asteroid signal', signalOk2 and barrenSignal == 'asteroid')
check('asteroid filter covers ore and barren rocks',
  Radar.ShowSignal('ore', { asteroids = true })
  and Radar.ShowSignal('asteroid', { asteroids = true })
  and not Radar.ShowSignal('ore', { asteroids = false })
  and not Radar.ShowSignal('asteroid', { asteroids = false }))
local crowded = {}
for i = 1, 70 do crowded[i] = { key = 'ship:' .. i, signal = 'ship', distance2 = i } end
crowded[#crowded + 1] = { key = 'ore:near', signal = 'ore', distance2 = 100 }
local selectOk, selected = pcall(function () return Radar.SelectContacts(crowded, 64) end)
local selectedShips, selectedOre = 0, 0
if selectOk then
  for _, contact in ipairs(selected) do
    if contact.signal == 'ship' then selectedShips = selectedShips + 1 end
    if contact.signal == 'ore' then selectedOre = selectedOre + 1 end
  end
end
check('radar reserves room for asteroids in crowded fields',
  selectOk and selectedOre == 1 and selectedShips <= 12 and #selected <= 64)

if failures == 0 then
  print(string.format('radar: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('radar: %d/%d checks failed', failures, checks))
  os.exit(1)
end
