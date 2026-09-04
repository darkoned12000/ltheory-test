-- Phase 5: persistent pooled DrawBatch (host enumerate + parallel worker fill + host replay).
-- Host enumerates minimal inputs single-threaded (pointers + floats, NO matrix copies);
-- workers fill matrices in parallel from disjoint bodies post-update barrier; host replays
-- in order via Render_DrawList. Order-preserving, no reordering, pixel-identical to legacy.
-- See multithreading.md §5.4.6, §6.1, §9.
-- Gated on Config.render.multithread (default false); when off, legacy immediate path.

local ffi = require('ffi')
local DrawBatch_ffi = require('ffi.DrawBatch')
local RenderJobQueue_ffi = require('ffi.RenderJobQueue')

local Batcher = {}

local BATCH_INITIAL = 16384  -- first pool size; grown host-only between frames if exceeded

local current = nil  -- { output = DrawJob[], bodies = void*[], count = int, capacity = int } or nil
local pool_output, pool_bodies, pool_capacity = nil, nil, 0  -- persistent host-owned pools
local pending_grow = 0  -- >0 means grow pool before next frame (set on overflow, consumed in begin)
local queue = nil    -- RenderJobQueue* (lazy init on first flag-on use; persists across frames/reload
                     -- since this module persists; queue holds no frame state so reload is safe)

function Batcher.isOpen ()
  return current ~= nil
end

function Batcher.begin ()
  if not (Config.render and Config.render.multithread) then return end
  assert(current == nil, 'Batcher.begin: nested batch (opaque render must not re-enter)')
  if pool_output == nil or pending_grow > 0 then
    local need = BATCH_INITIAL
    if pending_grow > 0 then need = pending_grow end
    if pool_capacity > 0 and need < pool_capacity * 2 then need = pool_capacity * 2 end
    pool_output = ffi.new('DrawJob[?]', need)
    pool_bodies = ffi.new('void*[?]', need)
    pool_capacity = need
    pending_grow = 0
  end
  current = {
    output = pool_output,
    bodies = pool_bodies,
    count = 0,
    capacity = pool_capacity,
  }
end

function Batcher.record (material, mesh, entity, lodDistance, split)
  -- Returns true if recorded (workers fill matrices later), false if caller should draw
  -- immediately via legacy path. Only called when a batch is open.
  -- onStart/state/body guards stay in Lua: C++ workers cannot check Lua callbacks.
  if material.onStart ~= nil then return false end
  if material.state == nil then return false end
  if entity.body == nil then return false end
  local b = current
  if b.count >= b.capacity then
    if pending_grow == 0 then pending_grow = b.capacity * 2 end  -- grow host-only before next frame
    return false  -- overflow this frame: legacy fallback per object (§5.4 capacity rule)
  end
  local job = b.output[b.count]
  job.state = material.state
  job.mesh = mesh
  job.imWorld = material.imWorld or -1
  job.imWorldIT = material.imWorldIT or -1
  job.iScale = material.iScale or -1
  -- Matrices NOT copied here (workers fill them); scale/lod/split now (cheap statics).
  job.scale = entity:getScale()
  job.lod = lodDistance or 0
  job.split = split and 1 or 0
  b.bodies[b.count] = entity.body
  b.count = b.count + 1
  return true
end

function Batcher.replay ()
  local b = current
  current = nil
  if not b or b.count == 0 then return end
  if queue == nil then
    queue = RenderJobQueue_ffi.Create(0)  -- auto worker count; lives for process lifetime
  end
  RenderJobQueue_ffi.BuildBatch(queue, b.bodies, b.output, b.count)  -- workers fill matrices; barrier waits
  DrawBatch_ffi.RenderDrawList(b.output, b.count)  -- host replays in order
end

return Batcher
