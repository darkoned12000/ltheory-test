local Action = require('Game.Action')
local Seed = require('Game.Seed')

local nextId = 0
local WAYPOINT_RANGE = 200

local Patrol = subclass(Action, function (self, center, radius)
  self.center = center
  self.radius = radius or 5000
  nextId = nextId + 1
  self.rng = Seed.rng('action.patrol', nextId):managed()
  self.waypoint = nil
end)

function Patrol:clone ()
  return Patrol(self.center, self.radius)
end

function Patrol:getName ()
  return 'Patrol'
end

function Patrol:newWaypoint (e)
  local center = self.center or e:getPos()
  self.waypoint = center + self.rng:getSphere():scale(self.radius)
end

function Patrol:onStart (e)
  self:newWaypoint(e)
end

function Patrol:onUpdateActive (e, dt)
  if (e:getPos() - self.waypoint):length() <= WAYPOINT_RANGE then
    self:newWaypoint(e)
    return
  end
  self:flyToward(e, self.waypoint, e:getForward(), e:getUp())
end

return Patrol
