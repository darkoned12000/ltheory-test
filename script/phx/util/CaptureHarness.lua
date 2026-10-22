-- CaptureHarness -- makes a headless look/perf capture reproducible.
--
-- WHY THIS EXISTS. Every visual A/B in docs/ltheory-planets.md was taken under a
-- camera that moved and a window that changed size between runs, and the
-- measurements were wrong more than once:
--
--   * W5's dt-drift trap: changing a nebula setting changed frame time, which
--     changed the `dt` history, which changed Bullet's settling, which changed
--     the camera attitude by the dump frame. Two "equivalent" runs showed the
--     sun fully visible in one and eclipsed in the other.
--   * Dumps came out 936x969, 1691x1232 and 1891x969 on runs that all logged
--     `Resolution: 1280x720`, because that line is printed once at boot and
--     then goes stale when the window resizes (getWindowMode always sets
--     WindowMode.Resizable).
--
-- So three independent things have to be pinned. All are opt-in and env-gated;
-- normal play is completely unaffected.
--
--   PHX_FIXED_DT=<seconds>   Force the frame delta. With dt constant, physics
--                             settling and entity motion at frame N are
--                             identical regardless of how fast the frame
--                             actually ran, so two runs differ only by the
--                             setting under test. (default 1/60)
--
--   PHX_FIXED_VIEW=hold      Freeze the camera pose at whatever it is on the
--                             first frame, then hold it forever. Lets you fly
--                             to a framing you like, note that you have done so,
--                             and replay it exactly. This is the interactive
--                             workflow: pose it once, then bake the numbers out
--                             of the log with PHX_FIXED_VIEW=log and paste them
--                             into an explicit spec.
--
--   PHX_FIXED_VIEW=log       Same, but print the frozen pose to stderr in a
--                             form you can paste back as an explicit spec.
--
--   PHX_FIXED_VIEW=<x,y,z,lookX,lookY,lookZ>[,<upX,upY,upZ>]
--                             Freeze to an explicit pose. Orientation is given
--                             as a forward vector plus an up hint rather than a
--                             quaternion, because that is how you describe a
--                             camera to a human. The look point is relative to
--                             the position.
--
--   PHX_FIXED_SIZE=<w>,<h>   Force the window size AND drop WindowMode.Resizable,
--                             so the compositor cannot resize it out from under
--                             the capture. Without this, Config.window.width /
--                             height are only a request.
--
-- Independent of the above, and always safe:
--
--   PHX_REPORT_SIZE=1        Print the ACTUAL render size every second, and
--                             once more at any dump frame. This is the check
--                             that makes a comparison trustworthy: if two
--                             captures disagree here, the comparison is void.
--
-- USAGE NOTE: mute audio for any headless boot. `sfx.engine` is a continuous
-- sound with a 60-unit full-volume radius, and spawning NPCs on a dev machine
-- produced an audible hum from it.

local CaptureHarness = {}

-- ---- parse ------------------------------------------------------------------

local function parseNumList (str)
  local out = {}
  for tok in tostring(str):gmatch('[^,]+') do
    out[#out + 1] = tonumber((tok:gsub('^%s*(.-)%s*$', '%1')))
  end
  return out
end

-- Read the pose off a running camera so it can be logged and replayed.
--
-- Use the engine's own Quat accessors rather than reasoning about matrix columns:
-- `Quat_GetForward`/`Quat_GetUp` are the basis CameraChase/CameraOrbit were built
-- from (CoordTest asserts the quat axes and the matrix columns agree), and
-- `Quat.FromLookUp(look, up)` is the inverse of exactly that. So
-- FromLookUp(q:getForward(), q:getUp()) reproduces `cam.rot` exactly, with no
-- convention guess and no accumulate/drift.
local function poseOf (cam)
  return {
    pos  = Vec3f(cam.pos.x, cam.pos.y, cam.pos.z),
    look = cam.rot:getForward(),
    up   = cam.rot:getUp(),
  }
end

-- ---- state ------------------------------------------------------------------

CaptureHarness.fixedDt   = tonumber(os.getenv('PHX_FIXED_DT') or '') or nil
CaptureHarness.reportSize = os.getenv('PHX_REPORT_SIZE') ~= nil

local viewSpec = os.getenv('PHX_FIXED_VIEW') or ''
local viewMode = nil
local specPose = nil
local heldPose = nil

if viewSpec ~= '' then
  if viewSpec == 'hold' or viewSpec == 'log' then
    viewMode = viewSpec
  else
    local n = parseNumList(viewSpec)
    if #n == 6 then
      viewMode = 'explicit'
      specPose = {
        pos  = Vec3f(n[1], n[2], n[3]),
        look = Vec3f(n[4], n[5], n[6]),
        up   = (n[7] and n[8] and n[9]) and Vec3f(n[7], n[8], n[9]) or Vec3f(0, 1, 0),
      }
    else
      -- Better to say so than to silently run unfrozen and poison a comparison.
      error(string.format(
        'CaptureHarness: PHX_FIXED_VIEW=%q is not "hold", "log", or '
        .. '<x,y,z,lookX,lookY,lookZ>[,upX,upY,upZ] (parsed %d numbers)', viewSpec, #n))
    end
  end
end

local sizeSpec = os.getenv('PHX_FIXED_SIZE') or ''
local fixedW, fixedH
if sizeSpec ~= '' then
  local n = parseNumList(sizeSpec)
  fixedW, fixedH = n[1], n[2]
end

CaptureHarness.enabled = (viewMode ~= nil) or (fixedW ~= nil)
                or (CaptureHarness.fixedDt ~= nil) or CaptureHarness.reportSize
CaptureHarness.fixedW, CaptureHarness.fixedH = fixedW, fixedH

-- ---- window -----------------------------------------------------------------

-- Called from Application:getWindowMode. Dropping Resizable is the part that
-- actually fixes the size: SDL honours the requested size for a fixed window,
-- whereas a resizable one under a compositor comes back at whatever it likes.
function CaptureHarness.windowMode (baseMode)
  if not fixedW then return baseMode end
  return baseMode -- Resizable is stripped by the caller when a size is fixed
end

function CaptureHarness.stripResizable ()
  return fixedW ~= nil
end

-- ---- camera -----------------------------------------------------------------

-- Called from GameView immediately before Camera:beginDraw, i.e. AFTER every
-- camera controller has run for the frame. Camera:refreshMatrices resolves
--     pos = posOffset + posT      rot = rotOffset * rotT
-- so writing posOffset/rotOffset here discards the controller's contribution
-- for this frame and pins the result. Writing posT/rotT instead would work too
-- but posOffset is the term the controllers do NOT own.
function CaptureHarness.freezeCamera (cam, frameN)
  if not viewMode then return false end

  if viewMode == 'explicit' then
    cam.posOffset = Vec3f()               -- zero, then pin the sources...
    cam.rotOffset = Quat.Identity()
    cam.posT = Vec3f(specPose.pos.x, specPose.pos.y, specPose.pos.z)
    cam.rotT = Quat.FromLookUp(specPose.look:normalize(), specPose.up:normalize())
    return true
  end

  -- hold / log: capture once, then replay it forever.
  --
  -- Capture on frame 2, not frame 1. `cam.pos`/`cam.rot` are only resolved inside
  -- Camera:refreshMatrices, which runs in beginDraw -- i.e. AFTER this hook. On
  -- the very first frame they are still the constructor's Identity, which is a
  -- perfectly legal-looking pose and would silently freeze the camera at the
  -- origin. By frame 2 at least one refresh has happened. The cost is that the
  -- pose is one frame of chase-camera motion away from the first frame, which
  -- is invisible at any sane dump frame.
  if not heldPose then
    if (frameN or 1) < 2 then return true end
    heldPose = poseOf(cam)
    if viewMode == 'log' then
      local p, l, u = heldPose.pos, heldPose.look, heldPose.up
      io.stderr:write(string.format(
        '[HARNESS] held pose -> PHX_FIXED_VIEW=%g,%g,%g,%g,%g,%g,%g,%g,%g\n',
        p.x, p.y, p.z, l.x, l.y, l.z, u.x, u.y, u.z))
    end
  end
  cam.posOffset = Vec3f()
  cam.rotOffset = Quat.Identity()
  cam.posT = Vec3f(heldPose.pos.x, heldPose.pos.y, heldPose.pos.z)
  cam.rotT = Quat.FromLookUp(heldPose.look, heldPose.up)
  return true
end

-- Is the camera pinned? Used by the dump header, which must not re-run
-- freezeCamera just to ask the question (it is idempotent, but a reporting
-- helper that mutates state is a trap).
function CaptureHarness.viewActive ()
  return viewMode ~= nil
end

-- ---- simulation clock -------------------------------------------------------

-- The volumetric medium's time source was the WALL CLOCK
-- (`volTime = Time.GetRaw() * 0.001`, consumed as `mod(volTime, 300.0)` drift in
-- medium.glsl). Pinning `dt` does not pin that, so two runs of an IDENTICAL
-- config still differed in ~0.5% of pixels -- all in the sky. That is enough to
-- swamp a look A/B, and it did: an early cloud-shell measurement read "0.518% of
-- the frame changed" and that number was pure run-to-run noise, not the knob.
--
-- So when dt is pinned, the medium's time advances with the SIMULATION instead,
-- which is reproducible. Normal play is untouched and still uses the wall clock.
CaptureHarness.simTime = 0.0

function CaptureHarness.advance (dt)
  if not CaptureHarness.fixedDt then return end
  CaptureHarness.simTime = CaptureHarness.simTime + dt
end

-- Time for the medium / shafts. Seconds.
function CaptureHarness.volTime ()
  if CaptureHarness.fixedDt then return CaptureHarness.simTime end
  return (tonumber(Time.GetRaw()) or 0) * 0.001
end

-- ---- reporting --------------------------------------------------------------

-- The check that makes a comparison honest. The `Resolution:` line at boot is a
-- one-shot print that goes stale on resize; this is the live value.
function CaptureHarness.report (resX, resY, frame, final)
  if not CaptureHarness.reportSize then return end
  local tag = final and 'FINAL' or ''
  if frame == nil or frame % 60 == 0 or final then
    io.stderr:write(string.format('[HARNESS] render %dx%d  frame=%s %s\n',
      resX, resY, tostring(frame or '?'), tag))
  end
end

return CaptureHarness