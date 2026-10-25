--[[ PriceCurve -- the LIVING price, one rule for every book in the game.

  The old sheet in Game/Content.lua (Item.Price) is the ANCHOR. This module
  moves the price around the anchor with the place's actual stock:

    * A BUYER bids highest when it has run out and lowest when its shelf is
      full -- stock 0 = 1.5x anchor (it needs the material NOW), stock at or
      above target = 0.75x anchor (saturated, easy pickings).
    * A SELLER asks highest when its shelf is empty and gives the biggest
      discount when glutted -- the SAME curve, so every dock's two books
      stay coherent with the shelf under them.

  The player-facing Market books, the AI-facing Trader books and the AI
  caravans (which price arbitrage runs against getBuyFromPrice /
  getSellToPrice) all price through this one curve, so no two systems in
  the game disagree about what a commodity is worth, and nothing can tell
  the player a different story from the trader room it sits next to.
]]

local PriceCurve = {}

-- The multiplier for a stock against a target: 1.5x at empty, 0.75x full.
function PriceCurve.factor (stock, target)
  if not (target and target > 0) then return 1 end
  local r = (stock or 0) / target
  if r < 0 then r = 0 elseif r > 1 then r = 1 end
  return 1.5 - 0.75 * r
end

-- The actual price: the anchor bent by the curve, floor 1 (prices are
-- integers, and a 0 bid reads as 'refusing').
function PriceCurve.price (anchor, stock, target)
  if not anchor then return end
  return math.max(1, math.floor(anchor * PriceCurve.factor(stock, target) + 0.5))
end

return PriceCurve
