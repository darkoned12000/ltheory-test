local Entity = require('Game.Entity')

-- A short-lived world-space industrial mining beam. The source ship owns it as
-- a child entity, so it follows the normal render broadcast and disappears when
-- the MineAt action stops.

local MiningBeam
MiningBeam = subclass(Entity, function (self, source, target)
  self.source = source
  self.target = target
  self.active = true
  self.accuracy = 1
  self:register(Event.Render, MiningBeam.render)
end)

local mesh
local shader

Preload.Add (function ()
  mesh = Gen.Primitive.Billboard(-1, -1, 1, 0)
  shader = Cache.Shader('billboard/axis', 'effect/pulsetail')
end)

local function usable (entity)
  return not entity.deleted and (not entity.isDestroyed or not entity:isDestroyed())
end

function MiningBeam.GetPose (source, target, index)
  if not source or not target or not usable(source) or not usable(target) then return nil end
  local origin = source:getPos()
  local delta = target:getPos() - origin
  if delta:length() < 1e-6 then return nil end
  local dir = delta:normalize()
  index = index or 1
  local lateral = index - 1
  local right = source.getRight and source:getRight() or Vec3f(1, 0, 0)
  local up = source.getUp and source:getUp() or Vec3f(0, 1, 0)
  local vertical = index == 1 and 0 or (index == 0 and -1 or 1)
  local start = origin + source:getForward():scale(source:getRadius() * 1.05)
               + right:scale(lateral * source:getRadius() * 0.18)
               + up:scale(vertical * source:getRadius() * 0.05)
  local finish = target:getPos() - dir:scale(target:getRadius() * 0.65)
               + right:scale(lateral * target:getRadius() * 0.04)
  local beamDir = finish - start
  local length = beamDir:length()
  if length <= 1e-3 then return nil end
  return {
    start = start,
    finish = finish,
    mid = start + beamDir:scale(0.5),
    dir = beamDir:normalize(),
    length = length,
  }
end

function MiningBeam.GetColor (accuracy)
  accuracy = math.max(0, math.min(1, accuracy or 1))
  local drift = 1.0 - accuracy
  return { 0.10 + 0.90 * drift, 0.65 - 0.55 * drift, 1.0 - 0.90 * drift }
end

function MiningBeam:setAccuracy (accuracy)
  self.accuracy = math.max(0, math.min(1, accuracy or 1))
end

function MiningBeam.GetRenderPose (source, target, index)
  local pose = MiningBeam.GetPose(source, target, index)
  if not pose then return nil end
  -- The axis billboard's UVs extend along negative local Z. Matrix.LookUp's
  -- local Z faces opposite its look direction, so passing +dir extends the
  -- quad from the ship nose toward the rock.
  return { position = pose.start, direction = pose.dir, length = pose.length }
end

function MiningBeam:render (state)
  if not self.active or state.mode ~= BlendMode.Additive then return end
  shader:start()
  local color = MiningBeam.GetColor(self.accuracy)
  Shader.SetFloat3('color', color[1], color[2], color[3])
  for index = 0, 2 do
    local pose = MiningBeam.GetRenderPose(self.source, self.target, index)
    if pose then
      local matrix = Matrix.LookUp(pose.position, pose.direction, Math.OrthoVector(pose.direction))
      Shader.SetFloat('alpha', 1.0)
      Shader.SetFloat2('size', 4.0, pose.length)
      Shader.SetFloat3('axis', pose.direction.x, pose.direction.y, pose.direction.z)
      Shader.SetMatrix('mWorld', matrix)
      mesh:draw()
      matrix:free()
    end
  end
  shader:stop()
end

return MiningBeam
