local Seed = require('Game.Seed')

local kFleckDistance = 1024

-- The SYSTEM, so the dust can ask it for the environmental field (13a).
local Dust = class(function (self, system)
  self.system = system
end)

function Dust:forceLoad ()
  if self.clouds then return end
  -- Loaded lazily on first render, well after Seed.setWorld, so the dust field
  -- is part of the reproducible world.
  local rng = Seed.rng('dust'):managed()

  do -- Dust clouds mesh
    local mesh = Mesh.Create():managed()
    for i = 1, Config.gen.nDustClouds do
      local p = rng:getVec3(-kFleckDistance, kFleckDistance)
      mesh:addVertex(p.x, p.y, p.z, 0, 0, 1, -1, -1)
      mesh:addVertex(p.x, p.y, p.z, 0, 0, 1,  1, -1)
      mesh:addVertex(p.x, p.y, p.z, 0, 0, 1,  1,  1)
      mesh:addVertex(p.x, p.y, p.z, 0, 0, 1, -1,  1)
      local i0 = 4 * (i + 1)
      mesh:addQuad(i0, i0 + 3, i0 + 2, i0 + 1)
    end
    self.clouds = mesh
  end

  do -- Dust fleck mesh
    local mesh = Mesh.Create():managed()
    for i = 1, Config.gen.nDustFlecks do
      local p = rng:getVec3(-kFleckDistance, kFleckDistance)
      mesh:addVertex(p.x, p.y, p.z, 0, 0, 1, -1, 0)
      mesh:addVertex(p.x, p.y, p.z, 0, 0, 1,  1, 0)
      mesh:addVertex(p.x, p.y, p.z, 0, 0, 1,  1, 1)
      mesh:addVertex(p.x, p.y, p.z, 0, 0, 1, -1, 1)
      local i0 = 4 * (i + 1)
      mesh:addQuad(i0, i0 + 3, i0 + 2, i0 + 1)
    end
    self.flecks = mesh
  end
end

local mIdentity = Matrix.Identity()

-- How much dust there is HERE (13a).
--
-- The dust is the last of the four subsystems that had a private stream of
-- its own (the nebula, the rocks and the lightning now all read the shared
-- field), and it is the one that was most obviously wrong for it: the same
-- dust in every sector, at the same density, whatever kind of place the
-- player was in.
--
-- The field's dust channel is the medium's own texture, so a "Dust Expanse"
-- region is dusty and the clear ones are not.
function Dust:amountAt (x, y, z)
  local system = self.system
  if not (system and system.fieldAt) then return 1 end
  local f = system:fieldAt(x, y, z)
  if not f then return 1 end
  return 0.25 + (f.dust or 0.5) * 1.5
end

function Dust:render (state)
  self:forceLoad()
  if state.mode == BlendMode.Alpha then
    Profiler.Begin('DustClouds.RenderAlpha')
    local cam = Camera.get()
    local shader = Cache.Shader('billboard/wrapped', 'effect/dustcloud')
    local up = cam.rot:getUp()
    shader:start()
    Shader.SetFloat3('axis', up.x, up.y, up.z)
    Shader.SetFloat2('size', 64, 64)
    Shader.SetFloat('dustAmount', self:amountAt(cam.pos.x, cam.pos.y, cam.pos.z))
    Shader.SetMatrix('mWorld', mIdentity)
    self.clouds:draw()
    shader:stop()
    Profiler.End()
  elseif state.mode == BlendMode.Additive then
    Profiler.Begin('DustFlecks.RenderAdditive')
    local velocity = state.velocity
    local vl = velocity and velocity:length() or 0
    -- Below this, the streak is sub-world-unit and contributes no visible
    -- pixels; avoid submitting the 1024-quad mesh for tiny camera drift.
    if vl > 10.0 then
      local vn = velocity:normalize()
      local shader = Cache.Shader('billboard/wrapped', 'effect/dustfleck')
      shader:start()
      Shader.SetMatrix('mWorld', mIdentity)
      Shader.SetFloat2('size', 2.0, 0.1 * min(1000.0, vl))
      Shader.SetFloat3('axis', vn.x, vn.y, vn.z)
      Shader.SetFloat('speed', vl)
      -- The flecks branch has no `cam` local of its own, so ask the camera
      -- directly.
      local cam2 = Camera.get()
      Shader.SetFloat('dustAmount', self:amountAt(cam2.pos.x, cam2.pos.y, cam2.pos.z))
      self.flecks:draw()
      shader:stop()
    end
    Profiler.End()
  end
end

return Dust
