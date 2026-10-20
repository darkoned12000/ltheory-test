--[[ Wormhole -- a jumpgate: the paired portal between two sectors.

  PORTED FROM THE ORIGINAL LIMIT THEORY (Warping/Wormhole.cpp).

  The old game's jumpgate was a PAIR of objects, one inside each of two
  sectors, each navigable-linked to the other:

      void Object_Wormholes(ObjectT* o1, ObjectT* o2) {
        a->GetNavigable()->nodes.push(NavigableNode(b, 0));
        b->GetNavigable()->nodes.push(NavigableNode(a, 0));
        a->SetName(o2->GetName() + " Wormhole");
        b->SetName(o1->GetName() + " Wormhole");
        a->SetScale(1000); b->SetScale(1000);
      }

  and travelling was a DOCK:

      void Wormhole::Dock(Object const& docker) override {
        Object const& dest = Navigable.nodes[0].dest;
        dest->GetContainer()->AddInterior(docker);
        docker->SetPos(dest->GetPos() - 1500.0f * Normalize(dest->GetPos()));
      }

  So: the endpoint knows its partner, and the travel is docking with it.
  That is exactly what this is -- a dockable entity that, when something
  docks with it, puts that something at its partner.

  THE DIFFERENCE FROM THE OLD ENGINE
  ==================================
  The old engine had real interior containers, so the arrival put the ship
  inside the OTHER SECTOR's container. This engine's container is the entity
  parent tree and the world is a single System, so the arrival instead:

    * moves the ship to the partner endpoint's position, and
    * tells the app that the player is now in ANOTHER SECTOR.

  The sector's identity (its name, its regions, its gates) is regenerated
  from the destination sector's seed on arrival -- see Game/SectorGraph.lua.
]]

local Entity = require('Game.Entity')

-- The gate's visual scale. The old code used 1000 for the wormhole's
-- scale, and 400000 for the distance between the two ends.
local GATE_SCALE = 1000

-- The radius within which the player can dock with the gate.
local GATE_DOCK_RANGE = 2500

-- The gate's DOCK radius. See the note where it is set: the DockAt action
-- aims the ship a radius-and-a-quarter below the dockable, so this has to
-- be small enough that the ship can actually get there.
local GATE_DOCK_RADIUS = 300

-- THE SOUND
-- =========
-- The original Limit Theory's warp node had a whole sound set, and it is
-- HERE -- Warping/warpnode/, brought over as res/sound/warpnode/:
--
--   drone1/2/3   the portal's hum, three variants
--   droneverb    the reverb tail
--   dronewarp    the tone the warp itself makes
--   crackle      electrical crackle
--   lashing      energy lashing
--   static       static
--   frame        a short click
--   group        a group sound
--   exit         arriving
--
-- The gate uses the DRONE as its hum (a variant per gate, so two gates
-- near each other do not sound like the same object), and EXIT when you
-- come through.
--
-- They were Vorbis in the old game; they are MP3 here, because the engine
-- has no master volume and miniaudio's Vorbis decoder has been known to
-- reject some valid streams (see the note in AGENTS.md). MP3 is what the
-- music assets use, so it is the well-trodden path.
local GATE_DRONES = { 'warpnode/drone1', 'warpnode/drone2', 'warpnode/drone3' }

-- The gate's hum: full volume inside this radius, falling off to nothing
-- at the far one. A portal that can be heard from the whole sector would
-- be a siren.
local GATE_DRONE_MIN_DIST = 3000
local GATE_DRONE_MAX_DIST = 45000

-- The mesh: a UNIT sphere (Mesh_BoxSphere normalises the box's vertices
-- onto the sphere), which is what the old wormhole used -- an inverted
-- box-sphere, so that the camera sits inside it and sees the far wall.
local mesh, material
local function getMesh ()
  if not mesh then
    mesh = Mesh.BoxSphere(16)
    mesh:computeNormals()
  end
  return mesh
end

local Wormhole = {}

Wormhole = subclass(Entity, function (self, opts)
  opts = opts or {}

  -- The sector this gate LEADS TO, and the position of the far end.
  self.partnerSector = opts.partnerSector
  self.partnerPos    = opts.partnerPos
  self.partnerName   = opts.partnerName
  -- The sector this gate stands in.
  self.homeSector    = opts.homeSector

  self.isWormhole = true
  self.name = opts.name or 'Wormhole'

  -- A gate is a PLACE, so it is on the map, and it can be docked with --
  -- which is how you travel.
  self:addDockable()
  self:addChildren()

  -- A gate has no rigid body: it is a portal, not a thing you can crash
  -- into. So its position and scale are plain fields, and the accessors
  -- below stand in for the ones the RigidBody component would provide.
  --
  -- The RADIUS is the DOCK radius, not the visual size. The DockAt action
  -- aims the ship at a point one-and-a-quarter radii "below" the dockable,
  -- so a huge radius would put the aim point a long way from the gate and
  -- the ship would never quite reach it.
  self.scale = GATE_SCALE
  self.radius = GATE_DOCK_RADIUS
  if opts.pos then self.pos = opts.pos end

  -- The glow material. It draws with culling off and an additive blend, so
  -- you see the INSIDE of the sphere: you are meant to be looking at the
  -- throat of the portal.
  self.material = Material.Wormhole()

  -- The gate is drawn as a glowing sphere you are meant to be inside of.
  --
  -- NOT a visible mesh: an ordinary visible mesh goes into the G-BUFFER
  -- pass (opaque, deferred), and this is an ADDITIVE glow that you look at
  -- from the inside. So it registers its own render handler and draws in
  -- the additive pass, the way the thrusters and the explosions do.
  self:register(Event.Render, Wormhole.render)
  self.time = 0
  self.sound = nil
end)

-- The gate's hum.
--
-- Started once, looping, and positioned at the gate. The 3D settings do
-- the attenuation: full volume inside the near radius, silent past the far
-- one, so the sound is a thing you fly TOWARDS rather than a thing that is
-- simply always on.
function Wormhole:startSound ()
  if self.sound then return end
  local variant = GATE_DRONES[(self.partnerSector or 0) % #GATE_DRONES + 1]
  local s = Sound.Load(variant, true, true)
  if not s then return end
  s:set3DPos(self.pos, Vec3f(0, 0, 0))
  s:set3DMinMaxDistance(GATE_DRONE_MIN_DIST, GATE_DRONE_MAX_DIST)
  s:setVolume(0.8)
  s:play()
  self.sound = s
end

-- The sound of coming through a gate.
function Wormhole:playExit ()
  local s = Sound.Load('warpnode/exit', false, false)
  if not s then return end
  s:setVolume(1.0)
  s:setFreeOnFinish(true)
  s:play()
end

-- The gate's own render: the fractal needs a time uniform, which the engine
-- only sets for the post-processing passes.
function Wormhole:render (state)
  -- Additive only: the glow is drawn in the forward pass, over the scene.
  if state.mode ~= BlendMode.Additive then return end
  local m = self.material
  if not (m and state.eye) then return end
  local p = self.pos or { x = 0, y = 0, z = 0 }
  local s = self.scale
  m:start()
    Shader.SetFloat('time', self.time)
    Shader.SetMatrix('mWorld', self:getGateMatrix())
    -- The eye in the gate's own frame. See the shader for why it is passed
    -- in rather than derived from the world matrix.
    Shader.SetFloat3('eyeLocal',
                     (state.eye.x - p.x) / s,
                     (state.eye.y - p.y) / s,
                     (state.eye.z - p.z) / s)
    getMesh():draw()
  m:stop()
end

-- The gate's world matrix.
--
-- A gate has no rigid body -- it is a portal, not a thing you can crash
-- into -- so there is no body to ask for a transform. The matrix is built
-- by hand: a translation to the gate and a uniform scale.
function Wormhole:getGateMatrix ()
  local p = self.pos or { x = 0, y = 0, z = 0 }
  -- SRT: scale, then translation, no rotation.
  return Matrix.SRT(self.scale, self.scale, self.scale, 0, 0, 0, p.x, p.y, p.z)
end

function Wormhole:update (state)
  self.time = (self.time or 0) + state.dt
end

-- The RigidBody component's accessors, for an entity that has no body.
function Wormhole:getPos () return self.pos end
function Wormhole:getScale () return self.scale end
function Wormhole:getRadius () return self.radius end

-- The DockAt action needs an "up" to aim at: it sends the ship to a point
-- below the dockable. A gate has no orientation, so it is upright.
function Wormhole:getUp () return Vec3f(0, 1, 0) end

-- Where the far end is, in world space.
function Wormhole:getPartnerPos ()
  return self.partnerPos
end

-- The partner's sector.
function Wormhole:getPartnerSector ()
  return self.partnerSector
end

-- Docking with a gate IS the travel.
--
-- The Dockable component's addDocked makes the docker a CHILD of the
-- dockable -- which is this engine's version of "put it inside the
-- container". The old engine then moved the docker into the destination
-- container; here the destination is a position and a sector index, so the
-- ship is moved there and the app is told the sector changed.
function Wormhole:addDocked (e)
  Entity.addDocked(self, e)
  self:transfer(e)
end

-- Move a docked body to the far end of the gate.
--
-- The position is the partner's position pulled back slightly, so the ship
-- arrives OFF the gate rather than inside it -- the old code did the same
-- thing with its 1500-unit inset.
function Wormhole:transfer (e)
  local dest = self.partnerPos
  if not (dest and e) then return end

  -- The ship is currently a CHILD of this gate -- the Dockable component
  -- puts a docked body there. It must not stay there: the gate is a
  -- trigger, not somewhere to be parked, and the ship belongs to the world
  -- again. (The old engine did the same thing with `dest->GetContainer()
  -- ->AddInterior(docker)`: the body ended up in a CONTAINER, not in the
  -- portal.)
  local parent = self:getParent()
  if parent then parent:addChild(e) end

  local pos = e:getPos()
  local dx = dest.x - pos.x
  local dz = dest.z - pos.z
  local d = math.sqrt(dx * dx + dz * dz)
  local inset = GATE_DOCK_RANGE
  if d < 1e-3 then
    e:setPos(Vec3f(dest.x, dest.y, dest.z))
  else
    e:setPos(Vec3f(dest.x - (dx / d) * inset, dest.y, dest.z - (dz / d) * inset))
  end
  -- The app has to know that the player is somewhere else now: the sector's
  -- name, its regions, and its gates all change.
  if self.onArrive then self.onArrive(self, e) end
  self:playExit()
end

-- The gate is not something you can shoot at, and it is not a place you
-- can drill into on the map.
function Wormhole:hasActions () return false end
function Wormhole:hasSockets () return false end

-- The dock range. The Dockable component has no range of its own (the
-- DockAt action uses a global 200), and a gate is BIG -- a 1000-scale
-- portal -- so the range is generous.
Wormhole.DOCK_RANGE = GATE_DOCK_RANGE

return Wormhole
