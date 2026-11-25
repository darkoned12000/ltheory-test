-- Pure radar/scanner presentation math. The HUD supplies ship basis vectors
-- and ScannerDB contacts; this module stays allocation-light and testable.

local Radar = {}

local RANGE = 50000

local function hash (value)
  local h = 2166136261 % 2147483647
  for i = 1, #tostring(value) do
    h = (h * 33 + tostring(value):byte(i)) % 2147483647
  end
  return h
end

function Radar.ClampScale (scale)
  scale = tonumber(scale) or 1
  if scale < 0.5 then return 0.5 end
  if scale > 2 then return 2 end
  return scale
end

function Radar.FormatRange (range)
  local km = math.max(0, tonumber(range) or 0) / 1000
  if km % 1 ~= 0 then return string.format('%.1f km', km) end
  return string.format('%.0f km', km)
end

function Radar.Contains (cx, cy, radius, x, y)
  local dx, dy = x - cx, y - cy
  return dx*dx + dy*dy <= radius*radius
end

function Radar.Blip (delta, right, forward, range, radius)
  local x = delta:dot(right)
  local y = delta:dot(forward)
  local distance = math.sqrt(x*x + y*y)
  if distance > range then return nil end
  local scale = radius / math.max(1, range)
  return { x = x * scale, y = -y * scale, distance = distance }
end

function Radar.SignalFor (entity)
  if not entity then return 'contact' end
  if entity.isAsteroid then
    return entity.hasYield and entity:hasYield() and 'ore' or 'asteroid'
  end
  if entity.isPlanet then return 'planet' end
  if entity.hasDockable and entity:hasDockable() then return 'station' end
  if entity.hasSockets and entity:hasSockets() then return 'ship' end
  return 'contact'
end

function Radar.ShowSignal (signal, filters)
  if not filters then return true end
  if signal == 'ore' or signal == 'asteroid' then return filters.asteroids ~= false end
  if signal == 'ship' then return filters.ships ~= false end
  if signal == 'station' then return filters.stations ~= false end
  if signal == 'planet' then return filters.planets ~= false end
  if signal == 'star' then return filters.stars ~= false end
  return true
end

function Radar.SelectContacts (contacts, limit)
  limit = limit or 64
  local caps = { star = 1, planet = 4, station = 8, ship = 12,
    asteroid = 32, contact = 8 }
  local order = { 'star', 'planet', 'station', 'ship', 'asteroid', 'contact' }
  local groups = {}
  local function distance (contact) return contact.distance2 or math.huge end

  -- Keep only each category's nearest cap while scanning. Sorting the whole
  -- 8k-rock field twice per refresh caused visible frame spikes; these bounded
  -- insertions do the same selection without an O(N log N) sort.
  for _, contact in ipairs(contacts) do
    local category = contact.signal == 'ore' and 'asteroid' or contact.signal
    local cap = caps[category] or limit
    local group = groups[category]
    if not group then group = {}; groups[category] = group end
    local d = distance(contact)
    if #group < cap then
      local at = #group + 1
      while at > 1 and d < distance(group[at - 1]) do
        group[at] = group[at - 1]
        at = at - 1
      end
      group[at] = contact
    elseif d < distance(group[#group]) then
      local at = #group
      while at > 1 and d < distance(group[at - 1]) do
        group[at] = group[at - 1]
        at = at - 1
      end
      group[at] = contact
    end
  end

  local selected = {}
  for _, category in ipairs(order) do
    for _, contact in ipairs(groups[category] or {}) do
      if #selected >= limit then break end
      selected[#selected + 1] = contact
    end
  end
  return selected
end

function Radar.SignalBand (signal)
  if signal == 'ore' then return 0.28 end
  if signal == 'asteroid' then return 0.22 end
  if signal == 'ship' then return 0.52 end
  if signal == 'station' then return 0.66 end
  if signal == 'planet' then return 0.74 end
  if signal == 'star' then return 0.96 end
  return nil
end

function Radar.Spectrum (contacts, origin, now, bars, forward, fovCos)
  bars = bars or 64
  local values = {}
  for i = 1, bars do
    values[i] = 0.035 + 0.015 * math.sin(i * 1.71 + (now or 0) * 0.7)
  end
  for _, contact in ipairs(contacts) do
    local p = contact.position
    if p then
      local dx, dy, dz = p.x - origin.x, p.y - origin.y, p.z - origin.z
      local distance = math.sqrt(dx*dx + dy*dy + dz*dz)
      local directional = 1
      if forward and distance > 1e-6 then
        local dot = (dx * forward.x + dy * forward.y + dz * forward.z) / distance
        if dot < (fovCos or 0.7) then directional = 0
        else directional = (dot - (fovCos or 0.7)) / math.max(1e-6, 1 - (fovCos or 0.7)) end
      end
      if distance <= RANGE and directional > 0 then
        local band = Radar.SignalBand(contact.signal)
        local center = band and math.floor(1 + band * (bars - 1))
          or (1 + hash(contact.key) % bars)
        local classBoost = contact.signal == 'star' and 2.0
          or contact.signal == 'planet' and 1.25 or 1.0
        local strength = (0.35 + 0.15 * (contact.tier or 1))
          * (1.0 - distance / RANGE) * directional * classBoost
        for i = 1, bars do
          local d = i - center
          if d > bars / 2 then d = d - bars end
          if d < -bars / 2 then d = d + bars end
          local peak = math.exp(-(d*d) / 5.0) * strength
          values[i] = math.min(1, values[i] + peak)
        end
      end
    end
  end
  return values
end

return Radar
