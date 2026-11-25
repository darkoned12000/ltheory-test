#!/usr/bin/env luajit
-- Durable module-slot identity and targeted plugging.

local root = (io.popen('pwd'):read('*l') or '.') .. '/'
package.path = root .. 'script/?.lua;' .. package.path
function class (ctor)
  local cls = {}; cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end
function insert (t, v) t[#t + 1] = v end
function min (a, b) return math.min(a, b) end
function max (a, b) return math.max(a, b) end
_G.Quat = { Identity = function () return {} end }
local Entity = class(); package.loaded['Game.Entity'] = Entity
dofile(root .. 'script/Game/Components/Sockets.lua')
local StableId = require('Game.StableId')

local failures, checks = 0, 0
local function check (name, ok)
  checks = checks + 1
  if ok then print('ok   - ' .. name) else failures = failures + 1; print('FAIL - ' .. name) end
end
local ship = setmetatable({}, Entity)
ship:addSockets()
ship:addSocket('Thruster', { x = 0, y = 0, z = 1 }, true, 1,
  StableId.Module('ship:1', 'Thruster', 1))
ship:addSocket('Thruster', { x = 1, y = 0, z = 1 }, true, 2,
  StableId.Module('ship:1', 'Thruster', 2))
function ship:attach (child) child.attached = true end
local module = { getSocketType = function () return 'Thruster' end }
check('targeted plug fills the requested slot', ship:plug(module, 2)
  and ship.sockets[2].child == module and ship.sockets[1].child == nil)
check('plug copies durable module identity', module.stableId == 'ship:1:module:Thruster:2'
  and module.moduleType == 'Thruster' and module.moduleIndex == 2)
check('targeted plug rejects an occupied slot', not ship:plug(module, 2))

if failures == 0 then
  print(string.format('module identity: %d checks passed', checks)); os.exit(0)
else
  print(string.format('module identity: %d/%d checks failed', failures, checks)); os.exit(1)
end
