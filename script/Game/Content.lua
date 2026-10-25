-- This is a placeholder file for directly adding game content that would
-- typically be added in mod format

local Item = require('Game.Item')

-- Items -----------------------------------------------------------------------
--
-- T1 = raw commodities (mined from asteroids, captured from nebulas, or
--      harvested). These are what the belts yield and what every market
--      stands a permanent bid for: the economy's "inputs".
-- T2 = refined / intermediate products (produced by factories). These are
--      what a place SELLS -- the loop's payoff and the crafting feedstock.
-- Gas = captured nebula gases. NOT in T1: they do not come out of a rock,
--       they are harvested from a nebula with the right equipment (a future
--       feature -- the item exists and is priced so the market can trade
--       it, but no source is wired yet).

Item.Energy = Item('Energy Cell', 1, 1.0)
Item.Isotopes = Item('Radioactive Isotopes', 5, 2.0)
Item.Silver = Item('Silver', 2, 5.0)
Item.Waste = Item('Radioactive Waste', 1, 0.5)

-- Raw minerals (precious + common): the belt's yield, and the feedstock
-- for weapon design, ship hulls and electronics.
Item.Iron = Item('Iron Ore', 4, 1.0)
Item.Copper = Item('Copper Ore', 3, 1.2)
Item.Titanium = Item('Titanium Ore', 4, 2.0)   -- weapon/ship hull metal
Item.Platinum = Item('Platinum', 3, 1.5)       -- weapon design catalyst
Item.Gold = Item('Gold', 2, 0.5)               -- computer applications

-- Hydration / life support: the pull from populated planets.
Item.WaterIce = Item('Water Ice', 3, 0.2)

-- Captured nebula gases (require capture equipment -- see docs).
Item.Helium3 = Item('Helium-3', 1, 0.1)

-- Refined / intermediate products.
Item.MachineParts = Item('Machine Parts', 4, 3.0)
Item.Electronics = Item('Electronics', 2, 4.0)  -- Gold + Silver
Item.WeaponComponents = Item('Weapon Components', 5, 5.0) -- Titanium + Platinum
Item.FoodRations = Item('Food Rations', 2, 2.0) -- hydration/population demand

Item.T1 = {}
Item.T2 = {}
Item.Gas = {}

insert(Item.T1, Item.Isotopes)
insert(Item.T1, Item.Silver)
insert(Item.T1, Item.Iron)
insert(Item.T1, Item.Copper)
insert(Item.T1, Item.Titanium)
insert(Item.T1, Item.Platinum)
insert(Item.T1, Item.Gold)
insert(Item.T1, Item.WaterIce)

insert(Item.T2, Item.Energy)
insert(Item.T2, Item.MachineParts)
insert(Item.T2, Item.Electronics)
insert(Item.T2, Item.WeaponComponents)
insert(Item.T2, Item.FoodRations)

insert(Item.Gas, Item.Helium3)

-- What things are worth.
--
-- A station BUYS the raw commodities a belt yields, at these prices, and
-- SELLS what its factory makes, for more than it paid. The spread is the
-- station's margin, and it is the reason the player's loop is worth
-- running: mine here, sell there, and the difference is yours.
Item.Price = {
  -- Raw ores (T1)
  [Item.Isotopes] = 14,   -- the belt's raw product, and the reactors' fuel
  [Item.Silver]   = 9,    -- the reactors' control rods
  [Item.Iron]     = 6,    -- common, cheap to haul
  [Item.Copper]   = 8,    -- conductive feedstock
  [Item.Titanium] = 18,   -- ship hulls and weapon housings
  [Item.Platinum] = 22,   -- weapon design catalyst
  [Item.Gold]     = 40,   -- computer applications, scarce
  [Item.WaterIce] = 5,    -- hydration / life support, bulky

  -- Captured nebula gases (require capture equipment -- see docs)
  [Item.Helium3]  = 15,   -- nebula gas, high energy density

  -- Refined / intermediate products (T2)
  [Item.Energy]   = 26,   -- a reactor makes 10 of these from one isotope
  [Item.MachineParts] = 24,
  [Item.Electronics] = 30,  -- Gold + Silver
  [Item.WeaponComponents] = 45, -- Titanium + Platinum
  [Item.FoodRations] = 12,  -- population demand

  -- Byproduct / sink
  [Item.Waste]    = 3,    -- toxic near-junk: the DISPOSAL price a place
                          -- pays to take it off your hold, and the bound
                          -- price it asks when handing it on to a solar
                          -- array -- a wash, so no round-trip arbitrage
}

-- Production ------------------------------------------------------------------
--
-- Recipes use the fluent chain; setDuration RETURNS self (see
-- Game/Production.lua) so the named fields are actually populated.

local Production = require('Game.Production')

Production.EnergySolar = Production('Solar Energy Array')
  :addInput(Item.Waste, 1)
  :addOutput(Item.Energy, 5)
  :setDuration(0.5)

Production.EnergyNuclear = Production('Nuclear Reactor')
  :addInput(Item.Isotopes, 1)
  :addInput(Item.Silver, 1) -- THE SILVER SINK: control rods per round.
  :addOutput(Item.Energy, 10)
  :addOutput(Item.Waste, 2)
  :setDuration(0.1)

Production.Refinery = Production('Refinery')
  :addInput(Item.Iron, 2)
  :addInput(Item.Copper, 1)
  :addOutput(Item.MachineParts, 1)
  :setDuration(0.2)

Production.Electronics = Production('Electronics Plant')
  :addInput(Item.Gold, 1)
  :addInput(Item.Silver, 1)
  :addOutput(Item.Electronics, 2)
  :setDuration(0.3)

Production.Weapons = Production('Weapons Fabricator')
  :addInput(Item.Titanium, 2)
  :addInput(Item.Platinum, 1)
  :addOutput(Item.WeaponComponents, 1)
  :setDuration(0.4)

Production.Hydroponics = Production('Hydroponics Bay')
  :addInput(Item.WaterIce, 2)
  :addOutput(Item.FoodRations, 3)
  :setDuration(0.5)

--------------------------------------------------------------------------------