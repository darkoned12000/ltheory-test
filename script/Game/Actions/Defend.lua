local Action = require('Game.Action')
local Attack = require('Game.Actions.Attack')
local Directives = require('Game.Directives')
local NpcSafety = require('Game.NpcSafety')
local TargetValidity = require('Game.Actions.TargetValidity')

local Defend = subclass(Action, function (self, protected, target, directive)
  self.protected = protected
  self.target = target
  self.directive = directive
  self.attack = nil
end)

function Defend:clone ()
  return Defend(self.protected, self.target, self.directive)
end

function Defend:getName ()
  local name = self.protected and self.protected.getName
    and self.protected:getName() or 'ally'
  return format('Defend %s', name)
end

function Defend:finish (ship, outcome)
  local root = ship.getRoot and ship:getRoot()
  local owner = ship.getOwner and ship:getOwner()
  if self.directive and root and root.directives and owner then
    if outcome == 'complete' then
      Directives.complete(root.directives, self.directive.id, owner)
    else
      Directives.fail(root.directives, self.directive.id)
    end
  end
  ship:popAction()
end

function Defend:onUpdateActive (ship)
  if not TargetValidity.Usable(self.protected) then self:finish(ship, 'failed'); return end
  if not TargetValidity.Usable(self.target) then self:finish(ship, 'complete'); return end
  if not NpcSafety.IsCombatant(self.target) then self:finish(ship, 'failed'); return end

  local directive = self.directive
  if directive and directive.status ~= 'active' and directive.status ~= 'open' then
    ship:popAction()
    return
  end

  local protectedPos = self.protected:getPos()
  local targetPos = self.target:getPos()
  local leash = (Config.game and Config.game.npcDefenseLeash) or 20000
  if (targetPos - protectedPos):length() > leash then
    self:finish(ship, 'failed')
    return
  end

  local guardRange = (Config.game and Config.game.npcDefendRange)
    or (Config.game and Config.game.npcRegroupDistance) or 1000
  local fromProtected = ship:getPos() - protectedPos
  local distance = fromProtected:length()
  local joinRange = guardRange * 0.8
  local leaveRange = guardRange * 1.1
  local holding = self.holdingPosition or false
  if not holding and distance > guardRange then
    local direction = distance > 1e-6 and fromProtected:scale(1 / distance)
      or ship:getRight()
    local waypoint = protectedPos + direction:scale(joinRange)
    self:flyToward(ship, waypoint, self.protected:getForward(), self.protected:getUp())
    return
  end
  if holding and distance > leaveRange then
    self.holdingPosition = false
    local direction = distance > 1e-6 and fromProtected:scale(1 / distance)
      or ship:getRight()
    local waypoint = protectedPos + direction:scale(joinRange)
    self:flyToward(ship, waypoint, self.protected:getForward(), self.protected:getUp())
    return
  end
  self.holdingPosition = true

  local engageRange = (Config.game and Config.game.npcDefenseEngageRange)
    or (ship.socketRangeMin or 6000)
  if (targetPos - protectedPos):length() <= engageRange then
    local attack = Attack(self.target)
    attack.protected = self.protected
    attack.leash = leash
    self.attack = attack
    ship:pushAction(attack)
    return
  end

  local controller = ship.getThrustController and ship:getThrustController()
  if controller and controller.clear then controller:clear() end
end

return Defend
