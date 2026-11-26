#!/usr/bin/env luajit
-- Dock screen exposes repair/refit/purchase services at a shipyard.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_dock_services%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

function class (ctor)
  local cls = {}; cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end
function insert (t, v) t[#t + 1] = v end
function format (f, ...) return string.format(f, ...) end
_G.Color = function (...) return { ... } end
local pushed = {}
local function action (kind)
  return function (...)
    local a = { kind = kind, args = { ... }, getName = function () return kind end }
    pushed[#pushed + 1] = a
    return a
  end
end
_G.requireAll = function ()
  return { Repair = action('Repair'), Refit = action('Refit'), PurchaseShip = action('PurchaseShip'),
    Undock = action('Undock') }
end
for _, name in ipairs({ 'Game.Controls.ShipBindings', 'Game.GUI.Screen',
  'UI.Grid', 'UI.Label', 'UI.MenuButton', 'UI.Table' }) do
  package.loaded[name] = {}
end
local DockScreen = dofile(root .. '/script/Game/GUI/DockScreen.lua')

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name)
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end

local station = { shipyard = true, credits = 500000, getName = function () return 'Yard' end,
  hasDockable = function () return true end,
  getCredits = function (self) return self.credits end,
  hasCredits = function (self, count) return self.credits >= count end,
  removeCredits = function (self, count) self.credits = self.credits - count end }
local ship = { parent = station, actions = {}, shipKind = 'fighter',
  health = 1000, healthMax = 2500, shield = 1000, shieldMax = 2500, credits = 500000,
  getParent = function (self) return self.parent end,
  getCurrentAction = function (self) return self.actions[#self.actions] end,
  pushAction = function (self, a) self.actions[#self.actions + 1] = a end,
  hasHealth = function () return true end,
  hasShield = function () return true end,
  hasSockets = function () return true end,
  getSockets = function () return {} end,
  getShield = function (self) return self.shield end,
  getShieldMax = function (self) return self.shieldMax end,
  getCredits = function (self) return self.credits end,
  hasCredits = function (self, n) return self.credits >= n end,
}
local screen = setmetatable({
  player = { getControlling = function () return ship end },
  refresh = function () end,
}, DockScreen)
local repairFn = screen.repair
check('dock screen has a repair service', repairFn ~= nil)
if repairFn then
  repairFn(screen)
  check('repair service pushes the real Repair action', pushed[#pushed]
    and pushed[#pushed].kind == 'Repair' and pushed[#pushed].args[1] == station)
end
ship.actions = {}
local refitFn = screen.refit
check('dock screen has a refit service', refitFn ~= nil)
if refitFn then
  refitFn(screen, 'turret-mk2', 1)
  check('refit service installs the selected equipment tier in the selected slot',
    pushed[#pushed] and pushed[#pushed].kind == 'Refit'
    and pushed[#pushed].args[1] == station and pushed[#pushed].args[2] == 'Turret'
    and pushed[#pushed].args[3].equipment == 'turret-mk2'
    and pushed[#pushed].args[3].slot == 1 and pushed[#pushed].args[3].replace == true)
end
ship.actions = {}
local buyFn = screen.buyShip
check('dock screen has a ship purchase service', buyFn ~= nil)
if buyFn then
  buyFn(screen, 'capital')
  check('shipyard service pushes PurchaseShip with trade-in', pushed[#pushed]
    and pushed[#pushed].kind == 'PurchaseShip' and pushed[#pushed].args[1] == station
    and pushed[#pushed].args[2].kind == 'capital' and pushed[#pushed].args[2].tradeIn == true)
  for _, kind in ipairs({ 'freighter', 'industrial' }) do
    ship.actions = {}
    buyFn(screen, kind)
    check('shipyard catalog allows player-selected ' .. kind, pushed[#pushed]
      and pushed[#pushed].kind == 'PurchaseShip' and pushed[#pushed].args[2].kind == kind)
  end
  ship.actions = {}
  check('shipyard rejects unknown hulls', buyFn(screen, 'not-a-hull') == false
    and #pushed == 5)
  ship.shipKind, station.credits = 'capital', 0
  check('shipyard rejects a downgrade it cannot fund', buyFn(screen, 'fighter') == false
    and #pushed == 5)
end
station.shipyard = false
local before = #pushed
local ok, err = pcall(function () refitFn(screen) end)
check('non-shipyard docks reject refit without crashing', ok and #pushed == before, err)

ship.actions = {
  { isDockService = true, getName = function () return 'Repair' end },
  { getName = function () return 'Wait' end },
}
check('queued dock service blocks competing services and undock',
  screen:serviceBusy() and screen:undock() == false)
ship.stableId = 'ship:test'
local keyFn = screen.serviceStateKey
local stateKey = keyFn and keyFn(screen, ship)
ship.health = 900
check('passive hull regeneration does not rebuild the whole dock page',
  keyFn and stateKey == keyFn(screen, ship))
ship.credits = 499999
check('wallet changes still refresh the dock page',
  keyFn and stateKey ~= keyFn(screen, ship))

if failures == 0 then
  print(string.format('dock services: %d checks passed', checks)); os.exit(0)
else
  print(string.format('dock services: %d/%d checks failed', failures, checks)); os.exit(1)
end
