local Generator = require('Gen.Generator')
local Palette   = require('Gen.Nebula.Palette')

local function generateNebulaIFS (rng, res, starDir)
  Profiler.Begin('Nebula.Generate.IFS')
  local self = TexCube.Create(res, TexFormat.RGBA16F)
  local shader = Cache.Shader('ui', 'gen/nebula')
  local ss = ShaderState.Create(shader)

  do -- Nebula color
    local h = rng:getUniform()
    -- Publish the sector hue so the volumetric plumes can match it.
    Palette.hue = h
    local s = rng:getUniformRange(0.2, 0.8)
    local l = rng:getUniformRange(0.2, 0.8)
    local color = Color.FromHSL(h, s, l)
    local r = color.r
    local g = color.g
    local b = color.b
    ss:setFloat3('color', r, g, b)
  end

  local roughness = 0.65 + 0.05 * rng:getSign() * rng:getUniform()^2
  ss:setFloat('roughness', roughness)

  local seed = rng:getUniformRange(1, 1000)
  ss:setFloat('seed', seed)

  local lutR = Gen.ColorLUT(rng, 5, 0.30, 0.6)
  local lutG = Gen.ColorLUT(rng, 5, 0.30, 0.6)
  local lutB = Gen.ColorLUT(rng, 5, 0.30, 0.6)
  ss:setTex1D('lutR', lutR)
  ss:setTex1D('lutG', lutG)
  ss:setTex1D('lutB', lutB)
  ss:setFloat3('starDir', starDir.x, starDir.y, starDir.z)
  -- Central Star brightness baked into the cube (see gen/nebula.glsl). Read at
  -- generation time, so changing it needs a relaunch to re-bake the sky.
  local glow = Settings.get('nebula.starGlow')
  ss:setFloat('starGlow', glow or 0.35)

  self:generate(ss)
  self:genMipmap()
  self:setMagFilter(TexFilter.Linear)
  self:setMinFilter(TexFilter.LinearMipLinear)

  ss:free()
  lutR:free()
  lutG:free()
  lutB:free()
  Profiler.End()
  return self
end

Generator.Add('Nebula', 1.0, generateNebulaIFS)
