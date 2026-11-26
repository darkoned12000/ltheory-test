#!/usr/bin/env luajit
-- Shield component: absorbs damage before hull and regenerates after a delay.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_shield%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

function class (ctor)
  local cls = {}; cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end
function insert (t, v) t[#t + 1] = v end
_G.min, _G.max = math.min, math.max
_G.Config = { debug = { damageLog = false } }

local Event = dofile(root .. '/script/Game/Event.lua')
_G.Event = Event
local Entity = dofile(root .. '/script/Game/Entity.lua')
package.loaded['Game.Entity'] = Entity
dofile(root .. '/script/Game/Components/Health.lua')
local shieldOk, Shield = pcall(require, 'Game.Components.Shield')

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name)
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end
check('Shield component module loads', shieldOk, Shield)
if not shieldOk then os.exit(1) end
dofile(root .. '/script/Game/Components/Shield.lua')

local ship = Entity()
ship:addHealth(100, 0)
ship:addShield(60, 10, 5)
ship:damage(25, nil)
check('shield absorbs the first hit', ship:getShield() == 35 and ship:getHealth() == 100)
ship:damage(50, nil)
check('overflow damage reaches hull after shield breaks', ship:getShield() == 0 and ship:getHealth() == 85)
ship:updateShield({ dt = 1 })
check('shield does not regenerate immediately', ship:getShield() == 0)
ship:updateShield({ dt = 5 })
check('shield regenerates after its delay', ship:getShield() > 0 and ship:getShield() <= 60)
ship:setShield(20, 60, 10, 5)
check('shield state setters retain max/rate/delay', ship:getShield() == 20
  and ship:getShieldMax() == 60 and ship.shieldRate == 10 and ship.shieldDelay == 5)

if failures == 0 then
  print(string.format('shield: %d checks passed', checks)); os.exit(0)
else
  print(string.format('shield: %d/%d checks failed', failures, checks)); os.exit(1)
end
