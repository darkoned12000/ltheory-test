local Action = require('Game.Action')

-- Active all-axis braking. Mining requires a genuinely stationary ship; simply
-- clearing thrust would leave capital hulls coasting for a long time.

local Stop = subclass(Action, function (self)
  self.stopSpeed = (Config.game and Config.game.miningStopSpeed) or 2
end)

function Stop:clone ()
  return Stop()
end

function Stop:getName ()
  return 'Stop'
end

local function clamp (value)
  if value < -1 then return -1 end
  if value > 1 then return 1 end
  return value
end

function Stop:onUpdateActive (e, dt)
  local controller = e:getThrustController()
  if not controller then e:popAction(); return end
  local velocity = e:getVelocity()
  if velocity:length() <= self.stopSpeed then
    controller:clear()
    e:popAction()
    return
  end
  controller.forward = clamp(-velocity:dot(e:getForward()) / 50.0)
  controller.right = clamp(-velocity:dot(e:getRight()) / 50.0)
  controller.up = clamp(-velocity:dot(e:getUp()) / 50.0)
  controller.yaw, controller.pitch, controller.roll = 0, 0, 0
  controller.boost = 0
end

function Stop:onStop (e)
  local controller = e.getThrustController and e:getThrustController()
  if controller then controller:clear() end
end

return Stop
