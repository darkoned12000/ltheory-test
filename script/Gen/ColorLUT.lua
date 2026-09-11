-- Optimized ColorLUT loop using linear segment interpolation (eliminates table churn)
local function GenerateColorLUT (rng, iterations, variation, rough)
  local self = Tex1D.Create(256, TexFormat.RGBA16F)
  self:setMagFilter(TexFilter.Linear)
  self:setMinFilter(TexFilter.Linear)

  -- 1. Midpoint displacement
  local cPoints = { Vec3f(0, 0, 0), Vec3f(1, 1, 1) }
  local v = variation
  for i = 1, iterations do
    local newPoints = {}
    for j = 1, #cPoints - 1 do
      local p0 = cPoints[j]
      local p1 = cPoints[j + 1]
      local pn = p0:lerp(p1, 0.5)
      pn.x = pn.x + v * rng:getGaussian()
      pn.y = pn.y + v * rng:getGaussian()
      pn.z = pn.z + v * rng:getGaussian()
      table.insert(newPoints, p0)
      table.insert(newPoints, pn)
    end
    table.insert(newPoints, cPoints[#cPoints])
    cPoints = newPoints
    v = v * rough
  end

  -- 2. Direct linear interpolation across texture samples (0 allocs in loop)
  local bytes = Bytes.Create(256 * 3 * 4)
  local numSegments = #cPoints - 1

  for i = 0, 255 do
    local t = i / 255.0
    local scaledT = t * numSegments
    local idx = math.max(1, math.min(numSegments, math.floor(scaledT) + 1))
    local frac = scaledT - (idx - 1)

    local color = cPoints[idx]:lerp(cPoints[math.min(#cPoints, idx + 1)], frac)
    bytes:writeF32(color.x)
    bytes:writeF32(color.y)
    bytes:writeF32(color.z)
  end

  self:setDataBytes(bytes, PixelFormat.RGB, DataFormat.Float)
  bytes:free()
  return self
end

return GenerateColorLUT
