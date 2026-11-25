local Action = require('Game.Action')

local Undock = subclass(Action, function (self) end)

function Undock:clone ()
  return Undock()
end

function Undock:getName ()
  return 'Undock'
end

function Undock:onUpdateActive (e, dt)
  local parent = e:getParent()
  if parent and parent.hasDockable and parent:hasDockable() then parent:removeDocked(e) end
  e:popAction()
  local root = e:getRoot()
  if root and root.app and root.app.syncDockScreen then root.app:syncDockScreen() end
end

return Undock
