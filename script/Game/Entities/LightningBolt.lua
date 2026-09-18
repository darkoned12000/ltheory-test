-- LightningBolt -- decorative life-limited ribbon bolt (fog-nebula Phase 4, M3).
-- Pure sim data + deterministic geometry: a jagged polyline running from the
-- plume nucleus to the strike point, generated from (seed, ordinal) so a fixed
-- sector seed replays the exact same bolt. No rigid body, no collision, no
-- damage -- the volumetric flash in volume.glsl does the lighting work; this
-- ribbon is the lit "channel" your eye follows. GameView projects it and draws
-- it as an additive screen-space polyline in the UI pass.

local Entity = require('Game.Entity')

local SEAMS = 14              -- polyline segments (12-16 band)
local BRANCHES = 2            -- side forks per bolt (real bolts fork)
local BSEAMS = 5              -- segments per fork

-- Deterministic jagged path nucleus -> target. Jitter peaks mid-flight and
-- dams at both anchors, so the strike roots exactly at the plume and the tip.
-- hash32 is the same exact integer hash NebulaVolumes/LightningStorm use
-- ([0,1) — the mod repairs LuaJIT's signed bitops); seed arrives already
-- folded to 32 bits by the controller.
local function hash32 (x, y, z, seed, k)
  local h = (x * 374761393 + y * 668265263 + z * 224682251 + seed * 3266489917 + k * 2654435761) & 0xFFFFFFFF
  h = ((h ~ (h >> 13)) * 1274126177) & 0xFFFFFFFF
  h = (h ~ (h >> 16)) & 0xFFFFFFFF
  return (h % 4294967296) / 4294967296.0
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

-- Side fork off the main channel at a deterministic mid node: shorter, kicked
-- sideways off the parent direction, same hash family salted by branch index
-- so a fixed sector seed replays identical forks.
local function branch (pts, seed, ordinal, b)
  local ni = math.floor(SEAMS * (0.35 + 0.2 * hash32(0, 0, b, seed, ordinal + 500)))
  ni = math.max(1, math.min(SEAMS - 1, ni))
  local root = pts[ni + 1] -- pts holds SEAMS+1 nodes (t = 0..SEAMS)
  local main = pts[SEAMS + 1] - root
  local mlen = main:length()
  if mlen < 1e-3 then return nil end
  local dir = main:scale(1.0 / mlen)
  local kick = Vec3f(hash32(0, 0, b, seed, ordinal + 600) * 2 - 1,
                      hash32(0, 0, b, seed, ordinal + 620) * 2 - 1,
                      hash32(0, 0, b, seed, ordinal + 640) * 2 - 1)
  local side = dir:cross(kick)
  if side:length() < 1e-3 then side = dir:cross(Vec3f(0, 1, 0)) end
  side = side:normalize()
  local blen = mlen * (0.25 + 0.2 * hash32(0, 0, b, seed, ordinal + 660))
  local out = {}
  for i = 0, BSEAMS do
    local t = i / BSEAMS
    local along = root + side:scale(blen * t) + dir:scale(blen * 0.35 * t)
    local wob = math.sin(math.pi * t) * blen * 0.25
    local jx = (hash32(i, b, 0, seed, ordinal + 700) * 2 - 1) * wob
    local jy = (hash32(i, b, 1, seed, ordinal + 720) * 2 - 1) * wob
    out[#out + 1] = along + Vec3f(jx, jy, 0)
  end
  return out
end

local LightningBolt = subclass(Entity, function (self, e, nucleus, seed, ordinal)
  self.color = Vec3f(e.color.x, e.color.y, e.color.z)
  self.life  = e.duration
  self.age   = 0
  self.points = geometry(e.target, nucleus, seed, ordinal)
  self.branches = {}
  for b = 0, BRANCHES - 1 do
    local br = branch(self.points, seed, ordinal, b)
    if br then self.branches[#self.branches + 1] = br end
  end
  self:register(Event.Update, self.update)
end)

function LightningBolt:update (state)
  self.age = self.age + state.dt
  if self.age >= self.life then self:delete() end
end

return LightningBolt