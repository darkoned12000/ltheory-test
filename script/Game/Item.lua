local all = {}

local Item = class(function (self, name, mass, energyDensity)
  self.name = name
  self.mass = mass or 1
  self.energy = (energyDensity or 1) * self.mass
  insert(all, self)
end)

function Item.All ()
  return all
end

function Item:getEnergy ()
  return self.energy
end

function Item:getEnergyDensity ()
  return self.energy / self.mass
end

function Item:getMass ()
  return self.mass
end

function Item:getName ()
  return self.name
end

function Item:setEnergy (energy)
  self.energy = energy
  return self
end

Item.Credit = Item('Credit')
Item.Credit.mass = 0

-- ORE: what a belt region is FOR.
--
-- The old code marked the last N rocks of a static field as ore-bearing
-- with `rng:choose(Item.T1)` -- and there is no Item.T1, so every one of
-- those rocks was given a yield of NIL, which is a mining action that hands
-- the player nothing. The item the game had been reaching for did not
-- exist.
Item.Ore = Item('Ore')

return Item
