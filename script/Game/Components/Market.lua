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
function Market:sell (actor, item, count)
  local book = self.data[item]
  if not book then return 0, 0 end
  local orders = book.ordersBuy
  local order = orders and orders[#orders]
  if not order or order.price <= 0 then return 0, 0 end

  count = math.min(count, order.count)
  if count <= 0 then return 0, 0 end
  if not actor:hasItem(item, count) then return 0, 0 end

  -- A SELL needs no credits from the seller -- the seller is being PAID.
  -- (It is the buyer who has to be able to pay, and that is the market's
  -- business, not the seller's.)
  local total = order.price * count

  -- The goods and the money change hands: the seller gives the goods and
  -- is paid; the buyer pays and gets them.
  actor:removeItem(item, count)
  order.actor:addItem(item, count)
  order.actor:removeCredits(total)
  actor:addCredits(total)

  order.count = order.count - count
  order.countTotal = order.countTotal - count
  if order.count <= 0 then table.remove(orders, #orders) end
  return count, total
end

-- Buy from the market: the best SELL order, which is the LOWEST ask.
function Market:buy (actor, item, count)
  local book = self.data[item]
  if not book then return 0, 0 end
  local orders = book.ordersSell
  local order = orders and orders[#orders]
  if not order or order.price <= 0 then return 0, 0 end

  count = math.min(count, order.count)
  if count <= 0 then return 0, 0 end
  local total = order.price * count
  if not actor:hasCredits(total) then
    count = math.floor(actor:getCredits() / order.price)
    if count <= 0 then return 0, 0 end
    total = order.price * count
  end
  if not actor:addItem(item, count) then return 0, 0 end

  actor:removeCredits(total)
  order.actor:removeItem(item, count)
  order.actor:addCredits(total)

  order.count = order.count - count
  order.countTotal = order.countTotal - count
  if order.count <= 0 then table.remove(orders, #orders) end
  return count, total
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
