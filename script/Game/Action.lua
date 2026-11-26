--[[----------------------------------------------------------------------------
  Base class for AI actions. Actions can be pushed and popped from action
  stacks on entities that have an 'Actions' component.

  clone           : Must return a copy of the action *in a clean state* (e.g.,
                    an attack action should return a clone that has the same
                    target, etc., but free of any bookeeping data that the
                    running instance may have accumulated).

  onUpdateActive  : Called only for the top action in the stack (the
                    'current' action)

  onUpdatePassive : Called for every action in the stack
----------------------------------------------------------------------------]]--

local Action = class(function (self) end)

-- Virtual ---------------------------------------------------------------------

function Action:clone ()
  assert(false, 'NYI @ Action.clone')
end

function Action:getName ()
  assert(false, 'NYI @ Action.getName')
end

function Action:onStart (e) end
function Action:onStop (e) end
function Action:onUpdateActive (e, dt) end
function Action:onUpdatePassive (e, dt) end

-- Helper ----------------------------------------------------------------------

local kLeadTime = 1
local expMap = PHX.Math.ExpMap1Signed

-- TODO : This is a *major* bottleneck; AI steering / thrust controller needs
--        to be pushed to C. Probably pathing / nav grid as well?
function Action:flyToward (e, targetPos, targetForward, targetUp)
  local c = e:getThrustController()
  if not c then return end

  local course = targetPos - e:getPos()
  local dist = course:length()
  if dist < 1e-6 then return end
  course = course - e:getVelocity():scale(kLeadTime)

  -- TODO : Fwd alignment can cause docking failure
  local forward = course + targetForward:scale(1.0)
  -- Lead compensation can put the desired course exactly opposite the
  -- requested heading (for example, when a fast ship is almost on its target).
  -- Keep the current heading in that degenerate case instead of normalizing 0.
  if forward:length() < 1e-6 then forward = e:getForward() end
  local owner = e.getOwner and e:getOwner()
  local current = e.getCurrentAction and e:getCurrentAction()
  local avoidActive = current and current.isAvoidAction
  if owner and owner.isNpc and owner:isNpc() and not avoidActive
     and Config.game and Config.game.npcAvoidance == true then
    local Perception = require('Game.NpcPerception')
    local contacts = Perception.Local(e, Perception.Range(e))
    local intendedObstacle = self.avoidTarget and self.target or nil
    forward = Perception.AvoidCourse(e, forward, contacts, intendedObstacle) or forward
    local avoidance = e.npcAvoidanceState
    if avoidance and not self.isAvoidAction and not avoidance.actionPushed
       and e.pushAction and e.getCurrentAction and e:getCurrentAction() == self then
      avoidance.actionPushed = true
      local Avoid = require('Game.Actions.Avoid')
      e:pushAction(Avoid(avoidance.obstacle, avoidance.side,
        avoidance.safeRadius, avoidance.courseDirection, targetUp))
    end
  end
  forward = forward:normalize()
  local yawPitch = e:getForward():cross(forward)
  local roll     = e:getUp():cross(targetUp)

  c.forward = expMap(2.0 * e:getForward():dot(forward))
  c.right = expMap(2.0 * e:getRight():dot(forward))
  c.up = expMap(2.0 * e:getUp():dot(forward))
  c.yaw = expMap(-10.0 * e:getUp():dot(yawPitch))
  c.pitch = expMap(10.0 * e:getRight():dot(yawPitch))
  c.roll = expMap(-10.0 * e:getForward():dot(roll))

  if Config.game.aiUsesBoost then
    c.boost = 1.0 - exp(-max(0.0, (dist / 150.0) - 1.0))
  else
    c.boost = 0
  end
end

--------------------------------------------------------------------------------

return Action
