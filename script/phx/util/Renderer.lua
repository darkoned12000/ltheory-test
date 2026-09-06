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
  seed('postfx.tonemap.enable',      gpu.tonemap)
  seed('postfx.exposure.ev',         gpu.exposureEV)
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

  local filterIdx = { Bilinear = 1, Trilinear = 2, Aniso = 3, Anisotropic = 3 }
  seed('render.textureFilter', filterIdx[gpu.filtering])

  local ssIdx = { ['Off'] = 1, ['2x'] = 2, ['4x'] = 3 }
  seed('render.superSample', ssIdx[gpu.superSample])

  local ops = { AgX = 1, ACES = 2, Filmic = 3, Khronos = 4 }
  seed('postfx.tonemap.operator', ops[gpu.tonemapOperator])
end)

local colorFormat = TexFormat.RGBA16F
local depthFormat = TexFormat.Depth32F

Settings.addBool  ('postfx.aberration.enable',   'Aberration',  false)
Settings.addFloat ('postfx.aberration.strength', ' - Strength', 1, 0, 1)
Settings.addBool  ('postfx.bloom.enable',        'Bloom',       true)
Settings.addFloat ('postfx.bloom.radius',        ' - Radius',   48, 4, 64)
Settings.addFloat ('postfx.bloom.intensity',     ' - Intensity', 1, 0, 4)
Settings.addFloat ('postfx.bloom.threshold',     ' - Threshold', 1, 0, 8)
Settings.addBool  ('postfx.sharpen.enable',      'Sharpen',     true)
Settings.addBool  ('postfx.radialblur.enable',   'RadialBlur',  false)
Settings.addFloat ('postfx.radialblur.strength', ' - Strength', 1, 0, 1)
Settings.addFloat ('postfx.radialblur.scanlines', ' - Scanlines', 1, 0, 1)
Settings.addBool  ('postfx.tonemap.enable',      'Tonemap',     true)
Settings.addEnum  ('postfx.tonemap.operator',    ' - Operator', 1, { 'AgX', 'ACES', 'Filmic', 'Khronos' })
Settings.addFloat ('postfx.exposure.ev',         ' - Exposure EV', 0, -4, 4)
Settings.addBool  ('postfx.vignette.enable',     'Vignette',    true)
Settings.addFloat ('postfx.vignette.strength',   ' - Strength', 0.25, 0, 1)
Settings.addFloat ('postfx.vignette.hardness',   ' - Hardness', 20.0, 2, 32)
Settings.addBool  ('postfx.grain.enable',        'Film Grain',  false)
Settings.addFloat ('postfx.grain.strength',      ' - Amount',   1, 0, 4)

Settings.addFloat ('render.fovY',        'FOV',                   70, 50, 100)
Settings.addFloat ('render.lodScale',    'LOD Scale',             0.3, 0.1, 1.0)
Settings.addEnum  ('render.superSample', 'SuperSampling',         2, { 'Off', '2x', '4x' })
Settings.addBool  ('render.wireframe',   'Wireframe',             false)
Settings.addBool  ('render.cullface',    'Backface Culling',      true)
Settings.addFloat ('render.logZNear',    'Log Z Near',            -1, -2, 3)
Settings.addFloat ('render.logZFar',     'Log Z Far',             7, 1, 8)
Settings.addBool  ('render.showBuffers', 'Show Deferred Buffers', false)
Settings.addEnum  ('render.textureFilter', 'Texture Filter', 3, { 'Bilinear', 'Trilinear', 'Trilinear + Aniso' })
Settings.addFloat ('render.shadow.radius', 'Shadow Radius (PCF)',   2, 0, 8)
Settings.addFloat ('render.shadow.bias',   'Shadow Bias',           0.001, -0.01, 0.1)
Settings.addFloat ('render.shadow.scale',  'Shadow Dist Scale',     0.0005, 0, 0.01)

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
    self.dsBuffer0:free()
    self.dsBuffer1:free()
    self.zBuffer:free()
    self.zBufferL:free()
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
    self.zBuffer = createBuffer(sx, sy, depthFormat)
    self.zBufferL = createBuffer(sx, sy, TexFormat.R32F)

    self.dsBuffer0 = createBuffer(resX / self.ds, resY / self.ds, colorFormat)
    self.dsBuffer1 = createBuffer(resX / self.ds, resY / self.ds, colorFormat)
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

function Renderer:startUI ()
  RenderTarget.Push(self.sx, self.sy)
  RenderTarget.BindTex2D(self.buffer1)
  RenderTarget.BindTex2D(self.zBuffer)
  Draw.Clear(0, 0, 0, 0)
  BlendMode.Push(BlendMode.Alpha)
  CullFace.Push(CullFace.None)
  RenderState.PushDepthTest(false)
  RenderState.PushDepthWritable(false)
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
  self.buffer1:pop()
  BlendMode.Pop()
  CullFace.Pop()
  RenderState.PopDepthTest()
  RenderState.PopDepthWritable()

  BlendMode.PushDisabled()
  self.buffer2:push()
  local shader = Cache.Shader('ui', 'ui/composite')
  if shader then -- item 4: broken composite -> skip the draw, but still pop + swap to keep buffer state balanced
    shader:start()
      Shader.SetTex2D('srcBottom', self.buffer0)
      Shader.SetTex2D('srcTop', self.buffer1)
      Draw.Color(1, 1, 1, 1)
      Draw.Rect(0, 0, self.sx, self.sy)
    shader:stop()
  end
  self.buffer2:pop()
  self.buffer2, self.buffer0 = self.buffer0, self.buffer2
  BlendMode.Pop()
end

function Renderer:swap ()
  self.buffer0, self.buffer1 = self.buffer1, self.buffer0
end

function Renderer:tonemap ()
  local shader = Cache.Shader('ui', 'filter/tonemap')
  if not shader then return end   -- item 4: skip broken pass; buffer push/pop/swap stay balanced below
  self.buffer1:pushLevel(self.level)
  shader:start()
    Shader.SetInt('texOp', Settings.get('postfx.tonemap.operator') or 1)
    Shader.SetFloat('exposure', 2.0 ^ (Settings.get('postfx.exposure.ev') or 0))
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
