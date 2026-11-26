-- Pure explosion tuning shared by ship/asteroid destruction and tests.
local FX = {}

function FX.Parameters (scale)
  scale = math.max(0.25, tonumber(scale) or 1)
  return {
    count = math.floor(math.min(1200, math.max(80, scale * 80))),
    speed = math.min(600, 8 + scale * 4),
    size = math.min(80, math.max(1, scale * 0.5)),
    life = math.min(3, 0.8 + scale * 0.02),
  }
end

return FX
