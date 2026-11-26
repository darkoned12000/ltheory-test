#!/usr/bin/env luajit
-- Canonical ship equipment definitions and their real stat application.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_ship_equipment%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

function class (ctor)
  local cls = {}; cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then
    print('ok   - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or ''))
  else
    failures = failures + 1
    print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or ''))
  end
end

local function finish ()
  if failures == 0 then
    print(string.format('ship equipment: %d checks passed', checks))
    os.exit(0)
  end
  print(string.format('ship equipment: %d/%d checks failed', failures, checks))
  os.exit(1)
end

local loaded, Equipment = pcall(require, 'Game.ShipEquipment')
check('ShipEquipment module loads', loaded, Equipment)
if not loaded then finish() end
local SocketType = require('Game.SocketKind')

check('thruster tiers are canonical and ordered',
  Equipment.DefaultId(SocketType.Thruster) == 'thruster-mk1'
  and Equipment.NextId('thruster-mk1') == 'thruster-mk2'
  and Equipment.NextId('thruster-mk2') == 'thruster-mk3'
  and Equipment.NextId('thruster-mk3') == nil)
check('turret tiers are canonical and ordered',
  Equipment.DefaultId(SocketType.Turret) == 'turret-mk1'
  and Equipment.NextId('turret-mk1') == 'turret-mk2'
  and Equipment.NextId('turret-mk2') == 'turret-mk3'
  and Equipment.NextId('turret-mk3') == nil)

local turret = {}
check('Mk II turret definition applies to a real module',
  Equipment.Apply(turret, 'turret-mk2') and turret.equipmentId == 'turret-mk2'
  and turret.equipmentTier == 2 and turret.projDamage == 60
  and turret.projRange == 1200 and turret.projSpeed == 750
  and turret.rateOfFire == 10 and turret.projLife == 1.6)
local thruster = {}
check('Mk III thruster definition applies real movement multipliers',
  Equipment.Apply(thruster, 'thruster-mk3') and thruster.equipmentId == 'thruster-mk3'
  and thruster.equipmentTier == 3 and thruster.thrustMultiplier == 1.4
  and thruster.turnMultiplier == 1.25)

local beforeDamage = turret.projDamage
check('unknown equipment fails without partially mutating a module',
  Equipment.Apply(turret, 'not-a-module') == false and turret.projDamage == beforeDamage)
local legacy = {}
check('legacy modules receive their default equipment definition',
  Equipment.Ensure(legacy, SocketType.Turret) and legacy.equipmentId == 'turret-mk1'
  and legacy.projDamage == 40 and legacy.equipmentTier == 1)
local unknown = { equipmentId = 'turret-mk9' }
check('explicit unknown equipment fails closed instead of silently downgrading',
  Equipment.Ensure(unknown, SocketType.Turret) == false
  and unknown.equipmentId == 'turret-mk9' and unknown.projDamage == nil)
local wrongType = { equipmentId = 'thruster-mk2' }
check('explicit equipment for the wrong socket type fails closed',
  Equipment.Ensure(wrongType, SocketType.Turret) == false)
check('equipment labels are readable for shipyard rows',
  Equipment.Label('turret-mk2') == 'Pulse Turret Mk II'
  and Equipment.Label('thruster-mk3') == 'Thruster Mk III')

local aggregate = { sockets = {
  { type = SocketType.Thruster, child = { equipmentId = 'thruster-mk1' } },
  { type = SocketType.Thruster, child = { equipmentId = 'thruster-mk3' } },
  { type = SocketType.Turret, child = { equipmentId = 'turret-mk1', projDamage = 40, rateOfFire = 10 } },
  { type = SocketType.Turret, child = { equipmentId = 'turret-mk2', projDamage = 60, rateOfFire = 10 } },
} }
local factors = type(Equipment.ThrustFactors) == 'function'
  and Equipment.ThrustFactors(aggregate) or nil
check('ship thrust averages installed thrusters without doubling baseline',
  factors ~= nil and factors.thrust == 1.2 and factors.turn == 1.125)
check('ship weapon power sums actual turret damage and fire rate',
  type(Equipment.WeaponDps) == 'function'
  and Equipment.WeaponDps(aggregate) == 1000)

-- Exercise the real Ship:getTopSpeed consumer with only its rendering/physics
-- dependencies stubbed; movement and equipment remain production code.
function subclass (base, ctor)
  local cls = {}; cls.__index = cls
  return setmetatable(cls, { __index = base, __call = function (T, ...)
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end
local Entity = class(); package.loaded['Game.Entity'] = Entity
package.loaded['Game.Material'] = {}
package.loaded['Game.Registry'] = {}
package.loaded['Game.Targeting'] = {}
package.loaded['Game.Knowledge'] = { Create = function () return {} end }
local Ship = dofile(root .. '/script/Game/Entities/Ship.lua')
local moving = setmetatable({
  radius = 10, inventoryCapacity = 100, inventoryFree = 100,
  sockets = aggregate.sockets,
}, Ship)
function moving:getRadius () return self.radius end
function moving:hasInventory () return true end
function moving:getInventoryCapacity () return self.inventoryCapacity end
function moving:getInventoryFree () return self.inventoryFree end
check('equipped thruster tier changes the real ship top-speed estimate',
  moving:getTopSpeed() == 600)

finish()
