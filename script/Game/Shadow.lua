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

function Shadow.isInMap (entity, state, outPos)
  local center = state.shadowCenter
  local mapRadius = state.shadowCullRadius
  if not (center and mapRadius and entity.getPos) then return true end

  local body = entity.body
  local pos
  if body then
    body:getPos(scratchPos)
    pos = scratchPos
  else
    pos = entity:getPos()
  end
  if outPos then
    outPos.x, outPos.y, outPos.z = pos.x, pos.y, pos.z
  end

  local objectRadius = 0
  if entity.getRadius then
    objectRadius = entity:getRadius()
  elseif entity.getScale then
    objectRadius = entity:getScale()
  end
  local limit = mapRadius + objectRadius
  return center:distanceSquared(pos) <= limit * limit
end

return Shadow
