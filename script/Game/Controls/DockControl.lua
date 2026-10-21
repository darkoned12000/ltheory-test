local Actions = requireAll('Game.Actions')
local ShipBindings = require('Game.Controls.ShipBindings')

local DockControl = {}
DockControl.__index = DockControl
setmetatable(DockControl, UI.Panel)

function DockControl:onEnable ()
  local pCamera = self.gameView.camera
  self.gameView:setOrbit(true)

  local station  = self.player:getControlling():getParent()
  self.station = station
  -- The MARKET, if the thing you are docked with has one. Every region's
  -- place has one, so this is the economy's front door: the panel is where
  -- the ore you mined becomes credits.
  self.market = (station and station.hasMarket and station:hasMarket())
                and station:getMarket() or nil
  self.message = nil

  self.camera = self.gameView.camera
  self.camera:setYaw(-Math.Pi2)
  self.camera:setPitch(Math.Pi4)
  self.camera:setRadius(1000)
  self.camera:setTarget(station)
  self.camera:setRelative(true)
  self.camera:warp()
  self.camera:lerpFrom(pCamera.pos, pCamera.rot)
end

-- Sell everything the market will take.
function DockControl:sellAll ()
  local ship = self.player:getControlling()
  local market = self.market
  if not market then return end
  local sold, earned = 0, 0
  for _, q in ipairs(market:quotes()) do
    if q.bid then
      local have = ship:getItemCount(q.item)
      if have > 0 then
        local n, credits = market:sell(ship, q.item, have)
        sold = sold + n
        earned = earned + credits
      end
    end
  end
  if sold > 0 then
    self.message = format('Sold %d for %d credits', sold, earned)
  else
    self.message = 'Nothing here the market wants'
  end
end

-- Buy the cheapest thing the market is selling.
function DockControl:buyOne ()
  local ship = self.player:getControlling()
  local market = self.market
  if not market then return end
  local best, bestPrice
  for _, q in ipairs(market:quotes()) do
    if q.ask and (not bestPrice or q.ask < bestPrice) then
      best, bestPrice = q, q.ask
    end
  end
  if not best then
    self.message = 'Nothing here for sale'
    return
  end
  local n, paid = market:buy(ship, best.item, 1)
  if n > 0 then
    self.message = format('Bought 1 %s for %d credits', best.item:getName(), paid)
  else
    self.message = format('Cannot afford a %s', best.item:getName())
  end
end

function DockControl:onInput (state)
  if ShipBindings.Dock:get() > 0 then
    self.player:getControlling():pushAction(Actions.Undock())
    return
  end
  if self.market then
    if ShipBindings.Sell:get() > 0 then self:sellAll() end
    if ShipBindings.Buy:get() > 0 then self:buyOne() end
  end
end

function DockControl:onDraw (focus, active)
  -- TODO : Unify this with HUD
  local x, y, sx, sy = self:getRectGlobal()
  UI.DrawEx.TextAdditive(
    'NovaMono',
    'Press F to Undock',
    16,
    x, y, sx, sy,
    1, 1, 1, 1,
    0.5, 0.99
  )

  if not self.market then return end

  -- THE MARKET.
  --
  -- The prices the market will pay and will ask, the player's hold and
  -- credits, and the two keys that move things. The economy was invisible
  -- until this: the ore could be mined and it could be carried, and there
  -- was nowhere to turn it into anything.
  local ship = self.player:getControlling()
  local line = 0
  local function put (text, r, g, b)
    line = line + 1
    UI.DrawEx.TextAdditive('NovaMono', text, 15,
      x + 24, y + 40 + (line - 1) * 20, sx, sy, r, g, b, 1, 0.0, 0.0)
  end

  local name = (self.station and self.station.getName and self.station:getName()) or 'Station'
  put(name .. '  --  MARKET', 1.0, 0.80, 0.40)
  put(format('Credits: %d', ship:getCredits()), 1, 1, 1)

  local holding = {}
  for _, item in ipairs(require('Game.Item').All()) do
    local n = ship:getItemCount(item)
    if n > 0 then holding[#holding + 1] = format('%s x%d', item:getName(), n) end
  end
  if #holding > 0 then
    put('Holding: ' .. table.concat(holding, ', '), 0.7, 0.9, 1.0)
  end

  put(' ', 0, 0, 0)
  put(format('%-22s %8s %8s', 'COMMODITY', 'BUY AT', 'SELL AT'), 0.7, 0.7, 0.8)
  for _, q in ipairs(self.market:quotes()) do
    put(format('%-22s %8s %8s', q.item:getName(),
      q.bid and tostring(q.bid) or '-',
      q.ask and tostring(q.ask) or '-'), 1, 1, 1)
  end

  put(' ', 0, 0, 0)
  put('R = sell everything    T = buy one', 0.6, 0.8, 1.0)
  if self.message then
    put(self.message, 0.4, 1.0, 0.5)
  end
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
