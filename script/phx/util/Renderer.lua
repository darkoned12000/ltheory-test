local Cache = require('phx.util.Cache')

-- TODO JP : Refactor all of this monolithic nonsense into RenderPass objects.

--------------------------------------------------------------------------------
-- Settings registration + GPU config seeding
--------------------------------------------------------------------------------
-- Each row below is the single source of truth for one Settings.add*() entry.
-- It replaces three things that used to live separately (and could drift out
-- of sync with each other): the Settings.add* call itself, the flat seed(...)
-- call that pulled a matching value out of Config.gpu, and -- for enums -- a
-- hand-written {label = index} lookup table used only to translate a GPU
-- config string into the right Settings.addEnum index.
--
-- Reordering an enum's displayed options (e.g. changing the AO quality list
-- from {Off,Half,Quarter} to something else) now automatically updates the
-- index used for GPU seeding, because the index is derived from the SAME
-- `options` array passed to Settings.addEnum, not a separate copy.
--
-- Fields:
--   kind    : 'bool' | 'float' | 'enum'
--   key     : Settings key, e.g. 'postfx.bloom.enable'
--   label   : display label passed straight to Settings.add*
--   default : default value (enum default is an option INDEX, as before)
--   gpu     : Config.gpu field name this is seeded from (nil = not GPU-seedable)
--   min/max : bounds, 'float' only
--   options : option label array, 'enum' only
--   optKey  : OPTIONAL function(rawGpuValue) -> option label string. Use this
--             when the raw Config.gpu value isn't already spelled exactly like
--             one of `options` (numbers vs. string labels, alternate spellings
--             like "Anisotropic" vs. "Aniso", etc). Defaults to identity.
--------------------------------------------------------------------------------

local function idKey (v) return v end
local function strKey (v) return v ~= nil and tostring(v) or nil end

local SETTINGS = {
  -- Post FX -------------------------------------------------------------------
  { kind = 'bool',  key = 'postfx.aberration.enable',   label = 'Aberration',   default = false, gpu = 'aberration' },
  { kind = 'float', key = 'postfx.aberration.strength', label = ' - Strength',  default = 1, min = 0, max = 1, gpu = 'aberrationStrength' },

  { kind = 'bool',  key = 'postfx.bloom.enable',        label = 'Bloom',        default = true,  gpu = 'bloom' },
  { kind = 'float', key = 'postfx.bloom.radius',        label = ' - Radius',    default = 48, min = 4, max = 64, gpu = 'bloomRadius' },
  { kind = 'float', key = 'postfx.bloom.intensity',     label = ' - Intensity', default = 1, min = 0, max = 4, gpu = 'bloomIntensity' },
  { kind = 'float', key = 'postfx.bloom.threshold',     label = ' - Threshold', default = 1, min = 0, max = 8, gpu = 'bloomThreshold' },

  { kind = 'bool',  key = 'postfx.sharpen.enable',      label = 'Sharpen',      default = true, gpu = 'sharpen' },
  { kind = 'float', key = 'postfx.sharpen.strength',    label = ' - Strength',  default = 1, min = 0, max = 3, gpu = 'sharpenStrength' },
  { kind = 'float', key = 'postfx.sharpen.radius',      label = ' - Radius',    default = 2, min = 1, max = 6, gpu = 'sharpenRadius' },

  { kind = 'bool',  key = 'postfx.radialblur.enable',    label = 'RadialBlur',   default = false, gpu = 'radialblur' },
  { kind = 'float', key = 'postfx.radialblur.strength',  label = ' - Strength',  default = 1, min = 0, max = 1, gpu = 'radialblurStrength' },
  { kind = 'float', key = 'postfx.radialblur.scanlines', label = ' - Scanlines', default = 1, min = 0, max = 1, gpu = 'radialblurScanlines' },

  { kind = 'bool',  key = 'postfx.tonemap.enable',    label = 'Tonemap',       default = true, gpu = 'tonemap' },
  { kind = 'enum',  key = 'postfx.tonemap.operator',  label = ' - Operator',   default = 1,
    options = { 'AgX', 'ACES', 'Filmic', 'Khronos' }, gpu = 'tonemapOperator' },
  { kind = 'float', key = 'postfx.exposure.ev',       label = ' - Exposure EV', default = 0, min = -4, max = 4, gpu = 'exposureEV' },

  -- Color Grading Micro-Knobs (Roadmap #14)
  { kind = 'float', key = 'postfx.color.sat',       label = ' - Saturation',  default = 1.0, min = 0, max = 3, gpu = 'colorSat' },
  { kind = 'float', key = 'postfx.color.contrast',  label = ' - Contrast',    default = 1.0, min = 0, max = 3, gpu = 'colorContrast' },
  { kind = 'float', key = 'postfx.color.temp',      label = ' - Temp (W/C)',  default = 0.0, min = -1, max = 1, gpu = 'colorTemp' },
  { kind = 'float', key = 'postfx.color.tint',      label = ' - Tint (M/G)',  default = 0.0, min = -1, max = 1, gpu = 'colorTint' },

  { kind = 'bool',  key = 'postfx.autoexposure.enable', label = 'Auto-Exposure',    default = false, gpu = 'autoExposure' },
  { kind = 'float', key = 'postfx.autoexposure.key',    label = ' - Key (mid-gray)', default = 0.18, min = 0.02, max = 1, gpu = 'autoExposureKey' },
  { kind = 'float', key = 'postfx.autoexposure.minEV',  label = ' - Min EV',        default = -6, min = -8, max = 2, gpu = 'autoExposureMinEV' },
  { kind = 'float', key = 'postfx.autoexposure.maxEV',  label = ' - Max EV',        default = 2, min = -8, max = 4, gpu = 'autoExposureMaxEV' },
  { kind = 'float', key = 'postfx.autoexposure.speed',  label = ' - Adapt (s)',     default = 0.5, min = 0.05, max = 3, gpu = 'autoExposureSpeed' },

  { kind = 'bool',  key = 'postfx.vignette.enable',   label = 'Vignette',    default = true, gpu = 'vignette' },
  { kind = 'float', key = 'postfx.vignette.strength', label = ' - Strength', default = 0.25, min = 0, max = 1, gpu = 'vignetteStrength' },
  { kind = 'float', key = 'postfx.vignette.hardness', label = ' - Hardness', default = 20.0, min = 2, max = 32, gpu = 'vignetteHardness' },

  { kind = 'bool',  key = 'postfx.grain.enable',   label = 'Film Grain', default = false, gpu = 'grain' },
  { kind = 'float', key = 'postfx.grain.strength', label = ' - Amount',  default = 1, min = 0, max = 4, gpu = 'grainStrength' },

  { kind = 'bool',  key = 'postfx.fog.enable',  label = 'Distance Haze', default = false, gpu = 'fogEnable' },
  { kind = 'float', key = 'postfx.fog.density', label = ' - Density',    default = 0.000005, min = 0, max = 0.0005, gpu = 'fogDensity' },
  { kind = 'float', key = 'postfx.fog.tint',    label = ' - Tint',       default = 0.15, min = 0, max = 1, gpu = 'fogTint' },
  { kind = 'float', key = 'postfx.fog.maxHaze', label = ' - Max Haze',   default = 0.95, min = 0, max = 1, gpu = 'fogMaxHaze' },
  { kind = 'float', key = 'postfx.fog.r',       label = ' - Color R',    default = 0.04, min = 0, max = 1, gpu = 'fogR' },
  { kind = 'float', key = 'postfx.fog.g',       label = ' - Color G',    default = 0.06, min = 0, max = 1, gpu = 'fogG' },
  { kind = 'float', key = 'postfx.fog.b',       label = ' - Color B',    default = 0.13, min = 0, max = 1, gpu = 'fogB' },

  { kind = 'bool',  key = 'nebula.enable',  label = 'Nebula Volume', default = false, gpu = 'nebulaEnabled' },
  { kind = 'enum',  key = 'nebula.quality', label = ' - Quality',    default = 2,
    options = { 'Off', 'Low', 'Medium', 'High' }, gpu = 'nebulaQuality' },
  { kind = 'enum',  key = 'nebula.debug',   label = ' - Debug View', default = 1,
    options = { 'Off', 'Density', 'Transmittance', 'Lighting', 'Steps', 'Anchors' }, gpu = 'nebulaDebug' },
  { kind = 'float', key = 'nebula.density', label = ' - Density',    default = 1, min = 0, max = 4, gpu = 'nebulaDensity' },
  { kind = 'float', key = 'nebula.radius',  label = ' - Radius',     default = 12000, min = 500, max = 40000, gpu = 'nebulaRadius' },
  { kind = 'float', key = 'nebula.g',       label = ' - Phase g',    default = 0, min = -1, max = 1, gpu = 'nebulaG' },
  { kind = 'float', key = 'nebula.tint',    label = ' - Glow Tint',  default = 0.0, min = 0, max = 1, gpu = 'nebulaTint' },
  { kind = 'float', key = 'nebula.tintR',   label = '   Color R',    default = 1.0, min = 0, max = 1, gpu = 'nebulaTintR' },
  { kind = 'float', key = 'nebula.tintG',   label = '   Color G',    default = 1.0, min = 0, max = 1, gpu = 'nebulaTintG' },
  { kind = 'float', key = 'nebula.tintB',   label = '   Color B',    default = 1.0, min = 0, max = 1, gpu = 'nebulaTintB' },

  -- Core render -----------------------------------------------------------
  { kind = 'float', key = 'render.fovY',        label = 'FOV',           default = 70, min = 50, max = 100 },
  { kind = 'enum',  key = 'render.superSample', label = 'SuperSampling', default = 2,
    options = { 'Off', '2x', '4x' }, gpu = 'superSample' },
  { kind = 'bool',  key = 'render.wireframe',   label = 'Wireframe',             default = false },
  { kind = 'bool',  key = 'render.cullface',    label = 'Backface Culling',      default = true },
  { kind = 'bool',  key = 'render.showBuffers', label = 'Show Deferred Buffers', default = false },
  { kind = 'enum',  key = 'render.textureFilter', label = 'Texture Filter', default = 3,
    options = { 'Bilinear', 'Trilinear', 'Trilinear + Aniso' }, gpu = 'filtering',
    optKey = function (v)
      if v == 'Aniso' or v == 'Anisotropic' then return 'Trilinear + Aniso' end
      return v
    end },
  { kind = 'float', key = 'render.shadow.radius', label = 'Shadow Radius (PCF)', default = 2, min = 0, max = 8 },
  { kind = 'float', key = 'render.shadow.bias',   label = 'Shadow Bias',         default = 0.001, min = -0.01, max = 0.1 },
  { kind = 'float', key = 'render.shadow.scale',  label = 'Shadow Dist Scale',   default = 0.0005, min = 0, max = 0.01 },

  { kind = 'bool',  key = 'render.sun.enable',    label = 'Sun Light',       default = true, gpu = 'sunLight' },
  { kind = 'float', key = 'render.sun.intensity', label = ' - Intensity',    default = 1, min = 0, max = 6, gpu = 'sunIntensity' },
  { kind = 'float', key = 'render.sun.fill',      label = ' - Ambient Fill', default = 0.30, min = 0, max = 1, gpu = 'sunAmbientFill' },
  { kind = 'float', key = 'render.sun.warmth',    label = ' - Warmth',       default = 1, min = 0, max = 1, gpu = 'sunWarmth' },
  { kind = 'bool',  key = 'render.sun.shadows',   label = ' - Shadows',      default = true, gpu = 'sunShadows' },
  { kind = 'float', key = 'render.sun.shadowRange', label = ' - Shadow Range', default = 8000, min = 500, max = 20000, gpu = 'sunShadowRange' },
  { kind = 'enum',  key = 'render.sun.shadowSize',  label = ' - Shadow Res',   default = 4,
    options = { '256', '512', '1024', '2048' }, gpu = 'sunShadowSize', optKey = strKey },

  { kind = 'bool',  key = 'render.vsync', label = 'VSync', default = true },

  { kind = 'float', key = 'lighting.ambientEnv', label = 'Environment Light',   default = 1.35, min = 0, max = 3, gpu = 'ambientEnv' },
  { kind = 'float', key = 'lighting.specular',   label = 'Dielectric Specular', default = 0.35, min = 0, max = 1, gpu = 'dielectricSpec' },

  -- SSAO / GTAO -------------------------------------------------------------
  { kind = 'bool',  key = 'ssao.enable',      label = 'Ambient Occlusion', default = false, gpu = 'aoEnabled' },
  { kind = 'enum',  key = 'ssao.quality',     label = ' - Resolution',     default = 2,
    options = { 'Off', 'Half', 'Quarter' }, gpu = 'aoQuality' },
  { kind = 'float', key = 'ssao.radius',      label = ' - Radius',         default = 500, min = 0.1, max = 4000, gpu = 'aoRadius' },
  { kind = 'float', key = 'ssao.intensity',   label = ' - Intensity',      default = 1.5, min = 0, max = 3, gpu = 'aoIntensity' },
  { kind = 'float', key = 'ssao.fillOcclude', label = ' - Fill Occlude',   default = 1, min = 0, max = 1, gpu = 'fillOcclude' },
  { kind = 'enum',  key = 'ssao.directions',  label = ' - Directions',     default = 2,
    options = { '2', '4', '6', '8' }, gpu = 'aoDirections', optKey = strKey },
  { kind = 'enum',  key = 'ssao.steps',       label = ' - Steps',          default = 2,
    options = { '2', '3', '4', '6' }, gpu = 'aoSteps', optKey = strKey },
  { kind = 'float', key = 'ssao.thickness',   label = ' - Thickness',      default = 0.25, min = 0, max = 1, gpu = 'aoThickness' },
  { kind = 'enum',  key = 'ssao.blur',        label = ' - Denoise',        default = 2,
    options = { '0', '1', '2' }, gpu = 'aoBlur', optKey = strKey },
  { kind = 'bool',  key = 'ssao.show',        label = ' - Show',           default = false },
}

for _, s in ipairs(SETTINGS) do
  if s.kind == 'bool' then
    Settings.addBool(s.key, s.label, s.default)
  elseif s.kind == 'float' then
    Settings.addFloat(s.key, s.label, s.default, s.min, s.max)
  elseif s.kind == 'enum' then
    Settings.addEnum(s.key, s.label, s.default, s.options)
    s.optionIndex = {}
    for i, name in ipairs(s.options) do s.optionIndex[name] = i end
  end
end

local function seedFromGpu (gpu)
  for _, s in ipairs(SETTINGS) do
    if s.gpu and Settings.exists(s.key) then
      local raw = gpu[s.gpu]
      if raw ~= nil then
        if s.kind == 'enum' then
          local optKey = s.optKey or idKey
          local idx = s.optionIndex[optKey(raw)]
          if idx then Settings.set(s.key, idx) end
        else
          Settings.set(s.key, raw)
        end
      end
    end
  end
end

--------------------------------------------------------------------------------

local Renderer = class(function (self)
  self.ds = 4

  seedFromGpu((Config and Config.gpu) or {})

  if Settings.exists('render.vsync') and Config and Config.render and Config.render.vsync ~= nil then
    Settings.set('render.vsync', Config.render.vsync)
  end

  self.exposure   = { avg = 0, max = 0, over = 0, lit = 0 }
  self.meterLast  = 0
  self.frameSeed  = 0
  self.autoEV     = 0
end)

local colorFormat = TexFormat.RGBA16F
local depthFormat = TexFormat.Depth32F

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

--------------------------------------------------------------------------------
function Renderer:applyFilter (frag, onSetVars)
  local shader = Cache.Shader('ui', 'filter/' .. frag)
  if not shader then return end
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

function Renderer:aberration (strength)
  Draw.Color(1, 1, 1, 1)
  self:applyFilter('aberration', function ()
    Shader.SetFloat('strength', strength)
  end)
end

function Renderer:tonemap ()
  self:applyFilter('tonemap', function ()
    Shader.SetInt('texOp', Settings.get('postfx.tonemap.operator') or 1)
    local ev = Settings.get('postfx.exposure.ev') or 0
    if Settings.get('postfx.autoexposure.enable') then
      ev = ev + self:autoExposureEV()
    end
    Shader.SetFloat('exposure', 2.0 ^ ev)

    -- Color Grading Micro-Knobs (Roadmap #14)
    Shader.SetFloat('colorSat',      Settings.get('postfx.color.sat') or 1.0)
    Shader.SetFloat('colorContrast', Settings.get('postfx.color.contrast') or 1.0)
    Shader.SetFloat('colorTemp',     Settings.get('postfx.color.temp') or 0.0)
    Shader.SetFloat('colorTint',     Settings.get('postfx.color.tint') or 0.0)
  end)
end

function Renderer:vignette ()
  local strength = Settings.get('postfx.vignette.strength') or 0.5
  local hardness = Settings.get('postfx.vignette.hardness') or 8.0
  self:applyFilter('vignette', function ()
    Shader.SetFloat('strength', strength)
    Shader.SetFloat('hardness', hardness)
  end)
end

function Renderer:grain (strength)
  self:applyFilter('grain', function ()
    Shader.SetFloat('strength', strength)
    Shader.SetFloat('time', (tonumber(Time.GetRaw()) or 0) * 0.001)
    Shader.SetFloat2('size', self.sx, self.sy)
  end)
end

function Renderer:colorGrade (curve1, curve2)
  self:applyFilter('colorgrade', function ()
    Shader.SetTex1D('curve1', curve1)
    Shader.SetTex1D('curve2', curve2)
  end)
end

function Renderer:blur (dst, src, dx, dy, radius)
  local shader = Cache.Shader('ui', 'filter/blur')
  if not shader then return end
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

function Renderer:sharpen (radius, sigma, strength)
  Draw.Color(1, 1, 1, 1)

  do -- Blur
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

  do -- High pass blend
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

function Renderer:bloom (radius)
  Draw.Color(1, 1, 1, 1)
  local A = self.dsBuffer0
  local B = self.dsBuffer1
  local threshold = Settings.get('postfx.bloom.threshold') or 1.0
  local intensity = Settings.get('postfx.bloom.intensity') or 1.0
  local knee = threshold * 0.5

  local baseW = self.resX / self.ds
  local baseH = self.resY / self.ds

  local mips = 1
  while mips < 12 and math.floor(baseW / (2 ^ mips)) >= 2 and math.floor(baseH / (2 ^ mips)) >= 2 do
    mips = mips + 1
  end
  local levels = math.max(2, math.min(mips, 4 + math.floor(radius / 8)))

  do -- Prefilter
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

  do -- Downsample
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

  do -- Seed accumulation
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

  do -- Progressive upsample
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

  do -- Composite bloom
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

  A:setMipRange(0, 0)
  B:setMipRange(0, 0)
  A:setMinFilter(TexFilter.Linear)
  B:setMinFilter(TexFilter.Linear)
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

  if self.volView then
    self.volView:free()
    self.volView = nil
  end
  if self.texAnchors then
    self.texAnchors:free()
    self.texAnchors = nil
  end
  if self.anchorBytes then
    self.anchorBytes:free()
    self.anchorBytes = nil
  end
end

function Renderer:present (x, y, sx, sy, useMips)
  Draw.Color(1, 1, 1, 1)
  RenderState.PushAllDefaults()
  local shader = Cache.Shader('ui', 'filter/identity')
  if not shader then
    RenderState.PopAll()
    return
  end
  shader:start()
    Shader.SetTex2D('src', self.buffer0)
    self.buffer0:draw(x, y + sy, sx, -sy)
  shader:stop()
  RenderState.PopAll()
end

function Renderer:presentAll (x, y, sx, sy)
  Draw.Color(1, 1, 1, 1)
  RenderState.PushAllDefaults()
  local shader = Cache.Shader('ui', 'filter/identity')
  if not shader then
    RenderState.PopAll()
    return
  end
  shader:start()
    self.buffer0:draw(x, y + sy / 2, sx / 2, -sy / 2)
    self.buffer1:draw(x + sx / 2, y + sy / 2, sx / 2, -sy / 2)
    self.buffer2:draw(x, y + sy, sx / 2, -sy / 2)
    self.zBufferL:draw(x + sx / 2, y + sy, sx / 2, -sy / 2)
  shader:stop()
  RenderState.PopAll()
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
end

function Renderer:startUI (tex)
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

function Renderer:compositeUI (post)
  if not self.uiTex then return end
  local shader = Cache.Shader('ui', post and 'filter/ui_overlay' or 'ui/composite')
  BlendMode.PushDisabled()
  self.buffer2:push()
  if shader then
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

function Renderer:swap ()
  self.buffer0, self.buffer1 = self.buffer1, self.buffer0
end

function Renderer:meter ()
  local shader = Cache.Shader('ui', 'filter/exposure')
  if not (shader and self.meterTex) then return end

  self.frameSeed = (self.frameSeed + 1) % 4096
  do
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

  local now = Time.GetRaw()
  local dt = 0
  if self.autoTime then dt = (now - self.autoTime) / 1000.0 end
  self.autoTime = now
  if dt > 0.25 then dt = 0.25 end

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

function Renderer:volume (med)
  local q = Settings.get('nebula.quality') or 1
  if q <= 1 then return end
  local steps = { 8, 16, 24 }
  local evals = { 2, 2, 3 }
  local stepF = steps[q - 1] or 16
  local evalF = evals[q - 1] or 2

  local shaderH = Cache.Shader('worldray', 'filter/volume')
  local shaderF = Cache.Shader('worldray', 'filter/volblur')
  if not (shaderH and shaderF) then return end

  local volW = math.max(1, math.floor(self.sx / 2))
  local volH = math.max(1, math.floor(self.sy / 2))
  local volMip = 1.0

  if not self.volView or self.volView:getSize().x ~= volW then
    if self.volView then self.volView:free() end
    self.volView = Tex2D.Create(volW, volH, TexFormat.RGBA16F)
    self.volView:setMagFilter(TexFilter.Linear)
    self.volView:setMinFilter(TexFilter.Linear)
    self.volView:setWrapMode(TexWrapMode.Clamp)
    self.volView:push()
    Draw.Clear(0, 0, 0, 0)
    self.volView:pop()
  end

  local anchors = med.anchors
  local volCount = anchors and #anchors or 0
  if volCount > 0 then
    if not self.texAnchors then
      self.texAnchors = Tex2D.Create(3, 16, TexFormat.RGBA32F)
      self.texAnchors:setMagFilter(TexFilter.Linear)
      self.texAnchors:setMinFilter(TexFilter.Linear)
      self.texAnchors:setWrapMode(TexWrapMode.Clamp)
    end
    if not self.anchorBytes then
      self.anchorBytes = Bytes.Create(48 * 16)
    end

    local bytes = self.anchorBytes
    local p = ffi.cast('float*', bytes:getData())
    for i = 1, volCount do
      local a = anchors[i]
      local o = (i - 1) * 12
      p[o + 0], p[o + 1], p[o + 2], p[o + 3]  = a[1], a[2], a[3], a[4]
      p[o + 4], p[o + 5], p[o + 6], p[o + 7]  = a[5], a[6], a[7], 0
      p[o + 8], p[o + 9], p[o + 10], p[o + 11] = a[8], a[9], a[10], 0
    end
    self.texAnchors:setDataBytes(bytes, PixelFormat.RGBA, DataFormat.Float)
  end

  local dens = Settings.get('nebula.density') or 1
  local sigT = dens * 0.00005
  local sigS = dens * 0.0000375
  local volDist   = Settings.get('nebula.radius') or 12000
  local volAniso  = Settings.get('nebula.g') or 0
  local tintAmt   = Settings.get('nebula.tint') or 0.35
  local tintR, tintG, tintB = Settings.get('nebula.tintR') or 1,
                              Settings.get('nebula.tintG') or 0.6,
                              Settings.get('nebula.tintB') or 0.2
  local fx, fy, fz, fsp = 0.4, 0.2, 0.8, 40
  local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
  local volTime = (tonumber(Time.GetRaw()) or 0) * 0.001
  local volGather = 8.0 / (800.0 * 800.0)

  Profiler.Begin('Render.Volume')

  do -- Pass A
    RenderTarget.Push(volW, volH)
    RenderTarget.BindTex2D(self.volView)
    RenderState.PushDepthTest(false)
    shaderH:start()
      Shader.SetTex2D('texDepth', self.zBufferL)
      Shader.SetTexCube('envMap', med.envMap)
      Shader.SetTexCube('irMap',  med.irMap)
      Shader.SetTex2D('texNoise', med.noise)
      Shader.SetFloat3('starDir',  med.starDir.x, med.starDir.y, med.starDir.z)
      Shader.SetFloat3('sunColor', med.sunColor.x, med.sunColor.y, med.sunColor.z)
      Shader.SetFloat('volMip',    volMip)
      Shader.SetFloat('volDensity', dens)
      Shader.SetFloat('volSigmaT',  sigT)
      Shader.SetFloat('volSigmaS',  sigS)
      Shader.SetFloat('volSteps',   stepF)
      Shader.SetFloat('volDist',    volDist)
      Shader.SetFloat('volEvals',   evalF)
      Shader.SetFloat3('volFlow', 40 * fx / fl, 40 * fy / fl, 40 * fz / fl)
      Shader.SetFloat('volTime',    volTime)
      Shader.SetFloat('volCount',   volCount)
      if volCount > 0 then Shader.SetTex2D('texAnchors', self.texAnchors) end
      Shader.SetFloat('volAniso',   volAniso)
      Shader.SetFloat3('volTint', tintR, tintG, tintB)
      Shader.SetFloat('volTintAmt', tintAmt)
      Draw.Color(1, 1, 1, 1)
      Draw.Rect(-1, -1, 2, 2)
    shaderH:stop()
    RenderState.PopDepthTest()
    RenderTarget.Pop()
  end

  do -- Pass B
    self.buffer1:pushLevel(self.level)
    RenderState.PushDepthTest(false)
    shaderF:start()
      Shader.SetInt('volMode', (Settings.get('nebula.debug') or 1) - 1)
      Shader.SetTex2D('texVol',   self.volView)
      Shader.SetTex2D('texScene', self.buffer0)
      Shader.SetTex2D('texDepth', self.zBufferL)
      Shader.SetFloat('volMip',    volMip)
      Shader.SetFloat('volGather', volGather)
      Shader.SetFloat('volDensity', dens)
      Shader.SetFloat('volSigmaT',  sigT)
      Shader.SetFloat('volSigmaS',  sigS)
      Shader.SetFloat('volSteps',   stepF)
      Shader.SetFloat('volDist',    volDist)
      Shader.SetFloat('volEvals',   evalF)
      Shader.SetFloat('volCount',   volCount)
      if volCount > 0 then Shader.SetTex2D('texAnchors', self.texAnchors) end
      Shader.SetFloat3('volFlow', 40 * fx / fl, 40 * fy / fl, 40 * fz / fl)
      Shader.SetFloat('volTime',    volTime)
      Shader.SetFloat3('volTint', tintR, tintG, tintB)
      Draw.Color(1, 1, 1, 1)
      Draw.Rect(-1, -1, 2, 2)
    shaderF:stop()
    RenderState.PopDepthTest()
    self.buffer1:pop()
    self:swap()
  end

  Profiler.End()
end

function Renderer:fog (envTex)
  local shader = Cache.Shader('worldray', 'filter/fogw')
  if not shader then return end
  self.buffer1:pushLevel(self.level)
  shader:start()
    Shader.SetFloat('fogDensity', Settings.get('postfx.fog.density') or 0.000005)
    Shader.SetFloat('fogTint', Settings.get('postfx.fog.tint') or 0.15)
    Shader.SetFloat('fogMax', Settings.get('postfx.fog.maxHaze') or 0.95)
    Shader.SetFloat3('fogColor',
      Settings.get('postfx.fog.r') or 0.04,
      Settings.get('postfx.fog.g') or 0.06,
      Settings.get('postfx.fog.b') or 0.13)
    Shader.SetTex2D('src', self.buffer0)
    Shader.SetTex2D('texDepth', self.zBufferL)
    Shader.SetTexCube('envMap', envTex)
    Draw.Color(1, 1, 1, 1)
    Draw.Rect(-1, -1, 2, 2)
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
