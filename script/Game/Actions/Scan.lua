local Action = require('Game.Action')
local ScanEffect = require('Game.Entities.ScanEffect')
local ScannerDB = require('Game.ScannerDB')
local Seed = require('Game.Seed')

local nextId = 0
local RESULT_DISPLAY_TIME = 1.0

local Scan = subclass(Action, function (self, target, duration)
  assert(target)
  self.target = target
  nextId = nextId + 1
  self.rng = Seed.rng('action.scan', nextId):managed()
  self.duration = duration or self.rng:getUniformRange(5, 10)
  self.t = 0
  self.result = nil
  self.resultTime = 0
end)

function Scan:clone ()
  return Scan(self.target, self.duration)
end

function Scan:getName ()
  return format('Scan %s', self.target:getName())
end

function Scan:onStart (e)
  self.effect = ScanEffect(e, self.target)
  e:addChild(self.effect)
end

function Scan:onStop (e)
  if self.effect then
    e:removeChild(self.effect)
    self.effect = nil
  end
end

function Scan:onUpdatePassive (e)
  if self.effect then self.effect.active = e:getCurrentAction() == self end
end

function Scan:resolve (e, found)
  self.result = found
  self.resultTime = 0
  if self.effect then self.effect.result = found end
  e.scannedAsteroids = e.scannedAsteroids or {}
  e.scannedAsteroids[self.target] = true
  if found then
    e.knownYields = e.knownYields or {}
    e.knownYields[self.target] = true
  end
  local root = e.getRoot and e:getRoot()
  local now = root and root.getTime and root:getTime() or 0
  e.scanNotice = found and ('DEPOSIT IDENTIFIED: ' .. self.target:getYield().item:getName())
    or 'NO RESOURCE YIELD'
  e.scanNoticeUntil = now + 3
  local owner = e.getOwner and e:getOwner()
  if owner and owner.getScannerDB then
    local pos = self.target.getPos and self.target:getPos()
    local contact = ScannerDB.Record(owner:getScannerDB(), self.target, 4, now, pos, found)
    ScannerDB.AddLog(owner:getScannerDB(), contact.key,
      found and 'Resource yield identified' or 'No resource yield identified', now)
  end
end

function Scan:onUpdateActive (e, dt)
  if self.result ~= nil then
    self.resultTime = self.resultTime + dt
    if self.resultTime >= RESULT_DISPLAY_TIME then e:popAction() end
    return
  end
  if self.target.deleted or (self.target.isDestroyed and self.target:isDestroyed()) then
    self:resolve(e, false)
    return
  end
  self.t = self.t + dt
  if self.t >= self.duration then self:resolve(e, self.target:hasYield()) end
end

return Scan
