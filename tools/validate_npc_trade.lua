#!/usr/bin/env luajit
-- Trader purchase atomicity: no cargo space or no credits means no charge and
-- no consumed ask. Exercises the real Trader and Inventory components.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_trade%.lua$', '')
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
function insert (t, v) t[#t + 1] = v end
function remove (t, index)
  index = index or #t
  t[index] = t[#t]
  t[#t] = nil
end

local Event = dofile(root .. '/script/Game/Event.lua')
_G.Event = Event
local Entity = dofile(root .. '/script/Game/Entity.lua')
package.loaded['Game.Entity'] = Entity
for _, name in ipairs({ 'Assets', 'Inventory', 'Owner' }) do
  dofile(root .. '/script/Game/Components/' .. name .. '.lua')
end
local Credit = { getMass = function () return 0 end }
local Ore = { getMass = function () return 1 end }
_G.Item = { Credit = Credit }
package.loaded['Game.Item'] = _G.Item
package.loaded['Game.EconomyRegistry'] = { register = function () end }
package.loaded['Game.PriceCurve'] = {}
dofile(root .. '/script/Game/Components/Trader.lua')

local failures, checks = 0, 0
local function check (name, ok)
  checks = checks + 1
  if ok then print('ok   - ' .. name) else failures = failures + 1; print('FAIL - ' .. name) end
end

local function fixture (capacity, credits)
  local owner = Entity()
  owner:addAssets()
  owner:addInventory(0)
  owner:addItem(Credit, credits)
  local asset = Entity()
  asset:addInventory(capacity)
  asset:setOwner(owner)
  local parent = Entity()
  parent:addInventory(100)
  parent:addTrader()
  local trader = parent.trader
  local data = trader:getData(Ore)
  data.asks = { 10 }
  data.escrow = 1
  return owner, asset, trader, data
end

local owner, full, trader, data = fixture(0, 100)
check('full cargo rejects purchase', not trader:buy(full, Ore))
check('full cargo does not charge owner', owner:getItemCount(Credit) == 100)
check('full cargo does not consume ask', #data.asks == 1 and data.escrow == 1)

local owner2, ship, trader2, data2 = fixture(1, 100)
check('affordable purchase succeeds', trader2:buy(ship, Ore))
check('purchase inserts cargo', ship:getItemCount(Ore) == 1)
check('purchase charges exact price', owner2:getItemCount(Credit) == 90)
check('purchase consumes one ask', #data2.asks == 0 and data2.escrow == 0)

local owner3, ship3, trader3, data3 = fixture(1, 5)
check('insufficient credits reject purchase', not trader3:buy(ship3, Ore))
check('insufficient credits do not charge owner', owner3:getItemCount(Credit) == 5)
check('insufficient credits do not consume ask', #data3.asks == 1)

if failures == 0 then
  print(string.format('npc trade: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('npc trade: %d/%d checks failed', failures, checks))
  os.exit(1)
end
