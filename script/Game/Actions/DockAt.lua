local Action = require('Game.Action')

-- TODO : Dock range should be specified by the dockable component
local kDockRange = 500

local function getTargetPos (e, target)
  local tp = target:getPos()
  local tr = target:getRadius()
  local tu = target:getUp()
  local er = e:getRadius()
  return tp - tu:muls(1.25*tr + er)
end

local DockAt = subclass(Action, function (self, target)
  self.target = target
end)

function DockAt:clone ()
  return DockAt(self.target)
end

function DockAt:getName ()
  return format('DockAt %s', self.target:getName())
end

function DockAt:onUpdateActive (e, dt)
  local tp = getTargetPos(e, self.target)
  if (e:getPos() - tp):length() <= kDockRange then
    self.target:addDocked(e)
    e:popAction()
    local root = e:getRoot()
    if root and root.app and root.app.syncDockScreen then root.app:syncDockScreen() end
    return
  end

  local tf = self.target:getForward()
  local tu = self.target:getUp()
  self:flyToward(e, tp, -tf, tu)
end

-- TODO : Update this when we have real dock positions.

return DockAt
