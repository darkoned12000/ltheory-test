#!/usr/bin/env luajit
-- Player mining/targeting contract: asteroids are targetable, mining requires
-- a yield and range, and repeated input cannot stack duplicate MineAt actions.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_player_mining%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

function class (ctor)
  local cls = {}
  cls.__index = cls
  setmetatable(cls, { __call = function (T, ...)
    local self = {}
    setmetatable(self, cls)
    if ctor then ctor(self, ...) end
    return self
  end })
  return cls
end
function subclass (base, ctor)
  local cls = {}
  cls.__index = cls
  setmetatable(cls, {
    __call = function (T, ...)
      local self = base()
      setmetatable(self, cls)
      if ctor then ctor(self, ...) end
      return self
    end,
    __index = base,
  })
  return cls
end
function format (f, ...) return string.format(f, ...) end
_G.Config = { game = { miningRange = 250 } }

local Entity = class(function () end)
package.loaded['Game.Entity'] = Entity
package.loaded['Game.Material'] = {}
package.loaded['Game.ShipMovement'] = {}
local Ship = dofile(root .. '/script/Game/Entities/Ship.lua')
local Targeting = require('Game.Targeting')

local created = 0
package.loaded['Game.Actions.MineAt'] = function (target, range)
  created = created + 1
  return { target = target, range = range,
    getName = function () return 'MineAt @ ' .. target:getName() end,
    onStart = function () end, onStop = function () end }
end
package.loaded['Game.Actions.Scan'] = function (target, duration)
  return { target = target, duration = duration,
    getName = function () return 'Scan ' .. target:getName() end,
    onStart = function () end, onStop = function () end }
end
package.loaded['Game.Actions.MoveTo'] = function (target, range)
  return { target = target, range = range,
    getName = function () return 'MoveTo ' .. target:getName() end,
    onStart = function () end, onStop = function () end }
end
package.loaded['Game.Actions.Stop'] = function ()
  return { getName = function () return 'Stop' end,
    onStart = function () end, onStop = function () end }
end

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. detail) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or '')) end
end

_G.DeviceType = { Mouse = 1, Keyboard = 2, Gamepad = 3 }
local aimOk1, keyboardMouseAim = pcall(function () return Targeting.UsesMouseAim(DeviceType.Keyboard) end)
local aimOk2, gamepadMouseAim = pcall(function () return Targeting.UsesMouseAim(DeviceType.Gamepad) end)
check('keyboard keeps mouse-aim semantics', aimOk1 and keyboardMouseAim)
check('gamepad uses stick aim', aimOk2 and not gamepadMouseAim)
local hitOk, hitDistance = pcall(function ()
  return Targeting.RaySphereDistance(0, 0, 0, 1, 0, 0, 10, 0, 0, 2)
end)
check('ray picks the near surface of a sphere', hitOk and hitDistance == 8)
local behindOk, behindDistance = pcall(function ()
  return Targeting.RaySphereDistance(0, 0, 0, 1, 0, 0, -10, 0, 0, 2)
end)
check('ray rejects spheres behind the camera', behindOk and behindDistance == nil)
local missOk, missDistance = pcall(function ()
  return Targeting.RaySphereDistance(0, 0, 0, 1, 0, 0, 10, 5, 0, 2)
end)
check('ray rejects a miss', missOk and missDistance == nil)

local world = { findScanTarget = function (self, scanner) return scanner.scanCandidate end }
local ship = setmetatable({ actions = {}, distance = 100, scannedAsteroids = {},
  getRoot = function () return world end }, Ship)
function ship:isIdle () return #self.actions == 0 end
function ship:getCurrentAction () return self.actions[#self.actions] end
function ship:pushAction (action) self.actions[#self.actions + 1] = action end
function ship:getMinDistance () return self.distance end
function ship:getPos () return { x = 0, y = 0, z = 0 } end
function ship:getTarget () return self.lockedTarget end
local rock = {
  body = {}, isAsteroid = true, hasYield = function () return true end,
  getName = function () return 'Iron Rock' end,
  getPos = function () return { x = ship.distance, y = 0, z = 0 } end,
}
local plain = { body = {}, isAlive = function () return true end, hasYield = function () return false end }
check('live ships are targetable', Targeting.IsTargetable(plain))
check('asteroids with yields are targetable', Targeting.IsTargetable(rock))
check('bodyless targets are rejected', not Targeting.IsTargetable({ hasYield = function () return true end }))
check('ordinary bodies are not auto-targets', not Targeting.IsTargetable({
  body = {}, isAlive = function () return false end, hasYield = function () return false end,
}))
check('planets are targetable', Targeting.IsTargetable({ body = {}, isPlanet = true }))
local inside = Targeting.ScreenScore(100, 100, 80, 80, 40, 40, { x = 100, y = 100 })
check('reticle inside target bounds produces a pick score', inside and inside == 0)
check('reticle outside target bounds is rejected',
  Targeting.ScreenScore(100, 100, 80, 80, 40, 40, { x = 200, y = 200 }) == nil)

ship.distance = 500
check('mining rejects out-of-range targets', not ship:mineTarget(rock) and created == 0)
ship.distance = 100
check('player can start mining a yielded rock', ship:mineTarget(rock) and created == 1)
check('mining action receives configured range', ship.actions[1].range == 250,
  tostring(ship.actions[1].range))
check('player mining actively brakes before extraction', #ship.actions == 2
  and ship:getCurrentAction():getName() == 'Stop')
ship:mineTarget(rock)
check('repeat input does not stack duplicate mining', created == 1 and #ship.actions == 2)
check('non-yield target cannot be mined', not ship:mineTarget(plain))

ship.actions = {}
ship.distance = 100
local scanOk = pcall(function () ship:scanTarget(rock) end)
check('player can scan a targeted asteroid', scanOk and #ship.actions == 1
  and ship.actions[1]:getName():sub(1, 4) == 'Scan')
ship.actions = {}
ship.distance = 5000
local approachOk, approachResult = pcall(function () return ship:scanTarget(rock) end)
check('player scan rejects distant targets without moving', approachOk and not approachResult
  and #ship.actions == 0)
ship.distance = 100
ship.scannedAsteroids = {}
ship.scanCandidate = rock
ship.lockedTarget = nil
local searchOk = pcall(function () return ship:scanForResources() end)
check('player scan search chooses an in-range unscanned candidate', searchOk and #ship.actions == 1)
ship.actions = {}
ship.scannedAsteroids[rock] = true
local rescanOk, rescanResult = pcall(function () return ship:scanTarget(rock) end)
check('player does not rescan the same asteroid', rescanOk and not rescanResult)
ship.distance = 5000
ship.scannedAsteroids = {}
check('scan status explains out-of-range', ship:getScanStatus(rock) == 'out of range')
ship.distance = 1000
check('mining status explains approach distance', ship:getMiningStatus(rock) == 'approach')
ship.distance = 100
ship.getSpeed = function () return 10 end
ship.getForward = function () return { x = 1, y = 0, z = 0 } end
check('mining status requires stopping', ship:getMiningStatus(rock) == 'stop')
ship.getSpeed = function () return 0 end
check('aligned stationary ship is ready to mine', ship:getMiningStatus(rock) == 'ready')
ship.getForward = function () return { x = -1, y = 0, z = 0 } end
check('mining status requires aim alignment', ship:getMiningStatus(rock) == 'align')

ship.actions = {}
ship.distance = 100
ship.getForward = function () return { x = 1, y = 0, z = 0 } end
ship.getSpeed = function () return 10 end
local beforeBrake = created
check('mining input brakes an aligned moving ship in range',
  ship:mineTarget(rock) and created == beforeBrake + 1
  and ship:getCurrentAction():getName() == 'Stop')
ship.actions = {}
ship.getForward = function () return { x = -1, y = 0, z = 0 } end
local brakeOk, brakeReason = ship:mineTarget(rock)
check('mining input still requires alignment before braking',
  not brakeOk and brakeReason == 'align' and #ship.actions == 0)
ship.getForward = function () return { x = 1, y = 0, z = 0 } end
ship.hasInventory = function () return true end
ship.getInventoryCapacity = function () return 100 end
ship.getInventoryFree = function () return 0 end
rock.getYield = function () return { item = { getMass = function () return 5 end } } end
check('full cargo reports why mining cannot start', ship:getMiningStatus(rock) == 'cargo full')

if failures == 0 then
  print(string.format('player mining: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('player mining: %d/%d checks failed', failures, checks))
  os.exit(1)
end
