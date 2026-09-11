local MeshUtil = {}

--[[----------------------------------------------------------------------------
  Combines an array of Mesh objects (`meshlist`) into a single unified Mesh.
  Note: Does not automatically free the input meshes in `meshlist`.
----------------------------------------------------------------------------]]--
function MeshUtil.Combine (meshlist)
  local mesh = Mesh.Create()
  for i = 1, #meshlist do
    mesh:addMesh(meshlist[i])
  end
  return mesh
end

--[[----------------------------------------------------------------------------
  Computes surface normals and per-vertex ambient occlusion for a mesh.
  `aoRadius` defaults to 1.0 if omitted.
----------------------------------------------------------------------------]]--
function MeshUtil.Finalize (mesh, aoRadius)
  mesh:computeNormals()
  mesh:computeAO(aoRadius or 1.0)
  return mesh
end

return MeshUtil
