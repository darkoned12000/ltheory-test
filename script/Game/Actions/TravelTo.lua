local Action = require('Game.Action')
local NpcLog = require('Game.NpcLog')
local NpcTravel = require('Game.NpcTravel')

local TravelTo = subclass(Action, function (self, gate, reason)
  assert(gate)
  self.gate = gate
  self.reason = reason or 'travel'
end)

function TravelTo:clone ()
  return TravelTo(self.gate, self.reason)
end

function TravelTo:getName ()
  return format('TravelTo %s', self.gate:getName())
end

function TravelTo:onStart (e)
  local distance, speed, eta = NpcTravel.NormalEta(e, self.gate)
  NpcLog.Event(e, format('gate approach %s -> sector %s dist=%.0f normalSpeed=%.0f eta=%.1fs (%s)',
    self.gate:getName(), tostring(self.gate:getPartnerSector()), distance, speed, eta, self.reason))
end

function TravelTo:onUpdateActive (e)
  if self.gate.deleted or not self.gate.isWormhole then
    NpcLog.Event(e, 'gate approach cancelled: gate disappeared')
    e:popAction()
    return
  end
  local range = self.gate.DOCK_RANGE or (Config.game and Config.game.dockRange) or 500
  if (NpcTravel.Distance(e, self.gate) or math.huge) <= range then
    local root = e.getRoot and e:getRoot()
    local owner = e.getOwner and e:getOwner()
    if root and root.beginNpcTransit and owner and owner.isNpc and owner:isNpc() then
      e:popAction()
      root:beginNpcTransit(owner, e, self.gate, self.reason)
    else
      self.gate:warp(e)
      e:popAction()
    end
    return
  end
  self:flyToward(e, self.gate:getPos(), e:getForward(), e:getUp())
end

return TravelTo
