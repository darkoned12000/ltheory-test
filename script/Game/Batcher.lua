-- Phase 3: CPU-side grouped draw submission via C++ replay (single-threaded).
-- Collects DrawJob records into a C array during the opaque broadcast, then hands
-- it to Render_DrawList for grouped replay — no reordering, pixel-identical to legacy.
-- Grouping (consecutive same-state/mesh/split, no reorder) lives in C++ now; Lua only
-- fills POD + opaque pointers. See multithreading.md §5.4, §14.2.
-- Gated on Config.render.multithread (default false); when off, components take legacy
-- immediate path and no C array is allocated.

local ffi = require('ffi')
local DrawBatch_ffi = require('ffi.DrawBatch')

local Batcher = {}

local BATCH_CAPACITY = 16384  -- max jobs per frame; overflow falls back to legacy per object

local current = nil  -- { array = DrawJob[], count = int } or nil when not batching

function Batcher.isOpen ()
  return current ~= nil
end

function Batcher.begin ()
  if not (Config.render and Config.render.multithread) then return end
  assert(current == nil, 'Batcher.begin: nested batch (opaque render must not re-enter)')
  current = { array = ffi.new('DrawJob[?]', BATCH_CAPACITY), count = 0 }
end

function Batcher.record (material, mesh, entity, lodDistance, split)
  -- Returns true if recorded (replay later), false if caller should draw immediately
  -- via legacy path. Only called when a batch is open (callers check isOpen first).
  -- onStart/state guards stay in Lua: C++ replay cannot check Lua Material callbacks,
  -- so materials with onStart (or broken state) fall back to legacy immediate draw.
  if material.onStart ~= nil then return false end
  if material.state == nil then return false end
  local b = current
  if b.count >= BATCH_CAPACITY then return false end  -- overflow: legacy fallback per object
  local job = b.array[b.count]
  job.state = material.state
  job.mesh = mesh
  job.imWorld = material.imWorld or -1
  job.imWorldIT = material.imWorldIT or -1
  job.iScale = material.iScale or -1
  -- Copy matrices by value IMMEDIATELY: both getters write to the same per-body
  -- scratch (self->mat), so the second call clobbers the first's result.
  local mw = entity:getToWorldMatrix()
  ffi.copy(job.mWorld, mw.m, ffi.sizeof(job.mWorld))
  local mi = entity:getToLocalMatrix()
  ffi.copy(job.mWorldIT, mi.m, ffi.sizeof(job.mWorldIT))
  job.scale = entity:getScale()
  job.lod = lodDistance or 0
  job.split = split and 1 or 0
  b.count = b.count + 1
  return true
end

function Batcher.replay ()
  local b = current
  current = nil
  if not b or b.count == 0 then return end
  DrawBatch_ffi.RenderDrawList(b.array, b.count)
end

return Batcher
