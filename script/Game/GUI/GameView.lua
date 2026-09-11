local GameView = {}
GameView.__index = GameView
setmetatable(GameView, UI.Container)

GameView.name = 'Game View'
local ssTable = { 1, 2, 4 }
local Batcher = require('Game.Batcher')
local NebulaVolumes = require('Game.NebulaVolumes')

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
  local d = (eye - lightPos):length()
  local z = Vec3f(0, math.max(d, 1e-4), 0):normalize()
  local ref = (math.abs(z.y) < 0.999) and Vec3f(0, 1, 0) or Vec3f(1, 0, 0)
  local x = (ref:cross(z)):normalize()
  local y = (z:cross(x)):normalize()
  local view = Matrix.FromBasis(x, y, z):product(Matrix.Translation(-lightPos.x, -lightPos.y, -lightPos.z))
  local proj = Matrix.Ortho(-halfSize, halfSize, -halfSize, halfSize, 0.1, 2 * halfSize)
  return view:product(proj)
end

-- Render per-light shadow maps into Depth32F textures (called before the light passes).
function GameView:renderShadows (world, lights)
  local eye = self.camera.pos
  self.shadowTexts = self.shadowTexts or {}
  self.shadowProjs = self.shadowProjs or {}

  for i, light in ipairs(lights) do
    local tex = self.shadowTexts[light.entity]

    if not tex then
      local sw, sh = shadowSize(self.sx, self.sy)
      tex = Tex2D.Create(sw, sh, TexFormat.Depth32F)
      tex:setMinFilter(TexFilter.Linear)
      tex:genMipmap()
      self.shadowTexts[light.entity] = tex
    end

    local halfSize = math.max((eye - light.lp):length() * 0.5, 100000)
    local proj = self:buildShadowFrustum(light.lp, eye, halfSize)
    self.shadowProjs[light.entity] = proj

    RenderTarget.Push(self.sx, self.sy)
    RenderTarget.BindTex2D(tex)

    ShaderVar.PushMatrix('mView', proj)
    ShaderVar.PushMatrix('mProj', Matrix.Identity())
    ShaderVar.PushFloat3('eye', light.lp.x, light.lp.y, light.lp.z)
    BlendMode.PushDisabled()
    CullFace.Push(CullFace.Back)
    RenderState.PushDepthTest(true)
    RenderState.PushDepthWritable(true)

    Draw.ClearDepth(1)

    world:render(Event.Render(BlendMode.Disabled, eye))

    RenderState.PopDepthWritable()
    RenderState.PopDepthTest()
    CullFace.Pop()
    BlendMode.Pop()
    ShaderVar.Pop('mView')
    ShaderVar.Pop('mProj')
    ShaderVar.Pop('eye')
    RenderTarget.Pop()
  end
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
    self.sunShadowTex:genMipmap()
    self.sunShadowSizeKey = key
  end

  local range = Settings.get('render.sun.shadowRange') or 8000
  local sd = Vec3f(world.starDir.x, world.starDir.y, world.starDir.z):normalize()
  self.sunShadowCenter = self.camera.pos
  local proj = self:buildShadowFrustum(self.sunShadowCenter, self.sunShadowCenter - sd, range)
  self.sunShadowProj = proj

  RenderTarget.Push(self.sx, self.sy)
  RenderTarget.BindTex2D(self.sunShadowTex)

  ShaderVar.PushMatrix('mView', proj)
  ShaderVar.PushMatrix('mProj', Matrix.Identity())
  ShaderVar.PushFloat3('eye', self.sunShadowCenter.x, self.sunShadowCenter.y, self.sunShadowCenter.z)
  BlendMode.PushDisabled()
  CullFace.Push(CullFace.Back)
  RenderState.PushDepthTest(true)
  RenderState.PushDepthWritable(true)

  Draw.ClearDepth(1)

  world:render(Event.Render(BlendMode.Disabled, self.sunShadowCenter))

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
    local shader = Cache.Shader('ui', 'filter/aoblur')
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
        mkDump('3_final')(self.renderer.buffer0)
        GameView.__dump = nil
      end
    end
  end
  self.camera:push()

  local ss = ssTable[Settings.get('render.superSample')]
  local x, y, sx, sy = self:getRectGlobal()
  ClipRect.PushDisabled()
  RenderState.PushAllDefaults()
  self.camera:setViewport(x, y, sx, sy)
  self.camera:beginDraw()

  local world = self.player:getRoot()
  if world == self.player or not world.beginRender then
    ClipRect.Pop()
    RenderState.PopAll()
    self.camera:endDraw()
    self.camera:pop()
    return
  end
  local eye = self.camera.pos
  world:beginRender()

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
    self.renderer:start(self.sx, self.sy, ss)
    Batcher.begin()
    RenderState.PushWireframe(Settings.get('render.wireframe'))
    world:render(Event.Render(BlendMode.Disabled, eye))
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
    local n = 0
    for i, v in world:iterChildren() do
      if v:hasLight() then
        n = n + 1
        local e = lights[n]
        if not e then
          e = { entity = nil, pos = nil, lp = Vec3f(0, 0, 0), color = nil }
          lights[n] = e
        end
        local p = v:getPos()
        e.entity = v
        e.pos = p
        e.lp.x = p.x
        e.lp.y = p.y + 5
        e.lp.z = p.z
        e.color = v:getLight()
      end
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
          Shader.SetTex2D('texAO', self.aoFull)
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
        local shader = Cache.Shader('worldray', 'light/dir')
        if shader then
          if Settings.get('render.sun.shadows') then
            self:renderSunShadow(world)
          end
          self.renderer.buffer2:push()
          BlendMode.PushAdditive()
          shader:start()
          Shader.SetFloat3('lightColor', sunCol.x, sunCol.y, sunCol.z)
          Shader.SetFloat ('materialSpec', Settings.get('lighting.specular') or 0.35)
          Shader.SetTex2D('texDepth', self.renderer.zBufferL)
          Shader.SetTex2D('texNormalMat', self.renderer.buffer1)
          if self.sunShadowTex then
            Shader.SetTex2D('texShadow', self.sunShadowTex)
            Shader.SetMatrix ('sShadowProj', self.sunShadowProj)
            Shader.SetFloat  ('sShadowBias',   Settings.get('render.shadow.bias') or 0.001)
            Shader.SetFloat  ('sShadowScale',  Settings.get('render.shadow.scale') or 0.0005)
            Shader.SetFloat  ('sShadowRadius', Settings.get('render.shadow.radius') or 2.0)
            Shader.SetFloat3 ('sunShadowCenter', self.sunShadowCenter.x, self.sunShadowCenter.y, self.sunShadowCenter.z)
          end
          Draw.Rect(-1, -1, 2, 2)
          shader:stop()
          BlendMode.Pop()
          self.renderer.buffer2:pop()
        end
      end
    end

    do -- Local lighting
      self:renderShadows(world, lights)
      local shader = Cache.Shader('worldray', 'light/point')
      if shader then
        self.renderer.buffer2:push()
        BlendMode.PushAdditive()
        shader:start()
        for i, v in ipairs(lights) do
          local lightPos = v.lp
          local stex = self.shadowTexts[v.entity]
          local sproj = self.shadowProjs[v.entity]

          Shader.SetFloat3('lightColor', v.color.x, v.color.y, v.color.z)
          Shader.SetFloat3('lightPos', lightPos.x, lightPos.y, lightPos.z)
          Shader.SetFloat ('materialSpec', Settings.get('lighting.specular') or 0.35)
          if stex then
            Shader.SetTex2D('texShadow', stex)
            Shader.SetMatrix ('sShadowProj', sproj)
            Shader.SetFloat  ('sShadowBias',   Settings.get('render.shadow.bias') or 0.001)
            Shader.SetFloat  ('sShadowScale',  Settings.get('render.shadow.scale') or 0.0005)
            Shader.SetFloat  ('sShadowRadius', Settings.get('render.shadow.radius') or 2.0)
          end
          Shader.SetTex2D('texDepth', self.renderer.zBufferL)
          Shader.SetTex2D('texNormalMat', self.renderer.buffer1)
          Draw.Rect(-1, -1, 2, 2)
        end
        shader:stop()
        BlendMode.Pop()
        self.renderer.buffer2:pop()
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
  world:render(Event.Render(BlendMode.Additive, eye))
  RenderState.PopWireframe()
  self.renderer:stopAlpha()

  -- Alpha Pass
  self.renderer:startAlpha(BlendMode.Alpha)
  RenderState.PushWireframe(Settings.get('render.wireframe'))
  world:render(Event.Render(BlendMode.Alpha, eye))
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

  world:endRender()
  ShaderVar.Pop('sunColor')
  ShaderVar.Pop ('sunFill')
  self.camera:endDraw()
  rtl.submit = TimeStamp.GetElapsedMs(rtl.t0)
  Profiler.End() -- Render.Submit

  -- Composited UI Pass
  self.renderer:startUI(self.renderer.uiBuffer)
  Viewport.Push(0, 0, ss * self.sx, ss * self.sy, true)
  ClipRect.PushTransform(0, 0, ss, ss)
  local uiScale = Matrix.Scaling(ss, ss, 1)
  ShaderVar.PushMatrix('mViewUI', uiScale)
  for i = 1, #self.children do self.children[i]:draw(focus, active) end
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
        if self.volCellKey ~= NebulaVolumes.cellKey(self.camera.pos) then
          self.volCellKey = NebulaVolumes.cellKey(self.camera.pos)
          self.volumes = NebulaVolumes.build(self.ltheory.seed, self.camera.pos,
            Settings.get('nebula.radius') or 12000)
        end
        ShaderVar.PushMatrix('mViewInv', self.camera.mViewInv)
        ShaderVar.PushMatrix('mProjInv', self.camera.mProjInv)
        self.renderer:volume({
          envMap   = neb.envMap,
          irMap    = neb.irMap,
          starDir  = neb.starDir,
          sunColor = sunCol,
          noise    = noiseTex,
          anchors  = self.volumes,
        })
        ShaderVar.Pop('mProjInv')
        ShaderVar.Pop('mViewInv')
      end
    end

    if Settings.get('postfx.fog.enable') then
      local sys = self.ltheory and self.ltheory.system
      local neb = sys and sys.nebula
      if neb and neb.envMap then
        ShaderVar.PushMatrix('mViewInv', self.camera.mViewInv)
        ShaderVar.PushMatrix('mProjInv', self.camera.mProjInv)
        self.renderer:fog(neb.envMap)
        ShaderVar.Pop('mProjInv')
        ShaderVar.Pop('mViewInv')
      end
    end

    self.renderer:meter()
    if Settings.get('postfx.tonemap.enable') then self.renderer:tonemap() end
    if Settings.get('postfx.vignette.enable') then self.renderer:vignette() end
    if Settings.get('postfx.aberration.enable') then
      self.renderer:applyFilter('aberration', function ()
        Shader.SetFloat('strength', Settings.get('postfx.aberration.strength'))
      end)
    end
    if Settings.get('postfx.radialblur.enable') then
      self.renderer:applyFilter('radialblur', function ()
        Shader.SetFloat('strength', Settings.get('postfx.radialblur.strength'))
      end)
    end
    if Settings.get('postfx.sharpen.enable') then
      self.renderer:sharpen(
        Settings.get('postfx.sharpen.radius') or 2,
        (Settings.get('postfx.sharpen.radius') or 2) * 0.5,
        Settings.get('postfx.sharpen.strength') or 1)
    end
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

  do -- Compute Eye Velocity EMA
    local eye = self.camera.pos
    local dt = math.max(1e-10, state.dt)
    local v = (eye - self.eyeLast):scale(1.0 / dt)
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

  local vsync = Settings.get('render.vsync')
  if vsync ~= self.appliedVsync and self.ltheory and self.ltheory.window then
    self.appliedVsync = vsync
    self.ltheory.window:setVsync(vsync)
  end

  self.camera:pop()
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
