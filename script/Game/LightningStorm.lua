-- LightningStorm -- deterministic weather-window controller (fog-nebula Phase 4).
-- Storm schedule, bolt geometry, energy and duration are pure functions of the
-- sector seed (stormSeed == NebulaVolumes.build's seed), so a fixed seed replays
-- the same storm timeline. Storms are ambient: the first window opens ~3-5 s
-- after boot and quiet gaps are short (12-30 s), so lightning is visible almost
-- anywhere you can see cloud. Each window fires 8-16 bolts at 0.15-0.45 s
-- ragged intervals (life 0.5-0.9 s => typically 2-4 concurrent, caps 4/6);
-- the Storm Rate setting multiplies count and divides intervals together.
-- Every strike picks its OWN nucleus plume (deterministic per window+ordinal),
-- so bolts dance across the sky in many directions instead of one spot.
-- The vapor gate is sight-range: any populated plume within nebula radius can
-- host a strike, so distant storms still draw ribbons + thunder while only
-- nearby ones light the local volume pass.

local LightningStorm = {}
LightningStorm.__index = LightningStorm

local LightningBolt = require('Game.Entities.LightningBolt')

local MAX_EVENTS = 6      -- texLightning rows (quality caps at 4 or 6)
local VAPOR_MIN   = 600   -- density * extent field a nucleus needs to host a storm

-- 32-bit integer hash: identical to NebulaVolumes.hash32 (deterministic, exact).
-- Returns [0,1): LuaJIT bitops are signed, so a raw /2^32 can go negative for
-- half the inputs (bolts outside their plume, negative bolt counts) — the mod
-- folds it back. Must stay in sync with the copies in NebulaVolumes.lua and
-- LightningBolt.lua.
local function hash32 (x, y, z, seed, k)
  local h = (x * 374761393 + y * 668265263 + z * 224682251 + seed * 3266489917 + k * 2654435761) & 0xFFFFFFFF
  h = ((h ~ (h >> 13)) * 1274126177) & 0xFFFFFFFF
  h = (h ~ (h >> 16)) & 0xFFFFFFFF
  return (h % 4294967296) / 4294967296.0
end

local function foldSeed (seed)
  -- Sector seeds are 64-bit ULL, but doubles only hold 53-bit integers: the
  -- raw value's low bits are mush and seed*K rounds to a quantum that swallows
  -- every small x/y/z/k term, so hash32 returns ONE constant for all inputs
  -- (same nucleus, same duration, straight-line bolts every strike). XOR both
  -- 32-bit halves into 32 bits. Must match NebulaVolumes.build's fold so
  -- stormSeed ≡ plume seed stays replay-identical.
  local s = math.floor(tonumber(seed) or 0)
  local lo = s % 4294967296
  local hi = math.floor(s / 4294967296) % 4294967296
  return (lo ~ hi) & 0xFFFFFFFF
end

local function cooldown (seed, w)
  -- 12-30 s of quiet between windows (ambient storm field, not rare weather).
  return 12 + hash32(0, 0, 0, seed, 200 + w) * 18
end

local function firstDelay (seed)
  -- First window opens almost immediately so a fresh boot shows weather.
  return 3 + hash32(0, 0, 0, seed, 100) * 2
end

local function windowLength (seed, w)
  return 8 + hash32(0, 0, 0, seed, 220 + w) * 8
end

local function boltCount (seed, w)
  -- 8-16 bolts per window, scaled by the Storm Rate setting (replay stays
  -- deterministic for fixed settings; the quality cap still bounds overlap).
  local rate = Settings.get('lightning.rate') or 1
  return math.max(1, math.floor((8 + math.floor(hash32(0, 0, 0, seed, 240 + w) * 9)) * rate))
end

function LightningStorm.new (seed)
  local self = setmetatable({}, LightningStorm)
  self.stormSeed = foldSeed(seed)
  self.tStorm = 0              -- controller clock (seconds, not the wrapped engine clock)
  self.window = 1              -- window number currently being scheduled/run
  self.state = 'cooldown'
  self.nextAt = firstDelay(self.stormSeed)    -- tStorm when window 1 opens
  self.nuclei = nil            -- anchor records (vapor gate) of the open window
  self.nucleus = nil           -- primary nucleus (first strike / legacy alias)
  self.strike = 0              -- ordinal within a window (attack ramp)
  self.events = {}             -- live LightningEvents [{pos,color,radius,energy,spawnTime,duration,attack}]
  self.bolts  = {}             -- live LightningBolt entities (drawn by GameView)
  self.stamp = 0               -- bumps whenever the live set changes (fire/expire)
  self._culled = {}
  self._culledN = 0
  self.region = nil            -- {nucleus = a} while a storm is open
  return self
end

local function pickNuclei (ctx)
  -- Vapor gate (sight-range): storms need real plumes the camera can SEE, not
  -- ones the camera sits inside. Collect up to 6 densest plumes within nebula
  -- (volume) radius; strikes round-robin across them (rotated per window) so a
  -- window reads as activity across the whole sky, never 3 pops on one plume.
  -- only feels the nearby ones (radius cull), distant ones carry the ribbon +
  -- thunder. Empty vapor field (views build plumes lazily in the render pass;
  -- the update pass can legitimately run first): no plume to anchor on ->
  -- GATE-FAIL, the controller stays in cooldown and retries after the next
  -- quiet window instead of blowing up on a nil deref.
  local volumes = ctx.volumes
  if not volumes or #volumes == 0 then return nil end
  local cam = ctx.cameraPos
  local sight = Settings.get('nebula.radius') or 12000
  -- Frustum bias: plumes inside the player's view cone sort first, so storms
  -- play where the player looks; off-screen plumes stay in the list (a storm
  -- you can turn toward), just later in the rotation. No camDir (or looking
  -- straight down the list) => old nearest-first behavior.
  local fx, fy, fz, halfCos = 0, 0, 1, -2
  if ctx.camDir then
    local dl = math.sqrt(ctx.camDir.x * ctx.camDir.x + ctx.camDir.y * ctx.camDir.y + ctx.camDir.z * ctx.camDir.z)
    if dl > 1e-6 then fx, fy, fz = ctx.camDir.x / dl, ctx.camDir.y / dl, ctx.camDir.z / dl end
    halfCos = math.cos(math.rad((ctx.fovY or 70) * 0.5 + 25))
  end
  local scored = {}
  for i = 1, #volumes do
    local a = volumes[i]
    local v = a[7] * a[4]
    if v >= VAPOR_MIN then
      local dx, dy, dz = a[1] - cam.x, a[2] - cam.y, a[3] - cam.z
      local d = math.sqrt(dx * dx + dy * dy + dz * dz)
      if d <= sight and d > 1e-3 then
        local inview = (dx / d) * fx + (dy / d) * fy + (dz / d) * fz >= halfCos
        scored[#scored + 1] = { a = a, v = v, d = d, inview = inview }
      end
    end
  end
  if #scored == 0 then return nil end
  -- In-view first (nearest wins inside each group); vapor breaks distance
  -- ties so thin nearby wisps don't beat thick banks.
  table.sort(scored, function (x, y)
    if x.inview ~= y.inview then return x.inview end
    if x.d ~= y.d then return x.d < y.d end
    return x.v > y.v
  end)
  local out = {}
  for i = 1, math.min(6, #scored) do out[i] = scored[i] end
  return out
end

local function strikeColor (h)
  -- Cool white-blue core, slight per-strike tint.
  return Vec3f(0.68 + 0.12 * h, 0.82 + 0.10 * h, 1.0)
end

local function strikeTarget (nucleus, seed, window, strike)
  -- Deterministic bolt destination inside the plume ellipsoid. The window term
  -- keeps successive windows from replaying identical targets at one plume.
  local s = seed
  local wk = window * 64
  local jx = (hash32(0, 0, 0, s, wk + 300 + strike) * 2 - 1)
  local jy = (hash32(0, 0, 0, s, wk + 320 + strike) * 2 - 1)
  local jz = (hash32(0, 0, 0, s, wk + 340 + strike) * 2 - 1)
  return Vec3f(
    nucleus[1] + jx * nucleus[4] * 0.65,
    nucleus[2] + jy * nucleus[5] * 0.65,
    nucleus[3] + jz * nucleus[6] * 0.65
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
    self.nuclei = nil
    self.nucleus = nil
    self.nextAt = self.tStorm + cooldown(self.stormSeed, self.window)
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
    if self.nuclei then
      -- Fire every bolt that is due this frame. Each strike picks its own
      -- nucleus plume (deterministic per window+ordinal) so one window reads
      -- as lightning in many directions. A single-clock now keeps all
      -- concurrent flash ages consistent for the same-frame shader read.
      local quality = Settings.get('lightning.quality') or 1
      local maxN = quality == 2 and 6 or 4
      while self.tStorm >= self.nextBolt and self.strike < self.boltTotal do
        self.strike = self.strike + 1
        local rate = Settings.get('lightning.rate') or 1
        self.nextBolt = self.nextBolt + (0.15 + hash32(0, 0, 0, self.stormSeed, 360 + self.strike) * 0.3) / rate
        local h = hash32(0, 0, 0, self.stormSeed, 400 + self.strike)
        -- Round-robin across nuclei, rotated by window: every window visits
        -- every plume evenly (spread guaranteed, deterministic) instead of
        -- uniform-pick clusters of 3 on one plume.
        local ni = ((self.strike - 1 + self.window) % #self.nuclei) + 1
        local nucleus = self.nuclei[ni].a
        local target = strikeTarget(nucleus, self.stormSeed, self.window, self.strike)
        local e = {
          pos       = target,
          target    = target,
          color     = strikeColor(h),
          radius    = Settings.get('lightning.radius') or 3500,
          energy    = (Settings.get('lightning.energy') or 15) * (0.75 + 0.5 * h),
          spawnTime = now,
          duration  = 0.5 + h * 0.4,          -- 0.5-0.9 s (storm overlap)
          attack    = self.strike == 1 and 0.15 or 0.02,
        }
        events[#events + 1] = e
        -- Concurrent cap: drop the oldest strike beyond the quality budget.
        while #events > maxN do
          table.remove(events, 1)
        end
        self.stamp = self.stamp + 1
        -- Spawn the decorative ribbon (the flash in volume.glsl is separate).
        local bolt = LightningBolt(e, nucleus, self.stormSeed, self.strike)
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
      -- Vapor gate: a storm needs populated plumes in sight (density *
      -- extent >= VAPOR_MIN within nebula radius). No nucleus => the window
      -- is an instant no-op (no bolts, no audio) and we drift to the next
      -- cooldown.
      local nuclei = pickNuclei(ctx or {})
      if nuclei then
        self.nuclei = nuclei
        self.nucleus = nuclei[1].a
        self.state = 'window'
        self.region = { nuclei = nuclei, endsAt = self.windowOpen + windowLength(self.stormSeed, self.window) }
        self.nextAt = self.windowOpen + windowLength(self.stormSeed, self.window)
      else
        self.window = self.window + 1
        self.state = 'cooldown'
        self.region = nil
        self.nuclei = nil
        self.nucleus = nil
        self.nextAt = self.tStorm + cooldown(self.stormSeed, self.window)
      end
    end
  end
end

-- Live upload set (nearest-first, capped to the quality budget) plus a change
-- stamp. Row ORDER in the texture is irrelevant (the shader loops them all);
-- a stamp bump just marks the set itself as different for Renderer:volume.
-- No camera pre-cull: distant strikes cost ~nothing (the shader's per-step
-- radius reject drops them) and a strike 6k away still lights its own cloud
-- when you look at it — culling past radius+margin is what made far storms
-- silently vanish.
function LightningStorm:activeEvents (cameraPos)
  local quality = Settings.get('lightning.quality') or 1
  local maxN = quality == 2 and 6 or 4
  local out, n = {}, 0
  for i = 1, #self.events do
    n = n + 1
    out[n] = self.events[i]
    if n >= maxN then break end
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

  if mode == 2 then -- Region: marker per nucleus plume + radius ring cross
    local nuclei = self.region.nuclei or (self.region.nucleus and { { a = self.region.nucleus } } or {})
    for k = 1, #nuclei do
      local entry = nuclei[k]
      local a = entry.a or entry
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