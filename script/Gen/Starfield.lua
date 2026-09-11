local insert = table.insert

local function generateStarfield (rng, count)
  local self = Mesh.Create()
  local brightness = 0.015
  local distance   = 1e6
  local baseRadius = 1.0 / 30.0

  local stars = {}

  -- 1. Initial seed star
  insert(stars, rng:getDir3():scale(rng:getExp()))
  local sum = stars[1]

  -- 2. Build star distribution (Blend of 70% cluster random-walk, 30% field stars)
  for i = 1, count do
    local p
    if rng:getUniform() < 0.70 and #stars > 0 then
      p = rng:choose(stars) + rng:getDir3():scale(rng:getExp() * 0.8)
      -- Apply galactic plane flattening along the Y-axis
      p.y = p.y * 0.35
    else
      -- Uniform background field stars
      p = rng:getDir3():scale(1.0 + rng:getUniform() * 2.0)
    end

    insert(stars, p)
    sum = sum + p
  end

  local source = sum:scale(1.0 / math.max(1, #stars))

  -- 3. Construct Billboard Quads
  for i = 1, #stars do
    local K = rng:getUniform()
    local baseColor = Color.FromTemperature(Math.Lerp(1600, 15000, K), 2.0):toVec3()

    -- Clamp exponential scale to avoid extreme HDR blowout outliers
    local expVal = math.min(rng:getExp(), 4.0)
    local intensity = brightness * (expVal ^ 2.2)
    local c = baseColor:scale(intensity)

    -- Vector from cluster center to star; fallback to unit dir if length is 0
    local dir = stars[i] - source
    local N = (dir:length() > 1e-5) and dir:normalize() or rng:getDir3()

    local T, B = Math.OrthoBasis(N)

    -- Vary quad size slightly based on star brightness
    local starRadius = baseRadius * (0.75 + 0.5 * math.min(1.0, expVal / 2.0))

    local N_dist = N:scale(distance)
    local T_scaled = T:scale(starRadius * distance)
    local B_scaled = B:scale(starRadius * distance)

    local index = self:getVertexCount()
    local p1 = N_dist - T_scaled
    local p2 = N_dist + B_scaled
    local p3 = N_dist + T_scaled
    local p4 = N_dist - B_scaled

    self:addVertex(p1.x, p1.y, p1.z, c.x, c.y, c.z, -1,  0)
    self:addVertex(p2.x, p2.y, p2.z, c.x, c.y, c.z,  0,  1)
    self:addVertex(p3.x, p3.y, p3.z, c.x, c.y, c.z,  1,  0)
    self:addVertex(p4.x, p4.y, p4.z, c.x, c.y, c.z,  0, -1)
    self:addQuad(index, index + 1, index + 2, index + 3)
  end

  return self
end

return generateStarfield
