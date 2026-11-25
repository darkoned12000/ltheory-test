#!/usr/bin/env luajit
-- Flight HUD must remain available during scan/mine/move actions.

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
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end
local Container = { Create = function () return {} end }
_G.UI = { Container = Container }
_G.List = function (...) return { ... } end
for _, name in ipairs({ 'Game.Controls.MasterBindings', 'Game.Controls.CommandControl',
  'Game.Controls.DebugControl', 'Game.Controls.DockControl', 'Game.Controls.HUD' }) do
  package.loaded[name] = {}
end
local MasterControl = dofile(root .. 'script/Game/Controls/MasterControl.lua')

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name)
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or '')) end
end
local ship = { parent = {}, getParent = function (self) return self.parent end,
  getCurrentAction = function () return { getName = function () return 'Scan Rock' end } end }
local master = setmetatable({ player = { getControlling = function () return ship end } }, MasterControl)
local ok, undocked = pcall(function () return master:isUndocked() end)
check('flight controls remain undocked during a scan action', ok and undocked, tostring(undocked))
ship.parent = { hasDockable = function () return true end }
local dockedOk, dockedUndocked = pcall(function () return master:isUndocked() end)
check('docked state still selects dock controls', dockedOk and not dockedUndocked, tostring(dockedUndocked))

if failures == 0 then
  print(string.format('hud lifecycle: %d checks passed', checks)); os.exit(0)
else
  print(string.format('hud lifecycle: %d/%d checks failed', failures, checks)); os.exit(1)
end
