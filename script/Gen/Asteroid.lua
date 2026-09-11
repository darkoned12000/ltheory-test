local GenUtil = require('Gen.GenUtil')
local floor, sqrt = math.floor, math.sqrt

local function generateAsteroid (seed)
  Profiler.Begin('Asteroid.Generate')
  local rng = RNG.Create(seed)
  local self = LodMesh.Create()
  local shader = Cache.Shader('identity', 'sdf/asteroid')
  local ss = ShaderState.Create(shader)

  -- Base SDF parameters
  ss:setInt('octaves', 8)
  ss:setFloat('seed', rng:getUniformRange(0, 1000))
  ss:setFloat('smoothness', 2.5)

  -- Derive randomized shape, elongation, and surface features per seed:
  -- Aspect ratio variation (0.7 to 1.35) stretches/compresses X/Y/Z into potato/wedge shapes
  local ax = rng:getUniformRange(0.70, 1.35)
  local ay = rng:getUniformRange(0.70, 1.35)
  local az = rng:getUniformRange(0.70, 1.35)

  -- Slight frequency and crater depth variations per seed
  local freq  = rng:getUniformRange(1.8, 2.4)
  local depth = rng:getUniformRange(0.8, 1.3)

  ss:setFloat('noiseFreq', freq)
  ss:setFloat3('aspect', ax, ay, az)
  ss:setFloat('craterDepth', depth)

  local res = 96
  local dMin = 0
  local dMax = 1
  local lac = 1.5

  for i = 1, 8 do
    local gridRes = math.max(16, floor(res))
    local density = GenUtil.ShaderToTex3D(ss, gridRes, TexFormat.R32F)
    local field = SDF.FromTex3D(density)
    field:computeNormals()
    local mesh = field:toMesh()
    field:free()

    mesh:computeOcclusion(density, 0.1)
    density:free()
    mesh:center()
    self:add(mesh, dMin, dMax)

    res = res / lac
    dMin = dMax
    dMax = dMax * lac * sqrt(2.0)
  end

  ss:free()
  rng:free()
  Profiler.End()
  return self
end

return generateAsteroid
