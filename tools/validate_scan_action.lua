#!/usr/bin/env luajit
-- Resource scan action contract: 5-10 second sweep, readable success/failure,
-- per-ship discovery memory, and clean effect cleanup.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_scan_action%.lua$', '')
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
function subclass (base, ctor)
  local cls = {}
  cls.__index = cls
  setmetatable(cls, {
    __call = function (T, ...)
      local self = base()
      setmetatable(self, cls)
      if ctor then ctor(self, ...) end
      return self
    end,
    __index = base,
  })
  return cls
end
function format (f, ...) return string.format(f, ...) end

local Action = class(function () end)
function Action:onStart () end
function Action:onStop () end
function Action:onUpdateActive () end
function Action:onUpdatePassive () end
package.loaded['Game.Action'] = Action
package.loaded['Game.Seed'] = { rng = function ()
  return { managed = function (self) return self end,
    getUniformRange = function () return 7 end }
end }
package.loaded['Game.Entities.ScanEffect'] = function (source, target)
  return { source = source, target = target, active = true, result = nil }
end
local Scan = dofile(root .. '/script/Game/Actions/Scan.lua')

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. detail) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or '')) end
end

local target = {
  hasYield = function () return true end,
  getYield = function () return { item = { getName = function () return 'Iron Ore' end } } end,
  isDestroyed = function () return false end,
  getName = function () return 'Rock' end,
}
local ship = {
  children = {}, popped = false, knownYields = {}, scannedAsteroids = {},
  addChild = function (self, child) self.children[#self.children + 1] = child end,
  removeChild = function (self, child)
    for i = 1, #self.children do
      if self.children[i] == child then table.remove(self.children, i); return end
    end
  end,
  getCurrentAction = function (self) return self.current end,
  popAction = function (self)
    self.popped = true
    if self.current then self.current:onStop(self) end
  end,
}
local scan = Scan(target, 5)
check('default scan duration is 5-10 seconds', Scan(target).duration == 7)
scan:onStart(ship)
ship.current = scan
scan:onUpdateActive(ship, 4)
check('scan does not resolve early', not ship.popped and scan.result == nil)
scan:onUpdateActive(ship, 1)
check('successful scan records discovery', scan.result == true and ship.knownYields[target] == true)
check('successful scan explains the discovered deposit',
  ship.scanNotice == 'DEPOSIT IDENTIFIED: Iron Ore')
check('scan result is visible before cleanup', not ship.popped
  and ship.children[1].result == true)
scan:onUpdateActive(ship, 1)
check('scan cleans up after result display', ship.popped and #ship.children == 0)

local empty = { hasYield = function () return false end,
  isDestroyed = function () return false end, getName = function () return 'Empty' end }
local ship2 = { children = {}, popped = false, knownYields = {}, scannedAsteroids = {},
  addChild = function (self, child) self.children[#self.children + 1] = child end,
  removeChild = function (self) self.children = {} end,
  getCurrentAction = function () return nil end,
  popAction = function (self) self.popped = true end,
}
local failed = Scan(empty, 5)
failed:onStart(ship2)
failed:onUpdateActive(ship2, 5)
check('failed scan is red and records the rock', failed.result == false
  and ship2.children[1].result == false and ship2.scannedAsteroids[empty] == true)

ship.current = { getName = function () return 'MoveTo' end }
scan = Scan(target, 5)
scan:onStart(ship)
scan:onUpdatePassive(ship)
check('scanner is hidden while approaching', ship.children[1].active == false)
check('Scan clone is independent', scan:clone() ~= scan and scan:clone().duration == 5)

if failures == 0 then
  print(string.format('scan action: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('scan action: %d/%d checks failed', failures, checks))
  os.exit(1)
end
