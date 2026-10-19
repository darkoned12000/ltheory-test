local Camera = class(function (self)
  self.x = 0
  self.y = 0
  self.sx = 1
  self.sy = 1
  self.pos = Vec3f()
  self.rot = Quat.Identity()
  self.posT = Vec3f()
  self.rotT = Quat.Identity()
  self.posOffset = Vec3f()
  self.rotOffset = Quat.Identity()
  self.zNear = 0.1
  self.zFar = 1e6
  self.mView = Matrix.Identity()
  self.mProj = Matrix.Identity()
  self.mViewInv = Matrix.Identity()
  self.mProjInv = Matrix.Identity()
  -- TAA reprojection. `mViewProjPrev` is LAST frame's view-projection, which is
  -- what the resolve projects this frame's world positions into. It is a frame
  -- behind on purpose: the history buffer holds last frame's image, so the
  -- correct matrix to reproject with is the one that produced it.
  -- `mVPThis` is the frame currently being set up, rotated into mViewProjPrev in
  -- beginDraw AFTER the push, so the push always sees the previous frame.
  self.mViewProjPrev = Matrix.Identity()
  self.mVPThis = nil
  -- TAA sub-pixel jitter, Halton(2,3) over 8 samples, in NDC. Consecutive frames
  -- rasterise geometry at different sub-pixel positions, and the resolve
  -- accumulates that into smooth edges. Owned here (not the Renderer) because it
  -- has to be published BEFORE anything is drawn, and the Renderer runs after.
  self.taaFrame = 0
  self.taaJitter = Vec2f(0, 0)
  self.taaJitterPrev = Vec2f(0, 0)
end)

local stack = {}

-- Halton(2,3), the standard low-discrepancy sequence for TAA jitter. Rotating
-- through 8 samples means every pixel lands on 8 different sub-pixel positions
-- over 8 frames, which is what the resolve accumulates. Deterministic and
-- allocation-free -- this runs once per frame on the hot path.
local kHalton23 = {
  { 0.5000, 0.3333 }, { 0.2500, 0.6667 }, { 0.7500, 0.1111 }, { 0.1250, 0.4444 },
  { 0.6250, 0.7778 }, { 0.3750, 0.2222 }, { 0.8750, 0.5556 }, { 0.0625, 0.8889 },
}
local function Halton23 (frame)
  local h = kHalton23[(frame - 1) % #kHalton23 + 1]
  return h[1], h[2]
end


function Camera:beginDraw ()
  self:push()
  self:refreshMatrices()
  ShaderVar.PushMatrix('mView', self.mView)
  ShaderVar.PushMatrix('mViewInv', self.mViewInv)
  ShaderVar.PushMatrix('mProj', self.mProj)
  ShaderVar.PushMatrix('mProjInv', self.mProjInv)
  ShaderVar.PushFloat3('eye', self.pos.x, self.pos.y, self.pos.z)
  -- TAA reprojection matrix. Pushed BEFORE the rotation below, so it is always
  -- the PREVIOUS frame's -- which is the frame the history buffer holds.
  ShaderVar.PushMatrix('mViewProjPrev', self.mViewProjPrev)
  -- Sub-pixel rasterisation jitter for this frame, plus LAST frame's, which the
  -- resolve needs in order to land on the pixel the history was actually written
  -- to. NDC units: a Halton sample in [-0.5, 0.5] pixels becomes
  -- 2 * offset / resolution.
  if Settings.get('render.taa.enable') then
    self.taaFrame = self.taaFrame + 1
    local hx, hy = Halton23(self.taaFrame)
    self.taaJitterPrev = self.taaJitter
    self.taaJitter = Vec2f(2 * (hx - 0.5) / math.max(1, self.sx),
                           2 * (hy - 0.5) / math.max(1, self.sy))
  else
    self.taaJitter = Vec2f(0, 0)
    self.taaJitterPrev = Vec2f(0, 0)
  end
  ShaderVar.PushFloat2('taaJitter',     self.taaJitter.x,     self.taaJitter.y)
  ShaderVar.PushFloat2('taaJitterPrev', self.taaJitterPrev.x, self.taaJitterPrev.y)
  -- taaValid is deliberately NOT pushed here. It is owned by the Renderer (set
  -- per-pass in Renderer:taa) because only the Renderer knows whether the history
  -- buffers exist and have been written yet -- see the note in filter/taa.glsl.
  -- Now the frame being drawn becomes next frame's history matrix.
  if self.mVPThis then
    local old = self.mViewProjPrev
    self.mViewProjPrev = self.mVPThis
    self.mVPThis = nil
    if old then old:free() end
  end
end

function Camera:endDraw ()
  ShaderVar.Pop('mView')
  ShaderVar.Pop('mViewInv')
  ShaderVar.Pop('mProj')
  ShaderVar.Pop('mProjInv')
  ShaderVar.Pop('eye')
  ShaderVar.Pop('mViewProjPrev')
  -- Must mirror the three taa* pushes in beginDraw. Each name is its own growable
  -- stack and ShaderVar_Get reads the TOP, so a missing Pop does not corrupt the
  -- value -- it just never rewinds, growing those three stacks by one entry per
  -- frame forever (~8 bytes x 3 x framerate; ~5 MB/hour). Balance them here.
  ShaderVar.Pop('taaJitter')
  ShaderVar.Pop('taaJitterPrev')
  self:pop()
end

function Camera:lerpFrom (pos, rot)
  self.posOffset = pos + self.posT:inverse()
  self.rotOffset = rot * self.rotT:inverse()
end

function Camera:cancelLerp ()
  self.posOffset = Vec3f.Identity()
  self.rotOffset =  Quat.Identity()
end

function Camera:lerp (dt)
  local f = 1.0 - exp(-10.0 * dt)
  self.posOffset:ilerp(Vec3f.Identity(), f)
  self.rotOffset:iLerp( Quat.Identity(), f)
end

-- Fundamental Transformations -------------------------------------------------
-- NOTE : These are all for *positions* not *directions*
-- NOTE : 'window' means the OpenGL window
-- NOTE : 'screen' means the camera widget, which may be offset and resized within the window

function Camera:windowToScreen (wnd)
  local ss = Vec2f()
  ss.x = wnd.x - self.x
  ss.y = wnd.y - self.y
  return ss
end

function Camera:screenToNDC (ss)
  local ndc = Vec3f()
  ndc.x =   2.0 * ss.x / self.sx - 1.0
  ndc.y = -(2.0 * ss.y / self.sy - 1.0)
  ndc.z = -1.0
  return ndc
end

-- BUG : ndc.z = 1 gives NaNs when zNear == 0.1 and zFar == 1e7. Expect 0.1
-- BUG : ndc.z = 1 gives 9,586,980 when zNear == 10 and zFar == 1e7. Expect 10,000,000
function Camera:ndcToView (ndc)
  local vs4 = self.mProjInv:mulVec(Vec4f(ndc.x, ndc.y, ndc.z, 1.0))
  local vs  = vs4:divs(vs4.w):toVec3f()
  return vs
end

function Camera:viewToWorld (vs)
  local ws = self.mViewInv:mulPoint(vs)
  return ws
end

function Camera:worldToView (ws)
  local vs = self.mView:mulPoint(ws)
  return vs
end

function Camera:viewToNDC (vs)
  local ndc4 = self.mProj:mulVec(Vec4f(vs.x, vs.y, vs.z, 1.0))
  local ndc  = ndc4:divs(ndc4.w):toVec3f()
  return ndc, Math.Sign(ndc4.w)
end

function Camera:ndcToScreen (ndc)
  local ss = Vec2f()
  ss.x = self.sx * ( ndc.x + 1.0) / 2.0
  ss.y = self.sy * (-ndc.y + 1.0) / 2.0
  return ss
end

function Camera:screenToWindow (ss)
  local wnd = Vec2f()
  wnd.x = ss.x + self.x
  wnd.y = ss.y + self.y
  return wnd
end

--------------------------------------------------------------------------------

-- Helper Transformations ------------------------------------------------------
-- NOTE : These are all for *positions* not *directions*

-- OPTIMIZE : Creating a table is maybe not so great
function Camera:entityToScreenRect (entity)
  local box = entity:getBoundingBoxLocal()
  local points = {
    Vec3f(box.lowerx, box.lowery, box.lowerz),
    Vec3f(box.upperx, box.lowery, box.lowerz),
    Vec3f(box.lowerx, box.uppery, box.lowerz),
    Vec3f(box.upperx, box.uppery, box.lowerz),
    Vec3f(box.lowerx, box.lowery, box.upperz),
    Vec3f(box.upperx, box.lowery, box.upperz),
    Vec3f(box.lowerx, box.uppery, box.upperz),
    Vec3f(box.upperx, box.uppery, box.upperz),
  }

  local xMin, yMin, xMax, yMax = math.huge, math.huge, -math.huge, -math.huge
  for i = 1, #points do
    local ws  = entity:toWorld(points[i])
    local vs  = self:worldToView(ws)
    local ndc = self:viewToNDC(vs)
    local ss  = self:ndcToScreen(ndc)

    xMin, yMin = min(xMin, ss.x), min(yMin, ss.y)
    xMax, yMax = max(xMax, ss.x), max(yMax, ss.y)
  end

  return xMin, yMin, xMax - xMin, yMax - yMin
end

function Camera:ndcToRay (ndc, length)
  ndc.z = 0.9
  local vs = self:ndcToView(ndc)
  local ws = self:viewToWorld(vs)

  -- NOTE : Calculate dir in View Space to avoid catastrophic cancellation
  ndc.z = 0.99
  local vs_p1 = self:ndcToView(ndc)
  local vs_dir = vs_p1 - vs
  local dir = self.mViewInv:mulDir(vs_dir):normalize()

  return Ray(ws.x, ws.y, ws.z, dir.x, dir.y, dir.z, 0, length)
end

function Camera:mouseToRay (length)
  local mp  = Input.GetMousePosition()
  local ss  = self:windowToScreen(mp)
  local ndc = self:screenToNDC(ss)
  local ray = self:ndcToRay(ndc, length)
  return ray
end

-- NOTE : NDC.z is +/- 1, indicating in front or behind the near plane.
function Camera:worldToNDC (ws)
  local vs  = self:worldToView(ws)
  local ndc, w = self:viewToNDC(vs)
  ndc.z = w
  return ndc
end

--------------------------------------------------------------------------------

function Camera:refreshMatrices ()
  self.mView:free()
  self.mViewInv:free()
  self.mProj:free()
  self.mProjInv:free()

  self.pos = self.posOffset + self.posT
  self.rot = self.rotOffset * self.rotT

  self.mViewInv = Matrix.FromPosRot(self.pos, self.rot)
  self.mView = self.mViewInv:inverse()

  self.mProj = Matrix.Perspective(
    Settings.get('render.fovY'),
    self.sx / self.sy,
    self.zNear,
    self.zFar)
  self.mProjInv = self.mProj:inverse()

  -- TAA: this frame's view-projection, stashed for beginDraw to rotate into
  -- mViewProjPrev. Column-vector convention, so view is applied before proj.
  self.mVPThis = self.mProj:product(self.mView)
end

function Camera:setViewport (x, y, sx, sy)
  self.x = x
  self.y = y
  self.sx = sx
  self.sy = sy
end

function Camera.get ()
  return stack[#stack]
end

function Camera:pop ()
  stack[#stack] = nil
end

function Camera:push ()
  stack[#stack + 1] = self
end

function Camera:warp () end

return Camera
