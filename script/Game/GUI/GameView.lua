local GameView = {}
GameView.__index = GameView
setmetatable(GameView, UI.Container)

GameView.name = 'Game View'
local ssTable = { 1, 2 }
local rsTable = { 1.0, 0.85, 0.75, 0.67, 0.50 }
local Batcher = require('Game.Batcher')
local NebulaVolumes = require('Game.NebulaVolumes')
local LightningStorm = require('Game.LightningStorm')
local CaptureHarness = require('phx.util.CaptureHarness')
local Frustum = require('Game.Frustum')

-- PHX_DEBUG_DUMP=<frame> : save pipeline checkpoints to PNGs once, at that frame.
-- Set PHX_DEBUG_DUMP=120 to snapshot ~2s after boot.
local dumpTargetFrame = tonumber(os.getenv('PHX_DEBUG_DUMP') or '')

-- AO render targets: color-only buffers (no depth attachment), clamped + linear,
-- cleared once so the FBO is complete. Half-res R8/16F for passes 1-2, full-res
-- R8 for the final depth-aware upsample.
local function aoTarget (w, h, format)
  local t = Tex2D.Create(w, h, format)
  t:setMagFilter(TexFilter.Linear)
  t:setMinFilter(TexFilter.Linear)
  t:setWrapMode(TexWrapMode.Clamp)
  t:push()
  Draw.Clear(0, 0, 0, 0)
  t:pop()
  return t
end

-- Blue-noise 64x64 slice-rotation LUT (Phase B). Frequency-domain-ranked blue
-- noise: forward-FFT a deterministic white field, high-pass the low-frequency
-- band, inverse-FFT, then assign ranks so the marginal distribution stays
-- uniform on [0,1). Determinism comes from a Park-Miller LCG (exact in double).
-- Low-frequency suppression is what keeps the half-res AO stable under the 3x3
-- denoise + 2x SS; a white-noise rotation would crawl. Build once (~2ms) at
-- first use, cache on self.aoNoise (R8, point, repeat).
local function fft1D (re, im, base, stride, n, inverse)
  local j = 0
  for i = 0, n - 1 do
    if i < j then
      local ri, gi = re[base+i*stride], im[base+i*stride]
      re[base+i*stride], im[base+i*stride] = re[base+j*stride], im[base+j*stride]
      re[base+j*stride], im[base+j*stride] = ri, gi
    end
    local m = n >> 1
    while m >= 1 and j >= m do j = j - m; m = m >> 1 end
    j = j + m
  end
  local len = 2
  while len <= n do
    local ang = (inverse and 1 or -1) * (2 * math.pi) / len
    local wdRe, wdIm = math.cos(ang), math.sin(ang)
    local half = len >> 1
    for k = 0, n - 1, len do
      local wRe, wIm = 1.0, 0.0
      for x = 0, half - 1 do
        local i0, i1 = base + (k+x)*stride, base + (k+x+half)*stride
        local vRe = re[i1]*wRe - im[i1]*wIm
        local vIm = re[i1]*wIm + im[i1]*wRe
        local uRe, uIm = re[i0], im[i0]
        re[i0], im[i0] = uRe + vRe, uIm + vIm
        re[i1], im[i1] = uRe - vRe, uIm - vIm
        wRe, wIm = wRe*wdRe - wIm*wdIm, wRe*wdIm + wIm*wdRe
      end
    end
    len = len * 2
  end
  if inverse then
    for i = 0, n - 1 do
      re[base+i*stride] = re[base+i*stride] / n
      im[base+i*stride] = im[base+i*stride] / n
    end
  end
end

local function smoothstep (a, b, x)
  x = math.min(1, math.max(0, (x - a) / (b - a)))
  return x * x * (3 - 2 * x)
end

local function buildBlueNoise (n)
  local total = n * n
  local re, im = {}, {}
  local x = 123457 -- Park-Miller seed; values in [0,1)
  local function rng ()
    x = (x * 16807) % 2147483647
    return (x - 1) / 2147483646
  end
  for i = 0, total - 1 do re[i] = rng(); im[i] = 0.0 end
  for r = 0, n - 1 do fft1D(re, im, r*n, 1, n, false) end
  for c = 0, n - 1 do fft1D(re, im, c, n, n, false) end
  local half = n / 2
  for v = 0, n - 1 do
    local dv = v
    if dv > half then dv = dv - n end
    for u = 0, n - 1 do
      local du = u
      if du > half then du = du - n end
      local rho = math.sqrt(du*du + dv*dv) / half
      local w = (du == 0 and dv == 0) and 0.0 or smoothstep(0.10, 0.90, rho)
      local i = v*n + u
      re[i] = re[i] * w
      im[i] = im[i] * w
    end
  end
  for r = 0, n - 1 do fft1D(re, im, r*n, 1, n, true) end
  for c = 0, n - 1 do fft1D(re, im, c, n, n, true) end
  local ord = {}
  for i = 0, total - 1 do ord[i+1] = { re[i], i } end
  table.sort(ord, function (a, b) return a[1] < b[1] end)
  local out = {}
  for k, e in ipairs(ord) do out[e[2]] = (k - 0.5) / total end
  return out
end

local function buildBlueNoiseTex (n)
  local vals = buildBlueNoise(n)
  local total = n * n
  local bytes = Bytes.Create(total)
  local p = ffi.cast('uint8_t*', bytes:getData())
  for i = 0, total - 1 do p[i] = math.floor(vals[i] * 256 + 0.5) % 256 end
  local tex = Tex2D.Create(n, n, TexFormat.R8)
  tex:setDataBytes(bytes, PixelFormat.Red, DataFormat.U8)
  tex:setMagFilter(TexFilter.Point)
  tex:setMinFilter(TexFilter.Point)
  tex:setWrapMode(TexWrapMode.Repeat)
  return tex
end

function GameView:getAoNoise()
  if not self.aoNoise then
    self.aoNoise = buildBlueNoiseTex(64)
  end
  return self.aoNoise
end

-- Point-light shadow maps (item #3). For each light we render the opaque world
-- into a Depth32F texture using an ortho frustum centered on the light and
-- aligned with the light->camera direction, then sample it in point.glsl with a
-- PCF test. Cached per entity so the texture is built once per frame.
local function shadowSize (sx, sy)
  local scale = math.min(1024 / sx, 1024 / sy)
  return math.max(256, math.floor(sx * scale)), math.max(256, math.floor(sy * scale))
end

function GameView:buildShadowFrustum (lightPos, eye, halfSize)
  -- Camera at lightPos looking toward eye; +Z is its back axis. The old code
  -- accidentally used a constant +Y axis for every shadow map.
  local z = (lightPos - eye):normalize()
  if z:length() < 1e-4 then z = Vec3f(0, 0, 1) end
  local ref = (math.abs(z.y) < 0.999) and Vec3f(0, 1, 0) or Vec3f(1, 0, 0)
  local x = (ref:cross(z)):normalize()
  local y = (z:cross(x)):normalize()
  local basis = Matrix.FromBasis(x, y, z)
  local inverseBasis = basis:inverse()
  local translation = Matrix.Translation(-lightPos.x, -lightPos.y, -lightPos.z)
  local view = inverseBasis:product(translation)
  local proj = Matrix.Ortho(-halfSize, halfSize, -halfSize, halfSize, 0.1, 2 * halfSize)
  local viewProj = proj:product(view)
  basis:free()
  inverseBasis:free()
  translation:free()
  view:free()
  proj:free()
  return viewProj
end

-- Render per-light shadow maps into Depth32F textures (called before the light passes).
function GameView:renderShadows (world, lights)
  Profiler.Begin('Render.PointShadows')
  local eye = self.camera.pos
  self.shadowTexts = self.shadowTexts or {}
  self.shadowProjs = self.shadowProjs or {}

  -- Each shadow-casting point light costs a full scene render, so cap the set to
  -- the N nearest the camera (render.shadow.maxLights). The rest still light the
  -- scene, just without a shadow map. `light.shadow` marks which lights have a
  -- valid map (maps persist across amortized updates; see render.shadow.period).
  local maxLights = math.max(0, math.floor(Settings.get('render.shadow.maxLights') or 2))
  for i = 1, #lights do lights[i].shadow = nil end
  local casters = lights
  if maxLights < #lights then
    local scored = {}
    for i = 1, #lights do
      local p = lights[i].lp
      local dx, dy, dz = eye.x - p.x, eye.y - p.y, eye.z - p.z
      scored[i] = { light = lights[i], dist = dx * dx + dy * dy + dz * dz }
    end
    table.sort(scored, function (a, b) return a.dist < b.dist end)
    casters = {}
    for i = 1, maxLights do casters[i] = scored[i].light end
  end

  for i, light in ipairs(casters) do
    light.shadow = true
    local tex = self.shadowTexts[light.entity]

    if not tex then
      local sw, sh = shadowSize(self.sx, self.sy)
      tex = Tex2D.Create(sw, sh, TexFormat.Depth32F)
      tex:setMinFilter(TexFilter.Linear)
      tex:setMagFilter(TexFilter.Linear)
      self.shadowTexts[light.entity] = tex
    end

    local halfSize = math.max((eye - light.lp):length() * 0.5, 100000)
    local proj = self:buildShadowFrustum(light.lp, eye, halfSize)
    if self.shadowProjs[light.entity] then self.shadowProjs[light.entity]:free() end
    self.shadowProjs[light.entity] = proj

    -- The viewport must match the shadow map's own resolution -- see the note
    -- in renderSunShadow. Pushing the full window size here rasterized the
    -- 1024x1024 map through a 4K viewport.
    local shadowSize = tex:getSize()
    RenderTarget.Push(shadowSize.x, shadowSize.y)
    RenderTarget.BindTex2D(tex)

    ShaderVar.PushMatrix('mView', proj)
    local identity = Matrix.Identity()
    ShaderVar.PushMatrix('mProj', identity)
    identity:free()
    ShaderVar.PushFloat3('eye', light.lp.x, light.lp.y, light.lp.z)
    BlendMode.PushDisabled()
    CullFace.Push(CullFace.Back)
    RenderState.PushDepthTest(true)
    RenderState.PushDepthWritable(true)

    Draw.ClearDepth(1)

    world:render(Event.Render(BlendMode.Disabled, eye, 'pointshadow',
                              light.lp, 2.5 * halfSize))

    RenderState.PopDepthWritable()
    RenderState.PopDepthTest()
    CullFace.Pop()
    BlendMode.Pop()
    ShaderVar.Pop('mView')
    ShaderVar.Pop('mProj')
    ShaderVar.Pop('eye')
    RenderTarget.Pop()
  end
  Profiler.End()
end

-- Whole-scene sun shadow map, sampled in light/dir.glsl.
local function sunShadowSize (sx, sy, target)
  local scale = math.min(target / sx, target / sy)
  return math.max(256, math.floor(sx * scale)), math.max(256, math.floor(sy * scale))
end

function GameView:renderSunShadow (world)
  local sizes = { '256', '512', '1024', '2048' }
  local target = tonumber(sizes[Settings.get('render.sun.shadowSize') or 4]) or 2048
  local key = target .. 'x' .. self.sx .. 'x' .. self.sy
  if key ~= self.sunShadowSizeKey then
    if self.sunShadowTex then self.sunShadowTex:free() end
    local sw, sh = sunShadowSize(self.sx, self.sy, target)
    self.sunShadowTex = Tex2D.Create(sw, sh, TexFormat.Depth32F)
    self.sunShadowTex:setMinFilter(TexFilter.Linear)
    self.sunShadowTex:setMagFilter(TexFilter.Linear)
    self.sunShadowSizeKey = key
  end

  local range = Settings.get('render.sun.shadowRange') or 8000
  local sd = Vec3f(world.starDir.x, world.starDir.y, world.starDir.z):normalize()
  self.sunShadowCenter = self.camera.pos
  -- Put the orthographic camera one range UPSTREAM, on the sun side, and look
  -- through the camera centre along the incoming-light direction. A camera at
  -- the receiver centre clips all potential occluders on the sunward half-space,
  -- which made the map look unresponsive as range/resolution were adjusted.
  local shadowEye = self.sunShadowCenter + sd:muls(range)
  local proj = self:buildShadowFrustum(shadowEye, self.sunShadowCenter, range)
  if self.sunShadowProj then self.sunShadowProj:free() end
  self.sunShadowProj = proj

  -- The viewport MUST match the shadow map's own resolution. It used to be pushed
  -- at the full window size (self.sx x self.sy), so a 512x512 map was being
  -- rasterized through a 3840x2160 viewport: every shadow fragment was shaded
  -- 8.3 MILLION pixels wide and then thrown away by the 512x512 attachment.
  -- That is the entire cost of the sun-shadow pass (measured 1.74 ms/frame, the
  -- second-largest item in the frame) and it is pure waste.
  local shadowSize = self.sunShadowTex:getSize()
  RenderTarget.Push(shadowSize.x, shadowSize.y)
  RenderTarget.BindTex2D(self.sunShadowTex)

  ShaderVar.PushMatrix('mView', proj)
  local identity = Matrix.Identity()
  ShaderVar.PushMatrix('mProj', identity)
  identity:free()
  ShaderVar.PushFloat3('eye', self.sunShadowCenter.x, self.sunShadowCenter.y, self.sunShadowCenter.z)
  BlendMode.PushDisabled()
  CullFace.Push(CullFace.Back)
  RenderState.PushDepthTest(true)
  RenderState.PushDepthWritable(true)

  Draw.ClearDepth(1)

  world:render(Event.Render(BlendMode.Disabled, self.sunShadowCenter, 'sunshadow',
                            self.sunShadowCenter, math.sqrt(3) * range))

  RenderState.PopDepthWritable()
  RenderState.PopDepthTest()
  CullFace.Pop()
  BlendMode.Pop()
  ShaderVar.Pop('mView')
  ShaderVar.Pop('mProj')
  ShaderVar.Pop('eye')
  RenderTarget.Pop()
end

-- GTAO chain: aoview -> ao -> aoblur
function GameView:renderAO ()
  local r = self.renderer
  local sx, sy = r.sx, r.sy

  local q = Settings.get('ssao.quality') or 2
  local k = (q <= 1) and 1 or ((q == 2) and 2 or 4)
  local aoW = math.max(1, math.floor(sx / k))
  local aoH = math.max(1, math.floor(sy / k))
  local aoMip = math.log(math.max(1, sx / aoW)) / math.log(2)

  if not self.aoView or self.aoView:getSize().x ~= aoW then
    if self.aoView then
      self.aoView:free()
      self.aoRaw:free()
    end
    self.aoView = aoTarget(aoW, aoH, TexFormat.RGBA16F)
    self.aoRaw  = aoTarget(aoW, aoH, TexFormat.R8)
  end

  if not self.aoFull or self.aoFull:getSize().x ~= sx then
    if self.aoFull then self.aoFull:free() end
    self.aoFull = aoTarget(sx, sy, TexFormat.R8)
  end

  if not self.aoWhite then
    self.aoWhite = aoTarget(1, 1, TexFormat.R8)
    self.aoWhite:push()
    Draw.Color(1, 1, 1, 1)
    Draw.Rect(0, 0, 1, 1)
    self.aoWhite:pop()
  end

  local noiseTex = self:getAoNoise()

  Profiler.Begin('Render.AO')

  do -- Pass 1: per-pixel view ray + NdotV (half-res)
    local shader = Cache.Shader('worldray', 'filter/aoview')
    if shader then
      RenderTarget.Push(aoW, aoH)
      RenderTarget.BindTex2D(self.aoView)
      shader:start()
      Shader.SetTex2D('texDepth', r.zBufferL)
      Shader.SetTex2D('texNormalMat', r.buffer1)
      Shader.SetFloat('aoMip', aoMip)
      Draw.Rect(-1, -1, 2, 2)
      shader:stop()
      RenderTarget.Pop()
    end
  end

  do -- Pass 2: horizon integral -> aoRaw (half-res)
    local shader = Cache.Shader('ui', 'filter/ao')
    if shader then
      local dirs  = { 2, 4, 6, 8 }
      local steps = { 2, 3, 4, 6 }
      RenderTarget.Push(aoW, aoH)
      RenderTarget.BindTex2D(self.aoRaw)
      shader:start()
      Shader.SetTex2D('texView', self.aoView)
      Shader.SetTex2D('texNormalMat', r.buffer1)
      Shader.SetTex2D('texDepth', r.zBufferL)
      Shader.SetTex2D('texNoise', noiseTex)
      Shader.SetFloat('aoRadius',    Settings.get('ssao.radius') or 500)
      Shader.SetFloat('aoIntensity', Settings.get('ssao.intensity') or 1)
      Shader.SetFloat('aoMip',       aoMip)
      Shader.SetFloat('aoSpacing',   1.0 / 3.0)
      Shader.SetFloat('aoNoiseSize', 64.0)
      Shader.SetFloat('thickness',   Settings.get('ssao.thickness') or 0.25)
      Shader.SetInt  ('dirCount',    dirs[Settings.get('ssao.directions')] or 4)
      Shader.SetInt  ('stepCount',   steps[Settings.get('ssao.steps')] or 3)
      Draw.Rect(0, 0, aoW, aoH)
      shader:stop()
      RenderTarget.Pop()
    end
  end

  do -- Pass 3: full-res depth-aware upsample + denoise -> aoFull
    -- `ssao.blur` was declared as a 0/1/2 enum and mapped to Config.gpu.aoBlur,
    -- but NOTHING ever read it and this pass ran unconditionally, so 'Denoise: 0'
    -- silently gave you denoised AO. Now it is honoured: 0 skips the pass and the
    -- half-res aoRaw is consumed directly (upscaled by the sampler), which is the
    -- raw AO the knob was meant to select. 1 and 2 both run the single existing
    -- denoise pass -- there is only one implementation of it, so the two steps
    -- were never distinguishable and 2 is kept as the signed-off default.
    local blurMode = tonumber(Settings.get('ssao.blur')) or 1
    self.aoDenoised = blurMode > 0
    local shader = self.aoDenoised and Cache.Shader('ui', 'filter/aoblur') or nil
    if shader then
      local rad = Settings.get('ssao.radius') or 500
      RenderTarget.Push(sx, sy)
      RenderTarget.BindTex2D(self.aoFull)
      shader:start()
      Shader.SetTex2D('texAO', self.aoRaw)
      Shader.SetTex2D('texDepth', r.zBufferL)
      Shader.SetFloat('aoMip', aoMip)
      Shader.SetFloat('aoBlurScale', 8.0 / math.max(1e-3, rad * rad))
      Draw.Rect(0, 0, sx, sy)
      shader:stop()
      RenderTarget.Pop()
    end
  end

  Profiler.End()
end

function GameView:draw (focus, active)
  if dumpTargetFrame then
    GameView.__dumpFrame = (GameView.__dumpFrame or 0) + 1
    if GameView.__dumpFrame == dumpTargetFrame then
      local function mkDump (name)
        return function (tex)
          Tex2D.Save(tex, 'dump_' .. name .. '.png')
          print('[DUMP] saved dump_' .. name .. '.png')
        end
      end
      GameView.__dumpGBuffer = function ()
        mkDump('1_gbuffer_albedo')(self.renderer.buffer0)
        mkDump('1b_gbuffer_normalmat')(self.renderer.buffer1)
        mkDump('1c_zbufferL')(self.renderer.zBufferL)
        GameView.__dumpGBuffer = nil
      end
      GameView.__dumpLit = function ()
        mkDump('2_lit')(self.renderer.buffer1)
        GameView.__dumpLit = nil
      end
      GameView.__dump = function ()
        -- Self-describing capture: the PNG's own dimensions, the live camera
        -- pose and the frozen-vs-live state. A pixel comparison between two
        -- dumps is only valid if these agree, and this is what makes checking
        -- them mechanical instead of a thing you have to remember.
        local t = self.renderer.buffer0:getSize()
        io.stderr:write(string.format(
          '[DUMP] frame=%d render=%dx%d camera=%s harness=%s dt=%s\n',
          GameView.__dumpFrame, t.x, t.y,
          string.format('(%.1f,%.1f,%.1f)', self.camera.pos.x, self.camera.pos.y, self.camera.pos.z),
          CaptureHarness.viewActive() and 'fixed' or 'live',
          tostring(CaptureHarness.fixedDt or 'unpinned')))
        mkDump('3_final')(self.renderer.buffer0)
        -- The UI LAYER. The HUD, the sector panel and the node-graph map are
        -- widgets, and widgets are composited into `uiBuffer` AFTER the scene
        -- has been rendered -- so `3_final` (which is the scene) has never
        -- contained any of them. Every "the panel is not rendering" hunt
        -- went looking for UI in a dump that could not hold it. This one
        -- can.
        if self.renderer.uiBuffer then mkDump('4_ui')(self.renderer.uiBuffer) end
        GameView.__dump = nil
      end
    end
  end
  self.camera:push()

  local ss = ssTable[Settings.get('render.superSample')] or 1
  local rs = rsTable[Settings.get('render.resolutionScale') or 1] or 1.0
  local x, y, sx, sy = self:getRectGlobal()
  ClipRect.PushDisabled()
  RenderState.PushAllDefaults()
  self.camera:setViewport(x, y, sx, sy)
  -- PHX_FIXED_VIEW: freeze the camera here, i.e. AFTER every camera controller
  -- has run for the frame and immediately BEFORE beginDraw resolves the pose.
  -- Camera:refreshMatrices does `pos = posOffset + posT` / `rot = rotOffset *
  -- rotT`, so writing posOffset/rotOffset discards the chase camera's
  -- contribution and pins the result. Without this the chase camera keeps
  -- drifting between runs and pixel comparisons are meaningless (see
  -- docs/ltheory-planets.md 11.3's dt-drift trap and 11.8).
  CaptureHarness.freezeCamera(self.camera, self.__harnessFrame)
  self.__harnessFrame = (self.__harnessFrame or 0) + 1
  self.camera:beginDraw()

  -- Build this frame's view frustum for CPU-side culling. Without it the
  -- engine submitted every visible mesh every frame, including the thousands of
  -- asteroid-field rocks that are behind the camera -- the single largest cost
  -- in the frame. See Game/Frustum.lua.
  Frustum.setCurrent(Frustum.build(self.camera, Settings.get('render.fovY')))

  -- A destroyed controlling ship detaches from the tree, so player:getRoot()
  -- returns the detached ship (or nil). Fall back to the sector so a death
  -- renders the scene instead of a black frame (Player:getRoot / GameView:render).
  local world = self.player and self.player:getRoot()
  if world == self.player or not (world and world.beginRender) then
    world = self.ltheory and self.ltheory.system
  end
  if not (world and world.beginRender) then
    ClipRect.Pop()
    RenderState.PopAll()
    self.camera:endDraw()
    self.camera:pop()
    return
  end
  local eye = self.camera.pos
  world:beginRender()

  -- The asteroid curtain samples the same 64x64 blue-noise tile used by GTAO
  -- and volumetrics. Lazily built and cached by getAoNoise(); bind it on the
  -- shader-var stack because asteroid material autovars are uploaded at
  -- Shader_Start, not at the point of each draw.
  ShaderVar.PushTex2D('rockFadeNoise', self:getAoNoise())

  local sUn = Settings.get('render.sun.enable')
  local sunCol, sunFill
  if sUn then
    local si = Settings.get('render.sun.intensity') or 1
    local sw = Settings.get('render.sun.warmth') or 1
    local mx = 1 * (1 - sw) + 1.0 * sw
    local my = 1 * (1 - sw) + 0.6 * sw
    local mz = 1 * (1 - sw) + 0.2 * sw
    sunCol = Vec3f(mx * si, my * si, mz * si)
    sunFill = Settings.get('render.sun.fill') or 0.12
  else
    sunCol, sunFill = Vec3f(0, 0, 0), 0
  end
  ShaderVar.PushFloat3('sunColor', sunCol.x, sunCol.y, sunCol.z)
  ShaderVar.PushFloat ('sunFill',  sunFill)

  -- Shadow cadence: every shadow map is a full scene render, so update them only
  -- every Nth frame (render.shadow.period). Maps + projs persist between updates
  -- and the passes reuse them.
  --
  -- ROUND, not floor. The period is a float slider, and floor() silently
  -- mapped every value in [1, 2) to 1 -- so a slider reading 1.953 (or 1.2, or
  -- 1.5) re-rendered the shadow maps EVERY frame, exactly as if the slider were
  -- still at its minimum. That is the difference between amortizing the sun
  -- shadow over 2 frames and paying for it twice as often as the displayed value
  -- implies -- and it is why the shadow sliders looked like they did nothing.
  do
    -- NOTE the parentheses around the default: `or` binds looser than `+`, so
    -- `x or 1 + 0.5` parses as `x or (1 + 0.5)` and the rounding never
    -- happens when the setting exists.
    local period = math.max(1, math.floor((Settings.get('render.shadow.period') or 1) + 0.5))
    if (self.shadowTick or 0) <= 0 then
      self.updateShadows = true
      self.shadowTick = period - 1
    else
      self.updateShadows = false
      self.shadowTick = self.shadowTick - 1
    end
  end

  do -- Texture-filter quality
    local tf = Settings.get('render.textureFilter')
    if tf ~= self.appliedTextureFilter then
      self.appliedTextureFilter = tf
      self.renderer:setTextureFilter(tf)
    end
  end

  local rtl = self.renderTimes
  rtl.t0 = TimeStamp.Get()

  Profiler.Begin('Render.Submit')
  do -- Opaque Pass
    Profiler.Begin('Render.Opaque')
    self.renderer:start(math.max(1, math.floor(self.sx * rs)), math.max(1, math.floor(self.sy * rs)), ss)
    Batcher.begin()
    RenderState.PushWireframe(Settings.get('render.wireframe'))
    world:render(Event.Render(BlendMode.Disabled, eye, 'gbuffer'))
    Batcher.replay()
    RenderState.PopWireframe()
    self.renderer:stop()
    Profiler.End()
  end
  if GameView.__dumpGBuffer then GameView.__dumpGBuffer() end

  do -- Lighting
    local lights = self.lights
    if not lights then
      lights = {}
      self.lights = lights
    end
    local lightEntities = world.lightEntities
    if not lightEntities then
      -- Compatibility for non-System roots used by small test apps.
      lightEntities = {}
      for _, entity in world:iterChildren() do
        if entity.hasLight and entity:hasLight() then
          lightEntities[#lightEntities + 1] = entity
        end
      end
    end
    local n = #lightEntities
    for i = 1, n do
      local v = lightEntities[i]
      local e = lights[i]
      if not e then
        e = { entity = nil, pos = nil, lp = Vec3f(0, 0, 0), color = nil }
        lights[i] = e
      end
      local p = v:getPos()
      e.entity = v
      e.pos = p
      e.lp.x = p.x
      e.lp.y = p.y + 5
      e.lp.z = p.z
      e.color = v:getLight()
    end
    for j = n + 1, #lights do lights[j] = nil end

    do -- GTAO
      if Settings.get('ssao.enable') then
        self:renderAO(world)
      end
    end

    do -- Global lighting (environment)
      local shader = Cache.Shader('worldray', 'light/global')
      if shader then
        self.renderer.buffer2:push()
        Draw.Clear(0, 0, 0, 0)
        shader:start()
        Shader.SetTex2D('texDepth', self.renderer.zBufferL)
        Shader.SetTex2D('texNormalMat', self.renderer.buffer1)
        Shader.SetFloat('envScale', Settings.get('lighting.ambientEnv') or 1)
        if self.aoFull then
          -- Denoise off => consume the raw half-res AO instead.
          Shader.SetTex2D('texAO', (self.aoDenoised ~= false) and self.aoFull or self.aoRaw)
          Shader.SetFloat('aoStrength', Settings.get('ssao.intensity') or 1)
          Shader.SetFloat('aoShow', Settings.get('ssao.show') and 1 or 0)
          Shader.SetFloat('fillOcclude', Settings.get('ssao.fillOcclude') or 1)
        else
          Shader.SetTex2D('texAO', self.aoWhite or self.renderer.zBufferL)
          Shader.SetFloat('aoStrength', 0)
          Shader.SetFloat('aoShow', 0)
          Shader.SetFloat('fillOcclude', 1)
        end
        Draw.Rect(-1, -1, 2, 2)
        shader:stop()
        self.renderer.buffer2:pop()
      end
    end

    do -- Direct sunlight
      if sUn then
        Profiler.Begin('Render.SunLight')
        local shader = Cache.Shader('worldray', 'light/dir')
        if shader then
          local sunShadows = Settings.get('render.sun.shadows')
          if sunShadows and self.updateShadows then
            Profiler.Begin('Render.SunShadow')
            self:renderSunShadow(world)
            Profiler.End()
          end
          local shadowEnabled = sunShadows and self.sunShadowTex ~= nil
          self.renderer.buffer2:push()
          BlendMode.PushAdditive()
          shader:start()
          Shader.SetFloat3('lightColor', sunCol.x, sunCol.y, sunCol.z)
          Shader.SetFloat ('materialSpec', Settings.get('lighting.specular') or 0.35)
          Shader.SetTex2D('texDepth', self.renderer.zBufferL)
          Shader.SetTex2D('texNormalMat', self.renderer.buffer1)
          Shader.SetFloat('shadowEnable', shadowEnabled and 1 or 0)
          if shadowEnabled then
            Shader.SetTex2D('texShadow', self.sunShadowTex)
            Shader.SetMatrix ('sShadowProj', self.sunShadowProj)
            Shader.SetFloat  ('sShadowBias',   Settings.get('render.shadow.bias') or 0.001)
            Shader.SetFloat  ('sShadowScale',  Settings.get('render.shadow.scale') or 0.0005)
            Shader.SetFloat  ('sShadowRadius', Settings.get('render.shadow.radius') or 2.0)
          else
            -- Bind a valid texture even though the branch skips sampling.
            Shader.SetTex2D('texShadow', self.renderer.zBufferL)
          end
          Draw.Rect(-1, -1, 2, 2)
          shader:stop()
          BlendMode.Pop()
          self.renderer.buffer2:pop()
        end
        Profiler.End()
      end
    end

    do -- Local lighting
      if n > 0 and self.updateShadows then self:renderShadows(world, lights) end
      local shader = n > 0 and Cache.Shader('worldray', 'light/point') or nil
      if shader then
        Profiler.Begin('Render.PointLights')
        self.renderer.buffer2:push()
        BlendMode.PushAdditive()
        shader:start()
        for i, v in ipairs(lights) do
          local lightPos = v.lp
          local stex = v.shadow and self.shadowTexts[v.entity]
          local sproj = v.shadow and self.shadowProjs[v.entity]

          Shader.SetFloat3('lightColor', v.color.x, v.color.y, v.color.z)
          Shader.SetFloat3('lightPos', lightPos.x, lightPos.y, lightPos.z)
          Shader.SetFloat ('materialSpec', Settings.get('lighting.specular') or 0.35)
          if stex then
            Shader.SetTex2D('texShadow', stex)
            Shader.SetMatrix ('sShadowProj', sproj)
            Shader.SetFloat  ('sShadowBias',   Settings.get('render.shadow.bias') or 0.001)
            Shader.SetFloat  ('sShadowScale',  Settings.get('render.shadow.scale') or 0.0005)
            Shader.SetFloat  ('sShadowRadius', Settings.get('render.shadow.radius') or 2.0)
            Shader.SetFloat  ('shadowEnable', 1)
          else
            -- Keep a valid 2D texture bound; shadowEnable=0 makes the shader skip it.
            Shader.SetTex2D('texShadow', self.sunShadowTex or self.renderer.zBufferL)
            Shader.SetFloat  ('shadowEnable', 0)
          end
          Shader.SetTex2D('texDepth', self.renderer.zBufferL)
          Shader.SetTex2D('texNormalMat', self.renderer.buffer1)
          Draw.Rect(-1, -1, 2, 2)
        end
        shader:stop()
        BlendMode.Pop()
        self.renderer.buffer2:pop()
        Profiler.End()
      end
    end

    do -- Composite albedo & accumulated light buffer
      local shader = Cache.Shader('worldray', 'light/composite')
      if shader then
        self.renderer.buffer1:push()
        shader:start()
        Shader.SetTex2D('texAlbedo', self.renderer.buffer0)
        Shader.SetTex2D('texDepth', self.renderer.zBufferL)
        Shader.SetTex2D('texLighting', self.renderer.buffer2)
        Draw.Rect(-1, -1, 2, 2)
        shader:stop()
        self.renderer.buffer1:pop()
      end
      if GameView.__dumpGBuffer then GameView.__dumpLit() end
    end

    self.renderer.buffer0, self.renderer.buffer1 = self.renderer.buffer1, self.renderer.buffer0
  end

  -- Alpha (Additive) Pass
  self.renderer:startAlpha(BlendMode.Additive)
  RenderState.PushWireframe(Settings.get('render.wireframe'))
  world:render(Event.Render(BlendMode.Additive, eye, nil, nil, nil, self.cameraVelocity))
  RenderState.PopWireframe()
  self.renderer:stopAlpha()

  -- Alpha Pass
  self.renderer:startAlpha(BlendMode.Alpha)
  RenderState.PushWireframe(Settings.get('render.wireframe'))
  world:render(Event.Render(BlendMode.Alpha, eye, nil, nil, nil, self.cameraVelocity))
  RenderState.PopWireframe()

  if Config.debug.physics.drawBoundingBoxesLocal or
     Config.debug.physics.drawBoundingBoxesWorld or
     Config.debug.physics.drawWireframes or
     Config.debug.physics.drawTriggers
  then
    local mat = Material.DebugColorA()
    mat:start()
    if Config.debug.physics.drawBoundingBoxesLocal then
      Shader.SetFloat4('color', 0, 0, 1, 0.5)
      world.physics:drawBoundingBoxesLocal()
    end
    if Config.debug.physics.drawBoundingBoxesWorld then
      Shader.SetMatrix ('mWorld',   Matrix.Identity())
      Shader.SetMatrixT('mWorldIT', Matrix.Identity())
      Shader.SetFloat('scale', 1)
      Shader.SetFloat4('color', 1, 0, 0, 0.5)
      world.physics:drawBoundingBoxesWorld()
    end
    if Config.debug.physics.drawTriggers then
      Shader.SetMatrix ('mWorld',   Matrix.Identity())
      Shader.SetMatrixT('mWorldIT', Matrix.Identity())
      Shader.SetFloat('scale', 1)
      Shader.SetFloat4('color', 1, 0.5, 0, 0.5)
      world.physics:drawTriggers()
    end
    if Config.debug.physics.drawWireframes then
      Shader.SetMatrix ('mWorld',   Matrix.Identity())
      Shader.SetMatrixT('mWorldIT', Matrix.Identity())
      Shader.SetFloat('scale', 1)
      Shader.SetFloat4('color', 0, 1, 0, 0.5)
      world.physics:drawWireframes()
    end
    mat:stop()
  end
  self.renderer:stopAlpha()

  -- TAA resolve. HERE, before camera:endDraw, not in the post chain: the resolve
  -- declares the camera's matrices as autovars and Shader_Start Fatal-aborts when
  -- a declared autovar is not on the ShaderVar stack. endDraw pops them.
  --
  -- The scene is complete at this point (opaque + additive + alpha), and it runs
  -- before the UI pass -- which is correct anyway, because the UI lives in its own
  -- buffer composited after post, so the HUD and debug panel are never smeared.
  local taaEnabled = Settings.get('render.taa.enable')
  if taaEnabled ~= self.taaWasEnabled then
    self.renderer:invalidateTAA()
    self.taaWasEnabled = taaEnabled
  end
  if taaEnabled then
    Profiler.Begin('Render.TAA')
    self.renderer:taa(Settings.get('render.taa.blend') or 0.9)
    Profiler.End()
  end

  world:endRender()
  ShaderVar.Pop('rockFadeNoise')
  ShaderVar.Pop('sunColor')
  ShaderVar.Pop ('sunFill')
  self.camera:endDraw()
  rtl.submit = TimeStamp.GetElapsedMs(rtl.t0)
  Profiler.End() -- Render.Submit

  -- Composited UI Pass
  self.renderer:startUI(self.renderer.uiBuffer)
  -- UI renders into the (possibly scaled) render buffer; present upscales it.
  local uiKx = self.renderer.sx / math.max(1, self.sx)
  local uiKy = self.renderer.sy / math.max(1, self.sy)
  Viewport.Push(0, 0, self.renderer.sx, self.renderer.sy, true)
  ClipRect.PushTransform(0, 0, uiKx, uiKy)
  local uiScale = Matrix.Scaling(uiKx, uiKy, 1)
  ShaderVar.PushMatrix('mViewUI', uiScale)
  -- A MENU HIDES THE GAME'S OWN UI.
  --
  -- The world is still rendered behind it -- the old game's splash had the
  -- nebula behind it, and a menu over a black frame looks like a bug --
  -- but the HUD, the panels and the markers are the GAME's, and the menu
  -- is the screen the player is looking at.
  local menuUp = self.ltheory and self.ltheory.anyScreenOpen
                 and self.ltheory:anyScreenOpen()
  if not menuUp then
    for i = 1, #self.children do self.children[i]:draw(focus, active) end
    self:drawLightningUI()   -- same widget-space transform as the HUD
    self:drawSunMarker()     -- where the scene light actually comes from
  end
  ShaderVar.Pop('mViewUI')
  uiScale:free()
  ClipRect.PopTransform()
  Viewport.Pop()
  self.renderer:endUI()

  -- Post chain + present
  Profiler.Begin('Render.PostFx')
  rtl.t1 = TimeStamp.Get()

  if Settings.get('render.showBuffers') then
    self.renderer:compositeUI()
    Profiler.Begin('Render.Present')
    local tPres = TimeStamp.Get()
    self.renderer:presentAll(x, y, sx, sy)
    rtl.present = TimeStamp.GetElapsedMs(tPres)
    Profiler.End()
  else
    self.renderer:startPostEffects()
    if Settings.get('postfx.bloom.enable') then self.renderer:bloom(Settings.get('postfx.bloom.radius')) end

    if Settings.get('nebula.enable') then
      local sys = self.ltheory and self.ltheory.system
      local neb = sys and sys.nebula
      if neb and neb.envMap and neb.irMap then
        local noiseTex = self:getAoNoise()
        local volumeRadius = Settings.get('nebula.radius') or 12000
        local volumeCellKey = tostring(self.ltheory.seed) .. ':'
                            .. NebulaVolumes.cellKey(self.camera.pos, volumeRadius)
        if self.volCellKey ~= volumeCellKey then
          self.volCellKey = volumeCellKey
          self.volumes = NebulaVolumes.build(self.ltheory.seed, self.camera.pos,
            volumeRadius, neb.hue,
            self.ltheory.system and self.ltheory.system.sectorRegions)
        end
        ShaderVar.PushMatrix('mViewInv', self.camera.mViewInv)
        ShaderVar.PushMatrix('mProjInv', self.camera.mProjInv)
        local flashes, fstamp = nil, 0
        if self.storm then
          flashes, fstamp = self.storm:activeEvents(self.camera.pos)
        end
        self.renderer:volume({
          envMap   = neb.envMap,
          irMap    = neb.irMap,
          starDir  = neb.starDir,
          sunColor = sunCol,
          noise    = noiseTex,
          anchors  = self.volumes,
          lightning     = flashes,
          lightningStamp = fstamp,
        })
        ShaderVar.Pop('mProjInv')
        ShaderVar.Pop('mViewInv')
      end
    end

    local godDbg = Settings.get('postfx.godrays.debug') or 0
    -- Also gated on nebula.enable: the god-ray pass marches the SAME medium as
    -- the volume pass (godrays.glsl calls mediumCloud), so 'Nebula Volume off'
    -- used to leave the shafts marching a medium the player had just switched
    -- off. That split also made the medium's inscatter impossible to A/B --
    -- disabling either toggle alone removed only half of it, which is why the
    -- glow at the planet's limb survived both.
    if (Settings.get('postfx.godrays.enable') or godDbg > 0) and Settings.get('nebula.enable') then
      local sys = self.ltheory and self.ltheory.system
      local neb = sys and sys.nebula
      if neb and neb.starDir then
        -- Sun screen-space vanishing point; clamped to the frame rim when off-screen.
        local sd = Vec3f(neb.starDir.x, neb.starDir.y, neb.starDir.z):normalize()
        local ndc = self.camera:worldToNDC(self.camera.pos + sd:muls(1e5))
        if ndc.z <= 0 then ndc.x = -ndc.x ndc.y = -ndc.y end
        local cx, cy = self.sx * 0.5, self.sy * 0.5
        local dx = ((ndc.x + 1.0) * 0.5 * self.sx) - cx
        local dy = ((1.0 - ndc.y) * 0.5 * self.sy) - cy
        local len = math.max(1e-4, math.sqrt(dx * dx + dy * dy))
        -- Fade to exactly 0 once the sun goes one rim-depth past the edge of the
        -- frame, so shafts ease in/out at the frustum edge instead of popping.
        local rim = math.min(cx, cy) * 0.98
        -- Clamp to [0,1]: inside the frame this is 1.0, and it only ramps down
        -- as the sun leaves. Without the min() it reaches 2.0 at screen centre,
        -- so shafts were boosted toward the middle instead of faded.
        local sunFade = math.max(0.0, math.min(1.0, 1.0 - (len - rim) / rim))
        local k = math.min(1.0, rim / len)
        local sunUv = { x = (cx + dx * k) / self.sx, y = (cy + dy * k) / self.sy }
        if sunFade > 1e-3 or godDbg > 0 then
          ShaderVar.PushMatrix('mViewInv', self.camera.mViewInv)
          ShaderVar.PushMatrix('mProjInv', self.camera.mProjInv)
          -- The region's LIGHT (13f): the archetype's `light` is how lit
          -- the place is -- "Solar Graveyard: hot haze, strong sun" against
          -- "Deep Field: quiet, nothing much here". The god rays are the
          -- sun's shafts, so they are the thing that reads it, and the
          -- shafts strengthen as you fly into a brighter region.
          --
          -- The archetype's `light` runs 0.25..0.70, so this is a
          -- 0.7x..1.5x multiplier on the player's own strength setting.
          local strength = Settings.get('postfx.godrays.strength') or 1
          if self.sectorField then
            strength = strength * (0.3 + self.sectorField.light * 1.7)
          end
          self.renderer:godrays({
            starDir  = neb.starDir,
            sunColor = sunCol,
            sunUv    = sunUv,
            sunFade  = sunFade,
            anchors  = self.volumes,
            strength = strength,
          })
          ShaderVar.Pop('mProjInv')
          ShaderVar.Pop('mViewInv')
        end
      end
    end

    -- Distance haze (filter/fogw) used to run here. Removed: it hazed by depth
    -- alone, so it applied ~0.50 of aerial perspective to a planet 137k away
    -- across 120k of vacuum, halving the planet's local contrast. See the note
    -- where Renderer:fog used to be defined.

    self.renderer:meter()
    if Settings.get('postfx.tonemap.enable') then self.renderer:tonemap() end
    if Settings.get('postfx.vignette.enable') then self.renderer:vignette() end
    if Settings.get('postfx.aberration.enable') then
      -- `aspect` and `dispersionAmount` are NOT optional here. aberration.glsl does
      --     dir.x *= aspect;  ...  dir.x /= aspect;
      -- and with aspect left at 0 that is 0.0/0.0 -> NaN, so every tap samples at
      -- a NaN coordinate, the offset collapses to depend on uv.y alone, and the
      -- result is visible horizontal blue scanlines across the frame (the blue
      -- comes from the loop's pow(..., 0.50) weight). Shipped off by default,
      -- which is why it survived. dispersionAmount has an in-shader fallback of
      -- 0.0002, so it was only ever "fine", but pass it explicitly now too.
      local abAspect = (self.sy > 0) and (self.sx / self.sy) or 1.0
      self.renderer:applyFilter('aberration', function ()
        Shader.SetFloat('strength', Settings.get('postfx.aberration.strength'))
        Shader.SetFloat('aspect', abAspect)
        Shader.SetFloat('dispersionAmount',
          Settings.get('postfx.aberration.dispersion') or 0.0002)
      end)
    end
    if Settings.get('postfx.radialblur.enable') then
      -- scanlines is declared and used by radialblur.glsl (crtColor mix) but was
      -- never uploaded, so it was pinned at 0 and the effect could never appear
      -- despite having a panel knob.
      self.renderer:applyFilter('radialblur', function ()
        Shader.SetFloat('strength', Settings.get('postfx.radialblur.strength'))
        Shader.SetFloat('scanlines', Settings.get('postfx.radialblur.scanlines') or 0)
      end)
    end
    if Settings.get('postfx.sharpen.enable') then
      self.renderer:sharpen(
        Settings.get('postfx.sharpen.radius') or 2,
        (Settings.get('postfx.sharpen.radius') or 2) * 0.5,
        Settings.get('postfx.sharpen.strength') or 1)
    end
    if Settings.get('postfx.fxaa.enable') then self.renderer:fxaa() end
    if Settings.get('postfx.grain.enable') then
      self.renderer:grain(Settings.get('postfx.grain.strength') or 1)
    end

    self.renderer:compositeUI(true)
    Profiler.Begin('Render.Present')
    local tPres = TimeStamp.Get()
    self.renderer:present(x, y, sx, sy, ss > 2)
    rtl.present = TimeStamp.GetElapsedMs(tPres)
    Profiler.End()
  end
  rtl.postfx = TimeStamp.GetElapsedMs(rtl.t1) - rtl.present
  Profiler.End() -- Render.PostFx

  if GUI.DrawHmGui then
    GUI.DrawHmGui(self.sx, self.sy)
  end

  if GameView.__dump then GameView.__dump() end
  RenderState.PopAll()
  ClipRect.Pop()
  self.camera:pop()
end

-- Sun direction marker (render.sun.marker, default off). The scene is lit from
-- starDir; before the skybox star existed nothing was drawn there, so a planet
-- could read as lit by a phantom. A crosshair at starDir's screen position turns
-- a seed sweep into "is the light coming from somewhere visible?". Uses the same
-- projection the god-rays call does, and the same UI-pass idiom as the lightning
-- ribbons, so it lines up with what is on screen.
function GameView:drawSunMarker ()
  if not Settings.get('render.sun.marker') then return end
  local sys = self.ltheory and self.ltheory.system
  local neb = sys and sys.nebula
  if not (neb and neb.starDir) then return end
  local sd = Vec3f(neb.starDir.x, neb.starDir.y, neb.starDir.z)
  if sd:length() < 1e-6 then return end
  sd = sd:normalize()
  local ndc = self.camera:worldToNDC(self.camera.pos + sd:muls(1e5))
  -- Only bail when the star is genuinely behind the camera (or the projection
  -- returned something non-finite). An off-screen star in FRONT of us must
  -- still get a marker -- see the rim clamp below.
  if not (ndc and ndc.z and ndc.z > 0) then return end
  local s = self.camera:ndcToScreen(ndc)
  local cx, cy = tonumber(s and s.x), tonumber(s and s.y)
  if not (cx and cy and cx == cx and cy == cy) then return end

  local w, h = self.camera.sx, self.camera.sy
  if not (w and h and w > 1 and h > 1) then return end

  -- Rim clamp. The star sits on the sphere, so for most headings it is off
  -- screen -- and an off-screen crosshair is simply clipped away, which made the
  -- marker useless exactly when it was wanted ("turn toward the light").
  -- Place it where the bearing to the star exits the view rect, inset by the
  -- ring: clamping each axis independently would pin it to a corner and lose
  -- the bearing as soon as both axes exceeded the rect.
  local inset = 24
  local mx, my = w * 0.5, h * 0.5
  local dx, dy = cx - mx, cy - my
  local halfW, halfH = mx - inset, my - inset
  local scaleW = dx ~= 0 and (halfW / math.abs(dx)) or 1e30
  local scaleH = dy ~= 0 and (halfH / math.abs(dy)) or 1e30
  local edge = math.min(scaleW, scaleH)
  local offScreen = edge < 1.0
  if offScreen then
    cx, cy = mx + dx * edge, my + dy * edge
  end

  -- Off-screen: smaller and dimmer, so it reads as a bearing hint rather than
  -- an assertion that the star is right there.
  local r = offScreen and 8 or 14
  local alpha = offScreen and 0.7 or 1.0
  Draw.Color(0, 0, 0, 0.55 * alpha)              -- backing: reads on sky + planet
  for i = 0, 15 do
    local t0 = (i / 16) * 6.2831853
    local t1 = ((i + 1) / 16) * 6.2831853
    Draw.Line(cx + math.cos(t0) * r, cy + math.sin(t0) * r,
              cx + math.cos(t1) * r, cy + math.sin(t1) * r)
  end
  Draw.Color(1.0, 0.75, 0.25, 0.95 * alpha)
  Draw.Line(cx - r - 6, cy, cx - r + 2, cy)
  Draw.Line(cx + r - 2, cy, cx + r + 6, cy)
  Draw.Line(cx, cy - r - 6, cx, cy - r + 2)
  Draw.Line(cx, cy + r - 2, cx, cy + r + 6)
  if offScreen then
    -- A tick on the outward side: which way to turn.
    local ux, uy = dx, dy
    local len = math.sqrt(ux * ux + uy * uy)
    if len > 1e-6 then
      ux, uy = ux / len, uy / len
      local t = r + 8
      Draw.Line(cx + ux * t, cy + uy * t, cx + ux * (t + 7), cy + uy * (t + 7))
    end
  end
end

-- Decorative storm visuals, drawn in the UI pass (screen-pixel space):
-- 1) LightningBolt ribbons as projected additive polylines (white-hot core
--    over a colored halo, both fading with bolt age);
-- 2) lightning.debug overlays (Region / Energy) via the controller.
-- Runs inside the composited UI buffer, above the post chain.
function GameView:drawLightningUI ()
  local storm = self.storm
  if not storm then return end
  if Settings.get('lightning.enable') then
    local camera = self.camera

    -- Project one control point; nil if behind the near plane or non-finite,
    -- so a broken projection can never poison the following points.
    local function screenXY (world)
      local ndc = camera:worldToNDC(world)
      if not (ndc and ndc.z and ndc.z > 0) then return nil end
      local s = camera:ndcToScreen(ndc)
      local x, y = tonumber(s and s.x), tonumber(s and s.y)
      if not (x and y and x == x and y == y) then return nil end
      return x, y
    end

    local bolts = storm.bolts
    for i = 1, #bolts do
      local b = bolts[i]
      local fade = math.max(0.0, 1.0 - b.age / b.life)
      if fade > 0.02 then
        -- Re-strike flicker: real bolts re-strike instead of fading smoothly.
        -- Same shimmer as the volume pass so ribbon and cloud glow agree.
        local flick = 0.72 + 0.28 * math.sin(b.age * 43.0) * math.sin(b.age * 17.0 + 1.3)
        -- Stroke every segment directly; for the halo we run the same polyline
        -- per offset (emulates a soft wide ribbon; core-GL wide lines bust).
        local function stroke (pts, ox, oy, cr, cg, cb, ca)
          Draw.Color(cr, cg, cb, ca)
          local prevX, prevY = nil, nil
          for j = 1, #pts do
            local x, y = screenXY(pts[j])
            local ok = x ~= nil
            if ok then
              if prevX then Draw.Line(prevX + ox, prevY + oy, x + ox, y + oy) end
              prevX, prevY = x, y
            else
              -- Drop the broken projection but KEEP drawing the rest: a bolt
              -- that swings behind the near plane or off-frame must not lose
              -- its entire tail (the visible remainder snaps back).
              prevX, prevY = nil, nil
            end
          end
        end
        for p = 1, 3 do -- halo offsets (wide soft ribbon, reads at range)
          stroke(b.points, p * 2.0, 0, b.color.x, b.color.y, b.color.z, 0.16 * fade * flick)
        end
        stroke(b.points, 0, 0, 1, 1, 1, 0.9 * fade * (0.5 + 0.5 * flick)) -- white-hot core
        if b.branches then -- side forks, thinner than the parent channel
          for q = 1, #b.branches do
            stroke(b.branches[q], 0, 0, b.color.x, b.color.y, b.color.z, 0.5 * fade * flick)
          end
        end
        -- Distance-readable strike glow: nested quads at the strike tip so a
        -- 10k-out strike still reads as a flash, not a rumor. Size falls with
        -- range (clamped), alpha follows the same fade+flicker as the ribbon.
        local tip = b.points[#b.points]
        local gx, gy = screenXY(tip)
        if gx then
          local dCam = math.max(1.0, tip:distance(camera.pos))
          local gs = math.max(8, math.min(140, 200000 / dCam))
          local ga = fade * flick
          Draw.Color(b.color.x, b.color.y, b.color.z, 0.10 * ga)
          Draw.Rect(gx - gs / 2, gy - gs / 2, gs, gs)
          Draw.Color(0.9, 0.95, 1.0, 0.22 * ga)
          Draw.Rect(gx - gs / 4, gy - gs / 4, gs / 2, gs / 2)
          Draw.Color(1, 1, 1, 0.75 * ga)
          local cs = math.max(2, gs / 5)
          Draw.Rect(gx - cs / 2, gy - cs / 2, cs, cs)
        end
      end
    end
  end
  storm:debugDraw(self.camera)
end

-- Vapor-gated thunder: one-shot 3D at the strike point (Turret pattern).
-- The controller only fires inside a real window, so this is always a valid
-- nucleus even when the camera is inside the plume.
function GameView:onLightningStrike (e)
  local sfx = Config.audio.sfx.thunder
  if not (sfx and sfx.sound) then return end
  local sound = Sound.Load(sfx.sound, false, true)
  sound:set3DPos(e.pos, Vec3f(0, 0, 0))
  sound:set3DMinMaxDistance(sfx.minDist or 500, 0)
  sound:setVolume(sfx.volume or 3.5)
  sound:setFreeOnFinish(true)
  sound:play()
end

function GameView:onInputChildren (state)
  self.camera:push()
  for i = 1, #self.children do
    local child = self.children[i]
    if not child.removed then child:input(state) end
  end
  self.camera:pop()
end

function GameView:onUpdate (state)
  self.camera:onUpdate(state.dt)

  -- THE MENU CAMERA.
  --
  -- While a screen is up the camera drifts, so the world behind the menu
  -- moves -- the old game's splash had the nebula behind it, and a nebula
  -- that does not move looks like a photograph. When the screen closes the
  -- offsets are cleared, so the camera goes back to the ship.
  local screenUp = self.ltheory and self.ltheory.anyScreenOpen
                   and self.ltheory:anyScreenOpen()
  if screenUp then
    self:updateMenuCamera(state.dt)
  elseif self.menuT then
    self.menuT = nil
    self.camera.posOffset = Vec3f()
    self.camera.rotOffset = Quat.Identity()
  end

  do -- Lightning storm schedule (vapor-gated, off = no-op)
    if self.ltheory then
      if not self.storm then
        self.storm = LightningStorm.new(self.ltheory.seed)
      end
      -- The environmental field at the camera (13f).
      --
      -- Computed ONCE per frame and kept, because two different passes want
      -- it: the lightning reads the region's storminess, and the god rays
      -- read the region's light. And it is computed whether or not the
      -- lightning is on -- a field that only exists when one of its
      -- consumers happens to be switched on is not a field.
      local stormField = self.ltheory.system
                          and self.ltheory.system:fieldAt(self.camera.pos.x,
                                                          self.camera.pos.y,
                                                          self.camera.pos.z)
      self.sectorField = stormField

      if Settings.get('lightning.enable') then
        local tNow = (tonumber(Time.GetRaw()) or 0) * 0.001
        self.storm:update(state.dt, tNow, {
          volumes   = self.volumes,
          field     = stormField,
          cameraPos = self.camera.pos,
          camDir    = self.camera.rot:getForward(),
          fovY      = Settings.get('render.fovY') or 70,
          system    = self.ltheory.system,
          onStrike  = function (e) self:onLightningStrike(e) end,
        })
      end
    end
  end

  do -- Compute Eye Velocity EMA
    local eye = self.camera.pos
    local dt = math.max(1e-10, state.dt)
    local v = (eye - self.eyeLast):scale(1.0 / dt)
    self.cameraVelocity = v
    local controlling = self.player:getControlling()
    if controlling then
      self.eyeVel:setv(controlling:getVelocity())
    end
    self.eyeLast:setv(eye)
  end

  Audio.SetListenerPos(
    self.camera.pos,
    self.eyeVel,
    self.camera.rot:getForward(),
    self.camera.rot:getUp())
  Audio.Update()

  if Input.GetPressed(Button.Keyboard.M) then
    self.musicMuted = not self.musicMuted
    if self.musicMuted then self.music:pause() else self.music:play() end
  end

  if Input.GetPressed(Button.Keyboard.F9) then
    local now = os.clock()
    if not self.__lastDebugToggle or now - self.__lastDebugToggle > 0.2 then
      self.__lastDebugToggle = now
      self.debugWindow:toggleEnabled()
    end
  end

  if Input.GetPressed(Button.Keyboard.F10) then
    local now = os.clock()
    if not self.__lastMapToggle or now - self.__lastMapToggle > 0.2 then
      self.__lastMapToggle = now
      if self.nodeGraph then self.nodeGraph:toggleEnabled() end
    end
  end

  local vsync = Settings.get('render.vsync')
  if vsync ~= self.appliedVsync and self.ltheory and self.ltheory.window then
    self.appliedVsync = vsync
    self.ltheory.window:setVsync(vsync)
  end

  self.camera:pop()
end

--[[ The menu camera.

  A menu over a still frame looks like a still frame. The old game's splash
  had the nebula behind it, and the nebula moved.

  The chase camera owns the frame's pose -- `pos = posOffset + posT` and
  `rot = rotOffset * rotT` -- and the controllers do not own the OFFSET
  terms, so the drift goes there: a slow orbit around the ship and a slow
  yaw, which moves the medium's structure across the frame.
]]
function GameView:updateMenuCamera (dt)
  self.menuT = (self.menuT or 0) + dt
  local t = self.menuT
  local a = t * 0.05
  self.camera.posOffset = Vec3f(math.cos(a) * 260,
                                120 + math.sin(a * 0.6) * 70,
                                math.sin(a) * 260)
  self.camera.rotOffset = Quat.FromAxisAngle(Vec3f(0, 1, 0),
                                              math.sin(t * 0.04) * 0.10)
end

function GameView:onUpdateChildren (state)
  self.camera:push()
  for i = 1, #self.children do
    local child = self.children[i]
    if not child.removed then child:update(state) end
  end
  self.camera:pop()
end

function GameView:onLayoutSizeChildren ()
  self.camera:push()
  for i = 1, #self.children do self.children[i]:layoutSize() end
  self.camera:pop()
end

function GameView:setOrbit (orbit)
  local lastCamera = self.camera

  self.orbit = orbit
  self.camera = self.orbit and self.cameraOrbit or self.cameraChase
  self.camera:setTarget(self.player:getControlling())

  local camera = Camera.get()
  if camera and camera == lastCamera then
    lastCamera:pop()
    self.camera:push()
  end
end

function GameView.Create (player)
  Audio.Init()
  Audio.Set3DSettings(0.0, 10, 2);

  local self = setmetatable({
    player       = player,
    renderer     = Renderer(),
    cameraChase  = CameraChase(),
    cameraOrbit  = CameraOrbit(),
    camera       = nil,
    eyeLast      = nil,
    eyeVel       = nil,
    appliedVsync = nil,
    shadowTexts  = {},
    shadowProjs  = {},
    renderTimes  = { submit = 0, postfx = 0, present = 0 },
    children     = List(),
  }, GameView)

  self:setOrbit(false)
  self.eyeLast = self.camera.pos:clone()

  local controlling = self.player:getControlling()
  self.eyeVel = controlling and controlling:getVelocity():clone() or Vec3f(0, 0, 0)

  self.music = Sound.Load(Config.audio.music, true, false)
  self.music:setVolume(Config.audio.musicVolume)
  self.music:play()
  return self
end

return GameView
