--[[ Frustum -- CPU-side view-frustum culling for visible meshes.

  WHY THIS EXISTS
  The engine had NO frustum culling at all: every entity with a visible mesh
  was submitted every frame, whether or not it was on screen. Measured on the
  4K asteroid-field scene (10,643 streamed rocks), that cost ~23 ms of CPU
  draw-call recording per frame -- the single largest item in the frame, and
  almost all of it wasted, because a camera with an 80 degree FOV sees a small
  fraction of a sphere of rocks that surrounds it.

  The cost is CPU-side (recording and replaying draw calls), NOT fill-rate:
  rendering the same scene at 67% resolution changed the frame time by 0.5 ms.
  That is why this is a draw-call cull and not a resolution lever.

  HOW THE TEST WORKS
  Four world-space planes bound the view cone. A bounding sphere is kept unless
  it lies entirely outside one plane. Testing a SPHERE rather than a point is
  what keeps this safe: a rock straddling the screen edge still has part of its
  geometry visible, and a point test would cull it and pop it out of existence.

  A plane is stored as (nx, ny, nz, d) with the normal pointing INWARD, so the
  visible half-space is n.p + d >= 0, and a sphere of radius r is completely
  outside the plane when n.p + d < -r.

  WHY THE CAMERA BASIS INSTEAD OF THE PROJECTION MATRIX
  The engine remaps clip-space depth in the vertex shader (vertex.glsl's
  logDepth), so the near and far planes recovered from the view-projection
  matrix do not describe the depth range the renderer actually uses. The side
  planes are unaffected by that, and they are the ones that decide "is this on
  screen" -- but taking all four from the camera's own basis avoids depending on
  a depth convention the renderer deliberately does not use.

  The camera basis matches the projection exactly: mViewInv is built from the
  same quaternion (Matrix_FromPosRot), and Matrix_Perspective scales x by
  cot/aspect and y by cot, so the half-angles are tan(fovY/2) vertically and
  tan(fovY/2)*aspect horizontally. Both are symmetric, so the test is correct
  regardless of the renderer's screen-space y flip.
]]

local Frustum = {}

local sqrt = math.sqrt
local tan  = math.tan
local pi   = math.pi

--[[ build -- the four side planes of the view cone, in world space.

  `camera` supplies pos, rot (a quaternion), sx and sy (the viewport size).
  `fovYDegrees` is the vertical field of view in degrees. ]]
function Frustum.build (camera, fovYDegrees)
  local fovY = fovYDegrees or 75
  local aspect = (camera.sy > 0) and (camera.sx / camera.sy) or 1

  -- Half-angle tangents. Matrix_Perspective uses rads = pi*fovY/360, so the
  -- vertical half-angle tangent is tan(rads) and the horizontal one is that
  -- times the aspect.
  local tanHalfY = tan(pi * fovY / 360.0)
  local tanHalfX = tanHalfY * aspect

  local rot = camera.rot
  local fwd  = rot:getForward()
  local right= rot:getRight()
  local up   = rot:getUp()
  local ex, ey, ez = camera.pos.x, camera.pos.y, camera.pos.z

  -- Inward normals, in world space, for the four side planes:
  --   "right"   bounds the +right side: tanHalfX*fwd - right
  --   "left"    bounds the -right side: tanHalfX*fwd + right
  --   "top"     bounds the +up side:    tanHalfY*fwd + up
  --   "bottom"  bounds the -up side:    tanHalfY*fwd - up
  -- The test below evaluates n.p + d and compares it against -radius, so d must
  -- be chosen such that n.p + d == n.(p - eye), i.e. d = -n.eye.
  local planes = {}

  local function add (nx, ny, nz)
    -- right and up are unit and orthogonal to fwd, so the normal's length is
    -- sqrt(1 + tanHalf^2).
    local len = sqrt(nx * nx + ny * ny + nz * nz)
    if len < 1e-9 then return end
    nx, ny, nz = nx / len, ny / len, nz / len
    planes[#planes + 1] = {
      nx, ny, nz,
      -(nx * ex + ny * ey + nz * ez),
    }
  end

  add(tanHalfX * fwd.x - right.x, tanHalfX * fwd.y - right.y, tanHalfX * fwd.z - right.z)
  add(tanHalfX * fwd.x + right.x, tanHalfX * fwd.y + right.y, tanHalfX * fwd.z + right.z)
  add(tanHalfY * fwd.x + up.x,    tanHalfY * fwd.y + up.y,    tanHalfY * fwd.z + up.z)
  add(tanHalfY * fwd.x - up.x,    tanHalfY * fwd.y - up.y,    tanHalfY * fwd.z - up.z)

  return planes
end

--[[ sphereVisible -- is a world-space sphere at least partly inside the frustum?

  A sphere is culled only when it is fully outside ONE plane. "Outside one
  plane" means that whole plane's half-space excludes it, so no part of the
  sphere can be seen through that plane. This is the conservative direction:
  it can keep something that is not visible (a small cost), but it must never
  drop something that is (a visible pop). ]]
function Frustum.sphereVisible (planes, x, y, z, radius)
  if not planes then return true end
  if Frustum.disableFrustum then return true end
  for i = 1, #planes do
    local p = planes[i]
    if p[1] * x + p[2] * y + p[3] * z + p[4] < -radius then
      return false
    end
  end
  return true
end

--[[ The asteroid curtain's fade band, in world units.

  material/asteroid.glsl discards every fragment of a rock whose distance from
  the eye is beyond the fade's far edge, so a rock ENTIRELY beyond that edge
  contributes NOTHING to the image -- the shader throws all of it away. The CPU
  was still recording a full draw call for it.

  This lets the CPU skip those draws outright, which is exact (the image is
  unchanged, because every one of those fragments was discarded anyway) and
  removes a large share of the field's draw calls: the field streams out to
  loadDist, while the fade ends at loadDist minus the spawn margin.

  near/far are the SAME numbers the shader uses; System:beginRender pushes them
  as the rockFadeNear/rockFadeFar uniforms. ]]
local fadeNear = 0
local fadeFar = math.huge
local fadeEyeX, fadeEyeY, fadeEyeZ = 0, 0, 0

function Frustum.setFadeBand (near, far, eye)
  fadeNear = near or 0
  fadeFar = far or math.huge
  if eye then
    fadeEyeX, fadeEyeY, fadeEyeZ = eye.x, eye.y, eye.z
  end
end

-- Diagnostic switches used by the perf probe to A/B each cull independently
-- against a captured frame. Off in normal play.
Frustum.disableFadeBand = false
Frustum.disableFrustum = false

-- Is any part of this sphere within the fade band (i.e. could it draw a pixel)?
function Frustum.withinFadeBand (x, y, z, radius)
  if fadeFar == math.huge then return true end
  if Frustum.disableFadeBand then return true end
  local dx, dy, dz = x - fadeEyeX, y - fadeEyeY, z - fadeEyeZ
  local d = math.sqrt(dx * dx + dy * dy + dz * dz)
  -- The nearest point of the sphere is what matters: if even that is beyond the
  -- far edge, every fragment of it is discarded.
  return (d - radius) <= fadeFar
end

return Frustum
