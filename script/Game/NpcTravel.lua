-- Deterministic wormhole routing for NPCs. Routing only chooses a gate; the
-- TravelTo action performs the approach at normal simulation speed.

local NpcTravel = {}

function NpcTravel.Route (root, fromIndex, toIndex)
  fromIndex, toIndex = tonumber(fromIndex), tonumber(toIndex)
  if not fromIndex or not toIndex or fromIndex == toIndex then return {} end
  local sectors = root and root.sectors
  if type(sectors) ~= 'table' or not sectors[toIndex + 1] then return {} end
  local queue, previous = { fromIndex }, { [fromIndex] = -1 }
  local head = 1
  while head <= #queue do
    local current = queue[head]; head = head + 1
    local sector = sectors[current + 1]
    for _, neighbour in ipairs(sector and sector.neighbours or {}) do
      if previous[neighbour] == nil and sectors[neighbour + 1] then
        previous[neighbour] = current
        if neighbour == toIndex then
          local path, cursor = {}, toIndex
          while cursor ~= -1 do
            path[#path + 1] = cursor
            cursor = previous[cursor]
          end
          local out = {}
          for i = #path - 1, 1, -1 do out[#out + 1] = path[i] end
          return out
        end
        queue[#queue + 1] = neighbour
      end
    end
  end
  return {}
end

local function gates (root)
  if type(root.gates) == 'table' then return root.gates end
  local out = {}
  for _, child in ipairs(root and root.children or {}) do
    if child.isWormhole then out[#out + 1] = child end
  end
  return out
end

local function radius (entity)
  if entity and entity.getRadius and (entity.body or entity.isWormhole) then
    return math.max(0, tonumber(entity:getRadius()) or 0)
  end
  return 0
end

function NpcTravel.Distance (a, b)
  local pa, pb = a and a.getPos and a:getPos(), b and b.getPos and b:getPos()
  if not pa or not pb then return nil end
  if a.body and b.body and a.getMinDistance then return a:getMinDistance(b) end
  return math.max(0, (pb - pa):length() - radius(a) - radius(b))
end

local function distance (asset, gate)
  return NpcTravel.Distance(asset, gate) or 0
end

function NpcTravel.SelectGate (root, asset, targetSector)
  local route = NpcTravel.Route(root, root and root.sectorIndex, targetSector)
  if targetSector ~= nil and #route == 0 then return nil, route end
  local desired = route[1]
  local best, bestDistance
  for _, gate in ipairs(gates(root)) do
    if not gate.deleted and (not desired or gate:getPartnerSector() == desired) then
      local d = distance(asset, gate)
      local id = gate.stableId or gate:getName()
      if not best or d < bestDistance or (d == bestDistance and id < best:getName()) then
        best, bestDistance = gate, d
      end
    end
  end
  return best, route
end

-- Breadth-first search for the nearest sector that can satisfy a station
-- service. The current sector is excluded; callers use this only after live
-- local station lookup failed. Unknown legacy metadata is not assumed to have
-- a shipyard, while an absent hasStation flag remains a conservative maybe.
function NpcTravel.ServiceSector (root, shipyardOnly)
  local sectors = root and type(root.sectors) == 'table' and root.sectors or nil
  local origin = root and tonumber(root.sectorIndex)
  if not sectors or not origin or not sectors[origin + 1] then return nil end
  local queue, seen = { origin }, { [origin] = true }
  local head = 1
  while head <= #queue do
    local current = queue[head]; head = head + 1
    local sector = sectors[current + 1]
    for _, neighbour in ipairs(sector and sector.neighbours or {}) do
      if not seen[neighbour] and sectors[neighbour + 1] then
        seen[neighbour] = true
        local candidate = sectors[neighbour + 1]
        local available = shipyardOnly and candidate.hasShipyard == true
          or (not shipyardOnly and candidate.hasStation ~= false)
        if available then return neighbour end
        queue[#queue + 1] = neighbour
      end
    end
  end
  return nil
end

function NpcTravel.NormalEta (asset, gate)
  local d = distance(asset, gate)
  local speed = asset and asset.getTopSpeed and asset:getTopSpeed() or 0
  return d, speed, speed > 0 and d / speed or math.huge
end

return NpcTravel
