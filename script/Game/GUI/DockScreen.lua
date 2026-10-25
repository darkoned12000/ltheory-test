--[[ DockScreen -- the docked state as a real page.

  THE USER'S ASK: docking opened a full-screen text overlay; this is the
  market as an actual WINDOW -- a centered page in the game's own Screen
  frame (the same machinery the menu and the popups use, which centers
  correctly), translucent so the station you pulled up to stays in view,
  with a MARKET tab (what the station sells) and a SELL tab (your hold,
  with SELL 1 / SELL ALL per row and SELL EVERYTHING at the bottom).

  DOCKED IS A STATE, NOT A PAGE: LTheory's onUpdate watcher opens this
  screen when the player docks and closes it silently when they undock
  (F, the UNDOCK button, or ESC -- this screen's Cancel is an UNDOCK, so
  one press cannot both undock and open the menu).

  Every trade goes through the same Market:buy/sell order book the keys
  always used (R sells everything, T buys the cheapest ask), and the page
  rebuilds after each one (prices, depth, credits and the hold all
  moved).
]]

local Actions = requireAll('Game.Actions')
local ShipBindings = require('Game.Controls.ShipBindings')
local Screen = require('Game.GUI.Screen')
local Grid = require('UI.Grid')
local Label = require('UI.Label')
local MenuButton = require('UI.MenuButton')
local Table = require('UI.Table')

local DockScreen = {}
DockScreen.__index = DockScreen
setmetatable(DockScreen, Screen)

DockScreen.name = 'Dock Screen'

-- COLUMN WIDTHS, fixed so the rows line up: each row is its own grid,
-- and label-sized columns would drift every row's cells (the settings
-- page's misalignment trap, again).
local COL_ITEM  = 200
local COL_PRICE = 110
local COL_DEPTH = 130
local COL_COUNT = 90

-- The palette (the menu's own family).
local ACCENT = Color(0.45, 0.80, 1.0, 1.0)
local WHITE  = Color(0.88, 0.93, 0.98, 1.0)
local MUTED  = Color(0.62, 0.72, 0.86, 1.0)
local GOOD   = Color(0.40, 1.0, 0.50, 1.0)
-- The market's state colors: OPEN green, CLOSED red.
local CLOSED_C = Color(1.0, 0.35, 0.35, 1.0)

-- One fixed-width cell: a label sized to a column so every row's cells
-- land on the same x.
local function cell (text, width, color)
  local l = Label():setText(text)
  l:setFontColor(color or WHITE)
  if width then l:setWidth(width) end
  return l
end

-- A VERTICAL BREATH of a given height: an empty label with a FIXED
-- height. (The plain empty-label spacer only ever gives one font line,
-- ~20px -- the user's half-inch gaps need the real height.)
local function spacer (h)
  local l = Label():setText('')
  l:setHeight(h)
  return l
end

-- opts:
--   player -- the player entity; the docked ship and its parent station
--             are resolved fresh on every refresh, so the page always
--             describes the dock you are actually at.
function DockScreen.Create (opts)
  opts = opts or {}
  local self = setmetatable({}, DockScreen)

  -- Copy the caller's opts and layer the defaults, exactly like every
  -- other screen does -- Screen.init keeps every option it is given, and
  -- a constructor that rebuilt the table field by field is how menu
  -- buttons once lost their callbacks (see MainMenu.Create).
  local o = {}
  for k, v in pairs(opts) do o[k] = v end
  o.title    = o.title or 'DOCK'
  o.subtitle = o.subtitle or ''
  o.bandAtTop = true
  -- TRANSLUCENT: the docked camera orbits the station you pulled up to;
  -- burying that under an opaque page wastes the best view in the game.
  o.backdrop = o.backdrop or Color(0.012, 0.016, 0.03, 0.72)

  Screen.init(self, o)
  self.content:setAlign(0.5, 0)
  self.content:setStretch(0, 0)

  -- ESC / right-click while docked = UNDOCK (docked is a state, not a
  -- page: closing the page and staying docked with no UI would strand
  -- the player in a menu-less dock).
  self.onCancel = function ()
    self.player:getControlling():pushAction(Actions.Undock())
  end

  self.body = nil
  self.tab = 'market'
  self.message = nil
  self:refresh()
  return self
end

-- Resolve the dock you are AT right now: the controlling ship's parent,
-- which must be a dockable (it is, whenever this screen is open).
function DockScreen:dock ()
  local ship = self.player and self.player:getControlling()
  local station = ship and ship:getParent()
  if not (station and station.hasDockable and station:hasDockable()) then
    return nil, nil
  end
  local market = station.hasMarket and station:hasMarket()
                and station:getMarket() or nil
  return station, market
end

-- POWER SERVICES: convert hold energy cells into capacitor charge, at
-- 25 charge a cell, in one button press. This is the commodity loop's
-- LAST MILE: the cells a place sells are worth carrying because they
-- are the only thing that fills a dead capacitor away from the dock.
-- The ship's own chargeRate regenerates the rest passively; the cells
-- pay for the NOW.
function DockScreen:recharge (cells)
  local ship = self.player:getControlling()
  if cells <= 0 then return end
  if not ship:removeItem(Item.Energy, cells) then return end
  local want = math.min(ship:getChargeMax(),
    ship:getCharge() + cells * 25)
  ship:setCharge(want, ship:getChargeMax(), ship.chargeRate)
  self.message = format('Recharged %d cell%s', cells,
    cells == 1 and '' or 's')
  self:refresh()
end

-- One trade through the book, then the page rebuilds (prices, depth,
-- credits and the hold all moved).
function DockScreen:trade (item, count, selling)
  local ship = self.player:getControlling()
  local _, market = self:dock()
  if not market then return end
  local n, total
  if selling then
    if not market:isOpen() then
      self.message = 'The market is not buying.'
      self:refresh()
      return
    end
    n, total = market:sell(ship, item, count)
    if n > 0 then
      self.message = format('Sold %d %s for %d credits', n, item:getName(), total)
    else
      self.message = format('The market is not buying %s', item:getName())
    end
  else
    n, total = market:buy(ship, item, count)
    if n > 0 then
      self.message = format('Bought %d %s for %d credits', n, item:getName(), total)
    else
      self.message = format('Cannot buy %s', item:getName())
    end
  end
  self:refresh()
end

-- Sell everything the market will take (the R key's action).
function DockScreen:sellAll ()
  local ship = self.player:getControlling()
  local _, market = self:dock()
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
  self:refresh()
end

-- Buy one of the cheapest thing the market is selling (the T key's
-- action).
function DockScreen:buyOne ()
  local _, market = self:dock()
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
  self:trade(best.item, 1, false)
end

-- The whole page body, rebuilt: on open, on every tab switch, and after
-- every trade. ONE swapped child grid of the content, so the framework's
-- add/remove keeps the widget bookkeeping honest (and no CLOSE-button
-- stacking -- that was the LOAD page's bug).
function DockScreen:refresh ()
  if self.body then self.content:remove(self.body) end
  self.body = Grid():setCols(1):setAlign(0.5, 0)
  self.body:setStretch(0, 0)

  local station, market = self:dock()
  local ship = self.player and self.player:getControlling()
  self.title = station and station.getName and station:getName() or 'DOCK'

  -- THE MARKET'S STATE: OPEN (green) or CLOSED (red). A closed market
  -- sells its stock but buys nothing -- abandoned, damaged, or a depot
  -- that only sells equipment; the knob gameplay mechanics will flip.
  local head = Grid():setCols(2):setStretch(0, 0)
  head:add(cell(
    market and (market:isOpen() and 'MARKET (OPEN)' or 'MARKET (CLOSED)'),
    280,
    market and market:isOpen() and GOOD or CLOSED_C))
  head:add(cell(format('YOUR CREDITS:  %d', ship and ship:getCredits() or 0), 240, WHITE))
  self.body:add(head)

  local tabs = Grid():setCols(2):setStretch(0, 0)
  tabs:setPadCellX(8)
  local buyBtn = MenuButton.Create('BUY', function ()
    if self.tab ~= 'market' then self.tab = 'market'; self:refresh() end
  end)
  local sellBtn = MenuButton.Create('SELL', function ()
    if self.tab ~= 'sell' then self.tab = 'sell'; self:refresh() end
  end)
  -- THE ACTIVE TAB IS UNMISSABLE: the selected plate reads like a
  -- focused one and stays that way (see MenuButton:setSelected).
  buyBtn:setSelected(self.tab == 'market')
  sellBtn:setSelected(self.tab == 'sell')
  tabs:add(buyBtn)
  tabs:add(sellBtn)
  self.body:add(tabs)

  -- A 25px BREATH before and after the table: the tab buttons and the
  -- UNDOCK button sat touching its outline.
  self.body:add(spacer(44))

  if market then
    local list = Grid():setCols(1):setStretch(0, 0)
    if self.tab == 'sell' then self:buildSellRows(list, ship, market)
                           else self:buildBuyRows(list, ship, market) end
    self.body:add(list)
  else
    self.body:add(cell('This dock has no market.', nil, MUTED))
  end

  -- POWER SERVICES: the energy cells the market sells have to DO
  -- something. Docking is where a ship trades cells for charge: each
  -- cell transfers 25 charge into the capacitor (a cell holds 25x what
  -- the capacitor does). The row always shows the state; the button
  -- does what it can, and the page rebuilds (trade()'s refresh).
  if ship and ship:hasCharge() then
    local Energy = Item.Energy
    local held = ship:getItemCount(Energy)
    local need = math.ceil((ship:getChargeMax() - ship:getCharge()) / 25)
    local use = math.min(math.max(need, 0), held)
    local row = Grid():setCols(2):setStretch(0, 0)
    row:add(cell(format('POWER  %d/%d   CELLS  %d',
      ship:getCharge(), ship:getChargeMax(), held), 300, WHITE))
    if use > 0 then
      row:add(MenuButton.Create(format('RECHARGE  %d CELL%s',
        use, use == 1 and '' or 'S'), function ()
        self:recharge(use)
      end))
    else
      row:add(cell(need > 0 and 'CAPACITOR LOW, NO CELLS' or 'CHARGE FULL',
        nil, MUTED))
    end
    self.body:add(row)
  end

  -- The breath after the table (same 25px rule).
  self.body:add(spacer(44))
  self.body:add(cell(self.message or ' ', nil, GOOD))
  self.body:add(MenuButton.Create('UNDOCK  (F)', function ()
    self.player:getControlling():pushAction(Actions.Undock())
  end))

  self.content:add(self.body)
end

-- The MARKET tab: ONE table, one row per commodity the station sells —
-- the price you would pay, the depth behind it, what you hold, and the
-- trade buttons right there in the row. No separate facts table: the
-- number you act on and the buttons that act sit together.
function DockScreen:buildBuyRows (grid, ship, market)
  local tbl = Table.Create({
    { title = 'COMMODITY', width = COL_ITEM  },
    { title = 'PRICE',     width = COL_PRICE },
    { title = 'SUP/DEM',   width = COL_DEPTH },
    { title = 'HELD',      width = COL_COUNT },
    { title = ' ',         width = 220       },
  }, { height = 240 })

  local any = false
  for _, q in ipairs(market:quotes()) do
    if q.ask then
      any = true
      local d = market:depth(q.item) or {}
      local btns = Grid():setCols(2):setStretch(0, 0)
      btns:setPadCellX(4)
      btns:add(MenuButton.Create('BUY 1', function ()
        self:trade(q.item, 1, false)
      end))
      btns:add(MenuButton.Create('BUY 5', function ()
        self:trade(q.item, 5, false)
      end))
      tbl:AddRow({
        q.item:getName(),
        tostring(q.ask),
        format('%s/%s', tostring(d.supply or 0), tostring(d.demand or 0)),
        tostring(ship:getItemCount(q.item)),
        btns,
      })
    end
  end
  grid:add(tbl)
  if not any then
    grid:add(cell('Nothing here for sale right now.', nil, MUTED))
  end
end

-- The SELL tab: ONE table of YOUR HOLD — one row per commodity you are
-- carrying that this market bids on, with the price you would get and
-- the sell buttons in the row. A CLOSED market buys nothing: the table
-- says so in its own voice.
function DockScreen:buildSellRows (grid, ship, market)
  if not market:isOpen() then
    grid:add(cell('This market is not buying.', nil, CLOSED_C))
    return
  end
  local tbl = Table.Create({
    { title = 'COMMODITY', width = COL_ITEM  },
    { title = 'HELD',      width = COL_COUNT },
    { title = 'PRICE',     width = COL_PRICE },
    { title = ' ',         width = 220       },
  }, { height = 240 })

  local any = false
  for _, q in ipairs(market:quotes()) do
    local have = ship:getItemCount(q.item)
    if q.bid and have > 0 then
      any = true
      local btns = Grid():setCols(2):setStretch(0, 0)
      btns:setPadCellX(4)
      btns:add(MenuButton.Create('SELL 1', function ()
        self:trade(q.item, 1, true)
      end))
      btns:add(MenuButton.Create('SELL ALL', function ()
        self:trade(q.item, have, true)
      end))
      tbl:AddRow({
        q.item:getName(),
        tostring(have),
        tostring(q.bid),
        btns,
      })
    end
  end
  grid:add(tbl)
  if not any then
    grid:add(cell('You are holding nothing this market bids on.', nil, MUTED))
  end
  grid:add(cell(' ', nil, MUTED))
  grid:add(MenuButton.Create('SELL EVERYTHING', function ()
    self:sellAll()
  end))
end

-- The dock keys keep working while the page is up: F undocks, R sells
-- everything, T buys the cheapest ask (the same keys the text overlay
-- had, so gamepad/quick hands keep their flow).
function DockScreen:onInput ()
  if ShipBindings.Dock:get() > 0 then
    self.player:getControlling():pushAction(Actions.Undock())
    return
  end
  if ShipBindings.Sell:get() > 0 then self:sellAll() end
  if ShipBindings.Buy:get() > 0 then self:buyOne() end
end

return DockScreen
