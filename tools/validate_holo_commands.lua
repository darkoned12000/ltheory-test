#!/usr/bin/env luajit
-- App-level Holo menu command routing and range contracts.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_holo_commands%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

local rangeReason = 'You are not within range to perform action.'
_G.Config = { game = { scanRange = 2000, miningRange = 250 } }
package.loaded['Game.Targeting'] = {
  IsTargetable = function (e) return e and e.body and not e.deleted end,
  SurfaceGap = function (e, ship) return e.gap end,
}
package.loaded['Game.Actions.TargetValidity'] = { Usable = function (e) return e and e.usable ~= false end }
package.loaded['Game.Actions.MoveTo'] = function (target, range)
  return { kind = 'MoveTo', target = target, range = range }
end
package.loaded['Game.Actions.DockAt'] = function (target) return { kind = 'DockAt', target = target } end
package.loaded['Game.Actions.TravelTo'] = function (target) return { kind = 'TravelTo', target = target } end
package.loaded['Game.Actions.Scan'] = function (target) return { kind = 'Scan', target = target } end
package.loaded['Game.Actions.MineAt'] = function (target, range)
  return { kind = 'MineAt', target = target, range = range }
end

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end
local function finish ()
  if failures == 0 then print(string.format('holo commands: %d checks passed', checks)); os.exit(0) end
  print(string.format('holo commands: %d/%d checks failed', failures, checks)); os.exit(1)
end

local loaded, Commands = pcall(require, 'Game.HoloCommands')
check('HoloCommands module loads', loaded, Commands)
if not loaded then finish() end

local pushed, targeted = {}, nil
local ship = {
  pushAction = function (self, action) pushed[#pushed + 1] = action end,
  setTarget = function (self, target) targeted = target end,
  getParent = function () return nil end,
  scanTarget = function (self, target) pushed[#pushed + 1] = { kind = 'ShipScan', target = target }; return true end,
  mineTarget = function (self, target) pushed[#pushed + 1] = { kind = 'ShipMine', target = target }; return true end,
}
local dockScreen = { opened = 0, refreshed = 0 }
function dockScreen:refresh () self.refreshed = self.refreshed + 1 end
function dockScreen:open () self.opened = self.opened + 1 end
local app = { player = { getControlling = function () return ship end }, dockScreen = dockScreen }
local commands = Commands.Create(app)
local asteroid = { body = {}, gap = 100, usable = true, isAsteroid = true,
  hasYield = function () return true end }
local node = { entity = asteroid }

local ok, why = commands:execute({ id = 'goto', range = 100 }, node)
check('Goto validates and pushes MoveTo without teleporting',
  ok and #pushed == 1 and pushed[1].kind == 'MoveTo' and pushed[1].range == 100
    and targeted == asteroid, tostring(why))
ok, why = commands:execute({ id = 'goto' }, { id = 'virtual' })
check('virtual nodes cannot receive physical Goto commands', ok == false)

local station = { body = {}, gap = 100, usable = true,
  hasDockable = function () return true end,
  hasMarket = function () return true end,
  getMarket = function () return { isOpen = function () return true end } end }
local stationNode = { entity = station }
pushed = {}
ok, why = commands:execute({ id = 'dock' }, stationNode)
check('in-range Dock pushes DockAt', ok and #pushed == 1 and pushed[1].kind == 'DockAt')
station.gap = 1000
pushed = {}
ok, why = commands:execute({ id = 'dock' }, stationNode)
check('out-of-range Dock is rejected before action creation',
  ok == false and why == rangeReason and #pushed == 0)
ok, why = commands:execute({ id = 'trade' }, stationNode)
check('out-of-range Trade uses the standard range message', ok == false and why == rangeReason)
station.gap = 100
ok, why = commands:execute({ id = 'trade' }, stationNode)
check('Trade requires docking even within service range',
  ok == false and why == 'Dock to trade.' and dockScreen.opened == 0)
ship.getParent = function () return station end
ok, why = commands:execute({ id = 'trade' }, stationNode)
check('docked Trade opens the existing market screen',
  ok and dockScreen.opened == 1 and dockScreen.refreshed == 1)

pushed = {}
asteroid.gap = 3000
ok, why = commands:execute({ id = 'scan' }, node)
check('Scan command enforces range before using ship logic',
  ok == false and why == rangeReason and #pushed == 0)
asteroid.gap = 100
ok, why = commands:execute({ id = 'scan' }, node)
check('in-range Scan uses the ship scan workflow',
  ok and #pushed == 1 and pushed[1].kind == 'ShipScan')
ok, why = commands:execute({ id = 'mine' }, node)
check('in-range Mine uses the ship mining workflow',
  ok and #pushed == 2 and pushed[2].kind == 'ShipMine')

local gate = { body = {}, gap = 0, usable = true, isWormhole = true }
pushed = {}
ok, why = commands:execute({ id = 'travel' }, { entity = gate })
check('wormhole travel uses TravelTo', ok and #pushed == 1 and pushed[1].kind == 'TravelTo')

finish()
