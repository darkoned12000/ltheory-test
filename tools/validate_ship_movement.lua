#!/usr/bin/env luajit
-- Ship movement contract: larger hulls and heavier loads must be slower.
-- This is intentionally a pure module test so it runs without GL/Engine state.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_ship_movement%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

local Movement = require('Game.ShipMovement')

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then
    print('ok   - ' .. name .. (detail and ('  -- ' .. detail) or ''))
  else
    failures = failures + 1
    print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or ''))
  end
end

local fighter = Movement.factors(10, 0, 100)
check('fighter reference speed is 500 u/s', Movement.topSpeed(10, 0, 100) == 500)
check('empty fighter has full speed factor', fighter.speed == 1)
check('empty fighter has reference acceleration', fighter.acceleration == 1)

local capital = Movement.factors(600, 0, 100)
check('capital is much slower than fighter', Movement.topSpeed(600, 0, 100) < 100,
  string.format('capital=%.2f u/s', Movement.topSpeed(600, 0, 100)))
check('capital speed remains positive', Movement.topSpeed(600, 0, 100) > 20)
check('capital acceleration is lower than fighter', capital.acceleration < fighter.acceleration)

local loaded = Movement.factors(10, 100, 100)
check('full cargo slows a fighter', Movement.topSpeed(10, 100, 100) < 500,
  string.format('loaded=%.2f u/s', Movement.topSpeed(10, 100, 100)))
check('cargo slowdown is bounded', Movement.topSpeed(10, 100, 100) >= 325)
check('empty and full cargo differ', loaded.speed < fighter.speed)

local zeroCargo = Movement.factors(10, 0, 0)
check('zero cargo capacity is finite', zeroCargo.speed == zeroCargo.speed and zeroCargo.speed > 0)
local tiny = Movement.factors(0, 0, 0)
check('zero radius is clamped to fighter-or-faster', tiny.size == 1)

local heavy = Movement.forceScale(1e10, 600, 0, 100)
local light = Movement.forceScale(5e4, 10, 0, 100)
check('capital force is larger in absolute terms', heavy > light)
check('capital force per mass is lower', heavy / 1e10 < light / 5e4)
check('capital drag is lower in absolute terms', Movement.linearDrag(600, 0, 100) < 0.75)
check('fighter drag remains reference', Movement.linearDrag(10, 0, 100) == 0.75)

if failures == 0 then
  print(string.format('ship movement: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('ship movement: %d/%d checks failed', failures, checks))
  os.exit(1)
end
