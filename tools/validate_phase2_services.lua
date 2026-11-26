#!/usr/bin/env luajit
-- Phase 2 shipyard economy: canonical hull prices, service costs, real refits,
-- and condition-adjusted trade-in quotes.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_phase2_services%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

function class (ctor)
  local cls = {}; cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end
function insert (t, value) t[#t + 1] = value end

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
    print(string.format('phase 2 services: %d checks passed', checks))
    os.exit(0)
  end
  print(string.format('phase 2 services: %d/%d checks failed', failures, checks))
  os.exit(1)
end

local Archetypes = require('Game.ShipArchetypes')
local Progression = require('Game.NpcProgression')
local SocketType = require('Game.SocketKind')

check('shipyard catalog has one stable entry per canonical hull',
  Archetypes.Order ~= nil
  and table.concat(Archetypes.Order, ',') == 'fighter,freighter,industrial,capital')
check('hull purchase prices use the tuned progression economy',
  Progression.ShipCost({}, 'fighter') == 18000
  and Progression.ShipCost({}, 'freighter') == 55000
  and Progression.ShipCost({}, 'industrial') == 95000
  and Progression.ShipCost({}, 'capital') == 280000)

local function ship (kind, hull, shield, shieldMax)
  local def = Archetypes.Get(kind)
  local maximumShield = shieldMax or def.shield
  local currentShield = shield == nil and maximumShield or shield
  return {
    shipKind = kind,
    health = hull or def.health,
    healthMax = def.health,
    hasHealth = function () return true end,
    hasShield = function () return true end,
    getShield = function () return currentShield end,
    getShieldMax = function () return maximumShield end,
    getSockets = function (self) return self.sockets or {} end,
    isAlive = function () return true end,
  }
end

check('full repair is a bounded fraction of hull value',
  Progression.RepairCost(ship('fighter', 0, 0)) == 2160
  and Progression.RepairCost(ship('freighter', 0, 0)) == 8250
  and Progression.RepairCost(ship('industrial', 0, 0)) == 17100
  and Progression.RepairCost(ship('capital', 0, 0)) == 56000)
check('repair speed scales by hull class without restoring two pools twice',
  Progression.RepairRate(ship('fighter')) == 2500 / 60
  and Progression.RepairRate(ship('capital')) == 150000 / 150)
check('upkeep is affordable and derived from hull value',
  Progression.Upkeep(ship('fighter'), 3600) == 4
  and Progression.Upkeep(ship('freighter'), 3600) == 11
  and Progression.Upkeep(ship('industrial'), 3600) == 19
  and Progression.Upkeep(ship('capital'), 3600) == 56)

check('trade-in value includes hull and shield condition',
  type(Progression.TradeInValue) == 'function'
  and Progression.TradeInValue(ship('fighter')) == 6300
  and Progression.TradeInValue(ship('fighter', 1250, 2500, 2500)) == 4725)
local upgrade = type(Progression.PurchaseQuote) == 'function'
  and Progression.PurchaseQuote(ship('fighter'), 'capital', true) or nil
check('upgrade quote applies trade-in as a discount',
  upgrade ~= nil and upgrade.price == 280000 and upgrade.tradeIn == 6300
  and upgrade.due == 273700 and upgrade.excess == 0)
local downgrade = type(Progression.PurchaseQuote) == 'function'
  and Progression.PurchaseQuote(ship('capital'), 'fighter', true) or nil
check('downgrade quote returns trade-in excess instead of losing it',
  downgrade ~= nil and downgrade.price == 18000 and downgrade.tradeIn == 98000
  and downgrade.due == 0 and downgrade.excess == 80000)
local fullPrice = type(Progression.PurchaseQuote) == 'function'
  and Progression.PurchaseQuote(ship('fighter'), 'freighter', false) or nil
check('purchase without trade-in charges the full hull price',
  fullPrice ~= nil and fullPrice.due == 55000)

local refit = ship('industrial')
refit.sockets = {
  { type = SocketType.Thruster, typeIndex = 1, child = { equipmentId = 'thruster-mk1', equipmentTier = 1 } },
  { type = SocketType.Thruster, typeIndex = 2, child = { equipmentId = 'thruster-mk2', equipmentTier = 2 } },
}
check('refit policy upgrades the lagging module rather than a maxed ship',
  type(Progression.NextEquipment) == 'function'
  and Progression.NextEquipment(refit, SocketType.Thruster) == 'thruster-mk2'
  and Progression.NeedsRefit(refit, 100000))
refit.sockets[1].child.equipmentId, refit.sockets[1].child.equipmentTier = 'thruster-mk3', 3
refit.sockets[2].child.equipmentId, refit.sockets[2].child.equipmentTier = 'thruster-mk3', 3
check('fully upgraded ships do not request another refit',
  type(Progression.NextEquipment) == 'function'
  and Progression.NextEquipment(refit, SocketType.Thruster) == nil
  and not Progression.NeedsRefit(refit, 100000))
local noSocket = ship('industrial')
check('a hull without the preferred socket does not request an impossible refit',
  Progression.NextEquipment(noSocket, SocketType.Thruster) == nil
  and not Progression.NeedsRefit(noSocket, 100000))
check('refit price includes the selected equipment tier',
  Progression.RefitCost(refit, SocketType.Thruster, 0, 'thruster-mk2') == 2700)

finish()
