--[[ TODO ----------------------------------------------------------------------
  - Generators should output ShipTypes, not just meshes (so that generating
    algorithm can select mount points, etc)
  - Now that entities are well-unified, these metatypes should be unified as
    well; we only need one 'prototype' class.
----------------------------------------------------------------------------]]--

local Ship = require('Game.Entities.Ship')
local LTheory_SocketType = require('Game.SocketKind')
local MeshValidate = require('ffi.libphx').lib.Mesh_Validate

local ShipType = class(function (self, seed, generator, scale, meta)
  local rng = RNG.Create(seed)
  self.seed = seed
  meta = meta or {}
  self.kind = meta.kind
  self.classId = meta.classId
  self.model = meta.model
  local mesh, meshSeed
  self.rejectedMeshes = {}
  for attempt = 0, 7 do
    local candidateSeed = seed + attempt
    local candidate = generator(candidateSeed, Config.gen.shipRes)
    candidate = candidate and candidate:managed()
    if candidate and MeshValidate(candidate) == 0 then
      mesh, meshSeed = candidate, candidateSeed
      break
    end
    if candidate then self.rejectedMeshes[#self.rejectedMeshes + 1] = candidate end
  end
  if not mesh and Gen.Ship and Gen.Ship.ShipFighter then
    for attempt = 0, 7 do
      local candidateSeed = seed + 101 + attempt
      local candidate = Gen.Ship.ShipFighter(candidateSeed, Config.gen.shipRes):managed()
      if MeshValidate(candidate) == 0 then
        mesh, meshSeed = candidate, candidateSeed
        break
      end
      self.rejectedMeshes[#self.rejectedMeshes + 1] = candidate
    end
  end
  assert(mesh, 'Unable to generate a valid ship mesh')
  self.seed = meshSeed
  self.mesh = mesh
  self.bsp = BSP.Create(self.mesh):managed()
  self.scale = scale

  self.sockets = {

[LTheory_SocketType.Thruster] = {},
    [LTheory_SocketType.Turret] = {}
  }

  for i = 1, Config.gen.nTurrets do
    local p = Gen.GenUtil.FindMountPoint(self.mesh, self.bsp, rng, Vec3f(0, 1, 0), Vec3f(0, 0, 1), 1000)
    if p then
      insert(self.sockets[LTheory_SocketType.Turret], p * Vec3f( 1, 1, 1))
      insert(self.sockets[LTheory_SocketType.Turret], p * Vec3f(-1, 1, 1))
    end
  end

  for i = 1, Config.gen.nThrusters do
    -- Ships fly along -Z (Entity forward); rear-facing hull surfaces point
    -- +Z. Searching -Z normals mounted engines on the NOSE, so their plumes
    -- fired straight through the hull.
    local p = Gen.GenUtil.FindMountPoint(self.mesh, self.bsp, rng, Vec3f(0, 0, 1), Vec3f(0, 0, 1), 1000)
    if p then
      insert(self.sockets[LTheory_SocketType.Thruster], p * Vec3f( 1, 1, 1))
      insert(self.sockets[LTheory_SocketType.Thruster], p * Vec3f(-1, 1, 1))
    end
  end

  rng:free()
end)

function ShipType:instantiate (stableId)
  self.instanceSerial = (self.instanceSerial or 0) + 1
  return Ship(self, self.instanceSerial, stableId)
end

return ShipType
