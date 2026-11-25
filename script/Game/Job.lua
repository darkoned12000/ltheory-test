local Action = require('Game.Action')
local NpcLog = require('Game.NpcLog')

local Job = subclass(Action, function (self) end)

function Job:clone ()
  assert(false, 'NYI @ Job.clone')
end

function Job:getFlows (e)
  assert(false, 'NYI @ Job.getFlows')
end

function Job:finish (e, outcome)
  self.result = outcome or 'completed'
  e:popAction()
end

function Job:onStop (e)
  if e.npcJobCheckpoint then
    NpcLog.Event(e, 'job checkpointed for sector transit')
    self.result = nil
    return
  end

  local outcome = self.result or 'cancelled'
  local name = (self.getName and self:getName())
    or (self.getKind and self:getKind()) or 'job'
  NpcLog.Event(e, format('job finished (%s): %s', outcome, name))
  local policy = e.npcPolicy
  if policy then
    local root = e:getRoot()
    local now = root and root.getTime and root:getTime() or 0
    policy.recordOutcome(policy, self, self.result or 'cancelled', now)
  end
  self.result = nil
end

function Job:getName ()
  assert(false, 'NYI @ Job.getName')
end

function Job:getPayout (e)
  assert(false, 'NYI @ Job.getPayout')
end

function Job:getPressure (e)
  local pressure = 0
  for _, flow in ipairs(self:getFlows(e)) do
    local prev = flow.location:getFlow(flow.item)
    local curr = prev + flow.rate
    pressure = pressure + (curr*curr - prev*prev)
  end
  return pressure
end

function Job:getTravelTime (e)
  assert(false, 'NYI @ Job.getTravelTime')
end

return Job
