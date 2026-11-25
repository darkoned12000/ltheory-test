#!/usr/bin/env luajit
-- Visible bodyless wormholes participate in the same target lock as ships.

local root = (io.popen('pwd'):read('*l') or '.') .. '/'
package.path = root .. 'script/?.lua;' .. package.path

function class (ctor)
  local cls = {}; cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end
function subclass (base, ctor)
  local cls = class(); cls.__index = cls
  return setmetatable(cls, { __index = base, __call = function (T, ...)
    local self = base(); setmetatable(self, T); if ctor then ctor(self, ...) end; return self
  end })
end
function format (f, ...) return string.format(f, ...) end
_G.max, _G.min, _G.abs = math.max, math.min, math.abs
_G.Vec3f = function () return { x = 0, y = 0, z = 0 } end
local Vec2 = {}; Vec2.__index = Vec2
_G.Vec2f = function (x, y) return setmetatable({ x = x or 0, y = y or 0 }, Vec2) end
function Vec2.__sub (a, b) return Vec2f(a.x-b.x, a.y-b.y) end
function Vec2.__add (a, b) return Vec2f(a.x+b.x, a.y+b.y) end
function Vec2:length () return math.sqrt(self.x*self.x + self.y*self.y) end
function Vec2:distance (b) return (self - b):length() end
function Vec2:scale (s) return Vec2f(self.x*s, self.y*s) end
function Vec2:inormalize () local n=self:length(); if n>1e-6 then self.x,self.y=self.x/n,self.y/n end end
function Vec2:idivs (s) self.x,self.y=self.x/s,self.y/s end
_G.Color = function (...) return { ... } end
_G.Time = { GetRaw = function () return 0 end }
_G.Math = { Impact = function () return nil end }
_G.Config = { ui = { showTrackers = true }, game = { dockRange = 500 } }
_G.UI = { Panel = { __index = false } }
UI.Panel.__index = UI.Panel
function UI.Panel:setPadUniform () return self end
for _, name in ipairs({
  'Game.Controls.CameraBindings', 'Game.Cargo', 'Game.Controls.ShipBindings',
  'Game.Components.Dispositions', 'Game.Frustum', 'Game.Radar', 'Game.ScannerDB',
  'Game.Region', 'Game.Seed', 'UI.Container',
}) do package.loaded[name] = {} end
package.loaded['Game.Components.Dispositions'] = { GetColor = function () return { a = 1 } end }
package.loaded['Game.Frustum'] = { getCurrent = function () return nil end }
_G.TrackingList = function () return {} end
_G.List = function () return {} end
_G.DrawEx = setmetatable({}, { __index = function () return function () end end })
UI.DrawEx = DrawEx
_G.DeviceType = { Mouse = 1, Keyboard = 2, Gamepad = 3 }

local Targeting = require('Game.Targeting')
local Info = require('Game.TargetInfo')
local HUD = dofile(root .. 'script/Game/Controls/HUD.lua')

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name)
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end

local gate = {
  isWormhole = true, stableId = 'gate:0:1:1', name = 'Gate to Sector 1',
  getPos = function () return { x = 100, y = 0, z = 0 } end,
  getRadius = function () return 900 end,
  getName = function () return 'Gate to Sector 1' end,
  getPartnerName = function () return 'Sector 1' end,
  getPartnerSector = function () return 1 end,
  hasDockable = function () return true end,
}
check('bodyless wormhole is targetable', Targeting.IsTargetable(gate))
check('deleted wormhole is not targetable', not Targeting.IsTargetable({
  isWormhole = true, deleted = true,
}))
check('wormhole has a readable target name', Info.Name(gate) == 'Gate to Sector 1')
local destinationOk, destination = pcall(function () return Info.Destination(gate) end)
check('wormhole target info exposes its destination', destinationOk and destination == 'Sector 1')
check('wormhole does not show combat disposition', not Info.HasDisposition(gate))

local ship = { getPos = function () return { x = 0, y = 0, z = 0 } end,
  getRadius = function () return 10 end }
local gapOk, gap = pcall(function () return Targeting.SurfaceGap(gate, ship) end)
check('wormhole surface gap supports bodyless geometry', gapOk and gap == 0)

local playerShip = {
  getPos = function () return { x = 0, y = 0, z = 0 } end,
  getRadius = function () return 10 end,
}
local hud = setmetatable({
  player = { getControlling = function () return playerShip end },
  targets = { tracked = { gate } },
  getAimRay = function () return { px = 0, py = 0, pz = 0,
    dirx = 1, diry = 0, dirz = 0, tMin = 0, tMax = 10000 } end,
}, HUD)
local pickOk, picked = pcall(function () return hud:pickTarget() end)
check('HUD target picking supports bodyless wormholes', pickOk and picked == gate)
local locked
function playerShip:setTarget (target) locked = target end
function playerShip:getTarget () return gate end
local bindings = require('Game.Controls.ShipBindings')
bindings.LockTarget = { get = function () return 1 end }
for _, name in ipairs({ 'ClearTarget', 'TargetNearestNpc', 'CycleNpcTarget', 'TargetNearestThreat', 'Scan', 'Mine' }) do
  bindings[name] = { get = function () return 0 end }
end
hud.target = gate
hud.updateInfoPanel = function () end
hud:controlTargetLock(playerShip)
check('T lock assigns a visible wormhole target', locked == gate)
Config.game.autoTarget = true
gate.getOwnerDisposition = function () return 0 end
gate.getVelocity = function () error('bodyless wormhole velocity requested') end
playerShip.iterSocketsByType = function () return function () end end
playerShip.socketRangeMin = 1
hud.usesMouseAim = function () return true end
hud.gameView = { camera = {
  mouseToRay = function () return { getPoint = function () return Vec3f() end } end,
} }
bindings.Fire = { get = function () return 0 end }
package.loaded['Game.SocketKind'] = { Turret = 1 }
local turretControlOk, turretControlErr = pcall(function () hud:controlTurrets(playerShip) end)
check('turret auto-aim ignores bodyless wormholes', turretControlOk, turretControlErr)
local alternate = { hasDockable = function () return true end }
hud.dockable = alternate
local preferredOk, preferred = pcall(function () return hud:preferredDockable(playerShip) end)
check('F prefers the locked wormhole when it is in docking range', preferredOk and preferred == gate)
local farGate = { isWormhole = true, hasDockable = function () return true end,
  getPos = function () return { x = 100000, y = 0, z = 0 } end,
  getRadius = function () return 900 end }
function playerShip:getTarget () return farGate end
check('F does not warp to a distant locked gate', hud:preferredDockable(playerShip) == alternate)

function playerShip:getTarget () return gate end
function playerShip:setTarget () end
playerShip.socketSpeedMax = 1
playerShip.getVelocity = function () return Vec3f() end
hud.sx, hud.sy = 800, 600
hud.gameView = { camera = {
  sx = 800, sy = 600,
  entityToScreenSphere = function () return 350, 250, 100, 100 end,
  worldToNDC = function () return { x = 0, y = 0, z = 1 } end,
  ndcToScreen = function () return Vec2f(400, 300) end,
} }
hud.getAimPoint = function () return Vec2f(400, 300) end
hud.resetNpcBoxes = function (self) self.npcBoxes = {} end
hud.addNpcBox = function () end
hud.updateInfoPanel = function () end
local drawTargetsOk, drawTargetsErr = pcall(function () hud:drawTargets(1) end)
check('HUD passive brackets support bodyless wormholes', drawTargetsOk, drawTargetsErr)
local drawLockOk, drawLockErr = pcall(function () hud:drawLock(1) end)
check('HUD locked bracket supports bodyless wormholes', drawLockOk, drawLockErr)

if failures == 0 then
  print(string.format('wormhole targeting: %d checks passed', checks)); os.exit(0)
else
  print(string.format('wormhole targeting: %d/%d checks failed', failures, checks)); os.exit(1)
end
