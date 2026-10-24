--[[ DockControl -- the docked STATE's controller.

  Docking has two halves. This one is the WORLD half: the camera leaves
  the chase and orbits the station you pulled up to, and the control bar
  keeps an icon for the docked control set. The UI half (the market
  window with its MARKET/SELL tabs, the trade buttons, the F/R/T keys)
  lives in GUI/DockScreen.lua -- a real Screen, opened and closed by
  LTheory's docked-state watcher, which centers and modal-inputs
  correctly (this panel is a full-screen overlay and always was: sizing
  a window inside it is what produced the edge-to-edge band).

  The keyboard shortcuts are the screen's now (F undock, R sell
  everything, T buy the cheapest ask) -- see DockScreen:onInput.
]]

local DockControl = {}
DockControl.__index = DockControl
setmetatable(DockControl, UI.Panel)

function DockControl:onEnable ()
  local pCamera = self.gameView.camera
  self.gameView:setOrbit(true)

  self.station = self.player:getControlling():getParent()
  self.message = nil

  self.camera = self.gameView.camera
  self.camera:setYaw(-Math.Pi2)
  self.camera:setPitch(Math.Pi4)
  self.camera:setRadius(1000)
  self.camera:setTarget(self.station)
  self.camera:setRelative(true)
  self.camera:warp()
  self.camera:lerpFrom(pCamera.pos, pCamera.rot)
end

-- Give the camera back to the ship.
--
-- Docking took the camera over: the game view switched to the orbit camera
-- and this control re-targeted it at the STATION. Nothing gave it back --
-- there was no onDisable at all -- so undocking left the camera orbiting
-- the station for good, and the ship was never followed again.
function DockControl:onDisable ()
  self.gameView:setOrbit(false)
end

function DockControl:onDrawIcon (iconButton, focus, active)
  local borderColor = iconButton == active
                      and Config.ui.color.controlActive
                      or iconButton == focus
                         and Config.ui.color.controlFocused
                         or Config.ui.color.control
  local contentColor = self:isEnabled()
                       and Config.ui.color.controlFocused
                       or Config.ui.color.control

  local x, y, sx, sy = iconButton:getRectGlobal()
  UI.DrawEx.RectOutline(x, y, sx, sy, borderColor)

  UI.DrawEx.Ring(x + sx/2, y + 10,      14, contentColor)
  UI.DrawEx.Ring(x + sx/2, y + 10 + 12, 10, contentColor)
  UI.DrawEx.Ring(x + sx/2, y + 10 + 20,  6, contentColor)
end

function DockControl.Create (gameView, player)
  local self = setmetatable({
    gameView = gameView,
    player   = player,
    icon     = UI.Icon(),
    camera   = nil,

    children = List(),
  }, DockControl)

  self.icon:setOnDraw(function (ib, focus, active)
    self:onDrawIcon(ib, focus, active)
  end)
  return self
end

return DockControl
