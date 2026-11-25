local Action = require('Game.Action')

local MoveTo = subclass(Action, function (self, target, range)
  self.target = target
  self.range = range
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

  self:flyToward(e,
    self.target:getPos(),
    e:getForward(),
    e:getUp())
end

return MoveTo
