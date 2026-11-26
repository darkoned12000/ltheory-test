local Action = require('Game.Action')

local Avoid = subclass(Action, function (self, obstacle, side, clearance, forward, up)
  self.obstacle = obstacle
  self.side = side
  self.clearance = clearance or 500
  self.forward = forward
  self.up = up
  self.elapsed = 0
  self.isAvoidAction = true
end)

function Avoid:clone ()
  return Avoid(self.obstacle, self.side, self.clearance, self.forward, self.up)
end

function Avoid:getName ()
  local name = self.obstacle and self.obstacle.getName
    and self.obstacle:getName() or 'obstacle'
  return 'Avoid ' .. tostring(name)
end

local function clear (ship, self)
  local state = ship.npcAvoidanceState
  if state and state.obstacle == self.obstacle then ship.npcAvoidanceState = nil end
  ship:popAction()
end

function Avoid:getWaypoint (ship)
  local obstaclePos = self.obstacle:getPos()
  local along = self.forward:scale(self.clearance * 2)
  local lateral = self.side:scale(self.clearance * 2)
  return obstaclePos + along + lateral
end

function Avoid:onUpdateActive (ship, dt)
  local obstacle = self.obstacle
  if not obstacle or obstacle.deleted or obstacle.parent ~= ship:getRoot()
     or (obstacle.isDestroyed and obstacle:isDestroyed()) then
    clear(ship, self)
    return
  end

  self.elapsed = self.elapsed + math.max(0, tonumber(dt) or 0)
  local relative = obstacle:getPos() - ship:getPos()
  local along = relative:dot(self.forward)
  local lateral = (relative - self.forward:scale(along)):length()
  local maxDuration = (Config.game and Config.game.npcAvoidanceTimeout) or 8
  if along < -self.clearance or lateral > self.clearance * 1.5
     or self.elapsed >= maxDuration then
    clear(ship, self)
    return
  end

  local waypoint = self:getWaypoint(ship)
  self.waypointPos = waypoint
  if (waypoint - ship:getPos()):length() <= self.clearance * 0.35 then
    clear(ship, self)
    return
  end
  self:flyToward(ship, waypoint, self.forward, self.up)
end

function Avoid:onStop (ship)
  local state = ship.npcAvoidanceState
  if state and state.obstacle == self.obstacle then ship.npcAvoidanceState = nil end
  local controller = ship.getThrustController and ship:getThrustController()
  if controller and controller.clear then controller:clear() end
end

return Avoid
