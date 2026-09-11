local MathUtil = {}
local log = math.log

--[[----------------------------------------------------------------------------
  Constructs a transform basis matrix facing `dir` centered at `pos`.
  If `up` is omitted, defaults to the world up vector (0, 1, 0).
----------------------------------------------------------------------------]]--
function MathUtil.CreateBasis (dir, pos, up)
  dir = Vec3f(dir.x, dir.y, dir.z)
  pos = Vec3f(pos.x, pos.y, pos.z)
  up  = up and Vec3f(up.x, up.y, up.z) or Vec3f(0, 1, 0)
  return Matrix.LookUp(pos, dir, up)
end

--[[----------------------------------------------------------------------------
  Generates `n` random positive floating-point numbers that sum to `desiredSum`
  using exponential spacing (Dirichlet distribution equivalent).
----------------------------------------------------------------------------]]--
function MathUtil.GenerateNumsThatAddToSum (n, desiredSum, rng)
  local v = {}
  local u = {}
  local sum = 0
  for i = 1, n do
    -- Clamp minimum uniform value to prevent math.log(0) -> -inf
    v[i] = math.max(1e-7, rng:getUniformRange(0, 1))
    u[i] = -log(v[i])
    sum = sum + u[i]
  end

  local p = {}
  for i = 1, n do
    p[i] = (u[i] / sum) * desiredSum
  end

  return p
end

return MathUtil
