-- Conservative CPU culling for the orthographic shadow maps. The sphere radius
-- is chosen by GameView to enclose the entire light-space box; expanding it by
-- the object's own bound keeps large casters at the edge.
--
-- WHY THIS IS HOT: the shadow pass renders the WHOLE world, so it visits every
-- entity in the system -- ~10,600 in a streamed asteroid field -- and the only
-- per-entity work is this test. `Entity:getPos` allocates a fresh Vec3f on
-- every call, so the test used to churn one heap allocation per entity per
-- shadow update, on top of the FFI calls.
--
-- The scratch vector below removes that allocation. `outPos` is filled with
-- the entity's world position when it is supplied, so the caller can reuse it
-- instead of asking for the position a second time (the LOD selection wants
-- the distance to the same point).
local Shadow = {}

local scratchPos = Vec3f()

-- The shadow map draws the VISIBLE MESH, but the only size the entity exposes
-- cheaply is its COLLISION sphere. Those differ: a station's greebles and a
-- ship's fins reach past their collision sphere, so a caster culled exactly at
-- the collision radius loses the tips of its shadow. The same 1.15 margin the
-- view cull uses (see VisibleLodMesh.lua) covers the gap.
--
-- The margin is duplicated as a literal here because the two culls measure
-- DIFFERENT things -- the view cull bounds the drawn LOD against the collision
-- sphere, this one bounds the drawn MESH against the same sphere -- and
-- sharing a constant across them would imply a coupling that does not exist.
local CULL_MARGIN = 1.15

function Shadow.isInMap (entity, state, outPos)
  local center = state.shadowCenter
  local mapRadius = state.shadowCullRadius
  if not (center and mapRadius) then return true end

  local body = entity.body
  local pos
  local objectRadius = 0
  if body then
    body:getPos(scratchPos)
    pos = scratchPos
    local r = body:getBoundingRadius()
    if r > 0 then objectRadius = r * CULL_MARGIN end
  else
    -- No rigid body. `Entity:getPos` ASSERTS one, so it cannot be called
    -- here -- an entity with no body has no position to test against, so it
    -- is kept (the shadow pass will draw it, or the mesh path will skip it).
    return true
  end
  if outPos then
    outPos.x, outPos.y, outPos.z = pos.x, pos.y, pos.z
  end

  local limit = mapRadius + objectRadius
  return center:distanceSquared(pos) <= limit * limit
end

return Shadow
