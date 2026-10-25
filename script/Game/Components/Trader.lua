local Entity = require('Game.Entity')
local Registry = require('Game.EconomyRegistry')
local PriceCurve = require('Game.PriceCurve')
local Credit = require('Game.Item').Credit

--------------------------------------------------------------------------------

local Trader = class(function (self, parent)
  self.parent = parent
  self.credits = 0
  self.elems = {}
  -- The STANDING bids: the station's permanent demand, re-armed by
  -- update() when the AI's deliveries drain the book (the same rule the
  -- player-facing Market's standing orders follow).
  self.standingBids = {}
  -- The STANDING offers: the shelf's goods, listed as AI-buyable asks
  -- (stock-backed, capped) -- the buy-in side of the caravan trade.
  self.standingAsks = {}
end)

function Trader:getData (item)
  if not self.elems[item] then
    self.elems[item] = {
      asks = {},
      bids = {},
      asksQueue = {},
      bidsQueue = {},
      totalAsk = 0,
      totalAskPrice = 0,
      totalBid = 0,
      totalBidPrice = 0,
      escrow = 0,
    }
  end
  return self.elems[item]
end

function Trader:addAsk (item, price)
  local data = self:getData(item)
  if not self.parent:removeItem(item, 1) then return false end
  data.escrow = data.escrow + 1
  insert(data.asksQueue, price)
  return true
end

function Trader:addBid (item, price)
  local data = self:getData(item)
  -- TODO : Remove credits
  insert(data.bidsQueue, price)
  return true
end

-- Return the maximum profitable volume and corresponding total profit from
-- buying item here and selling at dst
function Trader:computeTrade (item, maxCount, dst)
  local src = self

  local asks = src:getData(item).asks
  local bids = dst:getData(item).bids
  local count = 0
  local profit = 0

  local i = 1
  while count < maxCount do
    local ask = asks[i]
    local bid = bids[i]
    if not ask or not bid or ask >= bid then break end
    count = count + 1
    profit = profit + (bid - ask)
    i = i + 1
  end

  return count, profit
end

function Trader:getBidVolume (item)
  local data = self:getData(item)
  return #data.bids + #data.bidsQueue
end

function Trader:getAskVolume (item)
  local data = self:getData(item)
  return #data.asks + #data.asksQueue
end

function Trader:getBuyFromPrice (item, count)
  local price = 0
  local asks = self:getData(item).asks
  for i = 1, count do
    price = price + (asks[i] or math.huge)
  end
  return price
end

function Trader:getSellToPrice (item, count)
  local price = 0
  local bids = self:getData(item).bids
  for i = 1, count do
    price = price + (bids[i] or 0)
  end
  return price
end

function Trader:buy (asset, item)
  local player = asset:getOwner()
  local data = self:getData(item)
  if #data.asks == 0 then return false end
  local price = data.asks[1]
  assert(data.escrow > 0)
  if not player:hasItem(Credit, price) then return false end

  asset:addItem(item, 1)
  player:removeItem(Credit, price)
  self.credits = self.credits + price
  data.totalAsk = data.totalAsk + 1
  data.totalAskPrice = data.totalAskPrice + price
  data.escrow = data.escrow - 1
  remove(data.asks, 1)
  return true
end

function Trader:sell (asset, item)
  local player = asset:getOwner()
  local data = self:getData(item)
  if #data.bids == 0 then return false end
  if not asset:hasItem(item, 1) then return false end

  local price = data.bids[1]
  -- THE BANK: a trader pays from its own escrow (a 100k bank, seeded by
  -- the world). Without this guard the subtraction went NEGATIVE and the
  -- place kept buying with money it did not have.
  if self.credits < price then return false end
  asset:removeItem(item, 1)
  player:addItem(Credit, price)
  self.credits = self.credits - price
  data.totalBid = data.totalBid + 1
  data.totalBidPrice = data.totalBidPrice + price
  self.parent:addItem(item, 1)
  remove(data.bids, 1)
  return true
end

local function sortAsks (a, b)
  return a < b
end

local function sortBids (a, b)
  return a > b
end

-- STANDING demand: `count` deep, at this price. The AI's Mine jobs price
-- themselves against this book (Trader:sell pays the top bid); without a
-- seeded book every job pays 0 and the AI stays idle forever.
function Trader:addStandingBid (item, price, count)
  self.standingBids[item] = { price = price, count = count }
  for _ = 1, count do self:addBid(item, price) end
end

-- STANDING offers: the place's shelf, `count` deep, re-armed from what
-- it holds BEYOND a factory's working reserve (addAsk pulls the good
-- from inventory into the book's escrow, so an ask is real stock, never
-- a promise). These are the books the AI caravans buy from when running
-- Transport between two places, at the same living price.
function Trader:addStandingAsk (item, anchor, count, reserve)
  self.standingAsks[item] = {
    price = anchor, count = count, reserve = reserve or 0 }
end

-- The LIVING PRICE on this place's demand side: the same PriceCurve the
-- player-facing market bends -- the place bids high when its shelf is
-- bare, low when it is full. So two stations in different states offer
-- two different prices for the same commodity, and THAT difference is
-- what the AI caravans (Jobs.Transport via computeTrade) arbitrage.
function Trader:bidPrice (item)
  local s = self.standingBids[item]
  if not s then return 0 end
  local stock = self.parent.getItemCount and self.parent:getItemCount(item) or 0
  return PriceCurve.price(s.price, stock, s.count)
end

function Trader:update ()
  for item, data in pairs(self.elems) do
    if #data.asksQueue > 0 then
      for i, v in ipairs(data.asksQueue) do insert(data.asks, v) end
      table.clear(data.asksQueue)
      table.sort(data.asks, sortAsks)
    end

    if #data.bidsQueue > 0 then
      for i, v in ipairs(data.bidsQueue) do insert(data.bids, v) end
      table.clear(data.bidsQueue)
      table.sort(data.bids, sortBids)
    end
  end

  -- Re-arm the standing demand the deliveries have drained. At the
  -- living price, and only while the bank can conceivably pay for it:
  -- a broke trader stops pretending to buy.
  for item, s in pairs(self.standingBids) do
    local data = self:getData(item)
    local price = self:bidPrice(item)
    while #data.bids + #data.bidsQueue < s.count
      and self.credits >= price do
      self:addBid(item, price)
    end
  end

  -- Re-arm the standing offers from the shelf. Each listed ask moves
  -- one unit of the good from the place's inventory into the book's
  -- escrow (that is what addAsk does), so the asks never exceed the
  -- real stock; the cap (s.count) keeps a producing factory's whole
  -- output stream out of one book -- the trade stays from a shelf,
  -- not a firehose.
  for item, s in pairs(self.standingAsks) do
    local data = self:getData(item)
    local stock = self.parent.getItemCount and self.parent:getItemCount(item) or 0
    -- THE PLANT'S WORKING STOCK: the asks may only offer what the shelf
    -- holds BEYOND the production's reserve. Without it, the caravan
    -- books stripped the incoming ore instantly and the local factory
    -- starved -- input reserves guaranteed, surplus haulable.
    local reserve = s.reserve or 0
    if #data.asks + #data.asksQueue < s.count and stock > reserve then
      local price = PriceCurve.price(s.price, stock - reserve, s.count)
      self:addAsk(item, price)
    end
  end
end

--------------------------------------------------------------------------------

function Entity:addTrader ()
  assert(not self.trader)
  self.trader = Trader(self)
  self:register(Event.Debug, Entity.debugTrader)
  self:register(Event.Update, Entity.updateTrader)
  Registry.register(self)
end

function Entity:debugTrader (state)
  local ctx = state.context
  ctx:text('Trader')
  ctx:indent()
  ctx:text('Credits: %d', self.trader.credits)
  for item, data in pairs(self.trader.elems) do
    ctx:text('%s', item:getName())
    ctx:indent()
    if #data.bids > 0 then
      ctx:text('[BID] Vol: %d  Hi: %d', #data.bids, data.bids[1])
    end
    if #data.asks > 0 then
      ctx:text('[ASK] Vol: %d  Lo: %d', #data.asks, data.asks[1])
    end
    ctx:undent()
  end
  ctx:undent()
end

function Entity:getTrader ()
  assert(self.trader)
  return self.trader
end

function Entity:hasTrader ()
  return self.trader ~= nil
end

function Entity:updateTrader (state)
  self.trader:update(state.dt)
end

--------------------------------------------------------------------------------
