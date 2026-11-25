#!/usr/bin/env luajit
-- Shared cargo summary/manifest used by the flight HUD and dock screen.

local root = (io.popen('pwd'):read('*l') or '.') .. '/'
package.path = root .. 'script/?.lua;' .. package.path
local loaded, Cargo = pcall(require, 'Game.Cargo')
if not loaded then
  print('FAIL - cargo presentation module is available')
  os.exit(1)
end

local failures, checks = 0, 0
local function check (name, ok)
  checks = checks + 1
  if ok then print('ok   - ' .. name) else failures = failures + 1; print('FAIL - ' .. name) end
end

local iron = { getName = function () return 'Iron Ore' end, getMass = function () return 4 end }
local copper = { getName = function () return 'Copper Ore' end, getMass = function () return 3 end }
local ship = {
  hasInventory = function () return true end,
  getInventoryCapacity = function () return 100 end,
  getInventoryFree = function () return 55 end,
  getInventory = function () return { [iron] = 5, [copper] = 10 } end,
}
local used, capacity, free = Cargo.Summary(ship)
check('cargo summary reports used capacity', used == 45)
check('cargo summary reports total capacity', capacity == 100)
check('cargo summary reports free capacity', free == 55)
check('cargo summary is human readable', Cargo.FormatSummary(ship) == 'CARGO 45 / 100  FREE 55')
local lines = Cargo.Lines(ship)
check('cargo manifest lists every held item', #lines == 2)
check('cargo manifest is sorted by commodity name', lines[1].name == 'Copper Ore' and lines[2].name == 'Iron Ore')
check('cargo manifest reports count and mass', lines[1].count == 10 and lines[1].mass == 30)

local empty = {
  hasInventory = function () return true end,
  getInventoryCapacity = function () return 100 end,
  getInventoryFree = function () return 100 end,
  getInventory = function () return {} end,
}
check('empty hold has an empty manifest', #Cargo.Lines(empty) == 0)
check('empty hold reports all capacity free', Cargo.FormatSummary(empty) == 'CARGO 0 / 100  FREE 100')

if failures == 0 then
  print(string.format('cargo: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('cargo: %d/%d checks failed', failures, checks))
  os.exit(1)
end
