local Palette = require('Gen.Nebula.Palette')

local Nebula = class(function (self, seed, starDir)
  self.seed = seed
  self.starDir = starDir
end)

function Nebula:forceLoad ()
  if self.envMap then return end
  -- Deterministic sector hue. Nebula1 (the IFS skybox, 90% of systems) refines
  -- this to the exact hue it generates; Nebula2 (light-transport) has no single
  -- hue, so this seed-derived value stands. Either way the plumes and the sky
  -- share one palette instead of the plumes picking random wheel hues.
  Palette.hue = RNG.Create(self.seed + 0x517E5ULL):managed():getUniform()
  local rng = RNG.Create(self.seed + 0xC0104FULL):managed()
  self.envMap = Gen.Generator.Get('Nebula', rng)(rng, Config.gen.nebulaRes, self.starDir):managed()
  self.hue = Palette.hue
  -- Deterministic irradiance convolution: same sector seed => byte-identical
  -- lighting every boot (this used to be RNG_FromTime(), the last nondeterminism
  -- in the render path -- see ltheory-planets.md 11.1a). Separate sub-seed from
  -- the envMap's so a change to one does not reshuffle the other.
  self.irMap = self.envMap:genIRMap(256, self.seed + 0x1A11EDULL):managed()
  self.stars = Gen.Starfield(rng, Config.gen.nStars(rng)):managed()
end

function Nebula:render (state)
  -- The skybox never casts a shadow; skip it entirely in the shadow passes.
  if state.pass == 'sunshadow' or state.pass == 'pointshadow' then return end
  self:forceLoad()
  if state.mode == BlendMode.Disabled then
    RenderState.PushDepthWritable(false)
    local shader = Cache.Shader('farplane', 'skybox')
    CullFace.Push(CullFace.None)
    shader:start()
    do -- Visible star at starDir, mirroring the engine sun (see skybox.glsl).
       -- Same hue mix GameView uses to build the scene's sunColor, times
       -- intensity, so 'Sun Light' off takes the star with it.
      local sd = self.starDir
      local len = math.sqrt(sd.x * sd.x + sd.y * sd.y + sd.z * sd.z)
      if len < 1e-6 then sd = Vec3f(0, 1, 0); len = 1 end
      local sw = (Settings and Settings.get and Settings.get('render.sun.warmth')) or 1
      local si = (Settings and Settings.get and Settings.get('render.sun.intensity')) or 1
      local on = (not Settings) or (not Settings.get) or Settings.get('render.sun.enable')
      local gain = (on and si) or 0.0
      Shader.SetFloat3('sunStarDir', sd.x / len, sd.y / len, sd.z / len)
      Shader.SetFloat3('sunStarColor', 1.0, 1.0 - 0.4 * sw, 1.0 - 0.8 * sw)
      Shader.SetFloat('sunStarGain', gain)
      -- Star size/brightness. Defaults are a tight disc with a modest halo; the
      -- halo is what used to smear light across ~20 degrees of sky and read as a
      -- glow sitting on the planet's limb (see skybox.glsl).
      Shader.SetFloat('sunStarTight', Settings.get('render.sun.starTight') or 20000.0)
      Shader.SetFloat('sunStarDisc',  Settings.get('render.sun.starDisc')  or 30.0)
      Shader.SetFloat('sunStarHalo',  Settings.get('render.sun.starHalo')  or 900.0)
      Shader.SetFloat('sunStarGlow',  Settings.get('render.sun.starGlow')  or 0.35)
    end
    Draw.Box3(Box3f(-1, -1, -1, 1, 1, 1))
    shader:stop()
    CullFace.Pop()
    RenderState.PopDepthWritable()
  elseif state.mode == BlendMode.Additive then
    local shader = Cache.Shader('farplane', 'starbg')
    shader:start()
    Shader.SetTexCube('irMap', self.irMap)
    Shader.SetTexCube('envMap', self.envMap)
    self.stars:draw()
    shader:stop()
  end
end

return Nebula
