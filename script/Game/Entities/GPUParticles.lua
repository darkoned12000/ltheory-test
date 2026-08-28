--[[ GPUParticles -- compute-simulated, SSBO-rendered sprite pool.
  ----------------------------------------------------------------------------
  A single Entity owns a fixed-capacity particle pool that lives entirely in
  GPU memory:

    * `Event.Update` drains the CPU-side emit queue into a spawn SSBO and runs
      two compute kernels: particle_spawn (claims pool slots via an atomic ring
      cursor) and particle_simulate (integrates positions, applies drag,
      decrements life).
    * `Event.Render` (additive pass) draws the whole pool with ONE instanced
      draw call; the vertex shader expands camera-facing quads straight from
      the pool buffer -- no per-particle Lua work, no VBO, no mesh.

  Other systems never touch GL state; they just call:
      GPUParticles.explode(pos, baseVel, scale)
      GPUParticles.emit{ x=..., y=..., ... }          (one record = one sprite)

  Capacity notes: pool slots are recycled oldest-first, so bursts larger than
  the pool overwrite themselves rather than failing. Dead particles cost one
  clipped triangle pair in the vertex stage and nothing else.

  Data layout (SoA triplets of vec4, std430):
    posSize   : xyz = world position, w = sprite size (world units)
    velLife   : xyz = velocity (units/s), w = seconds of life remaining
    colMaxLife: rgb = color, a = max life (fade denominator)
]]

local Entity = require('Game.Entity')

local ffi = require('ffi')
local GPUBuffer = require('ffi.GPUBuffer')
local ShaderBarrier = Shader.Barrier

-- Pool geometry. 128k sprites * 48 B = ~6 MB VRAM.
local POOL_SIZE = 131072
local LOCAL_SIZE = 64
local MAX_SPAWNS_PER_FRAME = 8192
local RECORD_FLOATS = 16 -- four vec4s (last = exhaust axis used only for
                          -- streak shaping, so plume geometry is flight-independent)
local DRAG = 1.2         -- exponential velocity damping factor (per second)

-- glDrawArraysInstanced primitive enum for two-triangle quads.
local GL_TRIANGLES = 4

local function clamp (v, lo, hi) return min(max(v, lo), hi) end

-- CPU -> GPU spawn staging. Records beyond MAX_SPAWNS_PER_FRAME roll over to
-- the next frame instead of being dropped.
local queue = {}
local spawnData = ffi.new('float[?]', MAX_SPAWNS_PER_FRAME * RECORD_FLOATS)
local metaData = ffi.new('uint32_t[4]', { 0, 0, 0, 0 }) -- {count, tail(gpu), -}

local rng = RNG.FromTime()

-- PHX_SELFTEST_PARTICLES=1 : boot-time burst + pool readback verification.
local selfTestArmed = os.getenv('PHX_SELFTEST_PARTICLES') ~= nil

local GPUParticles = subclass(Entity, function (self)
  self:register(Event.Render, self.render)
  self:register(Event.Update, self.update)
end)

local spawnShader
local simShader
local drawShader
local poolBuf
local spawnBuf
local metaBuf
local uSpawnCapacity
local uSimDt
local uSimDrag
local uDrawSizeBoost

Preload.Add (function ()
  spawnShader = Cache.Compute('particle_spawn')
  simShader   = Cache.Compute('particle_simulate')
  drawShader  = Cache.Shader('particles', 'effect/gpu_particle')

  poolBuf  = GPUBuffer.Create(POOL_SIZE * RECORD_FLOATS * 4) -- MUST track
  -- RECORD_FLOATS: kernels write full 64B structs; a stale byte-count here
  -- turns every simulate dispatch into an out-of-bounds write
  spawnBuf = GPUBuffer.Create(MAX_SPAWNS_PER_FRAME * RECORD_FLOATS * 4)
  metaBuf  = GPUBuffer.Create(16)

  -- Binding points are context-global and nothing else in the engine uses
  -- SSBOs yet, so bind once here instead of every frame.
  poolBuf:bindSSBO(0)
  spawnBuf:bindSSBO(1)
  metaBuf:bindSSBO(2)

  uSpawnCapacity = ShaderVarCache(spawnShader, { 'capacity' })
  uSimDt         = ShaderVarCache(simShader,   { 'dt', 'drag' })
  uDrawSizeBoost = ShaderVarCache(drawShader,  { 'sizeBoost' })
end)

--[[
  emit -- queue one particle record (world-space). Table fields:
    x,y,z        position
    vx,vy,vz     initial velocity (units/s)
    size         sprite size (world units)
    r,g,b        color
    life         seconds until fade-out completes
]]
local freeRecords = {}

--[[ Records are recycled after packing: emitters call this ~1000x/sec while
  cruising, so allocating a fresh table per sprite made the GC sweep every
  second or two -- which showed up as a visible pulse in the trail. ]]
function GPUParticles.emit (record)
  if #queue < MAX_SPAWNS_PER_FRAME * 4 then
    queue[#queue + 1] = record
  else
    freeRecords[#freeRecords + 1] = record
  end
end

local function recycle (record)
  for k in pairs(record) do record[k] = nil end
  freeRecords[#freeRecords + 1] = record
end

function GPUParticles.newRecord ()
  return table.remove(freeRecords) or {}
end

--[[
  explode -- fireball burst at `pos`, inheriting `baseVel` (an entity's
  momentum) so debris keeps moving with its source. Scale drives count/speed/
  size together so big rocks pop bigger than small ones.
]]
function GPUParticles.explode (pos, baseVel, scale)
  -- Audio: one-shot boom sized with the burst (one-shot voices free themselves).
  local sfx = Config.audio.sfx.explosion
  local sound = Sound.Load(sfx.sound, false, true)
  sound:set3DPos(pos, baseVel)
  sound:set3DMinMaxDistance(sfx.minDist, 0)
  sound:setVolume(min(2.0, sfx.volume * (0.5 + 0.08 * scale)))
  sound:setFreeOnFinish(true)
  sound:play()

  local count = math.floor(min(400, max(60, scale * 60)))
  local speed = 6.0 + scale * 3.0
  local size  = clamp(scale, 0.5, 4.0)
  local bx, by, bz = baseVel.x, baseVel.y, baseVel.z
  for _ = 1, count do
    local d = rng:getSphere()
    GPUParticles.emit{
      x = pos.x, y = pos.y, z = pos.z,
      vx = bx + d.x * speed * (0.3 + 0.7 * rng:getUniform()),
      vy = by + d.y * speed * (0.3 + 0.7 * rng:getUniform()),
      vz = bz + d.z * speed * (0.3 + 0.7 * rng:getUniform()),
      size = size * (0.5 + rng:getUniform()),
      r = 2.0, g = 0.7 + 0.5 * rng:getUniform(), b = 0.15,
      life = 0.6 + 0.9 * rng:getUniform(),
    }
  end
end

function GPUParticles:update (state)
  -- Env-gated self-test: one burst shortly after boot, then a pool readback.
  -- Proves upload -> spawn kernel -> ring cursor -> simulate without needing
  -- to shoot anything. Look for '[PARTICLES-TEST] ... PASS' on stdout.
  if selfTestArmed then
    self.st = (self.st or 0) + state.dt
    if not self.burstDone and self.st > 0.5 then
      GPUParticles.explode(Config.gen.origin, Vec3f(0, 0, 0), 3)
      self.burstDone = true
    elseif self.burstDone and not self.checked and self.st > 1.5 then
      local samples = 256
      local probe = ffi.new('float[?]', samples * RECORD_FLOATS)
      GPUBuffer.Download(poolBuf, probe, samples * 64)
      local alive = 0
      for i = 0, samples - 1 do
        if probe[i * RECORD_FLOATS + 7] > 0 then alive = alive + 1 end
      end
      printf('[PARTICLES-TEST] %d/%d sampled slots alive -> %s',
        alive, samples, alive > 0 and 'PASS' or 'FAIL')
      self.checked = true
    end
  end

  local n = min(#queue, MAX_SPAWNS_PER_FRAME)

  if n > 0 then
    -- Pack records into the staging array (struct-of-vec4s layout).
    for i = 1, n do
      local r = queue[i]
      local o = (i - 1) * RECORD_FLOATS
      spawnData[o + 0]  = r.x  spawnData[o + 1]  = r.y
      spawnData[o + 2]  = r.z  spawnData[o + 3]  = r.size
      spawnData[o + 4]  = r.vx spawnData[o + 5]  = r.vy
      spawnData[o + 6]  = r.vz spawnData[o + 7]  = r.life
      spawnData[o + 8]  = r.r  spawnData[o + 9]  = r.g
      spawnData[o + 10] = r.b  spawnData[o + 11] = r.life
      -- Exhaust/shaping vector: emitters that care (thrusters) pass their
      -- pure nozzle direction here; everything else falls back to velocity.
      local ax, ay, az = r.ax or r.vx, r.ay or r.vy, r.az or r.vz
      spawnData[o + 12] = ax    spawnData[o + 13] = ay
      spawnData[o + 14] = az    spawnData[o + 15] = 0.0
    end
    -- Recycle packed records, preserving any overflow for next frame.
    for i = 1, n do recycle(queue[i]) end
    local remaining = #queue - n
    for i = 1, remaining do queue[i] = queue[i + n] end
    for i = remaining + 1, #queue do queue[i] = nil end

    GPUBuffer.Upload(spawnBuf, spawnData, n * 64)
    metaData[0] = n
    -- Upload ONLY the count word; the tail cursor is GPU-owned state.
    GPUBuffer.Upload(metaBuf, metaData, 4)

    spawnShader:start()
    Shader.ISetInt(uSpawnCapacity.capacity, POOL_SIZE)
    -- Group count must be an INTEGER: FFI casts floats to uint by truncation,
    -- so ceil-via-float would silently under-dispatch the tail batch.
    Shader.Dispatch(math.floor((n + LOCAL_SIZE - 1) / LOCAL_SIZE), 1, 1)
    spawnShader:stop()
  end

  simShader:start()
  Shader.ISetFloat(uSimDt.dt, min(state.dt, 0.05))
  Shader.ISetFloat(uSimDt.drag, DRAG)
  Shader.Dispatch(math.floor(POOL_SIZE / LOCAL_SIZE), 1, 1)
  simShader:stop()

  -- Publish this frame's SSBO writes to all later shader reads.
  Shader.MemoryBarrier(ShaderBarrier.ShaderStorage)
end

function GPUParticles:render (state)
  if state.mode ~= BlendMode.Additive then return end
  drawShader:start()
  Shader.ISetFloat(uDrawSizeBoost.sizeBoost, 1.0)
  Draw.DrawArraysInstanced(GL_TRIANGLES, 0, 6, POOL_SIZE)
  drawShader:stop()
end

return GPUParticles
