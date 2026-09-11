local sqrt = math.sqrt

--[[----------------------------------------------------------------------------
  Constructs a point billboard quad. Vertex positions are set to (0,0,0) with
  UV offsets passed in vertex attributes for GPU billboard expansion shaders.
----------------------------------------------------------------------------]]--
local function Billboard (u0, v0, u1, v1)
  local self = Mesh.Create()
  self:addVertex(0, 0, 0, 0, 0, 0, u0, v0)
  self:addVertex(0, 0, 0, 0, 0, 0, u1, v0)
  self:addVertex(0, 0, 0, 0, 0, 0, u1, v1)
  self:addVertex(0, 0, 0, 0, 0, 0, u0, v1)
  self:addQuad(0, 3, 2, 1)
  return self
end

--[[----------------------------------------------------------------------------
  Generates a spherical Mesh by subdividing an icosahedron `n` times.
  Note: Vertex count scales exponentially ($20 \times 4^n$ tris); keep $n \le 5$.
----------------------------------------------------------------------------]]--
local function IcoSphere (n)
  local p = (1.0 + sqrt(5)) / 2.0
  local self = PolyMesh()
    :addVertex(0,  p,  1) :addVertex(0, p, -1) :addVertex( 0, -p, 1) :addVertex(0, -p, -1)
    :addVertex(-1, 0, -p) :addVertex(1, 0, -p) :addVertex(-1,  0, p) :addVertex(1,  0,  p)
    :addVertex(-p,  1, 0) :addVertex(p, 1,  0) :addVertex(-p, -1, 0) :addVertex(p, -1,  0)
    :addTri(1, 0, 9)  :addTri(1, 9, 5)  :addTri(1, 5, 4)  :addTri(1, 4, 8)  :addTri(1, 8, 0)
    :addTri(7, 6, 2)  :addTri(11, 7, 2) :addTri(3, 11, 2) :addTri(10, 3, 2) :addTri(6, 10, 2)
    :addTri(9, 0, 7)  :addTri(9, 7, 11) :addTri(5, 9, 11) :addTri(5, 11, 3) :addTri(5, 3, 4)
    :addTri(4, 3, 10) :addTri(4, 10, 8) :addTri(8, 10, 6) :addTri(0, 8, 6)  :addTri(0, 6, 7)

  for i = 1, n or 1 do self:tessellate() end
  self:spherize()
  local mesh = self:getMesh()
  mesh:computeNormals()
  return mesh
end

return {
  Billboard = Billboard,
  IcoSphere = IcoSphere,
}
