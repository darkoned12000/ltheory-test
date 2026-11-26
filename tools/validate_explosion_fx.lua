#!/usr/bin/env luajit
-- Explosion parameters must scale visibly with hull size.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_explosion_fx%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

local fxOk, FX = pcall(require, 'Game.ExplosionFX')
local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name)
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end
check('ExplosionFX module loads', fxOk, FX)
if not fxOk then os.exit(1) end
local fighter = FX.Parameters(4)
local capital = FX.Parameters(64)
check('capital explosion emits more particles', capital.count > fighter.count)
check('capital explosion particles are visibly larger', capital.size > fighter.size * 4)
check('capital explosion throws debris farther', capital.speed > fighter.speed * 2)
check('explosion parameters stay bounded', capital.count <= 1200
  and capital.size <= 80 and capital.speed <= 600)

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
local exploded = 0
package.loaded['Game.Entities.GPUParticles'] = { explode = function () exploded = exploded + 1 end }
dofile(root .. '/script/Game/Components/Explodable.lua')
local ship = Entity()
ship:addHealth(100, 0)
ship:addExplodable()
ship.getPos = function () return { x = 0, y = 0, z = 0 } end
ship.getVelocity = function () return { x = 0, y = 0, z = 0 } end
ship.getScale = function () return 64 end
ship.getOwner = function () return nil end
ship.clearActions = function () end
ship:damage(1000, nil)
check('lethal hull damage emits an explosion', exploded == 1)

if failures == 0 then
  print(string.format('explosion fx: %d checks passed', checks)); os.exit(0)
else
  print(string.format('explosion fx: %d/%d checks failed', failures, checks)); os.exit(1)
end
