#!/usr/bin/env luajit
-- Finite asteroid deposits persist by stable key and survive reload/save.

local root = (io.popen('pwd'):read('*l') or '.') .. '/'
package.path = root .. 'script/?.lua;' .. package.path
function class (ctor)
  local cls = {}; cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end
function insert (t, v) t[#t + 1] = v end
local Event = dofile(root .. 'script/Game/Event.lua')
_G.Event = Event
local Entity = dofile(root .. 'script/Game/Entity.lua')
package.loaded['Game.Entity'] = Entity
package.loaded['Game.EconomyRegistry'] = { register = function () end }
dofile(root .. 'script/Game/Components/Yield.lua')

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name)
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or '')) end
end
_G.Config = { game = { depositMin = 120, depositMax = 5000 } }
local item = { getName = function () return 'Iron Ore' end, getMass = function () return 4 end }
local function generatedDeposit (seed, scale)
  local rock = Entity()
  rock.seed, rock.getScale = seed, function () return scale end
  rock:addYield(item, 1)
  return rock:getYieldInitial()
end
if type(Entity().getYieldRemaining) ~= 'function' then
  check('yield exposes finite remaining deposit state', false)
  os.exit(1)
end
local amount = generatedDeposit(12345, 10)
check('default deposit is randomized inside 120-5000', amount >= 120 and amount <= 5000,
  tostring(amount))
check('same asteroid seed and size give the same deposit', generatedDeposit(12345, 10) == amount)
check('larger asteroids bias toward larger deposits', generatedDeposit(12345, 900) >= amount)
check('different asteroid seeds vary deposit size', generatedDeposit(12346, 10) ~= amount)

local rock = Entity()
rock.getScale = function () return 10 end
rock:addYield(item, 1, 60)
check('consuming a deposit returns only available units', rock:consumeYield(20) == 20
  and rock:getYieldRemaining() == 40 and rock:hasYield())
check('depletion stops further extraction', rock:consumeYield(100) == 40
  and rock:getYieldRemaining() == 0 and not rock:hasYield())
check('depleted rock retains composition metadata', rock:getYield().item == item)

local keyed = Entity()
keyed.getScale = function () return 10 end
keyed:addYield(item, 1, 12)
local world = { depositState = { ['rock:1'] = 5 } }
keyed.getRoot = function () return world end
keyed:setDepositKey('rock:1')
check('stable deposit key restores saved remaining amount', keyed:getYieldRemaining() == 5)
keyed:consumeYield(2)
check('consumption updates persistent deposit state', world.depositState['rock:1'] == 3)
local reloaded = Entity()
reloaded.getScale = function () return 10 end
reloaded:addYield(item, 1, 12)
reloaded.getRoot = function () return world end
reloaded:setDepositKey('rock:1')
check('reloaded rock restores the remaining deposit', reloaded:getYieldRemaining() == 3)

if failures == 0 then
  print(string.format('deposits: %d checks passed', checks)); os.exit(0)
else
  print(string.format('deposits: %d/%d checks failed', failures, checks)); os.exit(1)
end
