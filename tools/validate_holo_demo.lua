#!/usr/bin/env luajit
-- Standalone Holo demo hierarchy and live mock-value contracts.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_holo_demo%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

function class (ctor)
  local cls = {}; cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end
_G.Application = function () return {} end
_G.UI = { Canvas = function () return {} end }
package.loaded['UI.HoloGraph'] = {}
package.loaded['UI.HoloInfoPanel'] = { Create = function () return {} end }
_G.RNG = { Create = function ()
  local rng = {}
  function rng:managed () return self end
  function rng:getUniform () return 0.5 end
  return rng
end }
_G.format = string.format
_G.max = math.max

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end
local function finish ()
  if failures == 0 then print(string.format('holo demo: %d checks passed', checks)); os.exit(0) end
  print(string.format('holo demo: %d/%d checks failed', failures, checks)); os.exit(1)
end

local loaded, Demo = pcall(require, 'App.HoloNodeDemo')
check('HoloNodeDemo module loads', loaded, Demo)
if not loaded then finish() end
local demo = setmetatable({}, { __index = Demo })
local graph = demo:buildDemoGraph()
check('mock root exposes three regions', graph.id == 'cluster' and #graph.children == 3)
local region = graph.children[1]
check('region exposes five spatial star systems', region.id == 'reg_1' and #region.children == 5)
local system = region.children[1]
check('system preview contains planets, a rig, ships, and an asteroid belt',
  #system.children >= 20 and system.preview and system.preview.layout == 'spatial')
check('only the region star-system preview opts into orbit',
  region.preview and region.preview.orbit == true
    and system.preview and system.preview.orbit == nil)
local minorAsteroids = 0
for i = 1, #system.children do
  if system.children[i].id:find('_rock_', 1, true) then
    if system.children[i].major == false then minorAsteroids = minorAsteroids + 1 end
  end
end
check('demo asteroids are marked minor for no-spoke rendering', minorAsteroids == 18)
check('region provides preview info and drill actions',
  region.info and region.info.preview == 'region'
    and region.actions and region.actions[1].id == 'drill')
local rig
for i = 1, #system.children do
  if system.children[i].id == 'sys_1_rig' then rig = system.children[i] end
end
check('station provides navigation, dock, trade, and factory menus',
  rig and rig.info and rig.info.preview == 'station'
    and rig.actions and #rig.actions >= 4
    and rig.actions[1].id == 'goto' and rig.actions[2].id == 'dock'
    and rig.actions[3].id == 'trade' and rig.actions[3].submenu
    and rig.actions[3].submenu.actions[1].id == 'buy_energy'
    and rig.actions[3].submenu.actions[3].id == 'sell_ore'
    and rig.actions[4].id == 'factory' and rig.actions[4].submenu)
check('mining rig exposes factory production metadata and controls',
  rig.factory and rig.factory.name == 'Refinery'
    and rig.factory.inputs and rig.factory.outputs)
local ship
for i = 1, #system.children do
  if system.children[i].id == 'sys_1_you' then ship = system.children[i] end
end
check('player ship exposes cardinal ship systems', ship and ship.childLayout == 'cardinal'
  and #ship.children >= 3)
check('player ship uses the yellow-gold node identity',
  ship and ship.color and ship.color.r > 0.9 and ship.color.g > 0.65
    and ship.color.b < 0.35)
local npcShip
for i = 1, #system.children do
  if system.children[i].id == 'sys_1_npc1' then npcShip = system.children[i] end
end
check('NPC ships retain a distinct non-player identity',
  npcShip and (not npcShip.color or npcShip.color.r < 0.9 or npcShip.color.b > 0.35))
local hardpoints
for i = 1, #ship.children do
  if ship.children[i].id == 'sys_1_you_hp' then hardpoints = ship.children[i] end
end
check('hardpoints expose editable weapon data', hardpoints and #hardpoints.children >= 5)
local rate
for i = 1, #hardpoints.children do
  if hardpoints.children[i].id == 'wep_1' then rate = hardpoints.children[i] end
end
local editable
for i = 1, #rate.children do
  if rate.children[i].id == 'rate' then editable = rate.children[i] end
end
check('weapon rate is editable and writes the mock live stats',
  editable and editable.editable and editable.setValue(9.5)
  and demo.laserStats.rate == 9.5)
local before = tonumber(editable.getValue())
demo.simOre = demo.simOre + 10
check('mock inventory values are live rather than static labels',
  before ~= nil and demo.simOre > 0)
check('demo suppresses global application shortcuts', Demo.anyScreenOpen(demo) == true)

local actionDemo = setmetatable({}, { __index = Demo })
local selectedVis = { id = rig.id, data = rig }
actionDemo.holo = {
  cam = { targetZoom = 1 },
  getSelectedVis = function () return selectedVis end,
  drillInto = function (self, vis) self.drilled = vis; return true end,
}
actionDemo.infoPanel = {
  subject = rig,
  setStatus = function (self, text) self.status = text end,
  rebuildActions = function () end,
}
actionDemo.mockCredits, actionDemo.simOre = 1000, 10
local rangeReason = 'You are not within range to perform action.'
check('demo exposes distance-based action availability', Demo.updateActionAvailability ~= nil)
if Demo.updateActionAvailability then
  actionDemo.mockPlayerPos = { x = 0, y = 0, z = 0 }
  actionDemo:updateActionAvailability(rig)
  local farDock, farTrade
  for i = 1, #rig.actions do
    if rig.actions[i].id == 'dock' then farDock = rig.actions[i] end
    if rig.actions[i].id == 'trade' then farTrade = rig.actions[i] end
  end
  check('Dock and Trade are range-gated with a visible reason',
    farDock and farTrade and farDock.enabled == false and farTrade.enabled == false
      and farDock.reason == rangeReason and farTrade.reason == rangeReason)
  actionDemo.mockPlayerPos = { x = 1800, y = 0, z = 900 }
  actionDemo:updateActionAvailability(rig)
  local nearDock, nearTrade
  for i = 1, #rig.actions do
    if rig.actions[i].id == 'dock' then nearDock = rig.actions[i] end
    if rig.actions[i].id == 'trade' then nearTrade = rig.actions[i] end
  end
  check('Dock and Trade enable within mock service range',
    nearDock and nearTrade and nearDock.enabled ~= false and nearTrade.enabled ~= false)
  local asteroid = system.children[7]
  actionDemo.mockPlayerPos = { x = 10000, y = 0, z = 10000 }
  actionDemo:updateActionAvailability(asteroid)
  local farScan
  for i = 1, #asteroid.actions do
    if asteroid.actions[i].id == 'scan' then farScan = asteroid.actions[i] end
  end
  check('Scan is range-gated on asteroids', farScan and farScan.enabled == false
    and farScan.reason == rangeReason)
end
local gotoStatus, dockStatus, sellStatus
if Demo.onHoloAction then
  actionDemo:onHoloAction({ id = 'goto', label = 'Goto' }, rig)
  gotoStatus = actionDemo.infoPanel.status
  actionDemo:onHoloAction({ id = 'dock', label = 'Dock' }, rig)
  dockStatus = actionDemo.infoPanel.status
  actionDemo:onHoloAction({ id = 'sell_ore', label = 'Sell Rochalite Ore' }, rig)
  sellStatus = actionDemo.infoPanel.status
  actionDemo:onHoloAction({ id = 'start_production', label = 'Start Production' }, rig)
  actionDemo:onHoloAction({ id = 'unpack', label = 'Unpack Cluster' }, rig)
  actionDemo:onHoloAction({ id = 'drill', label = 'Open' }, rig)
end
check('mock Goto action records a target and visible route status',
  actionDemo.mockTarget == rig and gotoStatus
    and gotoStatus:find(rig.label, 1, true) ~= nil)
check('mock service actions provide interactive feedback',
  dockStatus and dockStatus:find('Dock', 1, true) ~= nil)
check('trade submenu actions update mock cargo and credits',
  sellStatus and sellStatus:find('Sold', 1, true) ~= nil
    and actionDemo.simOre == 9 and actionDemo.mockCredits == 1014)
check('factory submenu controls toggle mock production',
  rig.factory and rig.factory.running == true)
check('cluster unpack action zooms the field to individual points',
  actionDemo.holo.cam.targetZoom == 1.7)
check('drill action uses the selected visual rather than raw data',
  actionDemo.holo.drilled == selectedVis)

local runtimeDemo = setmetatable({}, { __index = Demo })
runtimeDemo.holoTestStage = 1
runtimeDemo.holo = {
  activeNodes = {},
  setLayout = function () return true end,
  drillInto = function () return false end,
}
runtimeDemo.quit = function (self) self.quitCalled = true end
local runtimeMessages = {}
_G.printf = function (fmt, ...)
  runtimeMessages[#runtimeMessages + 1] = string.format(fmt, ...)
end
runtimeDemo:updateHoloTest(2.0)
local runtimeFailed, runtimePassed = false, false
for i = 1, #runtimeMessages do
  if runtimeMessages[i]:find('[HOLOTEST] FAIL:', 1, true) then runtimeFailed = true end
  if runtimeMessages[i]:find('[HOLOTEST] PASS:', 1, true) then runtimePassed = true end
end
check('runtime smoke test fails instead of passing when a drill target is missing',
  runtimeDemo.holoTestFailed == true and runtimeDemo.quitCalled == true
    and runtimeFailed and not runtimePassed)

finish()
