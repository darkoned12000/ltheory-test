local Cache = require('phx.util.Cache')

-- TODO JP : Refactor all of this monolithic nonsense into RenderPass objects.

local Renderer = class(function (self)
  self.ds = 4

  -- GPU portability: seed the whole graphics surface from Config.gpu if present,
  -- so a weak machine can drop expensive passes (bloom/sharpen/tonemap/...), an
  -- HDR look can be baked from config instead of the debug-window sliders, and a
  -- future in-game Settings screen will present exactly this set. Guarded by
  -- Settings.exists() so it's inert until Config.App.lua has defined the block;
  -- a key left nil (or absent) keeps the built-in/debug-window default.
  local gpu = (Config and Config.gpu) or {}
  local function seed (key, value)
    if Settings.exists(key) and value ~= nil then Settings.set(key, value) end
  end

  seed('postfx.bloom.enable',        gpu.bloom)
  seed('postfx.bloom.radius',        gpu.bloomRadius)
  seed('postfx.bloom.intensity',     gpu.bloomIntensity)
  seed('postfx.bloom.threshold',     gpu.bloomThreshold)
  seed('postfx.sharpen.enable',      gpu.sharpen)
  seed('postfx.sharpen.strength',    gpu.sharpenStrength)
  seed('postfx.sharpen.radius',      gpu.sharpenRadius)
  seed('postfx.tonemap.enable',      gpu.tonemap)
  seed('postfx.exposure.ev',         gpu.exposureEV)
  seed('postfx.autoexposure.enable', gpu.autoExposure)
  seed('postfx.autoexposure.key',    gpu.autoExposureKey)
  seed('postfx.autoexposure.minEV',  gpu.autoExposureMinEV)
  seed('postfx.autoexposure.maxEV',  gpu.autoExposureMaxEV)
  seed('postfx.autoexposure.speed',  gpu.autoExposureSpeed)
  seed('postfx.vignette.enable',     gpu.vignette)
  seed('postfx.vignette.strength',   gpu.vignetteStrength)
  seed('postfx.vignette.hardness',   gpu.vignetteHardness)
  seed('postfx.grain.enable',        gpu.grain)
  seed('postfx.grain.strength',      gpu.grainStrength)
  seed('postfx.aberration.enable',   gpu.aberration)
  seed('postfx.aberration.strength', gpu.aberrationStrength)
  seed('postfx.radialblur.enable',   gpu.radialblur)
  seed('postfx.radialblur.strength', gpu.radialblurStrength)
  seed('postfx.radialblur.scanlines', gpu.radialblurScanlines)

  seed('render.sun.enable',    gpu.sunLight)
  seed('render.sun.intensity', gpu.sunIntensity)
  seed('render.sun.fill',      gpu.sunAmbientFill)
  seed('render.sun.warmth',    gpu.sunWarmth)
  seed('render.sun.shadows',   gpu.sunShadows)
  seed('render.sun.shadowRange', gpu.sunShadowRange)

  seed('lighting.specular',  gpu.dielectricSpec)
  seed('lighting.ambientEnv', gpu.ambientEnv)

  local aoQIdx    = { Off = 1, Half = 2, Quarter = 3 }
  local aoDirIdx  = { ['2'] = 1, ['4'] = 2, ['6'] = 3, ['8'] = 4 }
  local aoStepIdx = { ['2'] = 1, ['3'] = 2, ['4'] = 3, ['6'] = 4 }
  local aoBlurIdx = { ['0'] = 1, ['1'] = 2, ['2'] = 3 }
  seed('ssao.enable',    gpu.aoEnabled)
  seed('ssao.quality',   aoQIdx[gpu.aoQuality])
  seed('ssao.radius',    gpu.aoRadius)
  seed('ssao.intensity', gpu.aoIntensity)
  seed('ssao.directions', aoDirIdx[gpu.aoDirections])
  seed('ssao.steps',     aoStepIdx[gpu.aoSteps])
  seed('ssao.thickness', gpu.aoThickness)
  seed('ssao.blur',      aoBlurIdx[gpu.aoBlur])

  local filterIdx = { Bilinear = 1, Trilinear = 2, Aniso = 3, Anisotropic = 3 }
  seed('render.textureFilter', filterIdx[gpu.filtering])

  local ssIdx = { ['Off'] = 1, ['2x'] = 2, ['4x'] = 3 }
  seed('render.superSample', ssIdx[gpu.superSample])

  local ops = { AgX = 1, ACES = 2, Filmic = 3, Khronos = 4 }
  seed('postfx.tonemap.operator', ops[gpu.tonemapOperator])

  -- VSync is a window/swap-interval setting (Config.render.vsync), applied live
  -- by GameView; seed it so the debug control matches the window's startup state.
  seed('render.vsync', (Config and Config.render) and Config.render.vsync)

  -- Exposure meter / auto-exposure state (see Renderer:meter / autoExposureEV).
  self.exposure   = { avg = 0, max = 0, over = 0, lit = 0 }
  self.meterLast  = 0
  self.frameSeed  = 0
  self.autoEV     = 0
end)

local colorFormat = TexFormat.RGBA16F
local depthFormat = TexFormat.Depth32F

Settings.addBool  ('postfx.aberration.enable',   'Aberration',  false)
Settings.addFloat ('postfx.aberration.strength', ' - Strength', 1, 0, 1)
Settings.addBool  ('postfx.bloom.enable',        'Bloom',       true)
Settings.addFloat ('postfx.bloom.radius',        ' - Radius',   48, 4, 64)
Settings.addFloat ('postfx.bloom.intensity',     ' - Intensity', 1, 0, 4)
Settings.addFloat ('postfx.bloom.threshold',     ' - Threshold', 1, 0, 8)
Settings.addBool  ('postfx.sharpen.enable',   'Sharpen',     true)
Settings.addFloat ('postfx.sharpen.strength', ' - Strength', 1, 0, 3)
Settings.addFloat ('postfx.sharpen.radius',   ' - Radius',   2, 1, 6)
Settings.addBool  ('postfx.radialblur.enable',   'RadialBlur',  false)
Settings.addFloat ('postfx.radialblur.strength', ' - Strength', 1, 0, 1)
Settings.addFloat ('postfx.radialblur.scanlines', ' - Scanlines', 1, 0, 1)
Settings.addBool  ('postfx.tonemap.enable',      'Tonemap',     true)
Settings.addEnum  ('postfx.tonemap.operator',    ' - Operator', 1, { 'AgX', 'ACES', 'Filmic', 'Khronos' })
Settings.addFloat ('postfx.exposure.ev',         ' - Exposure EV', 0, -4, 4)
Settings.addBool  ('postfx.autoexposure.enable', 'Auto-Exposure', false)
Settings.addFloat ('postfx.autoexposure.key',    ' - Key (mid-gray)', 0.18, 0.02, 1)
Settings.addFloat ('postfx.autoexposure.minEV',  ' - Min EV', -6, -8, 2)
Settings.addFloat ('postfx.autoexposure.maxEV',  ' - Max EV', 2, -8, 4)
Settings.addFloat ('postfx.autoexposure.speed',  ' - Adapt (s)', 0.5, 0.05, 3)
Settings.addBool  ('postfx.vignette.enable',     'Vignette',    true)
Settings.addFloat ('postfx.vignette.strength',   ' - Strength', 0.25, 0, 1)
Settings.addFloat ('postfx.vignette.hardness',   ' - Hardness', 20.0, 2, 32)
Settings.addBool  ('postfx.grain.enable',        'Film Grain',  false)
Settings.addFloat ('postfx.grain.strength',      ' - Amount',   1, 0, 4)

Settings.addFloat ('render.fovY',        'FOV',                   70, 50, 100)
Settings.addEnum  ('render.superSample', 'SuperSampling',         2, { 'Off', '2x', '4x' })
Settings.addBool  ('render.wireframe',   'Wireframe',             false)
Settings.addBool  ('render.cullface',    'Backface Culling',      true)
Settings.addBool  ('render.showBuffers', 'Show Deferred Buffers', false)
Settings.addEnum  ('render.textureFilter', 'Texture Filter', 3, { 'Bilinear', 'Trilinear', 'Trilinear + Aniso' })
Settings.addFloat ('render.shadow.radius', 'Shadow Radius (PCF)',   2, 0, 8)
Settings.addFloat ('render.shadow.bias',   'Shadow Bias',           0.001, -0.01, 0.1)
Settings.addFloat ('render.shadow.scale',  'Shadow Dist Scale',     0.0005, 0, 0.01)
Settings.addBool  ('render.sun.enable',    'Sun Light',             true)
Settings.addFloat ('render.sun.intensity', ' - Intensity',          1, 0, 6)
Settings.addFloat ('render.sun.fill',      ' - Ambient Fill',       0.30, 0, 1)
Settings.addFloat ('render.sun.warmth',    ' - Warmth',             1, 0, 1)
Settings.addBool  ('render.sun.shadows',   ' - Shadows',            true)
Settings.addFloat ('render.sun.shadowRange', ' - Shadow Range',     8000, 500, 20000)
Settings.addBool  ('render.vsync',       'VSync',                 true)

Settings.addFloat ('lighting.ambientEnv', 'Environment Light',     1.35, 0, 3)
Settings.addFloat ('lighting.specular',   'Dielectric Specular',   0.35, 0, 1)

-- Screen-space ambient occlusion (GTAO). Default OFF until the mid-tier perf
-- gate in ssao-gtao-implementation.md is measured; the debug section is
-- auto-built from the 'ssao' prefix (first key segment) by DebugWindow.
Settings.addBool  ('ssao.enable',      'Ambient Occlusion',  false)
Settings.addEnum  ('ssao.quality',     ' - Resolution',      2, { 'Off', 'Half', 'Quarter' })
Settings.addFloat ('ssao.radius',      ' - Radius',          500, 0.1, 4000)
Settings.addFloat ('ssao.intensity',   ' - Intensity',       1, 0, 3)
Settings.addEnum  ('ssao.directions',  ' - Directions',      2, { '2', '4', '6', '8' })
Settings.addEnum  ('ssao.steps',       ' - Steps',           2, { '2', '3', '4', '6' })
Settings.addFloat ('ssao.thickness',   ' - Thickness',       0.25, 0, 1)
Settings.addEnum  ('ssao.blur',        ' - Denoise',         2, { '0', '1', '2' })
Settings.addBool  ('ssao.show',        ' - Show',            false)

local function createBuffer (sx, sy, format)
  local self = Tex2D.Create(sx, sy, format)
  self:setMagFilter(TexFilter.Linear)
  self:setMinFilter(TexFilter.Linear)
  self:setWrapMode(TexWrapMode.Clamp)
  self:push()
  Draw.Clear(0, 0, 0, 0)
  self:pop()
  self:genMipmap()
  return self
end

function Renderer:aberration (strength)
  Draw.Color(1, 1, 1, 1)
  local shader = Cache.Shader('ui', 'filter/aberration')
  if not shader then return end   -- item 4: skip broken pass; buffer push/pop stay balanced below
  self.buffer1:pushLevel(self.level)
  shader:start()
    Shader.SetFloat('strength', strength)
    Shader.SetTex2D('src', self.buffer0)
    Draw.Color(1, 1, 1, 1)
    Draw.Rect(0, 0, self.sx, self.sy)
  shader:stop()
  self.buffer1:pop()
  self:swap()
end

function Renderer:applyFilter (frag, onSetVars)
  local shader = Cache.Shader('ui', 'filter/' .. frag)
  if not shader then return end   -- item 4: skip broken pass; buffer push/pop stay balanced below
  self.buffer1:pushLevel(self.level)
  shader:start()
    Shader.SetTex2D('src', self.buffer0)
    if onSetVars then onSetVars() end
    Draw.Color(1, 1, 1, 1)
    Draw.Rect(0, 0, self.sx, self.sy)
  shader:stop()
  self.buffer1:pop()
  self:swap()
end

function Renderer:bloom (radius)
  Draw.Color(1, 1, 1, 1)
  local A = self.dsBuffer0
  local B = self.dsBuffer1
  local threshold = Settings.get('postfx.bloom.threshold') or 1.0
  local intensity = Settings.get('postfx.bloom.intensity') or 1.0
  local knee = threshold * 0.5

  local baseW = self.resX / self.ds
  local baseH = self.resY / self.ds

  -- Pyramid budget: few enough levels that every level keeps a 2x2 block for
  -- the Karis downsample, and radius steers how many octaves get kept.
  local mips = 1
  while mips < 12 and math.floor(baseW / (2 ^ mips)) >= 2 and math.floor(baseH / (2 ^ mips)) >= 2 do
    mips = mips + 1
  end
  local levels = math.max(2, math.min(mips, 4 + math.floor(radius / 8)))

  do -- Prefilter (guarded, item 4): soft-knee threshold of the HDR scene -> level 0
    local shader = Cache.Shader('ui', 'filter/bloompre')
    if shader then
      A:pushLevel(0)
      shader:start()
        Shader.SetFloat('bloomThreshold', threshold)
        Shader.SetFloat('bloomKnee', knee)
        Shader.SetTex2D('src', self.buffer0)
        Draw.Rect(0, 0, baseW, baseH)
      shader:stop()
      A:pop()
    end
  end

  do -- Downsample (guarded, item 4): Karis-weighted average, one level per octave
    local shader = Cache.Shader('ui', 'filter/bloomdown')
    for i = 1, levels - 1 do
      if shader then
        local w = math.floor(baseW / (2 ^ (i - 1)))
        local h = math.floor(baseH / (2 ^ (i - 1)))
        A:setMipRange(i - 1, i - 1)
        A:setMinFilter(TexFilter.Linear)
        A:pushLevel(i)
        shader:start()
          Shader.SetFloat2('srcSize', w, h)
          Shader.SetTex2D('src', A)
          Draw.Rect(0, 0, math.floor(baseW / (2 ^ i)), math.floor(baseH / (2 ^ i)))
        shader:stop()
        A:pop()
      end
    end
  end

  do -- Seed the accumulation chain with the coarsest level
    local shader = Cache.Shader('ui', 'filter/identity')
    if shader then
      local w = math.floor(baseW / (2 ^ (levels - 1)))
      local h = math.floor(baseH / (2 ^ (levels - 1)))
      A:setMipRange(levels - 1, levels - 1)
      A:setMinFilter(TexFilter.Linear)
      B:pushLevel(levels - 1)
      shader:start()
        Shader.SetTex2D('src', A)
        Draw.Rect(0, 0, w, h)
      shader:stop()
      B:pop()
    end
  end

  do -- Progressive upsample (guarded, item 4): blend each level with the accumulated looser bloom
    local shader = Cache.Shader('ui', 'filter/bloomup')
    for i = levels - 2, 0, -1 do
      if shader then
        local w = math.floor(baseW / (2 ^ i))
        local h = math.floor(baseH / (2 ^ i))
        A:setMipRange(i, i)
        A:setMinFilter(TexFilter.Linear)
        B:setMipRange(i + 1, i + 1)
        B:setMinFilter(TexFilter.Linear)
        B:pushLevel(i)
        shader:start()
          Shader.SetFloat('scatter', 0.7)
          Shader.SetTex2D('src', A)
          Shader.SetTex2D('srcLow', B)
          Draw.Rect(0, 0, w, h)
        shader:stop()
        B:pop()
      end
    end
  end

  do -- Composite bloom back into the HDR scene (additive, pre-tonemap)
    local shader = Cache.Shader('ui', 'filter/bloomcomposite')
    if shader then
      B:setMipRange(0, 0)
      B:setMinFilter(TexFilter.Linear)
      self.buffer1:pushLevel(self.level)
      shader:start()
        Shader.SetFloat('intensity', intensity)
        Shader.SetTex2D('src', self.buffer0)
        Shader.SetTex2D('srcBlur', B)
        Draw.Rect(0, 0, self.sx, self.sy)
      shader:stop()
      self.buffer1:pop()
      self:swap()
    end
  end

  -- Leave the pyramid textures unrestricted for the next frame
  A:setMipRange(0, 0)
  B:setMipRange(0, 0)
  A:setMinFilter(TexFilter.Linear)
  B:setMinFilter(TexFilter.Linear)
end

function Renderer:blur (dst, src, dx, dy, radius)
  local shader = Cache.Shader('ui', 'filter/blur')
  if not shader then return end   -- item 4: skip broken pass; dst push/pop stay balanced below
  local size = src:getSize()
  dst:push()
  shader:start()
    Shader.SetFloat('variance', 0.2 * radius)
    Shader.SetFloat2('dir', dx, dy)
    Shader.SetFloat2('size', size.x, size.y)
    Shader.SetInt('radius', radius)
    Shader.SetTex2D('src', src)
    Draw.Color(1, 1, 1, 1)
    Draw.Rect(0, 0, size.x, size.y)
  shader:stop()
  dst:pop()
end

function Renderer:colorGrade (curve1, curve2)
  local shader = Cache.Shader('ui', 'filter/colorgrade')
  if not shader then return end   -- item 4: skip broken pass; buffer push/pop/swap stay balanced below
  self.buffer1:pushLevel(self.level)
  shader:start()
    Shader.SetTex2D('src', self.buffer0)
    Shader.SetTex1D('curve1', curve1)
    Shader.SetTex1D('curve2', curve2)
    Draw.Color(1, 1, 1, 1)
    Draw.Rect(0, 0, self.sx, self.sy)
  shader:stop()
  self.buffer1:pop()
  self:swap()
end

function Renderer:free ()
  if self.buffer0 then
    self.buffer0:free()
    self.buffer1:free()
    self.buffer2:free()
    self.uiBuffer:free()
    self.dsBuffer0:free()
    self.dsBuffer1:free()
    self.zBuffer:free()
    self.zBufferL:free()
    self.meterTex:free()
  end
end

function Renderer:present (x, y, sx, sy, useMips)
  Draw.Color(1, 1, 1, 1)
  RenderState.PushAllDefaults()
  -- NOTE : core-profile — program 0 has no fixed-function fallback, so the
  -- final window blit must run through an explicit passthrough shader.
  local shader = Cache.Shader('ui', 'filter/identity')
  if not shader then
    RenderState.PopAll()   -- item 4: balance PushAllDefaults above; render black this frame instead of crashing on a broken identity pass
    return end
  shader:start()
  if false and useMips then
    self.buffer0:genMipmap()
    self.buffer0:setMinFilter(TexFilter.LinearMipLinear)
    self.buffer0:draw(x, y + sy, sx, -sy)
    self.buffer0:setMinFilter(TexFilter.Linear)
  else
    Shader.SetTex2D('src', self.buffer0)
    self.buffer0:draw(x, y + sy, sx, -sy)
  end
  shader:stop()
  RenderState.PopAll()
end

function Renderer:presentAll (x, y, sx, sy)
  Draw.Color(1, 1, 1, 1)
  RenderState.PushAllDefaults()
  local shader = Cache.Shader('ui', 'filter/identity')
  if not shader then
    RenderState.PopAll()   -- item 4: balance PushAllDefaults above; render black this frame instead of crashing on a broken identity pass
    return end
  self.buffer0:draw(x, y + sy / 2, sx / 2, -sy / 2)
  self.buffer1:draw(x + sx / 2, y + sy / 2, sx / 2, -sy / 2)
  self.buffer2:draw(x, y + sy, sx / 2, -sy / 2)
  self.zBufferL:draw(x + sx / 2, y + sy, sx / 2, -sy / 2)
  shader:stop()
  RenderState.PopAll()
end

function Renderer:sharpen (radius, sigma, strength)
  Draw.Color(1, 1, 1, 1)

  do -- Blur (guarded, item 4)
    local shader = Cache.Shader('ui', 'filter/blur2d')
    if shader then
      self.buffer2:pushLevel(self.level)
      shader:start()
        Shader.SetInt('radius', radius)
        Shader.SetFloat('sigma', sigma)
        Shader.SetFloat2('size', self.sx, self.sy)
        Shader.SetTex2D('src', self.buffer0)
        Draw.Rect(0, 0, self.sx, self.sy)
      shader:stop()
      self.buffer2:pop()
    end
  end

  do -- High pass blend (guarded, item 4)
    local shader = Cache.Shader('ui', 'filter/sharpen')
    if shader then
      self.buffer1:pushLevel(self.level)
      shader:start()
        Shader.SetFloat('strength', strength)
        Shader.SetTex2D('src', self.buffer0)
        Shader.SetTex2D('srcBlur', self.buffer2)
        Draw.Rect(0, 0, self.sx, self.sy)
      shader:stop()
      self.buffer1:pop()
    end
  end

  self:swap()
end

function Renderer:start (resX, resY, ss)
  local ss = ss or 1
  local sx, sy = ss * resX, ss * resY
  if self.sx ~= sx or self.sy ~= sy or self.ss ~= ss then
    self.sx = sx
    self.sy = sy
    self.ss = ss
    self.resX = resX
    self.resY = resY

    if self.buffer0 then self:free() end

    self.buffer0 = createBuffer(sx, sy, colorFormat)
    self.buffer1 = createBuffer(sx, sy, colorFormat)
    self.buffer2 = createBuffer(sx, sy, colorFormat)
    self.uiBuffer = createBuffer(sx, sy, colorFormat)
    self.zBuffer = createBuffer(sx, sy, depthFormat)
    self.zBufferL = createBuffer(sx, sy, TexFormat.R32F)

    self.dsBuffer0 = createBuffer(resX / self.ds, resY / self.ds, colorFormat)
    self.dsBuffer1 = createBuffer(resX / self.ds, resY / self.ds, colorFormat)

    -- 1x1 exposure-meter texel (see Renderer:meter). Read back at ~10 Hz.
    self.meterTex = createBuffer(1, 1, colorFormat)
  end

  self.buffer0:setMipRange(0, 0)
  self.buffer1:setMipRange(0, 0)
  self.buffer2:setMipRange(0, 0)
  self.buffer0:setMinFilter(TexFilter.Linear)
  self.buffer1:setMinFilter(TexFilter.Linear)
  self.buffer2:setMinFilter(TexFilter.Linear)
  self.level = 0

  RenderTarget.Push(sx, sy)
  RenderTarget.BindTex2D(self.buffer0)
  RenderTarget.BindTex2D(self.buffer1)
  RenderTarget.BindTex2D(self.zBufferL)
  RenderTarget.BindTex2D(self.zBuffer)

  Draw.Clear(0, 0, 0, 0)
  Draw.ClearDepth(1)
  Draw.Color(1, 1, 1, 1)
  BlendMode.Push(BlendMode.Disabled)
  CullFace.Push(Settings.get('render.cullface') and CullFace.Back or CullFace.None)
  RenderState.PushDepthTest(true)
end

function Renderer:startAlpha (mode)
  RenderTarget.Push(self.sx, self.sy)
  RenderTarget.BindTex2D(self.buffer0)
  RenderTarget.BindTex2D(self.zBuffer)

  BlendMode.Push(mode)
  CullFace.Push(CullFace.None)
  RenderState.PushDepthTest(true)
  RenderState.PushDepthWritable(false)
end

function Renderer:startPostEffects ()
  -- Post effects run at the same resolution as the composited scene (level 0).
  -- The old ss>1 path shifted the chain into mip level 1 via pushLevel/setMipRange;
  -- that level did not exist on the render buffers (incomplete FBO -> the chain
  -- silently no-oped and the final present sampled undefined mip data). The
  -- full-chain post passes therefore draw to the ACTUAL buffer size (self.sx/sy,
  -- = ss*res at supersample) rather than the logical resX/resY -- drawing a 1x
  -- rect into a 2x buffer would only fill its bottom-left quarter each frame,
  -- leaving stale frames behind (visual mirror/feedback recursion at 2x).
end

function Renderer:startUI (tex)
  -- UI content goes into a dedicated target so it can either be folded into the
  -- scene immediately (legacy: stopUI) or parked and overlaid AFTER the post
  -- chain (game: endUI + compositeUI) so the HUD/debug panel stays crisp and is
  -- not affected by tonemap/exposure/bloom/vignette/sharpen/grain.
  self.uiTex = tex or self.buffer1
  RenderTarget.Push(self.sx, self.sy)
  RenderTarget.BindTex2D(self.uiTex)
  RenderTarget.BindTex2D(self.zBuffer)
  Draw.Clear(0, 0, 0, 0)
  BlendMode.Push(BlendMode.Alpha)
  CullFace.Push(CullFace.None)
  RenderState.PushDepthTest(false)
  RenderState.PushDepthWritable(false)
end

function Renderer:endUI ()
  if not self.uiTex then return end
  self.uiTex:pop()
  BlendMode.Pop()
  CullFace.Pop()
  RenderState.PopDepthTest()
  RenderState.PopDepthWritable()
end

-- Layer the UI target onto the current scene buffer (buffer0), then swap it
-- into place. post=true when buffer0 is already a finalized display-space
-- picture (after tonemap): straight alpha overlay so UI colors are not re-gamma'd.
function Renderer:compositeUI (post)
  if not self.uiTex then return end
  local shader = Cache.Shader('ui', post and 'filter/ui_overlay' or 'ui/composite')
  BlendMode.PushDisabled()
  self.buffer2:push()
  if shader then -- item 4: skip a broken composite, still restore buffer state
    shader:start()
      Shader.SetTex2D('srcBottom', self.buffer0)
      Shader.SetTex2D('srcTop', self.uiTex)
      Draw.Color(1, 1, 1, 1)
      Draw.Rect(0, 0, self.sx, self.sy)
    shader:stop()
  end
  self.buffer2:pop()
  self.buffer2, self.buffer0 = self.buffer0, self.buffer2
  BlendMode.Pop()
end

function Renderer:stopUI ()
  -- Legacy behavior: draw the UI, then composite it into the scene immediately
  -- (before the post chain). Test apps use this; the game uses
  -- startUI/endUI + compositeUI(post=true) instead.
  self:endUI()
  self:compositeUI()
end

function Renderer:stop ()
  BlendMode.Pop()
  CullFace.Pop()
  RenderState.PopDepthTest()
  RenderTarget.Pop()
end

function Renderer:stopAlpha ()
  BlendMode.Pop()
  CullFace.Pop()
  RenderState.PopDepthTest()
  RenderState.PopDepthWritable()
  RenderTarget.Pop()
end

function Renderer:stopUI ()
  -- Legacy behavior: draw the UI, then composite it into the scene immediately
  -- (before the post chain). Test apps use this; the game uses
  -- endUI + compositeUI(post=true) instead.
  self:endUI()
  self:compositeUI()
end

function Renderer:swap ()
  self.buffer0, self.buffer1 = self.buffer1, self.buffer0
end

--[[
  meter -- sample the pre-tonemap HDR scene, every frame, into a 1x1 texel.
  ----------------------------------------------------------------------------
  One tiny reduce pass (4096 scatter taps inside a single fragment) writes
  avg/max/%over/lit — see res/shader/fragment/filter/exposure.glsl. The texel
  is read back on a ~100 ms throttle (glGetTexImage forces a GPU sync; 10 Hz is
  plenty for both the DebugWindow readout and auto-exposure adaptation). The
  numbers live in `self.exposure`; the debug panel polls them.
]]---------------------------------------------------------------------------
function Renderer:meter ()
  local shader = Cache.Shader('ui', 'filter/exposure')
  if not (shader and self.meterTex) then return end

  self.frameSeed = (self.frameSeed + 1) % 4096
  do -- Render the meter texel (target is 1x1, so unit-rect the quad).
    self.meterTex:pushLevel(0)
    shader:start()
      Shader.SetFloat2('size', self.sx, self.sy)
      Shader.SetFloat('timeSeed', self.frameSeed + 1)
      Shader.SetTex2D('src', self.buffer0)
      Draw.Color(1, 1, 1, 1)
      Draw.Rect(0, 0, 1, 1)
    shader:stop()
    self.meterTex:pop()
  end

  local now = Time.GetRaw()
  if now - self.meterLast >= 100 then
    self.meterLast = now
    local b = self.meterTex:getDataBytes(PixelFormat.RGBA, DataFormat.Float):managed()
    self.exposure.avg  = b:readF32()
    self.exposure.max  = b:readF32()
    self.exposure.over = b:readF32()
    self.exposure.lit  = b:readF32()
  end
end

--[[
  autoExposureEV -- target EV from the meter, smoothed over time.
  ----------------------------------------------------------------------------
  Key the lit-content luminance `exposure.lit` to a mid-gray key (default
  0.18 linear) so "key <-> 0 stops". EV = log2(lit) - log2(key), clamped to
  [minEV, maxEV]. The manual Exposure EV slider acts as an offset/bias on top.
  The value eases toward target with a per-frame exponential (time constant
  `speed` seconds) so changes read as eye adaptation rather than stepping.
]]---------------------------------------------------------------------------
function Renderer:autoExposureEV ()
  local ex = self.exposure or { lit = 0 }
  local key = Settings.get('postfx.autoexposure.key') or 0.18
  local minEV = Settings.get('postfx.autoexposure.minEV') or -6
  local maxEV = Settings.get('postfx.autoexposure.maxEV') or 2
  local speed = Settings.get('postfx.autoexposure.speed') or 0.5
  local l = ex.lit or 0

  local l2 = math.log(2)
  local target = minEV
  if l > 1e-5 then
    target = (math.log(l) - math.log(key)) / l2
    if target < minEV then target = minEV end
    if target > maxEV then target = maxEV end
  end

  -- Smooth toward target (eye-adaptation feel). dt computed from the ticker
  -- since Renderer has no update loop of its own.
  local now = Time.GetRaw()
  local dt = 0
  if self.autoTime then dt = (now - self.autoTime) / 1000.0 end
  self.autoTime = now
  if dt > 0.25 then dt = 0.25 end   -- clamp pauses/load stalls

  local ev = self.autoEV or 0
  if dt > 0 then
    local t = 1.0 - math.exp(-dt / math.max(0.05, speed))
    ev = ev + (target - ev) * t
  else
    ev = target
  end
  self.autoEV = ev
  return ev
end

function Renderer:tonemap ()
  local shader = Cache.Shader('ui', 'filter/tonemap')
  if not shader then return end   -- item 4: skip broken pass; buffer push/pop/swap stay balanced below
  self.buffer1:pushLevel(self.level)
  shader:start()
    Shader.SetInt('texOp', Settings.get('postfx.tonemap.operator') or 1)
    local ev = Settings.get('postfx.exposure.ev') or 0
    if Settings.get('postfx.autoexposure.enable') then
      -- Manual EV becomes a bias applied on top of the auto exposure.
      ev = ev + self:autoExposureEV()
    end
    Shader.SetFloat('exposure', 2.0 ^ ev)
    Shader.SetTex2D('src', self.buffer0)
    Draw.Color(1, 1, 1, 1)
    Draw.Rect(0, 0, self.sx, self.sy)
  shader:stop()
  self.buffer1:pop()
  self:swap()
end

function Renderer:vignette ()
  local strength = Settings.get('postfx.vignette.strength') or 0.5
  local hardness = Settings.get('postfx.vignette.hardness') or 8.0
  local shader = Cache.Shader('ui', 'filter/vignette')
  if not shader then return end   -- item 4: skip broken pass; buffer push/pop/swap stay balanced below
  self.buffer1:pushLevel(self.level)
  shader:start()
    Shader.SetFloat('strength', strength)
    Shader.SetFloat('hardness', hardness)
    Shader.SetTex2D('src', self.buffer0)
    Draw.Color(1, 1, 1, 1)
    Draw.Rect(0, 0, self.sx, self.sy)
  shader:stop()
  self.buffer1:pop()
  self:swap()
end

function Renderer:grain (strength)
  local shader = Cache.Shader('ui', 'filter/grain')
  if not shader then return end   -- item 4: skip broken pass; buffer push/pop/swap stay balanced below
  self.buffer1:pushLevel(self.level)
  shader:start()
    Shader.SetFloat('strength', strength)
    Shader.SetFloat('time', (tonumber(Time.GetRaw()) or 0) * 0.001)
    Shader.SetFloat2('size', self.sx, self.sy)
    Shader.SetTex2D('src', self.buffer0)
    Draw.Color(1, 1, 1, 1)
    Draw.Rect(0, 0, self.sx, self.sy)
  shader:stop()
  self.buffer1:pop()
  self:swap()
end

local filterModes = {
  [1] = { min = TexFilter.Linear,          mag = TexFilter.Linear, aniso = 0,  mip = false },
  [2] = { min = TexFilter.LinearMipLinear, mag = TexFilter.Linear, aniso = 0,  mip = true },
  [3] = { min = TexFilter.LinearMipLinear, mag = TexFilter.Linear, aniso = 16, mip = true },
}

function Renderer:setTextureFilter (mode)
  Cache.filterMode = filterModes[mode] or filterModes[3]
  if Cache.applyFilterMode then Cache.applyFilterMode() end
  if Material and Material.applyFilterMode then Material.applyFilterMode() end
end

return Renderer
