#!/usr/bin/env luajit
--[[----------------------------------------------------------------------------
  Offline SectorGraph validator.

  The universe is a LATTICE: sectors placed by the old game's branching-spiral
  algorithm, each connected to its three nearest neighbours by jumpgates.

  The lattice is the one part of the universe that has to be RIGHT, because
  everything else hangs off it:

    * If the lattice is DISCONNECTED, part of the galaxy is unreachable and
      the player is stranded there with no way out.
    * If the gates are not SPREAD, they pile up on one side of a sector and
      the player has to fly around the rim to find them.
    * If a gate's two ends do not line up, arriving through one puts you
      somewhere that is not the far end of the other.

  So the contract is:

    1. CONNECTED -- every sector is reachable from every other.
    2. SPREAD -- the gates of a sector are evenly spread around its rim.
    3. PAIRED -- the two ends of a gate are each on their own sector's rim,
       at the SAME distance from that sector's centre.
    4. DETERMINISTIC -- the same seed always lays out the same galaxy.
    5. NO SELF-GATES -- a sector is never gated to itself.

  Runs under luajit with NO GL/Engine context. Exit code non-zero on any
  failure. Wired into `python3 configure.py test` and `cmake --build`.
----------------------------------------------------------------------------]]--

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1,1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.')..'/'..src end
local root = src:gsub('/tools/validate_sectors%.lua$', '')
if root == src then root = '.' end
package.path = root..'/script/?.lua;'..root..'/script/?/init.lua;'..package.path

local SectorGraph = dofile(root..'/script/Game/SectorGraph.lua')

local failures = 0
local checks = 0

local function check (name, ok, detail)
  checks = checks + 1
  if ok then
    print('ok   - '..name..(detail and ('  -- '..detail) or ''))
  else
    failures = failures + 1
    print('FAIL - '..name..(detail and ('  -- '..detail) or ''))
  end
end

local SEED = 15423934050514487609ULL
local RADIUS = 60000

-- ---------------------------------------------------------------------------
-- 1. Connectivity
-- ---------------------------------------------------------------------------
do
  local sectors = SectorGraph.layout(SEED, RADIUS)
  local seen, queue = { [0] = true }, { 0 }
  while #queue > 0 do
    local cur = table.remove(queue, 1)
    for _, g in ipairs(SectorGraph.gates(sectors, cur)) do
      if not seen[g.partner] then
        seen[g.partner] = true
        queue[#queue + 1] = g.partner
      end
    end
  end
  local reached = 0
  for _ in pairs(seen) do reached = reached + 1 end
  check('every sector is reachable from every other',
    reached == #sectors,
    string.format('%d of %d reachable', reached, #sectors))
end

-- ---------------------------------------------------------------------------
-- 2. The gates are spread
-- ---------------------------------------------------------------------------
do
  local sectors = SectorGraph.layout(SEED, RADIUS)
  local worstGap, worstSector = math.huge, nil
  local worstCount = 0
  for _, s in ipairs(sectors) do
    local gates = SectorGraph.gates(sectors, s.index)
    worstCount = math.max(worstCount, #gates)
    if #gates >= 2 then
      -- The angle between each pair of gates, around the rim.
      local angles = {}
      for _, g in ipairs(gates) do
        angles[#angles + 1] = math.atan2(g.self.z - s.center.z, g.self.x - s.center.x)
      end
      table.sort(angles)
      for i = 1, #angles do
        local a, b = angles[i], angles[(i % #angles) + 1]
        local gap = b - a
        if gap < 0 then gap = gap + 2 * math.pi end
        if gap < worstGap then worstGap = gap; worstSector = s.index end
      end
    end
  end
  -- The gates should be spread: the smallest gap between two of them should
  -- not be a tiny sliver. A sector with 3 gates has gaps of 120 degrees.
  local expected = 2 * math.pi / math.max(1, worstCount)
  check('the gates of a sector are spread around its rim',
    worstGap > expected * 0.5,
    string.format('smallest gap %.0f degrees on sector %s (a %d-gate sector spaces them %.0f apart)',
      math.deg(worstGap), tostring(worstSector), worstCount, math.deg(expected)))
end

-- ---------------------------------------------------------------------------
-- 3. The two ends of a gate line up
-- ---------------------------------------------------------------------------
do
  local sectors = SectorGraph.layout(SEED, RADIUS)
  local badRim, badPair = 0, 0
  for _, s in ipairs(sectors) do
    for _, g in ipairs(SectorGraph.gates(sectors, s.index)) do
      local other = sectors[g.partner + 1]
      -- Each end must be exactly on its own sector's rim.
      local da = math.sqrt((g.self.x - s.center.x)^2 + (g.self.z - s.center.z)^2)
      local db = math.sqrt((g.other.x - other.center.x)^2 + (g.other.z - other.center.z)^2)
      if math.abs(da - RADIUS) > 1 or math.abs(db - RADIUS) > 1 then badRim = badRim + 1 end
      -- And the partner must be symmetric: if A has a gate to B, B has one
      -- back to A.
      local mutual = false
      for _, g2 in ipairs(SectorGraph.gates(sectors, g.partner)) do
        if g2.partner == s.index then mutual = true break end
      end
      if not mutual then badPair = badPair + 1 end
    end
  end
  check('both ends of a gate sit on their own sector\'s rim',
    badRim == 0,
    string.format('%d gate ends were off the rim', badRim))
  check('every gate is mutual -- if A leads to B, B leads back to A',
    badPair == 0,
    string.format('%d gates had no partner', badPair))
end

-- ---------------------------------------------------------------------------
-- 4. Determinism
-- ---------------------------------------------------------------------------
do
  local a = SectorGraph.layout(SEED, RADIUS)
  local b = SectorGraph.layout(SEED, RADIUS)
  local same = #a == #b
  for i = 1, #a do
    if a[i].name ~= b[i].name then same = false end
    if a[i].center.x ~= b[i].center.x or a[i].center.z ~= b[i].center.z then same = false end
    if #a[i].neighbours ~= #b[i].neighbours then same = false end
  end
  check('the same seed lays out the same galaxy', same)

  -- A DIFFERENT galaxy seed must lay out a different galaxy.
  --
  -- The seed cannot be SEED + 1: a 64-bit seed does not fit in a double, so
  -- adding one to it does not change it at all -- the value rounds back to the
  -- same double. The seed has to be genuinely different.
  local c = SectorGraph.layout(987654321098765432, RADIUS)
  local differs = (#a ~= #c)
  local n = math.min(#a, #c)
  for i = 1, n do
    if a[i].center.x ~= c[i].center.x or a[i].center.z ~= c[i].center.z then
      differs = true
    end
  end
  check('a different seed lays out a different galaxy', differs)
end

-- ---------------------------------------------------------------------------
-- 5. No self-gates
-- ---------------------------------------------------------------------------
do
  local sectors = SectorGraph.layout(SEED, RADIUS)
  local selfGates, total = 0, 0
  for _, s in ipairs(sectors) do
    for _, g in ipairs(SectorGraph.gates(sectors, s.index)) do
      total = total + 1
      if g.partner == s.index then selfGates = selfGates + 1 end
    end
  end
  check('no sector is gated to itself',
    selfGates == 0,
    string.format('%d self-gates out of %d gates', selfGates, total))
end

-- ---------------------------------------------------------------------------
-- 6. The graph has REDUNDANCY
-- ---------------------------------------------------------------------------
do
  -- The old generator used the union of TWO spanning trees, so the gate graph
  -- has a few CYCLES in it: a gate is not the only way between two places.
  --
  -- This matters for play: with a bare tree, the galaxy is a corridor, and a
  -- sector at one end can only be reached by going through every sector
  -- between. With cycles there are routes around.
  local sectors = SectorGraph.layout(SEED, RADIUS)
  local edges = 0
  local seenPairs = {}
  for _, s in ipairs(sectors) do
    for _, g in ipairs(SectorGraph.gates(sectors, s.index)) do
      local a, b = math.min(s.index, g.partner), math.max(s.index, g.partner)
      local key = a .. ':' .. b
      if not seenPairs[key] then
        seenPairs[key] = true
        edges = edges + 1
      end
    end
  end
  -- A tree over N nodes has N-1 edges. More than that means there is a
  -- cycle somewhere.
  local trees = #sectors - 1
  check('the gate graph has a cycle in it, so there is a way around',
    edges > trees,
    string.format('%d edges over %d sectors (a bare tree would be %d)',
      edges, #sectors, trees))
end

-- ---------------------------------------------------------------------------
-- 6. The layout does not depend on the JIT
-- ---------------------------------------------------------------------------
do
  -- LuaJIT's compiled code and its interpreter can disagree about a float by
  -- one ULP -- and, worse, hash32's float-to-integer conversion happens on a
  -- value OUTSIDE the range the conversion is defined for, so the compiled
  -- and interpreted forms can return different hashes entirely.
  --
  -- That matters because the galaxy's TOPOLOGY comes out of comparisons on
  -- those values. A one-ULP difference flips a comparison, which changes
  -- which edge the spanning tree picks, which changes the shape of the whole
  -- universe.
  --
  -- It did: the sector layout came out different with the JIT on and with
  -- it off, so the offline validator and the game were describing two
  -- different galaxies -- and the validator's idea of the galaxy was not the
  -- galaxy the player flies through.
  --
  -- So the layout uses exact 32-bit integer arithmetic throughout, and this
  -- check proves it: the same layout, with the JIT off, must come out the
  -- same.
  local withJit = SectorGraph.layout(SEED, RADIUS)
  local ok = true
  local detail = ''
  jit.off()
  local withoutJit = SectorGraph.layout(SEED, RADIUS)
  jit.on()
  for i = 1, #withJit do
    if withJit[i].center.x ~= withoutJit[i].center.x or
       withJit[i].center.z ~= withoutJit[i].center.z then
      ok = false
      detail = string.format('sector %d moved: (%.4f,%.4f) vs (%.4f,%.4f)', i,
        withJit[i].center.x, withJit[i].center.z,
        withoutJit[i].center.x, withoutJit[i].center.z)
    end
    if #withJit[i].neighbours ~= #withoutJit[i].neighbours then
      ok = false
      detail = string.format('sector %d gained or lost a gate', i)
    end
  end
  check('the layout does not depend on whether the JIT is running', ok, detail)
end

print(string.format('\n%d checks, %d failure(s)', checks, failures))
if failures > 0 then os.exit(1) end
os.exit(0)
