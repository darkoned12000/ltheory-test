--[[ Rail -- a warp lane: a chain of frames you fly through.

  PORTED FROM THE ORIGINAL LIMIT THEORY (Warping/WarpNode.cpp, WarpRail.cpp
  and Warping/warprail.jsl), and from the May 2013 development video, which
  is where the LOOK comes from.

  Josh's own words, from that video:

      "if you want to get from point A to point B within a system, you use
       these lanes, warp lanes, to get around quickly -- assuming you can hit
       them."

  So a lane is a ROAD, not a door. You fly into it, it CAPTURES you, and it
  carries you: "you flew into it and you started going very fast, and as long
  as you kept the ship in the lane you travelled until you reached the end."

  WHAT THE OLD CODE BUILT
  ======================
  The old WarpRail had a tube (Mesh_Cylinder(50) with the flow shader,
  additive, culling off, no depth write) -- but its drawable was COMMENTED
  OUT:

      // Drawable.renderable = GetModel;

  so what you actually saw was the WARP NODES: a chain of structures along
  the lane. The tube was the connection, and it was not drawn.

  And the video shows what those structures looked like: a chain of
  RECTANGULAR FRAMES, each one a lit blue lattice in a pale bracket, spaced
  along the lane so the chain recedes into the distance. The ship flies
  THROUGH them.

  So: a frame is a PAIR of big rectangular energy PANELS, one on each side of
  the lane, each carrying a bright blue lattice. Beside each panel, on the
  lane's side of it, is a pale ribbed BRACKET -- a "C" channel -- and the gap
  BETWEEN the two brackets is the lane itself. The ship flies through that
  gap, and the grid on the panels is what accelerates it.

  (Two earlier attempts got this wrong. The first used a continuous TUBE with
  spheres on it: the video does not show a tube -- it shows a chain of discrete
  frames, and the old code had the tube's drawable COMMENTED OUT -- and a tube
  reads as one blown-out white streak from a distance, which is nothing like a
  highway. The second put a TILT on the panels with a rotation about the lane's
  own axis, which does not tilt them at all: it rotates each panel INSIDE its
  own plane, turning it into a diagonal slat, and each panel's half-width then
  overlapped the other's -- so there was no gap, and no lane.)

  (A first attempt used a continuous TUBE with spheres on it. The video does
  not show a tube: it shows a chain of discrete frames, and the old code had
  the tube disabled. The tube also read as one blown-out white streak from
  a distance, which is nothing like a highway.)

  THE THREE FORCES
  ================
  The old WarpNode controller moved a captured ship with three forces:

      1. a RAIL FORCE toward the next frame, scaled by the ship's mass;
      2. a LANE-LOCKING force, pulling the ship back onto the lane's line;
      3. the ARRIVAL -- at the far end the rail lets go.

  The old game also had a SLOT ALLOCATOR: each arriving ship was given a
  lane in the node's cross-section (a quadtree over angle x radius, split so
  each ship gets room), so two ships entering together did not fight. That
  part is not ported -- with one ship it buys nothing -- but the three forces
  are, and they are what makes a rail feel like a road.
]]

local Entity = require('Game.Entity')

-- The frame's size.
--
-- The old game's frame was a cylinder of radius 50 against a ship of a
-- similar size, so the opening was just big enough to fly down. The
-- reference frames dwarf the ship -- several times its length -- and that
-- matters: a rail has to read as a structure you fly THROUGH, not as a
-- glowing line in the distance.
local FRAME_SIZE = 1400

-- How close the ship has to be to a frame before it is captured.
local CAPTURE_RADIUS = 1600

-- How far off the lane's LINE the ship may be and still count as being on
-- the lane.
--
-- This is the second half of the capture, and the two halves have to be
-- thought about separately:
--
--   * the FRAME test -- you have to meet a gate to be caught, which is what
--     "you flew into it" means;
--   * the CORRIDOR test -- once you are caught you stay caught as long as
--     you keep the ship in the lane.
--
-- The first version used the frame test ALONE, and it dropped the ship off
-- the rail between the gates: the frames are 6000 apart, the capture radius
-- is 1600, and a ship doing 1500 u/s is inside that radius for barely two
-- seconds out of every four. So it accelerated to the rail's speed, sailed
-- past the next gate, was let go, and coasted to a stop in the middle of
-- the lane. (Which is what it did, every time.)
local CORRIDOR_RADIUS = 1400

-- The rail force. The old game used 2*2048, scaled by the ship's mass, so
-- it is an acceleration rather than a shove.
local RAIL_FORCE = 4200

-- The speed CAP along the rail.
--
-- The old game's rail force was limited by the ship's DRAG, which capped how
-- fast you could go. This engine's ship is created with zero friction (so it
-- coasts), so without a cap the rail would accelerate it without limit --
-- the ship would arrive at the far end at 40,000 units a second.
--
-- So the speed is capped here, and the rail simply stops pushing once the
-- ship is going fast enough. A 30k rail at this speed is about twenty
-- seconds: long enough to feel like a journey, short enough not to be a
-- chore.
local RAIL_SPEED = 1500

-- The lane-locking force. The old game applied the ship's mass times the
-- perpendicular offset, so it is also an acceleration.
local LANE_LOCK_FORCE = 0.6

-- The speed the ship is let go at, at the far end of the lane.
--
-- The rail brakes the ship over the last stretch of the lane, and lets it
-- go at this speed. A ship released at the rail's full 1500 u/s arrives
-- like a meteor: the first rock it meets in the destination region is a
-- 500-damage hit, which is a death.
local EXIT_SPEED = 250

-- The last stretch of the lane, as a fraction of its length, over which the
-- rail winds the ship down.
local BRAKE_ZONE = 0.20

-- How far apart the frames are along the lane.
--
-- The frames are WIDE -- a frame's panels reach a couple of thousand units
-- either side of the lane -- so at 3000 apart they ran into each other and
-- the lane read as one continuous caterpillar of structure rather than as a
-- chain of gates you fly through.
local FRAME_SPACING = 6000

-- The clear space at a lane's HUB end, in world units.
--
-- Every lane in a sector starts at the same hub, so if their frames started
-- there too, six lanes' worth of frames would be stacked on one spot and the
-- junction would read as a pile-up instead of as a place with six roads
-- leaving it. The frames start a couple of frame-widths out instead.
local HUB_CLEARANCE = 9000

-- The size of a lattice cell, in world units. The panel's cell counts are
-- derived from it (and rounded to EVEN numbers so a grid line runs through
-- the centre of the rings).
local LATTICE_CELL = 75

-- THE STRUCTURE (measured from the two reference screenshots)
-- ===========================================================
-- All sizes are in FRAME units: 1.0 = FRAME_SIZE = the bracket's height.
--
--   * Two energy PANELS, COPLANAR and AXIS-ALIGNED, one each side of the
--     lane. The gap between the brackets IS the lane.
--   * A BRACKET beside each panel: a ribbed post on the lane side, with a
--     thin dark arm top and bottom reaching OUT toward the panel -- a "["
--     on the right, a "]" on the left.
--
-- (The first port tilted the panels with rotZ. That rotates a panel INSIDE
-- its own plane, turning it into a diagonal slat, and its 0.12 offset was
-- smaller than the panel's half width so the two panels overlapped. Face-on
-- the reference panels are plain upright rectangles.)
--
--   x:   0 .. 0.245   the lane (gap between the post faces)
--        0.245 .. 0.415  the post
--        0.415 .. 0.69   the arms
--        0.58 .. 1.82    the panel (centre 1.20, width 1.24)
local POST_IN    = 0.245
local POST_OUT   = 0.415
local ARM_TIP    = 0.69
local ARM_THICK  = 0.035
local POST_DEPTH = 0.075
local ARM_DEPTH  = 0.055

local PANEL_CX = 1.20
local PANEL_W  = 1.24
local PANEL_H  = 0.64
local PANEL_T  = 0.02     -- half thickness of the panel's two faces

-- The outer edge of each panel sits a little DOWNSTREAM of its inner edge
-- (the oblique screenshot shows the panels shrinking toward their outer
-- edges, as if folded slightly away from the approach). Set to 0 for a dead
-- flat pair.
local PANEL_YAW = 0.12

local GRID_COLS = 2 * math.floor(PANEL_W * FRAME_SIZE / LATTICE_CELL / 2 + 0.5)
local GRID_ROWS = 2 * math.floor(PANEL_H * FRAME_SIZE / LATTICE_CELL / 2 + 0.5)

-- The energy panels: for each side s (-1 left, +1 right) a front and a
-- back quad, so the field is visible from either end of the lane.
--
-- uv.x = 1 on the edge NEXT TO THE BRACKET on both panels (the shader
-- fades the glow out there); uv.y = 0..1 bottom to top.
local panelMesh
local function getPanelMesh ()
  if panelMesh then return panelMesh end
  local m = Mesh.Create()
  local cy, sy = math.cos(PANEL_YAW), math.sin(PANEL_YAW)

  local function panel (s)
    local function corner (a, ly, z, nz, u, w)
      -- a: signed position along the panel, -W/2 .. +W/2, left to right.
      -- The outer edge (s*a > 0) is pushed downstream by the yaw.
      m:addVertex(s * PANEL_CX + a * cy, ly, z + s * a * sy, 0, 0, nz, u, w)
    end
    local hw, hh = PANEL_W * 0.5, PANEL_H * 0.5
    local function face (z, nz)
      local base = m:getVertexCount()
      local function uOf (a) return 0.5 - s * a / PANEL_W end
      corner(-hw, -hh, z, nz, uOf(-hw), 0)
      corner( hw, -hh, z, nz, uOf( hw), 0)
      corner( hw,  hh, z, nz, uOf( hw), 1)
      corner(-hw,  hh, z, nz, uOf(-hw), 1)
      return base
    end
    local f = face( PANEL_T,  1)
    m:addQuad(f, f + 1, f + 2, f + 3)
    local bk = face(-PANEL_T, -1)
    m:addQuad(bk, bk + 3, bk + 2, bk + 1)
  end

  panel(-1)
  panel( 1)
  m:computeNormals()
  panelMesh = m
  return panelMesh
end

-- A box with unshared vertices (hard edges). Faces are listed CCW seen from
-- outside. `ribbed` makes the +Z and -Z faces carry the post's rib uv
-- (u across, v 0..1 along the height); every other face is flagged uv.y=-1
-- (plain dark metal). `uOff` is 10 for the right-hand post: the shader reads
-- it as "which LED colour".
local function box (m, x0, x1, y0, y1, z0, z1, ribbed, uOff)
  local function quad (nx, ny, nz, p1, p2, p3, p4, uv)
    local base = m:getVertexCount()
    local pts = { p1, p2, p3, p4 }
    for i = 1, 4 do
      local p, t = pts[i], uv[i]
      m:addVertex(p[1], p[2], p[3], nx, ny, nz, t[1] + uOff, t[2])
    end
    m:addQuad(base, base + 1, base + 2, base + 3)
  end
  local plain = { {0,-1}, {1,-1}, {1,-1}, {0,-1} }
  local rib   = { {0, 0}, {1, 0}, {1, 1}, {0, 1} }
  local face  = ribbed and rib or plain
  quad(0, 0,  1, {x0,y0,z1}, {x1,y0,z1}, {x1,y1,z1}, {x0,y1,z1}, face)
  quad(0, 0, -1, {x1,y0,z0}, {x0,y0,z0}, {x0,y1,z0}, {x1,y1,z0}, face)
  quad( 1, 0, 0, {x1,y0,z1}, {x1,y0,z0}, {x1,y1,z0}, {x1,y1,z1}, plain)
  quad(-1, 0, 0, {x0,y0,z0}, {x0,y0,z1}, {x0,y1,z1}, {x0,y1,z0}, plain)
  quad(0,  1, 0, {x0,y1,z1}, {x1,y1,z1}, {x1,y1,z0}, {x0,y1,z0}, plain)
  quad(0, -1, 0, {x0,y0,z0}, {x1,y0,z0}, {x1,y0,z1}, {x0,y0,z1}, plain)
end

-- The brackets: for each side, a ribbed post and two thin arms that reach
-- OUT toward the panel.
local bracketMesh
local function getBracketMesh ()
  if bracketMesh then return bracketMesh end
  local m = Mesh.Create()
  local H = 0.5
  for _, s in ipairs({ -1, 1 }) do
    local uOff = (s > 0) and 10 or 0
    local function xs (a, b)            -- mirror an x range to this side
      if s > 0 then return a, b else return -b, -a end
    end
    -- the post
    local px0, px1 = xs(POST_IN, POST_OUT)
    box(m, px0, px1, -H, H, -POST_DEPTH, POST_DEPTH, true, uOff)
    -- the arms: top and bottom, from the post's outer face out to the tip
    local ax0, ax1 = xs(POST_OUT, ARM_TIP)
    box(m, ax0, ax1,  H - ARM_THICK,  H, -ARM_DEPTH, ARM_DEPTH, false, uOff)
    box(m, ax0, ax1, -H, -H + ARM_THICK, -ARM_DEPTH, ARM_DEPTH, false, uOff)
    -- the dark backing plate between the arms (the C's black pocket)
    local bx0, bx1 = xs(POST_OUT, ARM_TIP - 0.08)
    box(m, bx0, bx1, -H + ARM_THICK, H - ARM_THICK, -0.02, 0.02, false, uOff)
  end
  m:computeNormals()
  bracketMesh = m
  return bracketMesh
end

local Rail = {}

Rail = subclass(Entity, function (self, opts)
  opts = opts or {}
  self.from = opts.from
  self.to   = opts.to
  self.fromName = opts.fromName
  self.toName   = opts.toName
  self.isRail = true
  self.name = opts.name or ('Rail to ' .. tostring(opts.toName))
  self.time = 0

  local a, b = self.from, self.to
  local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
  self.length = math.sqrt(dx * dx + dy * dy + dz * dz)
  if self.length < 1e-3 then self.length = 1e-3 end
  self.dir = Vec3f(dx / self.length, dy / self.length, dz / self.length)

  -- The rail is a thing to fly through, not to crash into, so it has no
  -- rigid body -- but it still needs a position for the map.
  self.pos = { x = (a.x + b.x) * 0.5, y = (a.y + b.y) * 0.5, z = (a.z + b.z) * 0.5 }
  self.radius = FRAME_SIZE * 0.5

  -- The frames along the lane.
  --
  -- The clear space at the hub end, and the frames spread over what is left.
  -- The clearance is capped at a fraction of the lane, so a short lane still
  -- gets frames.
  local clear = math.min(opts.clearStart or 0, self.length * 0.35)
  local usable = self.length - clear
  self.frames = {}
  local count = math.max(1, math.floor(usable / FRAME_SPACING))
  for i = 1, count do
    self.frames[#self.frames + 1] = clear + usable * (i - 0.5) / count
  end

  self:register(Event.Render, Rail.render)
  self:register(Event.Update, Rail.update)
end)

-- Where the ship is relative to the lane's line: the distance along it, the
-- distance off it, and the perpendicular offset.
function Rail:project (x, y, z)
  local a = self.from
  local t = (x - a.x) * self.dir.x + (y - a.y) * self.dir.y + (z - a.z) * self.dir.z
  if t < 0 then t = 0 elseif t > self.length then t = self.length end
  local ox = x - (a.x + self.dir.x * t)
  local oy = y - (a.y + self.dir.y * t)
  local oz = z - (a.z + self.dir.z * t)
  return t, math.sqrt(ox * ox + oy * oy + oz * oz), ox, oy, oz
end

-- The nearest frame to a point on the lane.
function Rail:nearestFrame (t)
  local best, bestD = nil, math.huge
  for _, ft in ipairs(self.frames) do
    local d = math.abs(ft - t)
    if d < bestD then best, bestD = ft, d end
  end
  return best, bestD
end

-- The ride: the old controller's three forces.
--
-- The capture is at a FRAME, not along the whole lane -- the old game's slot
-- allocator lived in the node, so that was where a ship was caught.
function Rail:ride (ship, dt)
  local p = ship:getPos()
  local t, off = self:project(p.x, p.y, p.z)
  local frame, frameD = self:nearestFrame(t)

  -- The capture: TWO tests, and both have to pass.
  --
  -- The first is the corridor: the ship has to be ON the lane, which is a
  -- question about the lane's LINE and not about any one gate.
  --
  -- The second is the gate: the ship has to have met one, and it has to be
  -- between the first and the last of them -- outside that stretch there is
  -- nothing to fly into, and the lane does not exist.
  local inCorridor = off <= CORRIDOR_RADIUS
  local inSpan = frame ~= nil and frameD <= CAPTURE_RADIUS + FRAME_SPACING * 0.5
  if not (inCorridor and inSpan) then
    -- Out of the lane: the rail lets go.
    --
    -- Only if it was THIS rail that was carrying the ship. The app asks
    -- every rail in the sector whether it has the ship, and a rail that has
    -- not got it must not take the ship away from the rail that has.
    if self.carrier == ship then self:release(ship) end
    return false
  end

  local mass = 1
  if ship.getMass then
    local ok, m = pcall(ship.getMass, ship)
    if ok and type(m) == 'number' and m > 0 then mass = m end
  end
  self.carrier = ship

  -- The ship PASSES THROUGH the asteroids while it is on the rail.
  --
  -- The lane is a road through the asteroid field, and the rocks in it are
  -- solid and immovable: a ship that meets one stops dead against it and
  -- stays there. Which is what happened -- the rail force accelerated the
  -- ship to 100 u/s, it met a rock two seconds later, and it sat against
  -- that rock for the rest of the ride. The lane is supposed to carry you
  -- across a sector, and it carried you into a boulder.
  --
  -- So the ship is made non-collidable while it is being carried, and is
  -- made collidable again the moment the rail lets go.
  if not self.__ghosted and ship.setCollidable then
    self.__ghosted = true
    ship:setCollidable(false)
  end

  if ship.applyForce then
    -- 1. The rail force, down the lane -- but only while the ship is not
    --    already going fast enough. See RAIL_SPEED.
    --
    --    The cap comes down over the last stretch of the lane, so the ship
    --    is wound down to a speed it can arrive at, rather than being
    --    released at the rail's full speed.
    local cap = RAIL_SPEED
    local brakeAt = self.length * (1 - BRAKE_ZONE)
    if t > brakeAt then
      local f = (self.length - t) / (self.length - brakeAt)
      cap = math.max(EXIT_SPEED, RAIL_SPEED * f)
    end
    local v = ship:getVelocity()
    local along = v.x * self.dir.x + v.y * self.dir.y + v.z * self.dir.z
    if along < cap then
      ship:applyForce(Vec3f(self.dir.x * RAIL_FORCE * mass,
                           self.dir.y * RAIL_FORCE * mass,
                           self.dir.z * RAIL_FORCE * mass))
    end
    -- 2. The lane-locking force, back onto the line. This is what makes it
    --    a LANE: the ship is held on the rail's line rather than merely
    --    pushed along it.
    if off > 1 then
      local _, _, ox, oy, oz = self:project(p.x, p.y, p.z)
      local k = LANE_LOCK_FORCE * mass
      ship:applyForce(Vec3f(-ox * k, -oy * k, -oz * k))
    end
  end

  -- 3. The ARRIVAL: at the far end the rail lets go, and the ship is
  --    somewhere else -- in the other region.
  if t >= self.length - 1 then
    -- The exit: the ship is let go along the lane, at the exit speed, so
    -- it can fly on instead of arriving like a meteor.
    local vv = ship:getVelocity()
    local sp = vv.x * self.dir.x + vv.y * self.dir.y + vv.z * self.dir.z
    if sp > EXIT_SPEED then
      ship:setVelocity(Vec3f(self.dir.x * EXIT_SPEED,
                             self.dir.y * EXIT_SPEED,
                             self.dir.z * EXIT_SPEED))
    end
    self:release(ship)
    self.arrived = true
  end
  return true
end

-- Let the ship go, and give it back its collisions.
function Rail:release (ship)
  self.carrier = nil
  if self.__ghosted and ship and ship.setCollidable then
    self.__ghosted = false
    ship:setCollidable(true)
  end
end

-- The rail's orientation: a frame's plane is perpendicular to the lane, so
-- the ship flies THROUGH it.
function Rail:getBasis ()
  local up = Vec3f(0, 1, 0)
  if math.abs(self.dir.y) > 0.98 then up = Vec3f(1, 0, 0) end
  local right = self.dir:cross(up):normalize()
  local realUp = right:cross(self.dir):normalize()
  return right, realUp
end

-- The NORMAL matrix: the inverse-transpose of the world matrix.
--
-- The basis is ORTHONORMAL (three unit vectors) scaled by `size`, so its
-- inverse-transpose is the same basis with the scale undone. The
-- translation does not enter into it: a translation does not affect normals.
--
-- This has to be set EXPLICITLY. Leaving mWorldIT unset means the vertex
-- shader normalises a zero vector, and the whole fragment goes NaN -- which
-- under additive blending is a black field, not a missing one. The field was
-- being drawn; it was arriving as NaN.
function Rail:getNormalMatrix (size)
  local right, realUp = self:getBasis()
  local inv = 1 / math.max(size, 1e-6)
  return Matrix.FromBasis(right:muls(inv), realUp:muls(inv),
                          self.dir:muls(inv))
end

-- The matrix for a frame at a distance along the lane.
function Rail:getFrameMatrix (t, size)
  local right, realUp = self:getBasis()
  local a = self.from
  local p = Vec3f(a.x + self.dir.x * t, a.y + self.dir.y * t, a.z + self.dir.z * t)
  return Matrix.Translation(p.x, p.y, p.z)
         * Matrix.FromBasis(right, realUp, self.dir)
         * Matrix.Scaling(size, size, size)
end

-- The rail's render: the CHAIN OF FRAMES.
--
-- Two draws per frame: the BRACKETS (solid, ribbed, self-shaded, in the
-- forward pass) and the two ENERGY PANELS (additive).
function Rail:render (state)
  local bracket = self.bracketMaterial
  local field = self.material

  if state.mode == BlendMode.Alpha and bracket then
    for _, t in ipairs(self.frames) do
      bracket:start()
        Shader.SetMatrix('mWorld', self:getFrameMatrix(t, FRAME_SIZE))
        Shader.SetMatrixT('mWorldIT', self:getNormalMatrix(FRAME_SIZE))
        Shader.SetFloat('time', self.time)
        Shader.SetFloat3('color',    0.62, 0.65, 0.74)  -- pale cool rib
        Shader.SetFloat3('ledLeft',  1.00, 0.10, 0.08)  -- red, left post
        Shader.SetFloat3('ledRight', 0.20, 0.35, 1.00)  -- blue, right post
        getBracketMesh():draw()
      bracket:stop()
    end
    return
  end

  if state.mode ~= BlendMode.Additive then return end
  if not field then return end
  for _, t in ipairs(self.frames) do
    field:start()
      Shader.SetFloat('time', self.time)
      Shader.SetFloat3('scale', FRAME_SIZE, FRAME_SIZE, FRAME_SIZE)
      Shader.SetFloat('flowSpeed', self.flowSpeed or 512)
      Shader.SetFloat2('gridScale', GRID_COLS, GRID_ROWS)
      Shader.SetFloat('phase', self.phase or 0)
      Shader.SetMatrix('mWorld', self:getFrameMatrix(t, FRAME_SIZE))
      Shader.SetMatrixT('mWorldIT', self:getNormalMatrix(FRAME_SIZE))
      getPanelMesh():draw()
    field:stop()
  end
end

function Rail:update (state)
  self.time = (self.time or 0) + state.dt
  -- The flow speed follows the ship it is carrying.
  if self.carrier then
    local v = self.carrier:getVelocity()
    local along = v.x * self.dir.x + v.y * self.dir.y + v.z * self.dir.z
    self.flowSpeed = math.abs(along) + 256
  else
    self.flowSpeed = 512
  end
  -- The rings' phase, in cycles, accumulated here so a changing flow speed
  -- changes their SPEED without making them jump. About 0.25 cycles/s at
  -- rest, up to ~0.5 at full rail speed.
  --
  -- It is accumulated POSITIVE, and the shader adds the phase to the ring's
  -- radius, so the crests travel INWARD, from the panel's edge towards its
  -- bright core. (Negate it here to run them outward instead.)
  self.phase = (self.phase or 0) + state.dt * (0.25 + self.flowSpeed / 6000)
end

Rail.FRAME_SIZE = FRAME_SIZE
Rail.CAPTURE_RADIUS = CAPTURE_RADIUS
Rail.HUB_CLEARANCE = HUB_CLEARANCE
Rail.FRAME_SPACING = FRAME_SPACING

return Rail
