--[[ SectorGraph -- the universe's structure: sectors, and the gates between them.

  A SECTOR is a named volume of space with its own seed, its own regions, and
  its own WORMHOLES to the other sectors. The graph is a FULLY-CONNECTED MESH
  (procedural-space-environment.md §29b): every sector can be reached from
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

-- How many sectors the universe has. The old generator made a graph whose
-- size was the world it wanted; this is a fixed count so the galaxy is
-- finite, knowable, and -- importantly -- SO SMALL that a fully-connected
-- mesh is playable.
--
-- A fully-connected mesh of N sectors has N*(N-1)/2 gate pairs. At 8
-- sectors that is 28 pairs, 56 endpoints, and 7 gates ringing each sector.
-- At 16 it would be 120 pairs and 15 gates per sector, which starts to
-- look like a fence rather than a set of places.
SectorGraph.SECTOR_COUNT = 8

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

-- The sectors of a galaxy, in a deterministic order.
--
-- `galaxySeed` is the world seed: the same galaxy always has the same
-- sectors, in the same places, with the same names. That is the whole
-- point of a seeded universe -- the player's map of it is a map of
-- something real.
--
-- The centres are laid out on a GOLDEN-ANGLE SPIRAL, the same reasoning as
-- the regions inside a sector: a golden angle gives an even spread for any
-- count, where a random placement clumps.
function SectorGraph.layout (galaxySeed, radius)
  local SpaceField = require('Game.SpaceField')
  local NameGen = require('Game.NameGen')
  local Sector = require('Game.Region')

  local count = SectorGraph.SECTOR_COUNT
  local out = {}
  local ga = 2.39996323 -- golden angle, radians

  for i = 0, count - 1 do
    local seed = Sector.seedFor(galaxySeed, i)
    -- The spiral: uniform in z, rotated by the golden angle.
    local z = 1 - 2 * (i + 0.5) / count
    local r = math.sqrt(math.max(0, 1 - z * z))
    local theta = ga * i
    -- A per-sector jitter, so the spiral is a starting point rather than a
    -- pattern the player can recognise from the first sector.
    local j = SpaceField.hash32(i, 0, 0, seed, 77)
    local j2 = SpaceField.hash32(i, 0, 0, seed, 78)
    local jr = 0.75 + 0.5 * j
    local scale = SectorGraph.GALAXY_RADIUS * 0.5 * jr
    out[i + 1] = {
      index    = i,
      seed     = seed,
      name     = NameGen.sector(seed),
      -- The sector's own centre in WORLD space. Sector 0's centre is the
      -- world origin, so the starting sector is where the ship spawns.
      center = (i == 0) and { x = 0, y = 0, z = 0 } or {
        x = r * math.cos(theta) * scale,
        y = 0,
        z = r * math.sin(theta) * scale + (j2 - 0.5) * scale * 0.2,
      },
      radius   = radius,
      -- Which slot on this sector's rim each partner's gate occupies.
      gateSlot = {},
    }
  end

  -- Assign the rim slots. Each sector has one gate per OTHER sector, and
  -- the slots are spread evenly around its rim so the gates read as a set
  -- of distinct places rather than a pile on one side.
  for i = 1, count do
    local a = out[i]
    local slot = 0
    for j = 1, count do
      if j ~= i then
        a.gateSlot[j] = slot
        slot = slot + 1
      end
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
    local n = math.max(1, SectorGraph.SECTOR_COUNT - 1)
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

-- The gates of a sector: one per other sector.
--
-- Each entry names the pair from this sector's point of view:
--   self     the endpoint HERE
--   other    the endpoint THERE
--   partner  the index of the sector on the other end
function SectorGraph.gates (sectors, index)
  local a = sectors[index + 1]
  if not a then return {} end
  local out = {}
  for j = 1, #sectors do
    local b = sectors[j]
    if b.index ~= a.index then
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
