local Cache = require('phx.util.Cache')

-- TODO JP : Refactor all of this monolithic nonsense into RenderPass objects.

local Renderer = class(function (self)
  self.ds = 4

  -- GPU portability: seed post-processing from Config.gpu if present so a weak
  -- machine can drop the expensive bloom/sharpen passes at startup. Guarded by
  -- Settings.exists() so it's inert until Config.App.lua has defined the block.
  local gpu = (Config and Config.gpu) or {}
  if Settings.exists('postfx.bloom.enable') then
    Settings.set('postfx.bloom.enable', gpu.bloom ~= false)
  end
  if Settings.exists('postfx.sharpen.enable') then
    Settings.set('postfx.sharpen.enable', gpu.sharpen ~= false)
  end
end)

local colorFormat = TexFormat.RGBA16F
local depthFormat = TexFormat.Depth32F

Settings.addBool  ('postfx.aberration.enable',   'Aberration',  false)
Settings.addFloat ('postfx.aberration.strength', ' - Strength', 1, 0, 1)
Settings.addBool  ('postfx.bloom.enable',        'Bloom',       true)
Settings.addFloat ('postfx.bloom.radius',        ' - Radius',   48, 4, 64)
Settings.addBool  ('postfx.sharpen.enable',      'Sharpen',     true)
Settings.addBool  ('postfx.radialblur.enable',   'RadialBlur',  false)
Settings.addFloat ('postfx.radialblur.strength', ' - Strength', 1, 0, 1)
Settings.addFloat ('postfx.radialblur.scanlines', ' - Scanlines', 1, 0, 1)
Settings.addBool  ('postfx.tonemap.enable',      'Tonemap',     true)
Settings.addBool  ('postfx.vignette.enable',     'Vignette',    true)
Settings.addFloat ('postfx.vignette.strength',   ' - Strength', 0.25, 0, 1)
Settings.addFloat ('postfx.vignette.hardness',   ' - Hardness', 20.0, 2, 32)

Settings.addFloat ('render.fovY',        'FOV',                   70, 50, 100)
Settings.addFloat ('render.lodScale',    'LOD Scale',             0.3, 0.1, 1.0)
Settings.addEnum  ('render.superSample', 'SuperSampling',         2, { 'Off', '2x', '4x' })
Settings.addBool  ('render.wireframe',   'Wireframe',             false)
Settings.addBool  ('render.cullface',    'Backface Culling',      true)
Settings.addFloat ('render.logZNear',    'Log Z Near',            -1, -2, 3)
Settings.addFloat ('render.logZFar',     'Log Z Far',             7, 1, 8)
Settings.addBool  ('render.showBuffers', 'Show Deferred Buffers', false)
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
    Draw.Rect(0, 0, self.resX, self.resY)
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
    Draw.Rect(0, 0, self.resX, self.resY)
  shader:stop()
  self.buffer1:pop()
  self:swap()
end

function Renderer:bloom (radius)
  Draw.Color(1, 1, 1, 1)
  local width = radius * 0.2
  local A = self.dsBuffer0
  local B = self.dsBuffer1

  do -- bloompre: guarded (item 4) so a broken pass skips cleanly without leaving A un-pushed
    local shader = Cache.Shader('ui', 'filter/bloompre')
    if shader then
      A:push()
      shader:start()
        Shader.SetTex2D('src', self.buffer0)
        Draw.Rect(0, 0, self.resX / self.ds, self.resY / self.ds)
      shader:stop()
      A:pop()
    end
  end

  for i = 1, 3 do
    self:blur(B, A, 1, 0, radius, width)
    self:blur(A, B, 0, 1, radius, width)

    local shader = Cache.Shader('ui', 'filter/bloomcomposite')
    if shader then -- item 4: skip broken composite; blur loop above already guarded internally
      self.buffer1:pushLevel(self.level)
      shader:start()
        Shader.SetTex2D('src', self.buffer0)
        Shader.SetTex2D('srcBlur', A)
        Draw.Rect(0, 0, self.resX, self.resY)
      shader:stop()
      self.buffer1:pop()
      self:swap()
    end
  end
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
    Draw.Rect(0, 0, self.resX, self.resY)
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
        Shader.SetFloat2('size', self.resX, self.resY)
        Shader.SetTex2D('src', self.buffer0)
        Draw.Rect(0, 0, self.resX, self.resY)
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
        Draw.Rect(0, 0, self.resX, self.resY)
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
  if self.ss > 1 then
    -- Logarithmic downsample before post (we do not supersample post effects)
    local factor = 1
    self.level = 0
    while factor < self.ss do
      self.level = self.level + 1
      factor = factor * 2
      self.buffer1:pushLevel(self.level)
      -- NOTE : core-profile — explicit passthrough program (no fixed-function fallback)
      local dsShader = Cache.Shader('ui', 'filter/identity')
      if not dsShader then
        -- item 4: broken identity pass -> skip the downsample draw but keep buffer1 balanced
        self.buffer1:pop()
      else
        dsShader:start()
        self.buffer0:draw(0, 0, self.sx / factor, self.sy / factor)
        dsShader:stop()
        self.buffer1:pop()
      end

      -- Constrain all buffers to the new active mip level
      self.buffer0:setMipRange(self.level, self.level)
      self.buffer1:setMipRange(self.level, self.level)
      self.buffer2:setMipRange(self.level, self.level)
      self.buffer0:setMinFilter(TexFilter.LinearMipPoint)
      self.buffer1:setMinFilter(TexFilter.LinearMipPoint)
      self.buffer2:setMinFilter(TexFilter.LinearMipPoint)
      self:swap()
    end
  end
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
    Shader.SetInt('hdrOut', 0)
    Shader.SetFloat2('size', self.resX, self.resY)
    Shader.SetTex2D('src', self.buffer0)
    Draw.Color(1, 1, 1, 1)
    Draw.Rect(0, 0, self.resX, self.resY)
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
    Draw.Rect(0, 0, self.resX, self.resY)
  shader:stop()
  self.buffer1:pop()
  self:swap()
end

return Renderer
