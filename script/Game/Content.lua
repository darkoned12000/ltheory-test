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
  [Item.Silver]   = 9,
  [Item.Energy]   = 26,   -- a reactor makes 10 of these from one isotope
}

-- Production ------------------------------------------------------------------

local Production = require('Game.Production')

Production.EnergySolar = Production('Solar Energy Array')
  :addInput(Item.Waste, 1)
  :addOutput(Item.Energy, 5)
  :setDuration(0.5)

Production.EnergyNuclear = Production('Nuclear Reactor') 
  :addInput(Item.Isotopes, 1)
  :addOutput(Item.Energy, 10)
  :addOutput(Item.Waste, 2)
  :setDuration(0.1)

--------------------------------------------------------------------------------
