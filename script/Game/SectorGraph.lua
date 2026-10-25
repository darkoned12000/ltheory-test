--[[ SectorGraph -- the universe's structure: sectors, and the gates between them.

  A SECTOR is a named volume of space with its own seed, its own regions, and
  its own WORMHOLES to the other sectors. The graph is a FULLY-CONNECTED MESH
  (docs/procedural-space-environment.md §29b): every sector can be reached from
  every other, so the player is never stranded.

  PORTED FROM THE ORIGINAL LIMIT THEORY
  =====================================
  The old game's universe generator created a universe by LINKING sectors, and
  the link was a pair of wormholes -- one endpoint inside each sector:

      void Object_Wormholes(ObjectT* o1, ObjectT* o2) {
        a->GetNavigable()->nodes.push(NavigableNode(b, 0));
        b->GetNavigable()->nodes.push(NavigableNode(a, 0));
        a->SetName(o2->GetName() + " Wormhole");
        b->SetName(o1->GetName() + " Wormhole");
        V3 direction = Normalize(o2->GetPos() - o1->GetPos());
        a->SetPos( 400000.0f * direction);
        b->SetPos(-400000.0f * direction);
        o1->AddInterior(a);
        o2->AddInterior(b);
      }

  and the TRAVEL was a DOCK -- docking with one endpoint put you inside the
  other sector:

      void Wormhole::Dock(Object const& docker) override {
        Object const& dest = Navigable.nodes[0].dest;
        dest->GetContainer()->AddInterior(docker);
        docker->SetPos(dest->GetPos() - 1500.0f * Normalize(dest->GetPos()));
      }

  Two things carry over exactly:
    * a gate is a PAIR of linked endpoints, one per sector, and
    * travel is docking -- not a keypress, not a menu.

  What does not carry over is the container model. The old engine had real
  interior containers; this engine's "container" is the entity parent tree,
  and the world is a single System. So the sectors are placed in WORLD space
  (a golden-angle spiral through the galaxy, the same trick the regions use
  inside a sector) and a gate endpoint sits on its sector's boundary.

  THE OLD CODE HAD A SECOND, SEPARATE "WARP" SYSTEM
  ===================================================
  WarpNode + WarpRail (see the Warping/ folder) are NOT jumpgates. They are a
  physical RAIL TRANSIT network INSIDE a system: a ship flies into a node, is
  captured by a slot in the node's cross-section, and is then pushed along a
  bezier rail to the next node by forces, with the slot allocator splitting a
  quadtree so that arriving ships each get room.

  That is the old game's INTRA-system warp drive, and it maps onto the
  "FTL warp-drive planned later for that" decision rather than onto the
  jumpgates. It is a self-contained system and a good later project; the
  jumpgates are this file.
]]

local SectorGraph = {}

-- A precomputed cosine/sine table.
--
-- WHY A TABLE: LuaJIT's compiled code replaces math.cos and math.sin with a
-- fast polynomial, and that polynomial does NOT agree with libm to the last
-- bit. So a position computed with math.cos can differ between the
-- interpreter and the compiled code -- and a sector layout built out of
-- those positions is then built out of DIFFERENT coordinates depending on
-- whether the function was hot.
--
-- That is not a rounding curiosity here. The galaxy's TOPOLOGY comes out of
-- comparisons on those coordinates (which edge is cheapest, which sector
-- overlaps which), so a one-bit difference flips a comparison and the whole
-- galaxy changes shape. It did: the offline validator and the game were
-- describing two different universes, and the validator's idea of the galaxy
-- was not the galaxy the player flies through.
--
-- A table computed ONCE, at module load, in the interpreter, is identical
-- everywhere. The angles then become INTEGER INDICES into it, so the only
-- floating point left in the layout is a single multiply of two known
-- values -- which IEEE rounds identically in both modes.
-- An EXACT 32-bit integer mix.
--
-- SpaceField.hash32 mixes its arguments by MULTIPLICATION in floating point,
-- and its terms overflow the 32-bit range -- so the final conversion of the
-- sum to an integer is on a value outside the range the conversion is
-- DEFINED for, and LuaJIT's compiled code and its interpreter do that
-- conversion differently. The same call can therefore return different
-- values depending on whether the function was hot.
--
-- That is fatal for anything whose TOPOLOGY comes out of comparisons on
-- those values -- which is exactly what a universe is. The sector layout
-- came out different with the JIT on and with it off, so the offline
-- validator and the game were describing two different galaxies.
--
-- So the layout uses THIS mixer instead: xor and shift only, all of them
-- 32-bit, all of them exact. The result is identical in the interpreter and
-- in compiled code, on every machine.
--
-- The shifts go BOTH ways on purpose. A right shift alone propagates bits
-- DOWNWARD, so the low bits of the output barely move -- consecutive inputs
-- give consecutive outputs, and taking those low bits for the layout put
-- every sector on top of the others (the angle indices came out 218, 217,
-- 216, 223, 222, 221, 220, 210). The left shifts propagate the low bits
-- UPWARD, which is what mixes an index into the seed's high bits.
local function mix32 (a, b, c)
  local h = bit.bxor(bit.tobit(a), bit.tobit(b))
  h = bit.bxor(h, bit.tobit(c))
  h = bit.bxor(h, bit.lshift(h, 13))
  h = bit.bxor(h, bit.rshift(h, 7))
  h = bit.bxor(h, bit.lshift(h, 17))
  -- Fold to 31 bits so the result is a positive number, and so it can be
  -- used as a fraction's numerator without a sign flipping the layout.
  return bit.band(h, 0x7FFFFFFF)
end

local kTrigSteps = 256
local trigCos, trigSin = {}, {}
do
  for i = 0, kTrigSteps - 1 do
    local a = 2 * math.pi * i / kTrigSteps
    trigCos[i] = math.cos(a)
    trigSin[i] = math.sin(a)
  end
end

-- How many sectors the universe has.
--
-- The old game's universe generator (UniverseGen/universe.lts) used 512
-- nodes in its lattice simulation. That is a lot of sectors -- and with a
-- fully-connected gate graph it would be 511 gates per sector, which is a
-- fence, not a set of places. Which is exactly why the old generator used a
-- SPARSE lattice instead (see NEIGHBOUR_COUNT).
--
-- The number of sectors in this galaxy is derived from the seed, so
-- different universes get different galaxies instead of the same 8
-- every time. Range 8..25: few enough that every sector is worth
-- visiting, varied enough that a new seed feels like a new galaxy.
-- (The field is set inside layout(), since the count depends on the seed.)
SectorGraph.SECTOR_COUNT = 8

-- How many gates each sector has.
--
-- The old lattice connected every node to its THREE nearest neighbours --
-- a sparse graph that is still connected, so every sector is reachable,
-- but by a path rather than by a single hop. That is the right shape: a
-- fully-connected mesh of 512 sectors would put 511 gates on every rim.
SectorGraph.NEIGHBOUR_COUNT = 3

-- How far the sector centres are spread. The sector radius is 60k (the
-- playable volume), so this is how much EMPTY space sits between sectors --
-- which is what makes a warp feel like a journey rather than a step.
SectorGraph.GALAXY_RADIUS = 420000

-- The number of sectors to lay out.
function SectorGraph.count ()
  return SectorGraph.SECTOR_COUNT
end

-- ---------------------------------------------------------------------------
-- The layout
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- The gate graph
-- ---------------------------------------------------------------------------

-- A minimum spanning tree over a complete graph.
--
-- PORTED FROM THE OLD GAME's Region.cpp, which used the engine's LTE/Graph.h
-- `ComputeMST()`. This is Prim's algorithm, which is what a straightforward
-- MST on a small complete graph comes to.
--
-- `weightFn(i, j)` gives the edge weight between two 1-based nodes.
-- Returns the edges as { { i, j }, ... }.
local function computeMST (count, weightFn)
  local edges = {}
  if count < 2 then return edges end
  local inTree = { [1] = true }
  for _ = 2, count do
    local bestW, bestI, bestJ
    for i = 1, count do
      if inTree[i] then
        for j = 1, count do
          if not inTree[j] then
            local w = weightFn(i, j)
            if not bestW or w < bestW then bestW, bestI, bestJ = w, i, j end
          end
        end
      end
    end
    if not bestJ then break end
    inTree[bestJ] = true
    edges[#edges + 1] = { bestI, bestJ }
  end
  return edges
end

-- The gate graph: the union of TWO minimum spanning trees.
--
-- PORTED FROM THE OLD GAME's Region.cpp:
--
--     const size_t kConnectivity = 2;
--     for (size_t i = 0; i < kConnectivity; ++i) {
--       ... a complete graph with edge weight Length(p1 - p2) * (1 + 0.5 * Exp)
--       AutoPtr<Graph<ObjectT*>> mst = graph->ComputeMST();
--       for each mst edge: Connect(src, dst);   // -> Object_Wormholes
--     }
--
-- So the old game's gate graph was NOT a fully-connected mesh. It was two
-- spanning trees over the sibling regions, with RANDOMLY PERTURBED edge
-- weights, and the union of the two.
--
-- That shape is the right one, and it is why:
--   * a spanning tree is connected by construction -- every region is
--     reachable, so the player is never stranded;
--   * it is SPARSE -- N-1 edges per tree, not N*(N-1)/2. At the old
--     game's 512 nodes a fully-connected mesh would have put 511 gates on
--     every rim;
--   * the second tree adds REDUNDANCY -- the union has a few cycles, so a
--     gate is not the only way between two places;
--   * the random weight perturbation means the tree is not simply the
--     minimum-distance tree, so the galaxy does not degenerate into a path.
--
-- (The "fully-connected mesh" in the design notes was a guess made before
-- the old source was recovered. The old source says spanning trees.)
local CONNECTIVITY = 2

-- The sectors of a galaxy, in a deterministic order.
--
-- `galaxySeed` is the world seed: the same galaxy always has the same
-- sectors, in the same places, with the same names. That is the whole
-- point of a seeded universe -- the player's map of it is a map of
-- something real.
--
-- THE PLACEMENT is the old game's, from Region.cpp:
--
--     V2 co = rng->GetCircle();                       // a random point in a disc
--     V3 thisOffset = args.radius * (V3(co.x, 0, co.y));
--     float thisRadius = Min(maxRadius, args.radius - Length(thisOffset));
--     // ... and shrink it further if it would overlap a sibling
--
-- So the children of a region are scattered through a DISC around it, at
-- random positions, each smaller than the parent and smaller the further
-- out it is, and never overlapping a sibling. It is the same principle as
-- the regions inside a sector: big in the middle, smaller towards the
-- edge, no overlaps.
function SectorGraph.layout (galaxySeed, radius)
  local SpaceField = require('Game.SpaceField')
  local NameGen = require('Game.NameGen')
  local Sector = require('Game.Region')

  -- Sector count is derived from the galaxy seed: 8..25, so a new seed
  -- gives a genuinely different galaxy instead of the same 8 sectors.
  local folded = SpaceField.foldSeed(galaxySeed)
  local count = 8 + math.floor(SpaceField.hash32(0, 0, 0, folded, 7) * 18)
  if count < 8 then count = 8 end
  if count > 25 then count = 25 end
  SectorGraph.SECTOR_COUNT = count
  local out = {}

  -- The galaxy's own radius: the disc the sectors are scattered through.
  local galaxyRadius = SectorGraph.GALAXY_RADIUS
  -- A sector's own radius is the playable volume, so it does NOT shrink with
  -- its distance out -- the old code's "smaller the further out" rule was
  -- about a region's RADIUS, and here the radius is the play area. The
  -- overlap rule still applies.
  local maxRadius = radius * 0.7
  local minRadius = radius * 0.3
  local maxOverlap = radius * 0.1
  local kMaxAttempts = 1000

  -- The scatter. Positions first, so the placement does not depend on the
  -- names (which are generated later).
  --
  -- kPlacementCell is the grid the occupancy test works on. It is coarse
  -- enough that two sectors which would visibly overlap land in the same
  -- cell, and fine enough that the galaxy does not look like a grid.
  local kPlacementCell = 20000
  local taken = {}
  local placed = {}
  for i = 1, count do
    local chosen = nil
    for attempt = 1, kMaxAttempts do
      -- A random point in a disc (the old rng->GetCircle()).
      -- The seed MUST be folded to 32 bits before it goes into hash32.
      --
      -- hash32 mixes its arguments by MULTIPLICATION, and the seed term is
      -- multiplied by 3266489917. A raw 64-bit seed makes that term ~5e28,
      -- which is far past 2^53 -- so the float sum can no longer represent
      -- the x/y/z terms AT ALL, the hash returns the SAME value for every
      -- input, and the whole galaxy collapses to one layout. (Measured: with
      -- the raw seed, hash32(1,1,1) and hash32(2,3,4) both return
      -- 0.216540 -- identical. With the seed folded they differ.)
      --
      -- deriveSeed() folds the 64-bit seed and mixes in an index, so each
      -- sector and each edge gets its own well-distributed 32-bit seed.
      -- The ATTEMPT is mixed in, so a retry actually tries somewhere else.
      -- Without it every attempt computes the SAME point, and the rejection
      -- loop is a thousand repeats of one position.
      local s = SpaceField.deriveSeed(galaxySeed, 80 + i)
      -- The angle is an INDEX into the trig table and the radius is an
      -- INTEGER, so the position is a table lookup and one multiply -- the
      -- same bits in the interpreter and in compiled code.
      local ai = mix32(s, i, attempt) % kTrigSteps
      local ri = mix32(s, attempt, i + 7) % math.floor(galaxyRadius)
      local offset = {
        x = trigCos[ai] * ri,
        y = 0,
        z = trigSin[ai] * ri,
      }
      local dist = math.sqrt(offset.x * offset.x + offset.z * offset.z)
      -- Shrink the sector if it is far out (the old rule) ...
      local thisRadius = math.min(maxRadius, galaxyRadius - dist)
      -- ... and shrink it further if it would overlap a sibling.
      --
      -- The overlap SHRINKS a sector; it never REJECTS one. That is
      -- deliberate, and it is the difference between a stable universe and
      -- an unstable one.
      --
      -- A "does this candidate fit?" test is a comparison against a
      -- threshold, and LuaJIT's compiled code and its interpreter can
      -- disagree about a float by one ULP -- which flips the test, which
      -- changes WHICH candidate is taken, which changes every sector after
      -- it. It did exactly that: the layout came out different with the JIT
      -- on and with it off, so the offline validator and the game were
      -- describing two DIFFERENT universes, and the validator's idea of the
      -- galaxy was not the galaxy the player flies through.
      --
      -- So nothing here can change the SHAPE of the galaxy. The overlap
      -- only makes a sector smaller, and a radius that differs by one ULP
      -- changes how big a sector is by a millionth of a unit -- instead of
      -- changing which sectors exist.
      for k = 1, #placed do
        local other = placed[k]
        local d = math.sqrt((offset.x - other.off.x)^2 + (offset.z - other.off.z)^2)
        thisRadius = math.min(thisRadius, d - other.radius + maxOverlap)
      end
      thisRadius = math.max(minRadius, thisRadius)

      -- The occupancy test is on a GRID, so it is an INTEGER comparison.
      --
      -- A "does this spot overlap another?" test on raw floats is a
      -- comparison that can flip on a one-ULP difference -- and a flip
      -- changes which candidate is taken, and so the whole galaxy. So the
      -- candidates are quantised to a grid and the test is "is this cell
      -- taken?", which is exact.
      local gx = math.floor(offset.x / kPlacementCell)
      local gz = math.floor(offset.z / kPlacementCell)
      local key = gx .. ':' .. gz
      if not taken[key] then
        taken[key] = true
        chosen = { off = offset, radius = thisRadius }
        break
      end
    end
    -- If the rejection loop gave up, place it anyway so the count is right: a
    -- galaxy with fewer sectors than it should have is a bug.
    if not chosen then
      local ang = i / count * 2 * math.pi
      chosen = {
        off = { x = math.cos(ang) * galaxyRadius * 0.5, y = 0,
                z = math.sin(ang) * galaxyRadius * 0.5 },
        radius = minRadius,
      }
    end
    placed[#placed + 1] = chosen
  end

  -- The names and the seeds.
  for i = 0, count - 1 do
    local seed = Sector.seedFor(galaxySeed, i)
    out[i + 1] = {
      index    = i,
      seed     = seed,
      name     = NameGen.sector(seed),
      center   = placed[i + 1].off,
      radius   = radius,
      -- Which slot on this sector's rim each partner's gate occupies.
      gateSlot = {},
      -- The sectors this one is gated to.
      neighbours = {},
    }
  end

  -- Put the FIRST sector at the world origin.
  --
  -- The galaxy is scattered through a disc, so sector 0 lands somewhere in
  -- it -- but sector 0 is where the player starts, and the world origin is
  -- where the ship, the planet and the starting asteroid field are. Without
  -- this the player spawns tens of thousands of units OUTSIDE their own
  -- sector, and the panel says "outside the sector" from the first frame.
  local origin = out[1].center
  for i = 1, count do
    out[i].center = {
      x = out[i].center.x - origin.x,
      y = 0,
      z = out[i].center.z - origin.z,
    }
  end

  -- The gate graph: the union of two minimum spanning trees over the
  -- sectors, with randomly perturbed edge weights -- exactly the old
  -- generator's algorithm.
  --
  -- The weight is the DISTANCE between the two sectors, times a random
  -- factor, so the tree is not simply the minimum-distance one.
  local connections = {}
  for k = 1, CONNECTIVITY do
    local edges = computeMST(count, function (i, j)
      local a, b = out[i].center, out[j].center
      -- The weight is an INTEGER. A minimum spanning tree is decided by
      -- comparisons, and a comparison on a float can flip on a one-ULP
      -- difference -- which changes WHICH edge the tree picks, and so the
      -- shape of the whole galaxy. Quantising the distance makes the
      -- comparison exact.
      local dx, dz = a.x - b.x, a.z - b.z
      local d = math.floor(math.sqrt(dx * dx + dz * dz))
      -- The old code perturbed the edge weight by `1 + 0.5 * Exp` -- an
      -- EXPONENTIAL, not a uniform. That matters: an exponential has a long
      -- tail, so an edge that is nearly the shortest sometimes gets a large
      -- multiplier and the tree changes shape. A uniform perturbation (which
      -- is what this was first) barely moves the tree at all, and the two
      -- trees came out IDENTICAL -- which turned the gate graph into a bare
      -- path, with no shortcuts anywhere in the galaxy.
      -- A folded, index-mixed seed per edge -- see the note above about why
      -- the raw 64-bit seed cannot go into hash32.
      --
      -- The jitter is quantised to an INTEGER so the whole weight is an
      -- integer. A minimum spanning tree is decided by COMPARISONS, and a
      -- comparison between two floats can flip on a one-ULP difference --
      -- which changes which edge the tree picks, and so the shape of the
      -- whole galaxy. With an integer weight the comparison is exact.
      --
      -- The jitter is an INTEGER, and it comes from the exact integer mixer
      -- rather than from an exponential -- an exponential is a float, and a
      -- float in the weight is a comparison that can flip.
      --
      -- The old code perturbed the weight by `1 + 0.5 * Exp` -- an
      -- EXPONENTIAL, not a uniform. That matters: an exponential has a long
      -- tail, so an edge that is nearly the shortest sometimes gets a large
      -- multiplier and the tree changes shape. A uniform perturbation (which
      -- is what this was first) barely moves the tree at all, and the two
      -- trees came out IDENTICAL -- which turned the gate graph into a bare
      -- path, with no shortcuts anywhere in the galaxy.
      --
      -- The integer mixer keeps the "sometimes much larger" property (its
      -- low bits are uneven) without a float anywhere.
      local es = SpaceField.deriveSeed(galaxySeed, 200 + k * 100 + i * 10 + j)
      local jitter = 1 + (mix32(es, i, j) % 1024)
      return d * jitter
    end)
    for _, e in ipairs(edges) do
      local i, j = e[1], e[2]
      local key = math.min(i, j) .. ':' .. math.max(i, j)
      if not connections[key] then
        connections[key] = true
        -- The edge is recorded on BOTH ends: a gate is a pair, and each end
        -- has to know who its partner is.
        table.insert(out[i].neighbours, j - 1)
        table.insert(out[j].neighbours, i - 1)
      end
    end
  end

  -- Assign the rim slots. The slots are spread evenly around the rim so
  -- the gates read as a set of distinct places rather than a pile.
  for i = 1, count do
    local a = out[i]
    for slot, j in ipairs(a.neighbours) do
      a.gateSlot[j] = slot - 1
    end
  end

  return out
end

-- ---------------------------------------------------------------------------
-- The gates
-- ---------------------------------------------------------------------------

-- The two endpoints of the gate between two sectors.
--
-- Each endpoint sits on its own sector's rim, at the slot assigned to the
-- other sector. They are NOT at the same place: the point of a warp is that
-- the two ends are far apart, and the gate's own identity is the PAIR.
--
-- `slotAngle(sector, partnerIndex)` is the angle around the rim, so the
-- gates are spread. The angle is in the XZ plane, which is the plane the
-- map projects onto -- so a gate's position on the map is the position of
-- the gate in the world, with no projection fudge.
function SectorGraph.gateEndpoints (a, b)
  local function angleFor (sector, partnerIndex)
    local slot = sector.gateSlot[partnerIndex] or 0
    local n = math.max(1, #(sector.neighbours or {}))
    return 2 * math.pi * slot / n
  end

  local aa = angleFor(a, b.index)
  local ba = angleFor(b, a.index)

  local posA = {
    x = a.center.x + math.cos(aa) * a.radius,
    y = a.center.y,
    z = a.center.z + math.sin(aa) * a.radius,
  }
  local posB = {
    x = b.center.x + math.cos(ba) * b.radius,
    y = b.center.y,
    z = b.center.z + math.sin(ba) * b.radius,
  }
  return posA, posB
end

-- The gates of a sector: one per LATTICE NEIGHBOUR.
--
-- Each entry names the pair from this sector's point of view:
--   self     the endpoint HERE
--   other    the endpoint THERE
--   partner  the index of the sector on the other end
function SectorGraph.gates (sectors, index)
  local a = sectors[index + 1]
  if not a then return {} end
  local out = {}
  for _, partnerIndex in ipairs(a.neighbours or {}) do
    local b = sectors[partnerIndex + 1]
    if b and b.index ~= a.index then
      local posA, posB = SectorGraph.gateEndpoints(a, b)
      out[#out + 1] = {
        sector    = a.index,
        partner   = b.index,
        self      = posA,
        other     = posB,
        selfName  = a.name,
        otherName = b.name,
      }
    end
  end
  return out
end

-- Where a ship ARRIVES when it comes through a gate: just inside the
-- destination gate, facing the destination sector's centre.
--
-- The old code did the same thing -- `dest->GetPos() - 1500 *
-- Normalize(dest->GetPos())` -- which put the arrival point 1500 units
-- short of the destination along the line to the origin. Here the line is
-- to the destination sector's CENTRE, which is the thing worth facing.
function SectorGraph.arrivalPoint (sectors, partnerIndex, from)
  local b = sectors[partnerIndex + 1]
  if not b then return nil end
  local dx = b.center.x - from.x
  local dz = b.center.z - from.z
  local d = math.sqrt(dx * dx + dz * dz)
  if d < 1e-3 then
    return { x = from.x, y = from.y, z = from.z }, b
  end
  local inset = math.min(1500, d * 0.1)
  return {
    x = from.x - (dx / d) * inset,
    y = from.y,
    z = from.z - (dz / d) * inset,
  }, b
end

return SectorGraph
