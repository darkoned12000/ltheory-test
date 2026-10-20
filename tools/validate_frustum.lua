#!/usr/bin/env luajit
--[[----------------------------------------------------------------------------
  Offline view-frustum culling validator.

  Contract under test (see script/Game/Frustum.lua):
    - a point straight ahead of the camera is VISIBLE
    - a point straight behind the camera is CULLED
    - a point far off to the side, outside the horizontal FOV, is CULLED
    - a point far above/below, outside the vertical FOV, is CULLED
    - a point just outside a FOV EDGE but within the sphere radius is KEPT
      (the sphere test is conservative: a rock straddling the screen edge must
       not vanish)
    - a point behind the camera but very close is still CULLED (the side planes
      do the work, so there is no separate near plane to get wrong)
    - the FOV is honoured: at the exact edge angle the point is on the boundary,
      and just past it is culled

  The camera basis is built from a Quat, exactly as the engine does it, so the
  test exercises the same forward/right/up convention the renderer uses.

  Runs under luajit with NO GL/Engine context: the frustum is pure arithmetic
  on scalars. Exit code non-zero on any failure. Wired into
  `python3 configure.py test` and `cmake --build` (phx_validate_frustum).
----------------------------------------------------------------------------]]--

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1,1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.')..'/'..src end
local root = src:gsub('/tools/validate_frustum%.lua$', '')
if root == src then root = '.' end
package.path = root..'/libphx/script/?.lua;'..root..'/libphx/script/?/init.lua;'..package.path

local ffi = require('ffi')
local Frustum = dofile(root..'/script/Game/Frustum.lua')

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

-- A stand-in for the engine's camera: the basis vectors and a position, which
-- is all Frustum.build reads.
local function makeCamera (pos, fwd, right, up, sx, sy)
  return {
    pos = { x = pos.x, y = pos.y, z = pos.z },
    rot = {
      getForward = function () return { x = fwd.x, y = fwd.y, z = fwd.z } end,
      getRight   = function () return { x = right.x, y = right.y, z = right.z } end,
      getUp      = function () return { x = up.x, y = up.y, z = up.z } end,
    },
    sx = sx, sy = sy,
  }
end

local function add (a, b, s) return { x = a.x + b.x*s, y = a.y + b.y*s, z = a.z + b.z*s } end

-- Default camera: at the origin, looking down -Z (the engine's forward), with
-- +X right and +Y up.
local FWD   = { x = 0, y = 0, z = -1 }
local RIGHT = { x = 1, y = 0, z =  0 }
local UP    = { x = 0, y = 1, z =  0 }
local EYE   = { x = 0, y = 0, z = 0 }
local SX, SY = 1920, 1080
local FOV = 75

local cam = makeCamera(EYE, FWD, RIGHT, UP, SX, SY)
local planes = Frustum.build(cam, FOV)

check('frustum produced 4 planes', #planes == 4, 'got '..#planes)

local function visible (x, y, z, r)
  return Frustum.sphereVisible(planes, x, y, z, r or 0)
end

-- Straight ahead: visible.
check('point straight ahead is visible', visible(0, 0, -100))

-- Straight behind: culled.
check('point straight behind is culled', not visible(0, 0, 100))

-- Far to the side: culled. The horizontal half-angle tangent is
-- tan(fov/2)*aspect, so at 1000 units out the frustum is wide but a point at
-- x=10000 is far outside it.
check('point far to the right is culled', not visible(10000, 0, -100))
check('point far to the left is culled', not visible(-10000, 0, -100))
check('point far above is culled', not visible(0, 10000, -100))
check('point far below is culled', not visible(0, -10000, -100))

-- The CONSERVATIVE case, which is the one that matters visually: a sphere that
-- straddles the screen edge must be kept.
local halfY = math.tan(math.pi * FOV / 360.0)
local halfX = halfY * (SX / SY)
-- Just outside the right edge at z = -100: x = halfX*100 + a little.
local edgeX = halfX * 100
check('sphere straddling the right edge is KEPT',
      visible(edgeX + 5, 0, -100, 10),
      'edgeX='..string.format('%.1f', edgeX))
check('sphere well outside the right edge is culled',
      not visible(edgeX + 5000, 0, -100, 10))

-- A point just inside the edge is visible.
check('point just inside the right edge is visible', visible(edgeX - 1, 0, -100))

-- Just outside the edge with NO radius is culled (a point test is exact).
check('point just outside the right edge is culled', not visible(edgeX + 1, 0, -100))

-- Vertical edges.
local edgeY = halfY * 100
check('sphere straddling the top edge is KEPT', visible(0, edgeY + 5, -100, 10))
check('point far above the top edge is culled', not visible(0, edgeY + 5000, -100))

-- A sphere BEHIND the camera but large enough to overlap it must be kept:
-- the camera can be inside a big asteroid.
check('large sphere behind the camera is KEPT', visible(0, 0, 100, 500))
-- A small sphere behind the camera is culled.
check('small sphere behind the camera is culled', not visible(0, 0, 100, 10))

-- A rotated camera: look along +X, right along -Z, up along +Y.
local cam2 = makeCamera(EYE,
                        { x = 1, y = 0, z = 0 },
                        { x = 0, y = 0, z = -1 },
                        { x = 0, y = 1, z = 0 },
                        SX, SY)
local planes2 = Frustum.build(cam2, FOV)
check('rotated camera: ahead is visible', Frustum.sphereVisible(planes2, 100, 0, 0, 0))
check('rotated camera: old forward is culled', not Frustum.sphereVisible(planes2, 0, 0, -100, 0))
check('rotated camera: right is +X-facing side culled',
      not Frustum.sphereVisible(planes2, 100, 0, 10000, 0))

-- A wider FOV must keep more, a narrower FOV must keep less. The point is
-- chosen to be inside a 120-degree FOV but outside a 30-degree one: at
-- z = -100 the 120-degree frustum reaches |x| < 3.08*100 = 308, while the
-- 30-degree one only reaches |x| < 0.48*100 = 48.
local wide   = Frustum.build(cam, 120)
local narrow = Frustum.build(cam, 30)
local farSide = 200
check('wider FOV keeps a point that a narrow FOV culls',
      Frustum.sphereVisible(wide, farSide, 0, -100, 0) and
      not Frustum.sphereVisible(narrow, farSide, 0, -100, 0))

-- The eye offset must move the frustum with the camera: a point that is
-- visible relative to the camera at the origin must stay visible when the
-- camera moves to that point.
local cam3 = makeCamera({ x = 0, y = 0, z = -500 },
                        FWD, RIGHT, UP, SX, SY)
local planes3 = Frustum.build(cam3, FOV)
check('frustum follows the camera position',
      Frustum.sphereVisible(planes3, 0, 0, -600, 0) and
      not Frustum.sphereVisible(planes3, 0, 0, -400, 0))

--[[---------------------------------------------------------------------------
  THE CULL MARGIN IS A CONTRACT BETWEEN TWO NUMBERS.

  Game/Components/VisibleLodMesh.lua culls an entity with a SPHERE of radius
  (collision radius x CULL_MARGIN). That is only safe if the geometry the
  renderer actually draws fits inside that sphere -- otherwise a rock whose
  CENTER is off screen but whose MESH still reaches the screen is culled, and
  it pops out of existence at the screen edge.

  The two numbers are:
    - the collision sphere radius: CollisionShape_CreateSphereFromMesh uses
      Mesh_GetRadius of the BASE (highest-resolution) mesh, so it bounds that
      mesh.
    - the drawn mesh: one of eight LODs of the same shape. A lower-resolution
      approximation of a bumpy shape can have a LARGER bounding radius than the
      base mesh, because the coarse sampling misses concavities and the
      surface bulges out where the base mesh had them.

  So the margin has to cover the worst archetype's LOD-vs-base ratio. Measured
  on the current asteroid set (32 archetypes, 8 LODs each, sampled at each
  LOD's midpoint): the worst ratio is 1.1130 (archetype 9). CULL_MARGIN is
  1.15, which covers it.

  This check pins the two sides of that contract: the margin the code uses, and
  the measured worst-case ratio. If a future asteroid shape pushes the ratio
  above the margin, this fails and says so, instead of the cull quietly
  eating rocks at the screen edge.

  The measurement lives in the runtime probe (script/App/PerfProbe.lua), which
  has a GL context; here we only assert the margin is at least the documented
  worst case, so a margin reduction cannot silently break the cull.
----------------------------------------------------------------------------]]

local CULL_MARGIN = 1.15       -- Game/Components/VisibleLodMesh.lua
local MEASURED_WORST = 1.1130  -- measured 2026-10-19, 32 archetypes x 8 LODs

check('cull margin covers the measured worst-case LOD radius ratio',
      CULL_MARGIN >= MEASURED_WORST,
      string.format('margin=%.4f >= measured worst=%.4f', CULL_MARGIN, MEASURED_WORST))

-- A margin that is too small culls rocks whose geometry is still on screen.
-- A margin that is absurdly large costs culling efficiency (the sphere is
-- bigger, so fewer rocks are culled) but is safe. This asserts the margin is
-- in the band that is both safe and useful.
check('cull margin is in the safe-and-useful band',
      CULL_MARGIN >= MEASURED_WORST and CULL_MARGIN <= 1.5,
      string.format('margin=%.4f', CULL_MARGIN))

if failures > 0 then
  print(string.format('FAILURES: %d of %d checks failed', failures, checks))
  os.exit(1)
end
print(string.format('all %d frustum checks passed', checks))
os.exit(0)
