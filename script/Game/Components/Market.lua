local Entity = require('Game.Entity')
local Registry = require('Game.EconomyRegistry')

local OrderType = {
  Buy = {
    -- Buy orders are sorted such that last element has the highest bid price
    comparator = function (a, b) return a.price < b.price end
  },

  Sell = {
    -- Sell orders are sorted such that last element has the lowest ask price
    comparator = function (a, b) return a.price > b.price end
  },
}

local function addOrder (type, self, actor, item, count, price)
  -- `data`, not `marketData`: the Market class initialises `self.data`
  -- (and both `update` and the debug dump read `self.data`), so
  -- `marketData` was a typo that had never been reached -- the market
  -- component existed, and nothing had ever put an order in it.
  local data = self.data
  if not data[item] then
    data[item] = {
      ordersBuy = {},
      ordersSell = {},
    }
  end

  local orders = type == OrderType.Buy and
    data[item].ordersBuy or
    data[item].ordersSell

  insert(orders, {
    actor = actor,
    item = item,
    count = count,
    countTotal = count,
    price = price,
  })

  -- TODO : Remove credits / items, put in escrow

  -- `table.sort`, not a bare `sort`: there is no global `sort` in this
  -- sandbox, and this line had never run.
  table.sort(orders, type.comparator)
end

local Market = class(function (self)
  self.data = {}
  self.escrow = {}
end)

function Market:addBuy (...)
  addOrder(OrderType.Buy, self, ...)
end

function Market:addSell (...)
  addOrder(OrderType.Sell, self, ...)
end

function Market:update (e, dt)
  for k, v in pairs(self.data) do
    while
      #v.ordersBuy > 0 and
      #v.ordersSell > 0 and
       v.ordersSell[#v.ordersSell].price <= v.ordersBuy[#v.ordersBuy].price
    do
      local orderBuy = v.ordersBuy[#v.ordersBuy]
      local orderSell = v.ordersSell[#v.ordersSell]
      local count = min(orderBuy.count, orderSell.count)
      local price = orderSell.price
      local total = count * price

      -- TODO : Transfer credits from escrow, transfer item from storage
      orderBuy.count = orderBuy.count - count
      orderSell.count = orderSell.count - count

      if false then
        e:addMessage('Market Transaction: %d %s from %s -> %s @ %d/unit (%d total)',
          count,
          v.item.name,
          orderSell.actor:getName(),
          orderBuy.actor:getName(),
          price,
          total)
      end

      if orderBuy.count == 0 then table.remove(v.ordersBuy) end
      if orderSell.count == 0 then table.remove(v.ordersSell) end
    end
  end
end

--------------------------------------------------------------------------------

--[[---------------------------------------------------------------------------
  The TRANSACTION.

  The matching loop above moves ORDER COUNTS. The escrow -- actually moving
  the goods and the credits between the two parties -- is still a TODO, so a
  trade changed the books and nothing else: the ore stayed in the player's
  hold and the credits never appeared. These two functions are the real
  thing.

  The player sells to the market's best BUY order (the highest bid, which
  is the last one in the list, because the list is sorted that way) and buys
  from its best SELL order (the lowest ask, likewise last). That is the
  same matching the loop does, with the transfer.
---------------------------------------------------------------------------]]
-- The PRICE of a quantity, walking the order book.
--
-- This is the old Limit Theory's algorithm, from the recovered
-- Market/Transaction.lts: take what you need from each order in turn and
-- add up what it costs. Our first version took the best price for the WHOLE
-- lot, which no market does -- it pays the top bid for a hundred units, and
-- it empties one order in a single trade.
--
-- The lists are sorted with the BEST price last (the buy orders ascend, the
-- sell orders descend), so the walk runs from the end backwards.
--
-- Returns the total price and how much the book could actually fill.
function Market:priceFor (item, count, buying)
  local book = self.data[item]
  if not book then return 0, 0 end
  local orders = buying and book.ordersSell or book.ordersBuy
  if not orders then return 0, 0 end
  local total, filled = 0, 0
  for i = #orders, 1, -1 do
    if filled >= count then break end
    local o = orders[i]
    if o.price > 0 then
      local q = math.min(count - filled, o.count)
      total = total + q * o.price
      filled = filled + q
    end
  end
  return total, filled
end

-- How deep the market is: the total volume on each side, and the best price
-- on each side. The old market's panel showed exactly this -- the buy
-- price, the sell price, and the supply against the demand.
function Market:depth (item)
  local book = self.data[item]
  if not book then return nil end
  local bid, ask, demand, supply
  if book.ordersBuy and #book.ordersBuy > 0 then
    local o = book.ordersBuy[#book.ordersBuy]
    bid = o.price
    for _, b in ipairs(book.ordersBuy) do demand = (demand or 0) + b.count end
  end
  if book.ordersSell and #book.ordersSell > 0 then
    local o = book.ordersSell[#book.ordersSell]
    ask = o.price
    for _, a in ipairs(book.ordersSell) do supply = (supply or 0) + a.count end
  end
  if not bid and not ask then return nil end
  return { bid = bid, ask = ask, demand = demand, supply = supply }
end

function Market:sell (actor, item, count)
  local book = self.data[item]
  if not book then return 0, 0 end
  local orders = book.ordersBuy
  if not orders or #orders == 0 then return 0, 0 end

  -- A SELL needs no credits from the seller -- the seller is being PAID.
  -- (It is the buyer who has to be able to pay, and that is the market's
  -- business, not the seller's.)
  if not actor:hasItem(item, count) then return 0, 0 end

  -- Walk the book, best bid first, and settle each order as it is filled.
  local total, filled = 0, 0
  for i = #orders, 1, -1 do
    if filled >= count then break end
    local o = orders[i]
    if o.price > 0 then
      local q = math.min(count - filled, o.count)
      local paid = q * o.price
      -- The goods and the money change hands: the seller gives the goods and
      -- is paid; the buyer pays and gets them.
      actor:removeItem(item, q)
      o.actor:addItem(item, q)
      o.actor:removeCredits(paid)
      actor:addCredits(paid)
      o.count = o.count - q
      o.countTotal = o.countTotal - q
      total = total + paid
      filled = filled + q
      if o.count <= 0 then table.remove(orders, i) end
    end
  end
  return filled, total
end

-- Buy from the market: the best SELL order, which is the LOWEST ask.
function Market:buy (actor, item, count)
  local book = self.data[item]
  if not book then return 0, 0 end
  local orders = book.ordersSell
  if not orders or #orders == 0 then return 0, 0 end

  -- The cheapest ask first, and only what the buyer can afford.
  local price, fillable = self:priceFor(item, count, true)
  if price <= 0 or fillable <= 0 then return 0, 0 end
  if not actor:hasCredits(price) then
    -- What the whole book would cost is more than the buyer has: take
    -- what they can afford, at the book's own prices.
    local budget = actor:getCredits()
    local total, filled = 0, 0
    for i = #orders, 1, -1 do
      if total >= budget then break end
      local o = orders[i]
      if o.price > 0 then
        local q = math.min(fillable - filled, o.count,
                           math.floor((budget - total) / o.price))
        if q > 0 then
          total = total + q * o.price
          filled = filled + q
        end
      end
    end
    price, fillable = total, filled
  end
  if fillable <= 0 or price <= 0 then return 0, 0 end
  if not actor:addItem(item, fillable) then return 0, 0 end

  -- Walk the book again, settling each order as it is filled.
  local paid = 0
  for i = #orders, 1, -1 do
    if paid >= fillable then break end
    local o = orders[i]
    if o.price > 0 then
      local q = math.min(fillable - paid, o.count)
      local cost = q * o.price
      actor:removeCredits(cost)
      o.actor:removeItem(item, q)
      o.actor:addCredits(cost)
      o.count = o.count - q
      o.countTotal = o.countTotal - q
      paid = paid + q
      if o.count <= 0 then table.remove(orders, i) end
    end
  end
  return paid, price
end

-- The market's prices, as a list for a UI: the item, the best bid, the
-- best ask, and how much of each there is.
function Market:quotes ()
  local out = {}
  for item, book in pairs(self.data) do
    local bid, ask, bidCount, askCount
    if book.ordersBuy and #book.ordersBuy > 0 then
      local o = book.ordersBuy[#book.ordersBuy]
      bid, bidCount = o.price, o.count
    end
    if book.ordersSell and #book.ordersSell > 0 then
      local o = book.ordersSell[#book.ordersSell]
      ask, askCount = o.price, o.count
    end
    if bid or ask then
      out[#out + 1] = { item = item, bid = bid, ask = ask,
                        bidCount = bidCount, askCount = askCount }
    end
  end
  table.sort(out, function (a, b) return a.item:getName() < b.item:getName() end)
  return out
end

function Entity:addMarket ()
  assert(not self.market)
  self.market = Market()
  self:register(Event.Debug, Entity.debugMarket)
  self:register(Event.Update, Entity.updateMarket)
  Registry.register(self)
end

function Entity:debugMarket (state)
  local ctx = state.context
  ctx:text('Market')
  ctx:indent()
  for k, v in pairs(self.market.data) do
    ctx:text(
      '%s : %d/%d buy/sell orders',
      k:getName(),
      #v.ordersBuy,
      #v.ordersSell)
  end
  ctx:undent()
end

function Entity:getMarket ()
  assert(self.market)
  return self.market
end

function Entity:hasMarket ()
  return self.market ~= nil
end

function Entity:updateMarket (state)
  self.market:update(self, state.dt)
end

--------------------------------------------------------------------------------
