local Action = require('Game.Action')

local Regroup = subclass(Action, function (self, leader, distance, timeout)
  self.leader = leader
  self.distance = distance or (Config.game and Config.game.npcRegroupDistance) or 1000
  self.timeout = timeout or (Config.game and Config.game.npcRegroupTimeout) or 45
  self.elapsed = 0
end)

function Regroup:clone ()
  return Regroup(self.leader, self.distance, self.timeout)
end

function Regroup:getName ()
  local name = self.leader and self.leader.getName and self.leader:getName() or 'ally'
  return format('Regroup %s', name)
end

local function valid (ship, leader)
  if not (ship and leader) or ship.deleted or leader.deleted then return false end
  if ship.isAlive and not ship:isAlive() then return false end
  if leader.isAlive and not leader:isAlive() then return false end
  if ship.getRoot and leader.getRoot and ship:getRoot() ~= leader:getRoot() then return false end
  return true
end

function Regroup:onUpdateActive (ship, dt)
  if not valid(ship, self.leader) then
    ship.npcNeedsRegroup = false
    ship:popAction()
    return
  end

  self.elapsed = self.elapsed + math.max(0, tonumber(dt) or 0)
  if self.elapsed >= self.timeout then
    ship.npcNeedsRegroup = false
    ship:popAction()
    return
  end

  local leaderPos = self.leader:getPos()
  local fromLeader = ship:getPos() - leaderPos
  local distance = fromLeader:length()
  if distance <= self.distance then
    ship.npcNeedsRegroup = false
    local controller = ship.getThrustController and ship:getThrustController()
    if controller and controller.clear then controller:clear() end
    ship:popAction()
    return
  end

  if distance < 1e-6 then fromLeader = ship:getRight(); distance = fromLeader:length() end
  if distance < 1e-6 then return end
  local waypoint = leaderPos + fromLeader:scale(self.distance / distance)
  self:flyToward(ship, waypoint, self.leader:getForward(), self.leader:getUp())
end

function Regroup:onStop (ship)
  local controller = ship.getThrustController and ship:getThrustController()
  if controller and controller.clear then controller:clear() end
end

return Regroup
