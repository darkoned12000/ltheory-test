#!/usr/bin/env luajit
-- Real-entity Holo info/action adapter contracts.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_holo_provider%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

local rangeReason = 'You are not within range to perform action.'
_G.Config = { game = { scanRange = 2000, miningRange = 250 } }
package.loaded['Game.TargetInfo'] = {
  Name = function (e) return e.name or 'Object' end,
  Composition = function () return 'Rochalite' end,
  Deposit = function () return '120 / 500' end,
  Shield = function () return '80 / 100' end,
  Destination = function () return 'Aurelia' end,
  SurfaceGap = function (e, ship) return e.gap end,
}
package.loaded['Game.Targeting'] = {
  IsTargetable = function (e) return e and e.body and not e.deleted end,
  SurfaceGap = function (e, ship) return e.gap end,
}

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end
local function finish ()
  if failures == 0 then print(string.format('holo provider: %d checks passed', checks)); os.exit(0) end
  print(string.format('holo provider: %d/%d checks failed', failures, checks)); os.exit(1)
end

local loaded, Provider = pcall(require, 'UI.HoloProvider')
check('HoloProvider module loads', loaded, Provider)
if not loaded then finish() end

local ship = { name = 'Player' }
local player = { getControlling = function () return ship end }
local asteroid = {
  body = {}, name = 'Rich Asteroid', isAsteroid = true, gap = 100,
  health = 50, healthMax = 50,
  hasYield = function () return true end,
}
local asteroidNode = { id = 'rock:1', entity = asteroid, cat = 'rock' }
Provider.Enrich(asteroidNode, player)
check('real entity info uses target identity and exact preview entity',
  asteroidNode.info.title == 'Rich Asteroid'
    and asteroidNode.info.preview.kind == 'mesh'
    and asteroidNode.info.preview.entity == asteroid)
local hasDistance = false
for i = 1, #asteroidNode.info.stats do
  if asteroidNode.info.stats[i].label == 'Distance' then hasDistance = true end
end
check('real entity info includes live navigation stats', hasDistance)

local function action (node, id)
  for i = 1, #node.actions do if node.actions[i].id == id then return node.actions[i] end end
end
check('asteroid actions include goto, target, scan, and mine',
  action(asteroidNode, 'goto') and action(asteroidNode, 'target')
    and action(asteroidNode, 'scan') and action(asteroidNode, 'mine'))
check('in-range scan and mine are enabled',
  action(asteroidNode, 'scan').enabled ~= false and action(asteroidNode, 'mine').enabled ~= false)
asteroid.gap = 3000
Provider.Enrich(asteroidNode, player)
check('out-of-range scan and mine expose the standard reason',
  action(asteroidNode, 'scan').enabled == false and action(asteroidNode, 'scan').reason == rangeReason
    and action(asteroidNode, 'mine').enabled == false and action(asteroidNode, 'mine').reason == rangeReason)

local station = {
  body = {}, name = 'Mining Rig', gap = 100,
  hasDockable = function () return true end,
  hasMarket = function () return true end,
  hasFactory = function () return true end,
  getMarket = function () return { isOpen = function () return true end,
    quotes = function () return { { item = { getName = function () return 'Energy Cells' end } } } end } end,
  getFactory = function () return { prods = {} } end,
}
local stationNode = { id = 'station:1', entity = station, cat = 'station' }
Provider.Enrich(stationNode, player)
check('station actions include dock, trade, and factory',
  action(stationNode, 'dock') and action(stationNode, 'trade') and action(stationNode, 'factory'))
check('station trade submenu is derived from the real market',
  action(stationNode, 'trade').submenu and #action(stationNode, 'trade').submenu.actions >= 1)
station.gap = 1000
Provider.Enrich(stationNode, player)
check('out-of-range dock and trade expose the standard reason',
  action(stationNode, 'dock').enabled == false and action(stationNode, 'dock').reason == rangeReason
    and action(stationNode, 'trade').enabled == false and action(stationNode, 'trade').reason == rangeReason)

local virtual = { id = 'region:1', actions = { { id = 'drill', label = 'Open' } } }
Provider.Enrich(virtual, player)
check('virtual nodes retain provider-owned actions', virtual.actions[1].id == 'drill')

finish()
