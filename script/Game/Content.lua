-- This is a placeholder file for directly adding game content that would
-- typically be added in mod format

-- Items -----------------------------------------------------------------------

local Item = require('Game.Item')

Item.Energy = Item('Energy Cell', 1, 1.0)
Item.Isotopes = Item('Radioactive Isotopes', 5, 2.0)
Item.Silver = Item('Silver', 2, 5.0)
Item.Waste = Item('Radioactive Waste', 1, 0.5)

Item.T1 = {}
Item.T2 = {}

insert(Item.T1, Item.Isotopes)
insert(Item.T1, Item.Silver)
insert(Item.T2, Item.Energy)

-- What things are worth.
--
-- A station BUYS the raw commodities a belt yields, at these prices, and
-- SELLS what its factory makes, for more than it paid. The spread is the
-- station's margin, and it is the reason the player's loop is worth
-- running: mine here, sell there, and the difference is yours.
Item.Price = {
  [Item.Isotopes] = 14,   -- the belt's raw product, and the reactors' fuel
  [Item.Silver]   = 9,    -- the reactors' control rods: a SECOND reason a
                          -- belt pays (silver yields alongside isotopes)
  [Item.Energy]   = 26,   -- a reactor makes 10 of these from one isotope
  [Item.Waste]    = 3,    -- toxic near-junk: the DISPOSAL price a place
                          -- pays to take it off your hold, and the bound
                          -- price it asks when handing it on to a solar
                          -- array -- a wash, so no round-trip arbitrage
}

-- Production ------------------------------------------------------------------

local Production = require('Game.Production')

Production.EnergySolar = Production('Solar Energy Array')
  :addInput(Item.Waste, 1)
  :addOutput(Item.Energy, 5)
  :setDuration(0.5)

Production.EnergyNuclear = Production('Nuclear Reactor')
  :addInput(Item.Isotopes, 1)
  :addInput(Item.Silver, 1) -- THE SILVER SINK: control rods per round.
  -- The belt yields silver as well as isotopes, and without a consumer
  -- silver was dead weight; priced at 9 against a 260-credit round, it
  -- is the fee, not the cost -- the makers of the energy demand it.
  :addOutput(Item.Energy, 10)
  :addOutput(Item.Waste, 2)
  :setDuration(0.1)

--------------------------------------------------------------------------------
