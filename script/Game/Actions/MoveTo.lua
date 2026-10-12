local Action = require('Game.Action')
local Seed = require('Game.Seed')

local nextId = 0

local MoveTo = subclass(Action, function (self, target, range)
  self.target = target
  self.range = range
  -- Per-instance stream (was one process-wide clock-seeded stream, so two NPCs
  -- moving shared and advanced each other's sequence). The ordinal keeps
  -- clones/parallel instances distinct while staying reproducible.
  nextId = nextId + 1
  self.rng = Seed.rng('action.moveto', nextId):managed()
end)

function MoveTo:clone ()
  return MoveTo(self.target, self.range)
end

function MoveTo:getName ()
  return format('MoveTo %s', self.target:getName())
end

function MoveTo:onUpdateActive (e, dt)
  if e:getMinDistance(self.target) <= self.range then
    e:popAction()
    return
  end

  if Config.debug.instantJobs then
    local p = e:getPos()
    local dp = self.target:getPos() - p
    e:setPos(p + dp:normalize():scale(self.rng:getUniform() * min(dp:length(), dt * Config.debug.jobSpeed)))
  else
    self:flyToward(e,
      self.target:getPos(),
      e:getForward(),
      e:getUp())
  end
end

return MoveTo
