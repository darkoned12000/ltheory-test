#!/usr/bin/env luajit
-- Delta controls must be idempotent within one frame. UI focus and child input
-- traversal can both read the same binding before the next frame begins.

local root = (io.popen('pwd'):read('*l') or '.') .. '/'
package.path = root .. 'script/?.lua;' .. root .. 'script/WIP/?.lua;' .. package.path

function class (ctor)
  local cls = {}
  cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = setmetatable({}, T)
    if ctor then ctor(self, ...) end
    return self
  end })
end
function subclass (base, ctor)
  local cls = class()
  cls.__index = cls
  setmetatable(cls, { __index = base, __call = function (T, ...)
    local self = setmetatable({}, T)
    if ctor then ctor(self, ...) end
    return self
  end })
  return cls
end
function max (a, b) return math.max(a, b) end
function min (a, b) return math.min(a, b) end
function abs (a) return math.abs(a) end
function pow (a, b) return a ^ b end
_G.Math = { Sign = function (v) return v < 0 and -1 or 1 end }
_G.Button = { Gamepad = {} }
for _, name in ipairs({ 'LStickX', 'LStickY', 'RStickX', 'RStickY', 'LTrigger', 'RTrigger', 'RBumper', 'LBumper',
  'A', 'B', 'X', 'Y', 'Back', 'Start', 'LStick', 'RStick', 'Up', 'Down', 'Left', 'Right' }) do
  Button.Gamepad[name] = name
end

local Control = dofile(root .. 'script/WIP/Control.lua')
local raw = { value = 0 }
_G.Input = { GetValue = function () return raw.value end }
local source = Control.Key(1)
source.mult, source.expn, source.bias = 1, 1, 0
local delta = Control.Delta(source)

local failures, checks = 0, 0
local function check (name, ok)
  checks = checks + 1
  if ok then print('ok   - ' .. name) else failures = failures + 1; print('FAIL - ' .. name) end
end

if type(Control.BeginFrame) ~= 'function' then
  check('delta controls expose a per-frame clock', false)
  os.exit(1)
end
check('delta controls expose a per-frame clock', true)
Control.BeginFrame()
raw.value = 1
check('first read sees the press edge', delta:getRaw() == 1)
check('second read in the same frame preserves the edge', delta:getRaw() == 1)
Control.BeginFrame()
raw.value = 1
check('held control does not retrigger next frame', delta:getRaw() == 0)
Control.BeginFrame()
raw.value = 0
check('release edge is visible once per frame', delta:getRaw() == -1 and delta:getRaw() == -1)
Control.BeginFrame()
raw.value = 1
check('a new press is visible on the next frame even within one wall-clock second',
  delta:getRaw() == 1)

if failures == 0 then
  print(string.format('control delta: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('control delta: %d/%d checks failed', failures, checks))
  os.exit(1)
end
