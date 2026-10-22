local Generator = require('Gen.Generator')
local GenUtil   = require('Gen.GenUtil')

local function generateNebulaLightTransport (rng, res, starDir)
  Profiler.Begin('Nebula.Generate.LightTransport')
  local buffDst = TexCube.Create(res, TexFormat.RGBA16F)
  local buffSrc = TexCube.Create(res, TexFormat.RGBA16F)
  buffDst:setMagFilter(TexFilter.Linear)
  buffDst:setMinFilter(TexFilter.Linear)
  buffSrc:setMagFilter(TexFilter.Linear)
  buffSrc:setMinFilter(TexFilter.Linear)
  buffSrc:clear(0.05, 0.05, 0.05, 0)

  local emit   = Cache.Shader('ui', 'gen/nebula_emit')
  local absorb = Cache.Shader('ui', 'gen/nebula_absorb')

  for i = 1, 8 do
    for j = 1, rng:getInt(4, 8) do -- Emission
      local ss = ShaderState.Create(emit)
      local rot = rng:getQuat()
      local dir = rng:getDir3()
      -- ss:setFloat('seed', rng:getUniform())
      local T = rng:getUniform()
      local K = Math.Lerp(1600.0, 15000.0, T)
      local C = Color.FromTemperature(K, 2.5):toVec3():normalize():scale(2.5 + rng:getExp() * 2.0)
      ss:setFloat3('color', C.x, C.y, C.z)
      ss:setFloat4('rot', rot.x, rot.y, rot.z, rot.w)
      -- ss:setFloat3('starDir', starDir.x, starDir.y, starDir.z)
      -- `nebula.starGlow` is NOT set here, and setting it would ABORT the engine:
      -- gen/nebula_emit has no such uniform, and Shader_GetVariable aborts on a
      -- missing variable (see the trap in docs/ltheory-planets.md 12). This aborted the
      -- process at boot for any seed that selects the Nebula2 generator -- caught
      -- by S1 on seed 14112139399293175324.
      --
      -- So the Baked Star Glow knob applies to Nebula1 only (gen/nebula.glsl's
      -- "Central Star"). Nebula2 builds its emission from per-blob `color` +
      -- `density` + extinction passes instead of baking a star, so giving it the
      -- knob needs its own formulation -- not a copy of Nebula1's.
      ss:setTexCube('src', buffSrc)
      buffDst:generate(ss)
      ss:free()
      buffSrc, buffDst = buffDst, buffSrc
    end

    for j = 1, rng:getInt(2, 4) do -- Extinction
      local ss = ShaderState.Create(absorb)
      local rot = rng:getQuat()
      ss:setFloat('density', 1.0 + rng:getExp())
      ss:setFloat('seed', rng:getUniform())
      ss:setFloat4('rot', rot.x, rot.y, rot.z, rot.w)
      ss:setTexCube('src', buffSrc)
      buffDst:generate(ss)
      ss:free()
      buffSrc, buffDst = buffDst, buffSrc
    end
  end

  buffDst:free()
  buffSrc:setMinFilter(TexFilter.LinearMipLinear)
  buffSrc:genMipmap()
  Profiler.End()
  return buffSrc
end

Generator.Add('Nebula', 0.1, generateNebulaLightTransport)
