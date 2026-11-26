#!/usr/bin/env luajit
-- Repair/refit/purchase payments work for NPC actor credits and player ship credits.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_progression_wallet%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

function insert (t, v) t[#t + 1] = v end
function class (ctor)
  local cls = {}; cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end
local Item = require('Game.Item')
local Credit = Item.Credit
local walletOk, Wallet = pcall(require, 'Game.ProgressionWallet')
local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name)
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end
check('ProgressionWallet module loads', walletOk, Wallet)
if not walletOk then os.exit(1) end

local station = { credits = 0 }
function station:addItem (item, count) if item == Credit then self.credits = self.credits + count; return true end return false end
function station:removeItem (item, count) if item == Credit and self.credits >= count then self.credits = self.credits - count; return true end return false end
local playerShip = { credits = 1000 }
function playerShip:getCredits () return self.credits end
function playerShip:hasCredits (n) return self.credits >= n end
function playerShip:removeCredits (n) self.credits = self.credits - n end
function playerShip:addCredits (n) self.credits = self.credits + n end
function playerShip:getOwner () return nil end
local payment = Wallet.Pay(playerShip, station, 250)
check('player ship credits pay for services', payment and playerShip.credits == 750
  and station.credits == 250)
Wallet.Refund(payment, station, 100)
check('partial service refund returns credits', playerShip.credits == 850 and station.credits == 150)
local failed = Wallet.Pay(playerShip, station, 9999)
check('unaffordable service is atomic', failed == nil and playerShip.credits == 850
  and station.credits == 150)

local owner = { credits = 500 }
function owner:hasItem (item, n) return item == Credit and self.credits >= n end
function owner:removeItem (item, n) if item == Credit and self.credits >= n then self.credits = self.credits - n; return true end return false end
function owner:addItem (item, n) if item == Credit then self.credits = self.credits + n; return true end return false end
local npcShip = { getOwner = function () return owner end }
local npcPayment = Wallet.Pay(npcShip, station, 200)
check('NPC actor credits still pay for services', npcPayment and owner.credits == 300
  and station.credits == 350)

local refundStation = { credits = 0 }
function refundStation:addItem (item, count) self.credits = self.credits + count; return true end
function refundStation:removeItem () return false end
local refundShip = { credits = 100 }
function refundShip:getOwner () return nil end
function refundShip:getCredits () return self.credits end
function refundShip:hasCredits (n) return self.credits >= n end
function refundShip:removeCredits (n) self.credits = self.credits - n end
function refundShip:addCredits (n) self.credits = self.credits + n end
local refundPayment = Wallet.Pay(refundShip, refundStation, 40)
check('failed station refund cannot create player credits',
  refundPayment and Wallet.Refund(refundPayment, refundStation, 40) == 0
  and refundShip.credits == 60 and refundPayment.paid == 40)

if failures == 0 then
  print(string.format('progression wallet: %d checks passed', checks)); os.exit(0)
else
  print(string.format('progression wallet: %d/%d checks failed', failures, checks)); os.exit(1)
end
