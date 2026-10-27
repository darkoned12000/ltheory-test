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

  local dx = pos.x - center.x
  local dy = pos.y - center.y
  local dz = pos.z - center.z
  local limit = mapRadius + objectRadius
  if dx * dx + dy * dy + dz * dz > limit * limit then
    return false
  end

  local box = state.shadowBox
  if box then
    local rx = dx * box.rx + dy * box.ry + dz * box.rz
    if math.abs(rx) > box.halfSize + objectRadius then return false end
    local ux = dx * box.ux + dy * box.uy + dz * box.uz
    if math.abs(ux) > box.halfSize + objectRadius then return false end
    local zx = dx * box.zx + dy * box.zy + dz * box.zz
    if math.abs(zx) > box.depthExtent + objectRadius then return false end
  end

  return true
end

-- Single-pass cascade bucketing for CSM: test all top-level system children
-- against the 3 light-space orthographic cascade boxes in ONE scan (one FFI
-- getPos + getBoundingRadius per rock instead of three, and no Event.Broadcast
-- dispatch for the ~98% of rocks outside all cascades).
function Shadow.cullSunCascades (world, boxes, out0, out1, out2)
  local children = world.children
  if not children then return end
  local b0, b1, b2 = boxes[1], boxes[2], boxes[3]
  local rx, ry, rz = b0.rx, b0.ry, b0.rz
  local ux, uy, uz = b0.ux, b0.uy, b0.uz
  local zx, zy, zz = b0.zx, b0.zy, b0.zz
  local n0, n1, n2 = 0, 0, 0

  for i = #children, 1, -1 do
    local entity = children[i]
    if entity.parent == world then
      local body = entity.body
      if not body then
        n0 = n0 + 1; out0[n0] = entity
        n1 = n1 + 1; out1[n1] = entity
        n2 = n2 + 1; out2[n2] = entity
      else
        body:getPos(scratchPos)
        local r = body:getBoundingRadius()
        local objR = (r > 0) and (r * CULL_MARGIN) or 0
        local px, py, pz = scratchPos.x, scratchPos.y, scratchPos.z

        -- Project position onto the shared light-space basis once.
        local lx = px * rx + py * ry + pz * rz
        local ly = px * ux + py * uy + pz * uz
        local lz = px * zx + py * zy + pz * zz

        if math.abs(lx - b0.cx) <= b0.halfSize + objR
           and math.abs(ly - b0.cy) <= b0.halfSize + objR
           and math.abs(lz - b0.cz) <= b0.depthExtent + objR then
          n0 = n0 + 1; out0[n0] = entity
        end
        if math.abs(lx - b1.cx) <= b1.halfSize + objR
           and math.abs(ly - b1.cy) <= b1.halfSize + objR
           and math.abs(lz - b1.cz) <= b1.depthExtent + objR then
          n1 = n1 + 1; out1[n1] = entity
        end
        if math.abs(lx - b2.cx) <= b2.halfSize + objR
           and math.abs(ly - b2.cy) <= b2.halfSize + objR
           and math.abs(lz - b2.cz) <= b2.depthExtent + objR then
          n2 = n2 + 1; out2[n2] = entity
        end
      end
    end
  end

  for i = #out0, n0 + 1, -1 do out0[i] = nil end
  for i = #out1, n1 + 1, -1 do out1[i] = nil end
  for i = #out2, n2 + 1, -1 do out2[i] = nil end
end

return Shadow
