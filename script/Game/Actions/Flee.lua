local Action = require('Game.Action')

-- Temporary preemption: flee away from the recent damage source (or straight
-- ahead if it is gone), then pop so the existing job resumes underneath.
local Flee = subclass(Action, function (self, source, duration)
  self.source = source
  self.duration = duration or 6.0
  self.t = 0
end)

function Flee:clone ()
  return Flee(self.source, self.duration)
end

function Flee:getName ()
  return 'Flee'
end

function Flee:onUpdateActive (e, dt)
  self.t = self.t + dt
  if self.t >= self.duration then
    e:popAction()
    return
  end

  local pos = e:getPos()
  local forward = e:getForward()
  local up = e:getUp()
  local away = forward
  if self.source and self.source.isAlive and self.source:isAlive() then
    away = pos - self.source:getPos()
    if away:length() < 1e-6 then away = forward end
  end
  self:flyToward(e, pos + away:normalize():scale(5000), forward, up)
end

function Flee:onStop (e)
  local controller = e.getThrustController and e:getThrustController()
  if controller then controller:clear() end
end

return Flee
