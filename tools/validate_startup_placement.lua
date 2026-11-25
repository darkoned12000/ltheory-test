#!/usr/bin/env luajit
-- Startup capital placement must remain visible long enough to inspect. The
-- placement helper gives the demo ships a short Wait so instant jobs cannot
-- teleport them away on their first AI tick.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_startup_placement%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

local Vec = {}
Vec.__index = Vec
local function vec (x, y, z) return setmetatable({ x = x, y = y, z = z }, Vec) end
function Vec.__add (a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
function Vec:scale (s) return vec(self.x * s, self.y * s, self.z * s) end

local placed = {}
_G.requireAll = function ()
  return { Wait = function (duration) return { name = 'Wait', duration = duration } end }
end
local Placement = require('Game.StartupPlacement')

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

local function asset ()
  local a = { actions = {} }
  function a:setPos (pos) self.pos = pos end
  function a:pushAction (action) self.actions[#self.actions + 1] = action end
  function a:getRadius () return 600 end
  return a
end

local ship = {
  getForward = function () return vec(0, 0, -1) end,
  getRight = function () return vec(1, 0, 0) end,
  getUp = function () return vec(0, 1, 0) end,
  getPos = function () return vec(100, 200, 300) end,
}
local assets = { asset(), asset(), asset() }
local brain = { getAssets = function () return assets end }
Placement.place(brain, ship)
check('first capital is placed in front-left of player',
  assets[1].pos.x == -1280 and assets[1].pos.y == 680 and assets[1].pos.z == -4500,
  string.format('(%.0f,%.0f,%.0f)', assets[1].pos.x, assets[1].pos.y, assets[1].pos.z))
check('second capital is placed in front-right of player',
  assets[2].pos.x == 1900 and assets[2].pos.y == -160 and assets[2].pos.z == -5700,
  string.format('(%.0f,%.0f,%.0f)', assets[2].pos.x, assets[2].pos.y, assets[2].pos.z))
check('additional representative roles are repositioned', assets[3].pos ~= nil
  and assets[3].actions[1].duration == 5)
check('first capital waits before taking a job', assets[1].actions[1].duration == 5)
check('second capital waits before taking a job', assets[2].actions[1].duration == 5)

local independent = { asset(), asset() }
local brains = {
  { getAssets = function () return { independent[1] } end },
  { getAssets = function () return { independent[2] } end },
}
local listOk, listErr = pcall(function () Placement.place(brains, ship) end)
check('startup placement accepts independent NPC brains', listOk, tostring(listErr))
check('first independent NPC is positioned and held', independent[1].pos ~= nil
  and independent[1].actions[1].duration == 5)
check('second independent NPC is positioned and held', independent[2].pos ~= nil
  and independent[2].actions[1].duration == 5)

if failures == 0 then
  print(string.format('startup placement: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('startup placement: %d/%d checks failed', failures, checks))
  os.exit(1)
end
