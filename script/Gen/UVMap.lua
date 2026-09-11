local max, sqrt = math.max, math.sqrt

local function sortHeight (a, b)
  return a.sy > b.sy
end

--[[----------------------------------------------------------------------------
  A per-triangle bin-packing UV atlas generator. Splits non-shared vertices
  and maps 3D face areas into 2D UV texel bins.
----------------------------------------------------------------------------]]--
local function createUVMap (mesh, res)
  Profiler.Begin('Gen.UVMap')
  local res = res or 4096
  local self = Mesh.Create()

  do
    local indices = mesh:getIndexData()
    local vertices = mesh:getVertexData()

    for i = 0, mesh:getIndexCount() - 1 do
      self:addVertexRaw(vertices + indices[i])
      self:addIndex(i)
    end
  end

  local tris = List()
  local totalArea, totalSX, totalSY = 0, 0, 0

  local indices = self:getIndexData()
  local vertices = self:getVertexData()

  for i = 0, self:getIndexCount() - 1, 3 do
    local i1, i2, i3 = indices[i], indices[i + 1], indices[i + 2]
    local v1, v2, v3 = vertices + i1, vertices + i2, vertices + i3
    local e1 = Vec3f(v2.x - v1.x, v2.y - v1.y, v2.z - v1.z)
    local e2 = Vec3f(v3.x - v2.x, v3.y - v2.y, v3.z - v2.z)
    local e3 = Vec3f(v1.x - v3.x, v1.y - v3.y, v1.z - v3.z)
    local area = 0.5 * e1:cross(e2):length()
    totalArea = totalArea + area

    local l1, l2, l3 = e1:length(), e2:length(), e3:length()
    local maxLen = max(l1, max(l2, l3))

    if l2 == maxLen then
      e1, e2, e3 = e2, e3, e1
      l1, l2, l3 = l2, l3, l1
      i1, i2, i3 = i2, i3, i1
    elseif l3 == maxLen then
      e1, e2, e3 = e3, e1, e2
      l1, l2, l3 = l3, l1, l2
      i1, i2, i3 = i3, i1, i2
    end

    local e1n = e1:scale(1.0 / l1)
    local perp = e2:reject(e1n):normalize()
    local v3u = e2:dot(perp)
    local v3v = -e3:dot(e1n)

    local tri = {
      sx = v3u, sy = l1, oy = v3v,
      i1 = i1, i2 = i2, i3 = i3,
      area = area,
    }
    tris:add(tri)
    totalSX = totalSX + tri.sx
    totalSY = totalSY + tri.sy
  end

  local texelScale = 4.0 * res / sqrt(((totalSX + #tris) * (totalSY + #tris)) / #tris)

  for i = 1, #tris do
    local tri = tris[i]
    tri.sx = tri.sx * texelScale
    tri.sy = tri.sy * texelScale
    tri.oy = tri.oy * texelScale
  end

  tris:sort(sortHeight)

  local bins = List()
  local maxWidth = sqrt((texelScale * totalSX + #tris) * (texelScale * totalSY + #tris) / #tris)
  local mapSX, mapSY = 0, 0

  for i = 1, #tris do
    local tri = tris[i]
    for j = 1, #bins do
      local bin = bins[j]
      if tri.sy <= bin.sy and (tri.sx + bin.x) <= maxWidth then
        bin.tris:add(tri)
        tri.x, tri.y = bin.x, bin.y
        bin.sx = bin.sx + tri.sx + 1
        bin.x = bin.x + tri.sx + 1
        mapSX = max(mapSX, bin.x)
        goto found
      end
    end

    local bin = { tris = List(), sx = 0, sy = tri.sy, x = 0, y = mapSY }
    bin.tris:add(tri)
    tri.x, tri.y = bin.x, bin.y
    bin.sx = bin.sx + tri.sx + 1
    bin.x = bin.x + tri.sx + 1
    bins:add(bin)
    mapSY = mapSY + bin.sy + 1
    ::found::
  end

  local fill = 100 * (texelScale * texelScale * totalArea) / (mapSX * mapSY)
  printf('[UVMapper] %d tris packed into %.2f x %.2f with %.2f%% fill', #tris, mapSX, mapSY, fill)

  local scale = max(mapSX, mapSY)
  for i = 1, #tris do
    local tri = tris[i]
    tri.x = tri.x / scale
    tri.y = tri.y / scale
    tri.sx = tri.sx / scale
    tri.sy = tri.sy / scale
    tri.oy = tri.oy / scale
  end

  for i = 1, #tris do
    local tri = tris[i]
    local v1, v2, v3 = vertices + tri.i1, vertices + tri.i2, vertices + tri.i3
    v1.u, v1.v = tri.x, tri.y
    v2.u, v2.v = tri.x, tri.y + tri.sy
    v3.u, v3.v = tri.x + tri.sx, tri.y + tri.oy
  end

  mesh:free()
  Profiler.End()
  return self
end

return createUVMap
