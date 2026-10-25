local Entity = require('Game.Entity')
local Registry = require('Game.EconomyRegistry')
local PriceCurve = require('Game.PriceCurve')

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
      -- THE ESCROW: a SELL order parks its goods at list time, so the
      -- book never promises one shelf twice (a factory and a book would
      -- otherwise both spend the same inventory), and a buyer can never
      -- be told the shelf has stock it does not.
      escrowStock = 0,
    }
  end

  local orders = type == OrderType.Buy and
    data[item].ordersBuy or
    data[item].ordersSell

  -- A SELL order is escrowed goods, not a promise: take what the actor
  -- actually holds out of its inventory the moment the order is listed.
  -- Whatever it lacked simply does not make it into the book.
  if type == OrderType.Sell and actor.getItemCount then
    local held = actor:getItemCount(item)
    if held < count then count = held end
    if count > 0 then
      actor:removeItem(item, count)
      data[item].escrowStock = data[item].escrowStock + count
    end
    -- An ask with nothing behind it never enters the book.
    if count <= 0 then return end
  end

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
  -- The STANDING orders: a station's permanent demand and stock, seeded
  -- by the world and topped up by update() whenever trading depletes
  -- the book (a one-shot bid would go silent forever once filled, which
  -- read as "the market stopped wanting my ore").
  self.standingBuy = {}
  self.standingSell = {}
  -- THE OPEN STATE: whether this station BUYS at all. A closed market
  -- still SELLS its stock (an abandoned or damaged station has
  -- leftovers but no demand; a fuel depot may sell equipment but not
  -- take goods) -- the knob gameplay mechanics will flip.
  self.open = true
end)

function Market:isOpen ()
  return self.open ~= false
end

function Market:setOpen (open)
  self.open = open and true or false
end

function Market:addBuy (...)
  addOrder(OrderType.Buy, self, ...)
end

function Market:addSell (...)
  addOrder(OrderType.Sell, self, ...)
end

-- STANDING orders: the world seeds a station's permanent demand (the
-- bid for a belt's ore) and stock (what its factory makes, the
-- consumables an outpost sells). update() keeps the books at that
-- level, and the OPENING order prices off the shelf like every re-arm
-- does (a new place with an empty shelf bids 1.5x its anchors).
function Market:addStandingBuy (actor, item, count, price)
  self.standingBuy[item] = { actor = actor, count = count, price = price }
  local stock = actor.getItemCount and actor:getItemCount(item) or 0
  self:addBuy(actor, item, count, PriceCurve.price(price, stock, count))
end

function Market:addStandingSell (actor, item, count, price)
  self.standingSell[item] = { actor = actor, count = count, price = price }
  self:addSell(actor, item, count, price)
end

function Market:escrowFor (item, count)
  local book = self.data[item]
  if not book then return 0 end
  local parked = math.min(count, book.escrowStock or 0)
  book.escrowStock = (book.escrowStock or 0) - parked
  return parked
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

  -- TOP UP the standing books. Trading (the player's, an NPC miner's)
  -- depletes them; the demand and the stock are the station's
  -- PERMANENT state, so a sold-out bid re-arms instead of the market
  -- going quiet forever.

  -- THE LIVING PRICE: the re-arm price follows the shelf (PriceCurve).
  -- A drained bid means the place wanting the material, and it pays more
  -- to get it; a full shelf discounts. Prices drift around the anchors
  -- in Content.lua, so two stations in different states quote different
  -- prices -- which is what the AI caravans arbitrage.
  for item, s in pairs(self.standingBuy) do
    local book = self.data[item]
    local cur = 0
    if book then
      for _, o in ipairs(book.ordersBuy) do cur = cur + o.count end
    end
    if s.count > cur then
      -- The buyer can only bid for what it can pay for when filled
      -- (the settle path takes the credits out of the actor's bank).
      local credits = s.actor.getCredits and s.actor:getCredits() or 0
      local stock = s.actor.getItemCount and s.actor:getItemCount(item) or 0
      local price = PriceCurve.price(s.price, stock, s.count)
      local want = min(s.count - cur, floor(credits / price))
      if want > 0 then
        self:addBuy(s.actor, item, want, price)
      end
    end
  end

  -- The SELL side re-arms from the SHELF, not from the standing level:
  -- the book offers what the place actually holds (escrowed at list
  -- time), at a scarcity price. A station that has produced comes back
  -- on the market; a drained depot goes quiet rather than lying.
  for item, s in pairs(self.standingSell) do
    local book = self.data[item]
    local cur = 0
    if book then
      for _, o in ipairs(book.ordersSell) do cur = cur + o.count end
    end
    local stock = s.actor.getItemCount and s.actor:getItemCount(item) or s.count
    local want = min(s.count, stock)
    if want > cur then
      local price = PriceCurve.price(s.price, stock, s.count)
      self:addSell(s.actor, item, want - cur, price)
    elseif
      -- Orphaned escrow returns to the shelf: no sell orders left means
      -- the goods are not promised to anyone.
      cur == 0 and book and (book.escrowStock or 0) > 0 then
      s.actor:addItem(item, book.escrowStock)
      book.escrowStock = 0
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

  -- Walk the book, best bid first, and settle each order as it is
  -- filled. Per order, the fill is the least of what remains in the
  -- caller's trade, what the order holds, and what the buyer's bank
  -- actually covers (removeCredits asserts; without the clamp a
  -- drained bid crashed the market instead of just going quiet). A buy
  -- order holds no goods-escrow -- the escrow is the ASKS' business,
  -- and applying it here withdrew every standing bid instantly.
  local total, filled = 0, 0
  -- Walking DOWN from the best bid (the list sorts best-last). Every
  -- settle-or-withdraw step removes at the current index only, which
  -- shifts just the already-visited tail; stepping down one seems then.
  local i = #orders
  while i >= 1 do
    if filled >= count then break end
    local o = orders[i]
    if o.price > 0 then
      local q = math.min(count - filled, o.count)
      -- The buyer's bank: a place cannot pay for what it no longer has
      -- credits for (removeCredits asserts; without the clamp a drained
      -- bid crashed the market instead of just going quiet). BUY orders
      -- hold no goods-escrow -- the escrow check is the ASKS' business,
      -- and applying it here withdrew every standing bid instantly.
      q = math.min(q, math.floor(o.actor:getCredits() / o.price))
      if q > 0 then
        local paid = q * o.price
        -- The goods and the money change hands: the seller gives the
        -- goods (their hold) and is paid; the buyer pays (their bank)
        -- and takes the goods into their inventory.
        if not actor:removeItem(item, q) then break end
        o.actor:removeCredits(paid)
        o.actor:addItem(item, q)
        actor:addCredits(paid)
        o.count = o.count - q
        o.countTotal = o.countTotal - q
        total = total + paid
        filled = filled + q
        if o.count <= 0 then table.remove(orders, i) end
      else
        -- A broke bid withdraws itself rather than sitting at the top
        -- of the book forever.
        table.remove(orders, i)
      end
      i = i - 1
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

  -- Walk the book again, settling each order as it is filled. The
  -- goods come out of the BOOK'S ESCROW (they were parked from the
  -- seller at list time), the credits from the buyer; the seller is
  -- compensated from nothing -- the ask took no credits from them.
  local paid = 0
  for i = #orders, 1, -1 do
    if paid >= fillable then break end
    local o = orders[i]
    if o.price > 0 then
      local q = math.min(fillable - paid, o.count,
                         book.escrowStock or 0)
      local cost = q * o.price
      actor:removeCredits(cost)
      self:escrowFor(item, q)
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
