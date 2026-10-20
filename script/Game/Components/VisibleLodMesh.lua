local Entity = require('Game.Entity')
local Batcher = require('Game.Batcher')
local Material = require('Game.Material')
local Shadow = require('Game.Shadow')
local Frustum = require('Game.Frustum')

--[[ Frustum culling for visible meshes.

  The engine submitted EVERY entity with a visible mesh every frame, whether or
  not it was on screen. On the 4K asteroid-field scene (10,643 streamed rocks)
  that cost ~14 ms of CPU draw-call recording per frame -- the largest single
  item in the frame -- and nearly all of it was wasted, because a camera with
  an 80 degree FOV sees a small fraction of a sphere of rocks that surrounds it.

  The test is a bounding SPHERE against the view cone, so a rock straddling the
  screen edge keeps part of its geometry on screen instead of popping out of
  existence.

  The radius comes from the entity's own collision sphere, which for the
  asteroid archetypes is built from the SAME mesh that is drawn (see
  CollisionShape_CreateSphereFromMesh), so it is the visible size and not a
  guess. It is then scaled by the entity's world scale, because the drawn
  geometry is scaled too.

  Culling is opt-in per material via `material.cullable`: only meshes that are
  known to be closed, bounded shapes are culled, and a false value (the
  default) means "always draw". A mesh whose visible geometry extends well past
  its collision sphere -- a station's greebles, a ship's fins -- would
  otherwise be culled while still partly on screen. ]]

-- Cache of the current frame's frustum, rebuilt by the camera. The accessor
-- lives in Frustum.lua (see Frustum.setCurrent / Frustum.getCurrent) -- it is
-- core state, not a property of this component, and putting it here made
-- GameView depend on this file being loaded first.
local scratchPos = Vec3f()

-- Diagnostic counters, read by the perf probe.
local culled = 0
local kept = 0
function Frustum.cullStats () return culled, kept end
function Frustum.resetCullStats () culled, kept = 0, 0 end

function Entity:addVisibleLodMesh (mesh, material)
  assert(not self.mesh)
  assert(mesh)
  assert(material)
  self.mesh = mesh
  self.material = material
  self:register(Event.Render, Entity.renderVisibleLodMesh)
end

-- Is this entity's visible geometry at least partly inside the view cone?
-- Returns true when it cannot be decided (no frustum, no radius, not cullable).
--
-- The radius is the collision sphere, which is built from the BASE asteroid mesh
-- (CollisionShape_CreateSphereFromMesh), while what is drawn is one of eight
-- lower-resolution LODs of the same shape. Those agree to within a few percent,
-- but a rock culled a few percent too eagerly would pop out of existence, so a
-- margin is added. It is a fraction of the radius, so it costs almost nothing
-- in culling efficiency.
local CULL_MARGIN = 1.15

-- `visible` tests the entity's bounding sphere against the view cone. The
-- world position is fetched by the caller and passed in, so it is read from
-- the rigid body exactly once per entity per frame.
local function visible (entity, x, y, z, radius)
  local planes = Frustum.getCurrent()
  if not planes then return true end
  -- The curtain's fade band: a rock ENTIRELY beyond the far edge has every
  -- fragment discarded by material/asteroid.glsl, so drawing it contributes
  -- nothing. The field streams out to loadDist while the fade ends short of
  -- that, so this removes a large share of the field's draw calls for an image
  -- that is bit-for-bit the same.
  if not Frustum.withinFadeBand(x, y, z, radius * CULL_MARGIN) then
    culled = culled + 1
    return false
  end
  local vis = Frustum.sphereVisible(planes, x, y, z, radius * CULL_MARGIN)
  if vis then kept = kept + 1 else culled = culled + 1 end
  return vis
end

-- Is this entity eligible for frustum culling at all? Only a material marked
-- `cullable` may be culled, and only if the entity has a usable radius.
-- The radius is fetched once and handed to `visible`, so the bounding sphere
-- is not computed twice per entity per frame.
local function cullRadius (entity)
  local material = entity.material
  if not (material and material.cullable) then return 0 end
  local body = entity.body
  if not body then return 0 end
  local radius = body:getBoundingRadius()
  if radius <= 0 then return 0 end
  return radius
end

function Entity:renderVisibleLodMesh (state)
  if state.pass == 'sunshadow' or state.pass == 'pointshadow' then
    if state.mode == BlendMode.Disabled then
      -- Shadow.isInMap fills scratchPos with the entity's world position, so the
      -- LOD distance below reuses it instead of asking the rigid body for the
      -- position a second time. The shadow pass visits every entity in the
      -- system, so each avoided call is ~10,600 fewer per frame.
      if Shadow.isInMap(self, state, scratchPos) then
        local lod = state.eye:distanceSquared(scratchPos) / (self:getScale() ^ 2.0)
        local shadow = Material.Shadow()
        shadow:start()
        shadow:setState(self)
        self.mesh:draw(lod)
        shadow:stop()
      end
    end
    return
  end

  if state.mode == BlendMode.Disabled then
    local body = self.body
    local radius = cullRadius(self)
    local x, y, z
    if body then
      body:getPos(scratchPos)
      x, y, z = scratchPos.x, scratchPos.y, scratchPos.z
    else
      local p = self:getPos()
      scratchPos.x, scratchPos.y, scratchPos.z = p.x, p.y, p.z
      x, y, z = p.x, p.y, p.z
    end

    if radius > 0 then
      if not visible(self, x, y, z, radius) then return end
    end

    local lod = state.eye:distanceSquared(scratchPos) / (self:getScale() ^ 2.0)
    if not (Batcher.isOpen() and Batcher.record(self.material, self.mesh, self, lod, false)) then
      self.material:start()
      self.material:setState(self)
      self.mesh:draw(lod)
      self.material:stop()
    end
  end
end
