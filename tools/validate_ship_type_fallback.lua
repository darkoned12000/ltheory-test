#!/usr/bin/env luajit
-- ShipType must reject invalid generated meshes and retry another seed before
-- BSP/socket construction. Only engine boundaries are stubbed.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_ship_type_fallback%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

function class (ctor)
  local cls = {}
  cls.__index = cls
  setmetatable(cls, { __call = function (T, ...)
    local self = {}
    setmetatable(self, cls)
    if ctor then ctor(self, ...) end
    return self
  end })
  return cls
end
function insert (t, v) t[#t + 1] = v end
_G.Config = { gen = { shipRes = 8, nTurrets = 0, nThrusters = 0 } }
_G.RNG = { Create = function (seed)
  return { free = function () end }
end }
_G.BSP = { Create = function (mesh)
  return { managed = function (self) return self end }
end }
_G.Gen = { GenUtil = { FindMountPoint = function () return nil end } }
_G.Vec3f = function () return {} end
package.loaded['Game.Entities.Ship'] = function () return {} end
package.loaded['Game.SocketKind'] = { Thruster = 1, Turret = 2 }
package.loaded['ffi.libphx'] = { lib = { Mesh_Validate = function (mesh)
  return mesh.seed == 100 and 1 or 0
end } }

local calls, meshes = {}, {}
local function generator (seed)
  calls[#calls + 1] = seed
  local mesh = { seed = seed, freed = false }
  meshes[#meshes + 1] = mesh
  function mesh:managed () return self end
  function mesh:free () self.freed = true end
  return mesh
end
local ShipType = dofile(root .. '/script/Game/ShipType.lua')
local proto = ShipType(100, generator, 4, { kind = 'fighter' })

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. detail) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or '')) end
end
check('invalid first seed is retried', #calls >= 2 and proto.mesh.seed ~= 100,
  string.format('calls=%d seed=%s', #calls, tostring(proto.mesh.seed)))
check('retry uses a deterministic nearby seed', calls[2] == 101)
check('invalid mesh is retained safely during retry', proto.rejectedMeshes[1] == meshes[1]
  and not meshes[1].freed)

if failures == 0 then
  print(string.format('ship type fallback: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('ship type fallback: %d/%d checks failed', failures, checks))
  os.exit(1)
end
