-- Shared cargo presentation for the flight HUD and dock screen.

local Cargo = {}

function Cargo.Summary (ship)
  if not ship or not ship.hasInventory or not ship:hasInventory() then return 0, 0, 0 end
  local capacity = ship:getInventoryCapacity()
  local free = ship:getInventoryFree()
  return capacity - free, capacity, free
end

function Cargo.Lines (ship)
  local lines = {}
  if not ship or not ship.hasInventory or not ship:hasInventory() then return lines end
  for item, count in pairs(ship:getInventory()) do
    if count > 0 then
      lines[#lines + 1] = {
        item = item,
        name = item:getName(),
        count = count,
        mass = count * item:getMass(),
      }
    end
  end
  table.sort(lines, function (a, b) return a.name < b.name end)
  return lines
end

function Cargo.FormatSummary (ship)
  local used, capacity, free = Cargo.Summary(ship)
  return string.format('CARGO %d / %d  FREE %d', used, capacity, free)
end

return Cargo
