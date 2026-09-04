-- Phase 4: worker-built DrawBatch (host enumerate + parallel worker fill + host replay).
-- Host enumerates minimal inputs single-threaded (pointers + floats, NO matrix copies);
-- workers fill matrices in parallel from disjoint bodies post-update barrier; host replays
-- in order via Render_DrawList. Order-preserving, no reordering, pixel-identical to legacy.
-- See multithreading.md §5.4.6, §6.1, §9.
-- Gated on Config.render.multithread (default false); when off, legacy immediate path.

local ffi = require('ffi')
local DrawBatch_ffi = require('ffi.DrawBatch')
local RenderJobQueue_ffi = require('ffi.RenderJobQueue')

local Batcher = {}

local BATCH_CAPACITY = 16384  -- max jobs per frame; overflow falls back to legacy per object

local current = nil  -- { output = DrawJob[], bodies = void*[], count = int } or nil
local queue = nil    -- RenderJobQueue* (lazy init on first flag-on use; persists across frames/reload
                     -- since this module persists; queue holds no frame state so reload is safe)

function Batcher.isOpen ()
  return current ~= nil
end

function Batcher.begin ()
  if not (Config.render and Config.render.multithread) then return end
  assert(current == nil, 'Batcher.begin: nested batch (opaque render must not re-enter)')
  current = {
    output = ffi.new('DrawJob[?]', BATCH_CAPACITY),
    bodies = ffi.new('void*[?]', BATCH_CAPACITY),
    count = 0,
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
  if b.count >= BATCH_CAPACITY then return false end  -- overflow: legacy fallback per object
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
