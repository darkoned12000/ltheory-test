-- LightningBolt -- decorative life-limited ribbon bolt (fog-nebula Phase 4, M3).
-- Pure sim data + deterministic geometry: a jagged polyline running from the
-- plume nucleus to the strike point, generated from (seed, ordinal) so a fixed
-- sector seed replays the exact same bolt. No rigid body, no collision, no
-- damage -- the volumetric flash in volume.glsl does the lighting work; this
-- ribbon is the lit "channel" your eye follows. GameView projects it and draws
-- it as an additive screen-space polyline in the UI pass.

local Entity = require('Game.Entity')

local SEAMS = 14              -- polyline segments (12-16 band)

-- Deterministic jagged path nucleus -> target. Jitter peaks mid-flight and
-- dams at both anchors, so the strike roots exactly at the plume and the tip.
-- hash32 is the same exact integer hash NebulaVolumes/LightningStorm use.
local function hash32 (x, y, z, seed, k)
  local h = (x * 374761393 + y * 668265263 + z * 224682251 + seed * 3266489917 + k * 2654435761) & 0xFFFFFFFF
  h = ((h ~ (h >> 13)) * 1274126177) & 0xFFFFFFFF
  h = (h ~ (h >> 16)) & 0xFFFFFFFF
  return h / 4294967296.0
end

local function geometry (target, nucleus, seed, ordinal)
  local from = Vec3f(nucleus[1], nucleus[2], nucleus[3])
  local dir = target - from
  local len = dir:length()
  if len < 1e-3 then return { target } end
  local base = dir:scale(1.0 / len)
  -- Perpendicular frame (stable even when base is near-axis-aligned).
  local ref = math.abs(base.x) < 0.9 and Vec3f(1, 0, 0) or Vec3f(0, 1, 0)
  local up = base:cross(ref):normalize()
  local right = base:cross(up):normalize()

  local pts = {}
  for i = 0, SEAMS do
    local t = i / SEAMS
    local along = from + base:scale(len * t)
    local arch = math.sin(math.pi * t) * len * 0.18
    local hy = (hash32(0, 0, i, seed, ordinal) * 2 - 1) * arch
    local hz = (hash32(0, 0, i, seed, ordinal + 100) * 2 - 1) * arch
    pts[#pts + 1] = along + up:scale(hy) + right:scale(hz)
  end
  return pts
end

local LightningBolt = subclass(Entity, function (self, e, nucleus, seed, ordinal)
  self.color = Vec3f(e.color.x, e.color.y, e.color.z)
  self.life  = e.duration
  self.age   = 0
  self.points = geometry(e.target, nucleus, seed, ordinal)
  self:register(Event.Update, self.update)
end)

function LightningBolt:update (state)
  self.age = self.age + state.dt
  if self.age >= self.life then self:delete() end
end

return LightningBolt