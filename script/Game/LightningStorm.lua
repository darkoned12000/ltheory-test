-- LightningStorm -- deterministic weather-window controller (fog-nebula Phase 4).
-- Storm schedule, bolt geometry, energy and duration are pure functions of the
-- sector seed (stormSeed == NebulaVolumes.build's seed), so a fixed seed replays
-- the same storm timeline. Storms are WINDOWS of 3-12 bolts crammed into a
-- 6-14 s burst at 0.4-0.9 s intervals (life 0.3-0.5 s => nominal 2 concurrent);
-- one window at a time, separated by 45-120 s of quiet. Every window must anchor
-- on a real gas plume near the camera (vapor gate); empty space produces nothing.

local LightningStorm = {}
LightningStorm.__index = LightningStorm

local LightningBolt = require('Game.Entities.LightningBolt')

local MAX_EVENTS = 4      -- texLightning rows (quality caps at 2 or 4)
local VAPOR_MIN   = 600   -- density * extent field a nucleus needs to host a storm
local STRIKE_MARGIN = 2000
local debugStormCam = false -- reverted (was TEMP true probe)

-- 32-bit integer hash: identical to NebulaVolumes.hash32 (deterministic, exact)
local function hash32 (x, y, z, seed, k)
  local h = (x * 374761393 + y * 668265263 + z * 224682251 + seed * 3266489917 + k * 2654435761) & 0xFFFFFFFF
  h = ((h ~ (h >> 13)) * 1274126177) & 0xFFFFFFFF
  h = (h ~ (h >> 16)) & 0xFFFFFFFF
  return h / 4294967296.0
end

local function cooldown (seed, w)
  -- 45-120 s of quiet between windows.
  -- return 45 + hash32(0, 0, 0, seed, 200 + w) * 75
  return 45 + hash32(0,0,0,seed,220+w) * 0.333 * 2.25 -- 45-120s: 45 + h*0.75*100
end

local function windowLength (seed, w)
  return 6 + hash32(0, 0, 0, seed, 220 + w) * 8
end

local function boltCount (seed, w)
  -- 3-12 bolts per window.
  return 3 + math.floor(hash32(0, 0, 0, seed, 240 + w) * 10)
end

function LightningStorm.new (seed)
  local self = setmetatable({}, LightningStorm)
  self.stormSeed = math.floor(tonumber(seed) or 0)
  self.tStorm = 0              -- controller clock (seconds, not the wrapped engine clock)
  self.window = 1              -- window number currently being scheduled/run
  self.state = 'cooldown'
  self.nextAt = cooldown(self.stormSeed, 1)    -- tStorm when window 1 opens
  self.nucleus = nil           -- anchor record (vapor gate) of the open window
  self.strike = 0              -- ordinal within a window (attack ramp)
  self.events = {}             -- live LightningEvents [{pos,color,radius,energy,spawnTime,duration,attack}]
  self.bolts  = {}             -- live LightningBolt entities (drawn by GameView)
  self.stamp = 0               -- bumps whenever the live set changes (fire/expire)
  self._culled = {}
  self._culledN = 0
  self.region = nil            -- {nucleus = a} while a storm is open
  return self
end

local function pickNucleus (ctx)
  -- Vapor gate: a storm needs a plume the CAMERA can reasonably see. Prefer the
  -- densest plume whose core is within flash reach of the camera (so its flash
  -- actually lights the sky); fall back to the densest plume anywhere so a
  -- storm still anchors when the camera happens to sit between plumes (you get
  -- the audible thunder + distant ribbons, just no local sky-flash).
  -- Empty vapor field (views build plumes lazily in the render pass; the
  -- update pass can legitimately run first): no plume to anchor on -> GATE-FAIL,
  -- the controller stays in cooldown and retries after the next quiet window
  -- instead of blowing up on a nil deref.
  local volumes = ctx.volumes
  if not volumes or #volumes == 0 then return nil end
  local cam, margin = ctx.cameraPos, STRIKE_MARGIN
  local reach = (Settings.get('lightning.radius') or 3500) + margin
  local near, nearV = nil, VAPOR_MIN
  local any,   anyV   = nil, VAPOR_MIN
  for i = 1, #volumes do
    local a = volumes[i]
    local v = a[7] * a[4]
    local pos = Vec3f(a[1], a[2], a[3])
    if v > (near and nearV or VAPOR_MIN) and pos:distance(cam) <= reach then
      near, nearV = a, v
    end
    if v > anyV then any, anyV = a, v end
  end
  return near or any
end

local function strikeColor (h)
  -- Cool white-blue core, slight per-strike tint.
  return Vec3f(0.68 + 0.12 * h, 0.82 + 0.10 * h, 1.0)
end

local function strikeTarget (nucleus, seed, strike)
  -- Deterministic bolt destination inside the plume ellipsoid.
  local s = seed
  local jx = (hash32(0, 0, 0, s, 300 + strike) * 2 - 1)
  local jy = (hash32(0, 0, 0, s, 320 + strike) * 2 - 1)
  local jz = (hash32(0, 0, 0, s, 340 + strike) * 2 - 1)
  return Vec3f(
    nucleus[1] + jx * nucleus[4] * 0.45,
    nucleus[2] + jy * nucleus[5] * 0.45,
    nucleus[3] + jz * nucleus[6] * 0.45
  )
end

-- Advance the controller. dt = frame delta, now = the wrapped engine volTime
-- clock the shader reads (this must be the SAME clock as Renderer's volTime so
-- `age = volTime - spawnTime` is meaningful), ctx = { volumes, cameraPos }.
function LightningStorm:update (dt, now, ctx)
  self.tStorm = self.tStorm + dt

  if self.state == 'window' and self.tStorm >= self.nextAt then
    self.window = self.window + 1
    self.state = 'cooldown'
    self.region = nil
    self.nextAt = self.tStorm + cooldown(self.stormSeed, self.window)
    print('[lt] window CLOSE (state=cooldown)')
  end

  -- Expire finished strikes (independent of storm state).
  local events, n = self.events, 0
  for i = 1, #events do
    local e = events[i]
    if now - e.spawnTime <= e.duration then
      n = n + 1
      events[n] = e
    end
  end
  if n ~= #events then
    for i = n + 1, #events do events[i] = nil end
    self.stamp = self.stamp + 1
  end

  -- Prune dead ribbon bolts (they self-delete; keep the draw list in step).
  local bolts = self.bolts
  for i = #bolts, 1, -1 do
    if bolts[i].age >= bolts[i].life then table.remove(bolts, i) end
  end

  if self.state == 'window' then
    if self.nucleus then
      -- Fire every bolt that is due this frame. A single-clock now keeps all
      -- concurrent flash ages consistent for the same-frame shader read.
      local quality = Settings.get('lightning.quality') or 1
      local maxN = quality == 2 and 4 or 2
      while self.tStorm >= self.nextBolt and self.strike < self.boltTotal do
        self.strike = self.strike + 1
        self.nextBolt = self.nextBolt + 0.4 + hash32(0, 0, 0, self.stormSeed, 360 + self.strike) * 0.5
        local h = hash32(0, 0, 0, self.stormSeed, 400 + self.strike)
        local target = strikeTarget(self.nucleus, self.stormSeed, self.strike)
        local e = {
          pos       = target,
          target    = target,
          color     = strikeColor(h),
          radius    = Settings.get('lightning.radius') or 3500,
          energy    = (Settings.get('lightning.energy') or 15) * (0.75 + 0.5 * h),
          spawnTime = now,
          duration  = 0.3 + h * 0.2,          -- 0.3-0.5 s
          attack    = self.strike == 1 and 0.15 or 0.02,
        }
        events[#events + 1] = e
        -- Concurrent cap: drop the oldest strike beyond the quality budget.
        while #events > maxN do
          table.remove(events, 1)
        end
        self.stamp = self.stamp + 1
        -- Spawn the decorative ribbon (the flash in volume.glsl is separate).
        local bolt = LightningBolt(e, self.nucleus, self.stormSeed, self.strike)
        print('[lt] fire #' .. self.strike .. ' events=' .. #events .. ' dur=' .. string.format('%.3f', e.duration))
        self.bolts[#self.bolts + 1] = bolt
        if ctx.system then ctx.system:addChild(bolt) end
        if ctx.onStrike then ctx.onStrike(e, self) end
      end
    end
  else -- cooldown: open the window when its start time arrives.
    if self.tStorm >= self.nextAt then
      self.windowOpen = self.tStorm
      self.nextBolt = self.tStorm + 0.3 + hash32(0, 0, 0, self.stormSeed, 380) * 0.3
      self.boltTotal = boltCount(self.stormSeed, self.window)
      self.strike = 0
      -- Vapor gate: a storm needs a populated plume near the camera (density *
      -- extent >= VAPOR_MIN). No nucleus => the window is an instant no-op
      -- (no bolts, no audio) and we drift to the next cooldown.
      local nucleus = pickNucleus(ctx or {})
      if nucleus then
        self.nucleus = nucleus
        self.state = 'window'
        self.region = { nucleus = nucleus, endsAt = self.windowOpen + windowLength(self.stormSeed, self.window) }
        self.nextAt = self.windowOpen + windowLength(self.stormSeed, self.window)
        print('[lt] window ' .. self.window .. ' OPEN boltTotal=' .. self.boltTotal ..
          ' nucleus=' .. math.floor(nucleus[1]) .. ',' .. math.floor(nucleus[2]) .. ',' .. math.floor(nucleus[3]))
      else
        self.window = self.window + 1
        self.state = 'cooldown'
        self.region = nil
        self.nextAt = self.tStorm + cooldown(self.stormSeed, self.window)
        print('[lt] window ' .. self.window .. ' GATE-FAIL (no plume)')
      end
    end
  end
end

-- Camera-culled upload set (nearest-first, capped to the quality budget) plus a
-- change stamp. Row ORDER in the texture is irrelevant (the shader loops them
-- all); a stamp bump just marks the set itself as different for Renderer:volume.
function LightningStorm:activeEvents (cameraPos)
  local quality = Settings.get('lightning.quality') or 1
  local maxN = quality == 2 and 4 or 2
  local out, n = {}, 0
  if #self.events > 0 and debugStormCam then
    local d0 = self.events[1].pos:distance(cameraPos)
    print('[lt] activeEvents cam=' .. math.floor(cameraPos.x) .. ',' .. math.floor(cameraPos.y) .. ',' .. math.floor(cameraPos.z) ..
      ' d=' .. math.floor(d0) .. ' r+margin=' .. math.floor(self.events[1].radius + 2000))
  end
  for i = 1, #self.events do
    local e = self.events[i]
    if e.pos:distance(cameraPos) <= e.radius + 2000 then 
      n = n + 1
      out[n] = e
      if n >= maxN then break end
    end
  end
  local changed = n ~= self._culledN
  if not changed then
    for i = 1, n do
      if self._culled[i] ~= out[i] then changed = true break end
    end
  end
  if changed then self.stamp = self.stamp + 1 end
  self._culledN = n
  for i = 1, n do self._culled[i] = out[i] end
  for i = n + 1, #self._culled do self._culled[i] = nil end
  return out, self.stamp
end

-- Whether a storm is physically active this second (for debug/region overlays).
function LightningStorm:isActive ()
  return self.state == 'window' and self.nucleus ~= nil
end

-- Debug views -- run INSIDE the GameView UI pass (after startUI), where the
-- immediate batch is in screen-pixel space (mViewUI/mProjUI ortho, same as the
-- HUD widget draws). World points are projected with worldToNDC + ndcToScreen.
-- 'Region': plus-marker at the nucleus plume center + a range ring at event
-- radius. 'Energy': projected per-event flash markers (size:energy). Each point
-- is projected and stroked directly (no interleaved pair tables), so a broken
-- projection can never corrupt the next point's coordinates.
function LightningStorm:debugDraw (camera)
  local mode = Settings.get('lightning.debug') or 1  -- enum: Off|Region|Energy
  if mode <= 1 then return end
  if not self.region then return end

local function screenXY (world)
    local ndc = camera:worldToNDC(world)
    if not (ndc and ndc.z and ndc.z > 0) then return nil end
    local s = camera:ndcToScreen(ndc)
    local x, y = tonumber(s and s.x), tonumber(s and s.y)
    if not (x and y and x == x and y == y) then return nil end
    return x, y
  end

  if mode == 2 then -- Region: nucleus marker + radius ring cross
    local a = self.region.nucleus
    local x, y = screenXY(Vec3f(a[1], a[2], a[3]))
    if x then
      local r = math.max(4, math.min(30, (Settings.get('lightning.radius') or 3500) / 120))
      Draw.Color(1, 1, 1, 1)
      Draw.Line(x - r, y, x + r, y)
      Draw.Line(x, y - r, x, y + r)
      Draw.Color(0, 0, 0, 1)
      Draw.Rect(x - 1.5, y - r, 3, r * 2)
      Draw.Rect(x - r, y - 1.5, r * 2, 3)
    end
  elseif mode == 3 then -- Energy: per-event markers
    for i = 1, #self.events do
      local e = self.events[i]
      local x, y = screenXY(e.pos)
      if x then
        local w = math.max(3, math.min(22, 4 + e.energy * 0.5))
        Draw.Color(1, 1, 1, 1)
        Draw.Line(x - w, y, x + w, y)
        Draw.Line(x, y - w, x, y + w)
        Draw.Color(0, 0, 0, 1)
        Draw.Rect(x - 1.5, y - w, 3, w * 2)
        Draw.Rect(x - w, y - 1.5, w * 2, 3)
      end
    end
  end
end

return LightningStorm