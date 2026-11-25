local Job = require('Game.Job')
local Actions = requireAll('Game.Actions')

local Mine = subclass(Job, function (self, src, dst)
  self.src = src
  self.dst = dst
end)

function Mine:clone ()
  return Mine(self.src, self.dst)
end

function Mine:getFlows (e)
  local capacity = e:getInventoryCapacity()
  local duration = self:getTravelTime(e) -- TODO : + miningTime
  local item = self.src:getYield().item
  local rate = math.floor(capacity / item:getMass()) / duration
  return { Flow(item, rate, self.dst) }
end

function Mine:getKind ()
  return 'mine'
end

function Mine:isKnown (asset)
  if not (asset.knownYields and asset.knownYields[self.src]) then return false end
  if self.src.deleted or (self.src.isDestroyed and self.src:isDestroyed()) then return false end
  if self.src.hasYield and not self.src:hasYield() then return false end
  if self.src.getParent and not self.src:getParent() then return false end
  return true
end

function Mine:getKey ()
  return format('mine:%s:%s:%s', self.src.id, self.dst.id,
    self.src:getYield().item:getName())
end

function Mine:getName ()
  return format('Mine %s at %s, drop off at %s',
    self.src:getYield().item:getName(),
    self.src:getName(),
    self.dst:getName())
end

function Mine:getPayout (e)
  local capacity = e:getInventoryCapacity()
  local item = self.src:getYield().item
  local count = math.floor(capacity / item:getMass())
  return self.dst:getTrader():getSellToPrice(item, count)
end

function Mine:getTravelTime (e)
  return 2.0 * self.src:getDistance(self.dst) / e:getTopSpeed()
end

function Mine:onStop (e)
  e.jobState = nil
  Job.onStop(self, e)
end

function Mine:onUpdateActive (e, dt)
  if not e.jobState then e.jobState = 0 end
  e.jobState = e.jobState + 1

  if e.jobState == 1 then
    local capacity = e:getInventoryCapacity()
    local item = self.src:getYield().item
    local count = math.floor(capacity / item:getMass())
    local profit = self.dst:getTrader():getSellToPrice(item, count)
    -- printf("[MINE] %d x %s from %s -> %s, expect %d profit", count, item:getName(), self.src:getName(), self.dst:getName(), profit)
    e:pushAction(Actions.MoveTo(self.src, 100))
  elseif e.jobState == 2 then
    e:pushAction(Actions.Stop())
  elseif e.jobState == 3 then
    e:pushAction(Actions.MineAt(self.src))
  elseif e.jobState == 4 then
    e:pushAction(Actions.DockAt(self.dst))
  elseif e.jobState == 5 then
    local item = self.src:getYield().item
    while self.dst:getTrader():sell(e, item) do end
  elseif e.jobState == 6 then
    e:pushAction(Actions.Undock())
  elseif e.jobState == 7 then
    -- TODO : This is just a quick hack to force AI to re-evaluate job
    --        decisions. In reality, AI should 'pre-empt' the job, which
    --        should otherwise loop indefinitely by default
    self:finish(e, 'completed')
  end
end

return Mine
