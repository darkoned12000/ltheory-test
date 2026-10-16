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
  -- Planets are static/immovable: mass 0 sets Bullet's CF_STATIC_OBJECT, which
  -- exempts them from the "AABB too large -> object removed from simulation"
  -- check (so radius isn't bounded by ~289k). Static is correct here: gravity is
  -- 0, nothing drives the planet, the collision shape is a sphere (its AABB is
  -- rotation-invariant, so the axial spin needs no broadphase update), and it
  -- still collides with the ship. Moons pass `mass` + setKinematic below.
  self:setMass(opts.mass or 0)

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
  -- Can this body emit aurorae? Needs a global magnetic dynamo AND an
  -- atmosphere to excite, which is a per-type property, not a per-planet one.
  -- Default 0 so a type that has not thought about it (including the implicit
  -- 'moon' type built above) simply never emits.
  self.auroraCapable = (t.aurora or 0.0)

  -- Kept on the entity for the boot log. This is the seed the surface cube was
  -- generated from, and that cube carries BOTH the terrain and the baked cloud
  -- field -- so logging it makes any reported world reproducible from its own
  -- log line, without having to guess which world seed produced it.
  local genSeed = rng:getUniform()
  self.genSeed  = genSeed

  local params = {
    seed  = genSeed,
    freq  = (t.freqBase or 4) + rng:getExp(),
    power = (t.powerBase or 1.0) + (t.powerVar or 0.5) * rng:getExp(),
    coef  = (rng:getVec4(0.05, 1.00) ^ Vec4f(2, 2, 2, 2)):normalize()
  }
  -- Only gen/planet declares `mountain`/`crater`/`valley`; setting a uniform a
  -- shader lacks aborts.
  if t.gen == 'gen/planet' then
    params.mountain = t.mountain or 0.0
    params.crater   = t.crater or 0.0
    params.valley   = t.valley or 0.0
    params.crack    = t.crack or 0.0
  end
  self.texSurface = Gen.GenUtil.ShaderToTexCube(cubeRes, TexFormat.RGBA16F, t.gen, params):managed()

  self.cloudLevel = rng:getUniformRange(-0.2, 0.15)
  -- Per-type cloud chance (Phase C). Was carried in Config since the type table
  -- was written and never wired; the material now reads the baked cloud channel,
  -- gated by this. cloudLevel is the per-planet coverage bias on top, so two
  -- terrestrial worlds do not get identical weather.
  self.weather    = t.weather or 0.0
  self.cloudTime  = 0.0
  self.atmoScale  = t.atmo > 0 and t.atmo or 1.0
  self.hasAtmo    = t.atmo > 0
  self.atmoTint   = t.atmoTint or { 1, 1, 1 }
  self.relief     = t.relief or 1.0
  self.emissive   = t.emissive or { 0, 0, 0 }
  self.emissiveAmt = t.emissiveAmt or 0.0

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
    self:setKinematic(true)
  end

  self:register(Event.Update, self.update)
  self:register(Event.Render, self.render)
end)

-- Resolved cloud coverage, 0..1. This is the number that actually decides how
-- cloudy a world looks, and it is the one neither panel knob shows:
--
--     clouds = clamp( weather * Coverage + cloudLevel, 0, 1 )
--
-- `weather` comes from the type (itself a seeded weighted pick) and `cloudLevel`
-- is a per-planet bias of U(-0.2, +0.15) drawn from THIS planet's rng -- so two
-- ice worlds resolve anywhere in 0.20..0.55. The panel's Coverage slider is only
-- a multiplier on the first term; it is 1.0 (neutral) by default and setting it
-- to 0 does NOT switch clouds off, because the bias can be positive.
--
-- Single definition, used both by the shader path and by the boot log, so the
-- number the log prints is the number that rendered.
function Planet:cloudCoverage ()
  if Settings.get('render.planet.cloudsEnabled') == false then return 0.0 end
  -- An airless body has no air to hold cloud. Barren types and moons carry
  -- weather = 0, but weather = 0 alone does NOT switch them off: cloudLevel is a
  -- per-planet bias that can be POSITIVE, so a barren world resolved to 0.14 and
  -- rendered a cloud deck over a body with no atmosphere at all. Found by logging
  -- the resolved value per world rather than assuming the prior was decisive.
  -- Gating on hasAtmo also makes the long-standing "airless bodies cost nothing"
  -- comment actually true.
  if not self.hasAtmo then return 0.0 end
  local knob = Settings.get('render.planet.clouds')
  if knob == nil then knob = 2.0 end
  -- Clamped at 1.5, NOT 1.0. `clouds` parameterises the coverage window rather
  -- than being a literal 0..1 fraction, and clamping at 1.0 made the wet types
  -- saturate: at knob 2 both ocean (0.70) and terrestrial (0.60) resolved to
  -- exactly 1.00, which not only flattened them into each other but DISCARDED
  -- the per-planet bias, since it is added before the clamp. 1.5 keeps the
  -- ordering ocean > terrestrial > ice > lava > desert and the seed variation
  -- inside each. The shader clamps the mix factor to match.
  return math.max(0.0, math.min(1.5, (self.weather or 0.0) * knob + (self.cloudLevel or 0.0)))
end

function Planet:update (state)
  -- Cloud advection clock. Accumulated from dt rather than read from a wall
  -- clock, so it stays reproducible with a pinned world seed, and advanced for
  -- moons too (they return early below).
  self.cloudTime = (self.cloudTime or 0.0) + state.dt

  -- Moon: orbit the parent and keep one face toward it (tidal lock).
  if self.parentPlanet then
    self.orbitPhase = self.orbitPhase + self.orbitSpeed * state.dt
    local pp = self.parentPlanet:getPos()
    local r  = self.orbitRadius
    -- Orbit in the PLANET'S equatorial plane: a fixed basis perpendicular to
    -- the planet's spin axis, so moons orbit its equator rather than a world
    -- plane. `orbitIncl` tilts off the equator; radius is preserved exactly.
    local axis = self.parentPlanet.spinAxis or Vec3f(0, 1, 0)
    local ref  = (math.abs(axis.y) < 0.9) and Vec3f(0, 1, 0) or Vec3f(1, 0, 0)
    local e1 = axis:cross(ref):normalize()
    local e2 = axis:cross(e1):normalize()
    local ca, sa = math.cos(self.orbitPhase), math.sin(self.orbitPhase)
    local ci, si = math.cos(self.orbitIncl), math.sin(self.orbitIncl)
    local a1, a2, a3 = ca, sa * ci, sa * si
    local x = (e1.x * a1 + e2.x * a2 + axis.x * a3) * r
    local y = (e1.y * a1 + e2.y * a2 + axis.y * a3) * r
    local z = (e1.z * a1 + e2.z * a2 + axis.z * a3) * r
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
  -- The planet shader is heavy (fbm + scattering); it contributes nothing to a
  -- thruster's point-light shadow map, so skip it there. It still goes into the
  -- sun map so it can occlude the ship/asteroids.
  if state.pass == 'pointshadow' then return end
  -- Engine sun, mirrored so the atmosphere tracks render.sun.* like every other
  -- surface term. starColor carries the hue (the same warmth mix GameView uses
  -- to build the scene's sunColor) and atmoSun the intensity x the scattering
  -- gain (historically a fixed 22x). These were a hardcoded (1, 0.5, 0.1) star
  -- at a constant 22x, so the limb glow ignored the sun controls and lit the
  -- planet from a direction with no visible source in the sky.
  local sw = Settings.get('render.sun.warmth') or 1
  local si = Settings.get('render.sun.intensity') or 1
  local starR, starG, starB = 1.0, 1.0 - 0.4 * sw, 1.0 - 0.8 * sw
  local atmoSun = 22.0 * si

  if state.mode == BlendMode.Disabled then
    local shader = Cache.Shader('wvp', 'material/planet')
    shader:start()
    Shader.SetFloat('heightMult', 1.0)
    Shader.SetFloat('oceanLevel', self.oceanLevel)
    Shader.SetFloat('hasAtmo', self.hasAtmo and 1.0 or 0.0)
    Shader.SetFloat('relief', self.relief * (Settings.get('render.planet.relief') or 1))
    Shader.SetFloat3('emissive', self.emissive[1], self.emissive[2], self.emissive[3])
    Shader.SetFloat('emissiveAmt', self.emissiveAmt)
    Shader.SetFloat('envAmbient', Settings.get('render.planet.envAmbient') or 2.0)
    Shader.SetFloat('sunScale',   Settings.get('render.planet.sunScale') or 1.0)
    Shader.SetFloat('atmoGlow',   Settings.get('render.planet.atmoGlow') or 1.0)
    -- Cloud coverage: per-type chance x the panel knob, offset by the per-planet
    -- bias. weather is 0 for barren/moon types, so airless bodies cost nothing.
    -- See Planet:cloudCoverage for why the slider alone cannot switch these off.
    Shader.SetFloat('clouds',     self:cloudCoverage())
    Shader.SetFloat('cloudTime',  self.cloudTime or 0.0)
    -- Cloud shell altitude as a fraction of rPlanet. 0 = v1's ground-projected
    -- deck exactly (no parallax), so this is a clean A/B against the old look.
    -- Real cloud decks sit ~0.16% of a planet's radius up; the default is an
    -- order of magnitude above that because a physically-scaled shell gives an
    -- offset too small to read at any sane camera distance.
    Shader.SetFloat('cloudHeight', Settings.get('render.planet.cloudHeight') or 0.02)
    -- How fast the deck slides across the body, in RADIANS PER SECOND, derived
    -- from this planet's own rotation rather than a fixed constant.
    --
    -- It used to be a hardcoded `cloudTime * 2.0e-4`, which is an ABSOLUTE rate,
    -- and that is wrong here for two reasons. Against a rotation of 0.01-0.05
    -- rad/s (randomised per planet) it is 1/50th to 1/250th of the spin -- the
    -- ground sweeps 1 degree in under two seconds while the clouds need 87, so
    -- the drift is invisible. And because the spin is randomised, the same
    -- absolute drift is 5x more visible on a slow planet than a fast one.
    --
    -- Tying it to spinSpeed keeps the RATIO constant on every world, which is
    -- also the physically meaningful relationship: real cloud drift is ~6% of
    -- Earth's rotation, and on a body that spins faster the wind should scale
    -- with it. Direction reads correctly too -- a small fraction of spin means
    -- the deck creeps *backwards* relative to the terrain, exactly as it does
    -- on Earth.
    local windFrac = Settings.get('render.planet.cloudWind')
    if windFrac == nil then windFrac = 0.04 end
    Shader.SetFloat('cloudWindRate', (self.spinSpeed or 0.0) * windFrac)
    -- How much the deck dims the sun term beneath it. 0 disables shadowing
    -- entirely, which is the A/B against the pre-shadow look.
    Shader.SetFloat('cloudShadow', Settings.get('render.planet.cloudShadow') or 0.55)

    -- ---- Storms -----------------------------------------------------------
    -- Scaled by the type's existing `weather` prior rather than a second table,
    -- so "storminess" stays consistent with how wet the world already is: ocean
    -- (0.70) and terrestrial (0.60) get the worst of it, ice (0.40) moderate,
    -- lava (0.15) and desert (0.08) rare, and barren/moon -- weather 0 -- none
    -- at all, which also keeps airless bodies free.
    local stormKnob = Settings.get('render.planet.storms')
    if stormKnob == nil then stormKnob = 1.0 end
    Shader.SetFloat('stormAmount', self.hasAtmo and ((self.weather or 0.0) * stormKnob) or 0.0)
    -- Intra-cloud lightning brightness. Separate knob so the flashes can be
    -- auditioned against a calm sky.
    Shader.SetFloat('stormFlash', Settings.get('render.planet.stormFlash') or 1.0)

    -- ---- Aurorae ----------------------------------------------------------
    -- Gated on the per-type `aurora` flag (see Config.App types): a dynamo AND
    -- an atmosphere. Multiplied by hasAtmo as a belt-and-braces check, so a type
    -- that gains the flag but loses its air still cannot emit.
    local auroraKnob = Settings.get('render.planet.aurora')
    if auroraKnob == nil then auroraKnob = 1.0 end
    local canAurora = self.hasAtmo and (self.auroraCapable and 1.0) or 0.0
    Shader.SetFloat('auroraAmt', canAurora * auroraKnob)
    -- Green emission sits at 100-300 km on a 6371 km Earth, so ~2-4% of radius;
    -- the red band above it is derived in the shader at 2.2x this altitude.
    Shader.SetFloat('auroraHeight', Settings.get('render.planet.auroraHeight') or 0.03)
    -- The body's local axes in WORLD space. The surface cube is authored in local
    -- space so the terrain spins with the planet; the cloud shell needs to convert
    -- a world-space ray hit back into that local frame. Passed explicitly rather
    -- than reusing the mWorldIT autovar because no fragment shader has ever
    -- declared it, and an autovar that never gets uploaded is silently IDENTITY --
    -- which would look like "parallax just doesn't work" rather than an error.
    local rot = self:getRot()
    if rot then
      local ax, ay, az = rot:getAxisX(), rot:getAxisY(), rot:getAxisZ()
      Shader.SetFloat3('planetAxisX', ax.x, ax.y, ax.z)
      Shader.SetFloat3('planetAxisY', ay.x, ay.y, ay.z)
      Shader.SetFloat3('planetAxisZ', az.x, az.y, az.z)
    else
      Shader.SetFloat3('planetAxisX', 1, 0, 0)
      Shader.SetFloat3('planetAxisY', 0, 1, 0)
      Shader.SetFloat3('planetAxisZ', 0, 0, 1)
    end
    -- Terminator shape: 0 = cosine law (a diffuse planet dims toward the limb),
    -- 1 = the old flat wrap that glowed almost to the edge.
    Shader.SetFloat('terminator', Settings.get('render.planet.terminator') or 0.35)
    Shader.SetFloat3('atmoTint', self.atmoTint[1], self.atmoTint[2], self.atmoTint[3])
    Shader.SetFloat('rPlanet', self:getScale())
    Shader.SetFloat('rAtmo', self:getScale() * self.atmoScale)
    Shader.SetFloat3('color1', self.color1.x, self.color1.y, self.color1.z)
    Shader.SetFloat3('color2', self.color2.x, self.color2.y, self.color2.z)
    Shader.SetFloat3('color3', self.color3.x, self.color3.y, self.color3.z)
    Shader.SetFloat3('color4', self.color4.x, self.color4.y, self.color4.z)
    local pos = self:getPos()
    Shader.SetFloat3('origin', pos.x, pos.y, pos.z)
    Shader.SetFloat3('starColor', starR, starG, starB)
    Shader.SetFloat('atmoSun', atmoSun)
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
    Shader.SetFloat3('starColor', starR, starG, starB)
    Shader.SetFloat('atmoSun', atmoSun)
    Shader.SetFloat3('atmoTint', self.atmoTint[1], self.atmoTint[2], self.atmoTint[3])
    Shader.SetFloat('atmoGlow', Settings.get('render.planet.atmoGlow') or 1.0)
    self.meshAtmo:draw()
    shader:stop()
    BlendMode.Pop()
    CullFace.Pop()
  end
end

return Planet
