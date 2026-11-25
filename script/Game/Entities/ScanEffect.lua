local Entity = require('Game.Entity')

-- Rotating resource scanner. Green while searching, green-white on success,
-- red on failure. Four thin world-space sweeps make the 5-10 second process
-- readable from outside the ship.

local ScanEffect
ScanEffect = subclass(Entity, function (self, source, target)
  self.source = source
  self.target = target
  self.time = 0
  self.result = nil
  self.active = true
  self:register(Event.Render, ScanEffect.render)
  self:register(Event.Update, ScanEffect.update)
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

function ScanEffect.GetPose (source, target, index, time)
  if not source or not target or not usable(source) or not usable(target) then return nil end
  local origin = source:getPos()
  local delta = target:getPos() - origin
  if delta:length() < 1e-6 then return nil end
  local dir = delta:normalize()
  local right = source.getRight and source:getRight() or Vec3f(1, 0, 0)
  local up = source.getUp and source:getUp() or Vec3f(0, 1, 0)
  local angle = (time or 0) * 1.8 + (index or 0) * math.pi * 0.5
  local start = origin + source:getForward():scale(source:getRadius() * 1.05)
               + right:scale(math.cos(angle) * source:getRadius() * 0.45)
               + up:scale(math.sin(angle) * source:getRadius() * 0.45)
  local finish = target:getPos() - dir:scale(target:getRadius() * 0.65)
               + right:scale(math.cos(angle + 0.8) * target:getRadius() * 0.12)
               + up:scale(math.sin(angle + 0.8) * target:getRadius() * 0.12)
  local beamDir = finish - start
  local length = beamDir:length()
  if length <= 1e-3 then return nil end
  return { start = start, finish = finish, dir = beamDir:normalize(), length = length }
end

function ScanEffect.GetRenderPose (source, target, index, time)
  local pose = ScanEffect.GetPose(source, target, index, time)
  if not pose then return nil end
  return { position = pose.start, direction = pose.dir, length = pose.length }
end

function ScanEffect.GetColor (result)
  if result == false then return { 1.0, 0.08, 0.04 } end
  if result == true then return { 0.2, 1.0, 0.45 } end
  return { 0.08, 0.9, 0.3 }
end

function ScanEffect:update (state)
  self.time = self.time + state.dt
end

function ScanEffect:render (state)
  if not self.active or state.mode ~= BlendMode.Additive then return end
  local color = ScanEffect.GetColor(self.result)
  shader:start()
  Shader.SetFloat3('color', color[1], color[2], color[3])
  for index = 0, 3 do
    local pose = ScanEffect.GetRenderPose(self.source, self.target, index, self.time)
    if pose then
      local matrix = Matrix.LookUp(pose.position, pose.direction, Math.OrthoVector(pose.direction))
      Shader.SetFloat('alpha', 0.9)
      Shader.SetFloat2('size', 2.2, pose.length)
      Shader.SetFloat3('axis', pose.direction.x, pose.direction.y, pose.direction.z)
      Shader.SetMatrix('mWorld', matrix)
      mesh:draw()
      matrix:free()
    end
  end
  shader:stop()
end

return ScanEffect
