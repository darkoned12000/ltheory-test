local Entity = require('Game.Entity')

-- Weighted pick from a type table (a planet picks a surface TYPE from its seed).
local function pickType (rng, types)
  local total = 0
  for i = 1, #types do total = total + (types[i].weight or 1) end
  local r = rng:getUniform() * total
  for i = 1, #types do
    r = r - (types[i].weight or 1)
    if r <= 0 then return types[i] end
  end
  return types[#types]
end

-- One stop of a type's biome ramp: `f` 0 = low, 1 = peak. Peaks are lighter and
-- less saturated (snow/ice caps); hue is jittered inside the type's range, or
-- chosen from `huePick` (moons pick a rock/ice/rust family).
local function typeColor (rng, t, f)
  local h
  if t.huePick then
    h = t.huePick[rng:getInt(1, #t.huePick)] + rng:getUniformRange(-0.03, 0.03)
  else
    h = rng:getUniformRange(t.hue[1], t.hue[2])
  end
  local l = t.light[1] + (t.light[2] - t.light[1]) * f
  local s = t.sat[1] + (t.sat[2] - t.sat[1]) * (1.0 - f)
  local c = Color.FromHSL(h, s, Math.Saturate(l))
  return Vec3f(c.r, c.g, c.b)
end

local Planet = subclass(Entity, function (self, seed, opts)
  opts = opts or {}
  local detail  = opts.detail  or 5
  local cubeRes = opts.cubeRes or 2048

  -- TODO : Had to lower quality to 2 because RigidBody is automatically
  --        building BSP, and sphere is pathological case for BSPs. Need
  --        generalized CollisionShape.
  local mesh = Gen.Primitive.IcoSphere(detail):managed()

  self:addRigidBody(true, mesh)
  self:setMass(opts.mass or 1000)

  self.mesh = mesh
  local rng = RNG.Create(seed):managed()

  -- Surface TYPE drives generator + palette + ocean + atmosphere. Moons get a
  -- fixed barren/rocky type; planets pick one from the seed by weight, so a
  -- planet's "biome" IS its type (and can be shown/queried by name).
  local t
  if opts.parent then
    t = {
      name = 'moon', gen = 'gen/moon', atmo = 0, ocean = { 0, 0 },
      huePick = { 0.08, 0.58, 0.02 }, sat = { 0.05, 0.24 }, light = { 0.05, 0.22 },
      freqBase = 6, powerBase = 1.0, powerVar = 1.0,
    }
  else
    -- forceType (Config.Local) pins a type for auditioning; else weighted pick.
    local forced = Config.render.planet.forceType
    if forced then
      for _, ty in ipairs(Config.render.planet.types) do
        if ty.name == forced then t = ty break end
      end
    end
    t = t or pickType(rng, Config.render.planet.types)
  end
  self.typeName = t.name

  local params = {
    seed  = rng:getUniform(),
    freq  = (t.freqBase or 4) + rng:getExp(),
    power = (t.powerBase or 1.0) + (t.powerVar or 0.5) * rng:getExp(),
    coef  = (rng:getVec4(0.05, 1.00) ^ Vec4f(2, 2, 2, 2)):normalize()
  }
  -- Only gen/planet declares `mountain`; setting a uniform a shader lacks aborts.
  if t.gen == 'gen/planet' then
    params.mountain = t.mountain or 0.0
    params.crater   = t.crater or 0.0
  end
  self.texSurface = Gen.GenUtil.ShaderToTexCube(cubeRes, TexFormat.RGBA16F, t.gen, params):managed()

  self.cloudLevel = rng:getUniformRange(-0.2, 0.15)
  self.atmoScale  = t.atmo > 0 and t.atmo or 1.0
  self.hasAtmo    = t.atmo > 0
  self.atmoTint   = t.atmoTint or { 1, 1, 1 }

  -- 4-stop biome ramp: low -> mid -> high -> peak (snow/ice caps etc.).
  self.oceanLevel = t.ocean[1] + (t.ocean[2] - t.ocean[1]) * rng:getUniform()
  self.color1 = typeColor(rng, t, 0.0)
  self.color2 = typeColor(rng, t, 0.5)
  self.color3 = typeColor(rng, t, 0.8)
  self.color4 = typeColor(rng, t, 1.0)

  -- Atmosphere mesh only for bodies that actually have one.
  if self.hasAtmo then
    self.meshAtmo = Gen.Primitive.IcoSphere(detail):managed()
    self.meshAtmo:computeNormals()
    self.meshAtmo:invert()
  end

  -- Axial spin (planets-work Phase A). Drawn LAST so a given seed's appearance
  -- parameters above are unchanged. The surface is sampled in LOCAL space
  -- (`vertPos = vertex_position`), so rotating the body spins the visible
  -- terrain; a slow, tilted, deterministically-signed axis reads as a planet.
  self.spinAxis = Vec3f(
    rng:getUniformRange(-0.35, 0.35), 1, rng:getUniformRange(-0.35, 0.35)):normalize()
  self.spinSpeed = Config.render.planet.spinSpeed(rng)
  self.spinAngle = 0

  -- Moon (planets-work Phase B): orbit a parent body instead of spinning free.
  -- Kinematic so the physics step never fights the scripted orbital placement
  -- (it still collides). Orbit radius is world units, derived by the caller.
  if opts.parent then
    local cfg = Config.render.planet.moon
    self.parentPlanet = opts.parent
    self.orbitRadius  = opts.orbitRadius or (opts.parent:getScale() * 4)
    self.orbitPhase   = rng:getUniform() * 2 * math.pi
    self.orbitSpeed   = cfg.orbitSpeed(rng) * (rng:getUniform() < 0.5 and -1 or 1)
    self.orbitIncl    = cfg.inclination(rng)
    self.orbitRoll    = cfg.roll(rng)
    self:setKinematic(true)
  end

  self:register(Event.Update, self.update)
  self:register(Event.Render, self.render)
end)

function Planet:update (state)
  -- Moon: orbit the parent and keep one face toward it (tidal lock).
  if self.parentPlanet then
    self.orbitPhase = self.orbitPhase + self.orbitSpeed * state.dt
    local pp = self.parentPlanet:getPos()
    local r  = self.orbitRadius
    -- Circular orbit in a tilted + rolled plane. Radius is preserved exactly
    -- (roll about Y, then inclination about X); roll/incl are per-moon so
    -- sibling orbits don't line up.
    local ox = math.cos(self.orbitPhase) * r
    local oz = math.sin(self.orbitPhase) * r
    local cr, sr = math.cos(self.orbitRoll), math.sin(self.orbitRoll)
    local x = ox * cr + oz * sr
    local z = -ox * sr + oz * cr
    local ci, si = math.cos(self.orbitIncl), math.sin(self.orbitIncl)
    local y = -z * si
    z = z * ci
    self:setPos(Vec3f(pp.x + x, pp.y + y, pp.z + z))
    self:setRot(Quat.FromLookUp(Vec3f(-x, -y, -z):normalize(), Vec3f(0, 1, 0)))
    return
  end
  if not Config.render.planet.spin then return end
  self.spinAngle = (self.spinAngle + self.spinSpeed * state.dt) % (2 * math.pi)
  -- Base rotation is identity at spawn, so this is a clean spin about the
  -- planet's own fixed axis. (Verified not to be clobbered by the physics step:
  -- planets carry zero angular velocity, so Bullet leaves the transform alone.)
  self:setRot(Quat.FromAxisAngle(self.spinAxis, self.spinAngle))
end

function Planet:render (state)
  if state.mode == BlendMode.Disabled then
    local shader = Cache.Shader('wvp', 'material/planet')
    shader:start()
    Shader.SetFloat('heightMult', 1.0)
    Shader.SetFloat('oceanLevel', self.oceanLevel)
    Shader.SetFloat('hasAtmo', self.hasAtmo and 1.0 or 0.0)
    Shader.SetFloat3('atmoTint', self.atmoTint[1], self.atmoTint[2], self.atmoTint[3])
    Shader.SetFloat('rPlanet', self:getScale())
    Shader.SetFloat('rAtmo', self:getScale() * self.atmoScale)
    Shader.SetFloat3('color1', self.color1.x, self.color1.y, self.color1.z)
    Shader.SetFloat3('color2', self.color2.x, self.color2.y, self.color2.z)
    Shader.SetFloat3('color3', self.color3.x, self.color3.y, self.color3.z)
    Shader.SetFloat3('color4', self.color4.x, self.color4.y, self.color4.z)
    local pos = self:getPos()
    Shader.SetFloat3('origin', pos.x, pos.y, pos.z)
    Shader.SetFloat3('starColor', 1.0, 0.5, 0.1)
    Shader.SetMatrix('mWorld', self:getToWorldMatrix())
    Shader.SetMatrixT('mWorldIT', self:getToLocalMatrix())
    Shader.SetTexCube('surface', self.texSurface)
    self.mesh:draw()
    shader:stop()
  elseif state.mode == BlendMode.Alpha and self.meshAtmo then
    CullFace.Push(CullFace.Back)
    BlendMode.Push(BlendMode.PreMultAlpha)
    local shader = Cache.Shader('wvp', 'material/atmosphere')
    shader:start()
    do -- Scale the atmosphere MESH to match its scattering shell (rAtmo ==
       -- scale * atmoScale). A hardcoded 1.5x left a wide empty halo out to
       -- 1.5x where density ~0, so the background showed through the planet.
      local as = self.atmoScale
      local mScale = Matrix.Scaling(as, as, as)
      local mWorld = self:getToWorldMatrix():product(mScale)
      Shader.SetMatrix('mWorld', mWorld)
      mScale:free()
      mWorld:free()
    end

    Shader.SetMatrixT('mWorldIT', self:getToLocalMatrix())
    local scale = self:getScale()
    Shader.SetFloat('rAtmo', scale * self.atmoScale)
    Shader.SetFloat('rPlanet', scale)
    local pos = self:getPos()
    Shader.SetFloat3('origin', pos.x, pos.y, pos.z)
    Shader.SetFloat3('scale', scale, scale, scale)
    Shader.SetFloat3('starColor', 1.0, 0.5, 0.1)
    Shader.SetFloat3('atmoTint', self.atmoTint[1], self.atmoTint[2], self.atmoTint[3])
    self.meshAtmo:draw()
    shader:stop()
    BlendMode.Pop()
    CullFace.Pop()
  end
end

return Planet
