-- Deterministic sector population planning. Engine spawning consumes this plan;
-- the planner itself is pure so sector contents can be tested without GL.

local Population = {}

Population.Roles = {
  fighter = {
    name = 'Fighter', shipType = 'fighter', scale = 4, cargo = 25,
    organization = 'belt-miners', jobs = { patrol = true },
  },
  freighter = {
    name = 'Freighter', shipType = 'freighter', scale = 28, cargo = 300,
    organization = 'free-traders', jobs = { transport = true, patrol = true },
  },
  industrial = {
    name = 'Industrial', shipType = 'industrial', scale = 36, cargo = 180,
    organization = 'belt-miners', jobs = { mine = true, transport = true },
  },
  capital = {
    name = 'Capital', shipType = 'capital', scale = 64, cargo = 400,
    organization = 'belt-miners', jobs = { mine = true, transport = true, patrol = true },
  },
}

Population.DefaultMix = {
  fighter = 3,
  freighter = 2,
  industrial = 2,
  capital = 1,
}

local function hash (value)
  local h = 2166136261 % 2147483647
  if type(value) == 'string' then
    for i = 1, #value do h = (h * 33 + value:byte(i)) % 2147483647 end
  else
    h = (h * 33 + math.floor(tonumber(value) or 0)) % 2147483647
  end
  return h
end

function Population.Plan (seed, mix)
  mix = mix or Population.DefaultMix
  local entries = {}
  for _, role in ipairs({ 'fighter', 'freighter', 'industrial', 'capital' }) do
    local count = math.max(0, math.floor(tonumber(mix[role]) or 0))
    for _ = 1, count do entries[#entries + 1] = role end
  end
  for i = #entries, 2, -1 do
    local j = 1 + hash(tostring(seed) .. ':shuffle:' .. i) % i
    entries[i], entries[j] = entries[j], entries[i]
  end
  local plan = {}
  for i, role in ipairs(entries) do
    plan[i] = {
      id = 'npc:' .. tostring(seed) .. ':' .. i,
      shipId = 'ship:' .. tostring(seed) .. ':' .. i,
      role = role,
      variant = 1 + hash(tostring(seed) .. ':variant:' .. i .. ':' .. role) % 3,
      seed = hash(tostring(seed) .. ':ship:' .. i .. ':' .. role),
    }
  end
  return plan
end

function Population.ScaleMix (total)
  total = math.max(0, math.floor(tonumber(total) or 0))
  local mix = { fighter = 0, freighter = 0, industrial = 0, capital = 0 }
  if total == 0 then return mix end
  local defaultTotal = 0
  for _, count in pairs(Population.DefaultMix) do defaultTotal = defaultTotal + count end
  if total >= defaultTotal then
    for role, count in pairs(Population.DefaultMix) do mix[role] = count end
    return mix
  end
  local guaranteed = { 'capital', 'industrial', 'freighter', 'fighter' }
  for i = 1, math.min(4, total) do mix[guaranteed[i]] = 1 end
  local extras = { 'fighter', 'fighter', 'freighter', 'industrial' }
  local index = 1
  for _ = 5, total do
    mix[extras[index]] = mix[extras[index]] + 1
    index = index % #extras + 1
  end
  return mix
end

function Population.CanDoJob (role, kind)
  local def = Population.Roles[role]
  return def ~= nil and def.jobs[kind] == true
end

return Population
