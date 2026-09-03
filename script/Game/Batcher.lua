-- Phase 1: CPU-side grouped draw submission (single-threaded, order-preserving).
-- Collects (material, mesh, entity) records during the opaque broadcast, then replays
-- them grouped by consecutive same-(material, mesh) runs — no reordering, so output is
-- pixel-identical to the legacy per-object path. Reduces program start/stop + Bind/Unbind
-- to once per run instead of once per object. See multithreading.md §5.3, §14.2 option (b).
-- Gated on Config.render.multithread (default false); when off, components take the legacy
-- immediate path and this module is never opened.

local Batcher = {}

local current = nil  -- open batch list, or nil when not batching

function Batcher.isOpen ()
  return current ~= nil
end

function Batcher.begin ()
  if not (Config.render and Config.render.multithread) then return end
  assert(current == nil, 'Batcher.begin: nested batch (opaque render must not re-enter)')
  current = {}
end

function Batcher.record (material, mesh, entity, lodDistance, split)
  -- Only called when a batch is open (callers check isOpen first).
  -- split=true iff mesh supports split bind/draw (Mesh, not LodMesh); declared by caller
  -- because probing a cdata member that doesn't exist throws instead of returning nil.
  current[#current + 1] = { material = material, mesh = mesh, entity = entity, lod = lodDistance, split = split }
end

function Batcher.replay ()
  local batch = current
  current = nil
  if not batch or #batch == 0 then return end
  local i = 1
  while i <= #batch do
    local first = batch[i]
    local j = i
    while j + 1 <= #batch
      and batch[j+1].material == first.material
      and batch[j+1].mesh == first.mesh
      and batch[j+1].split == first.split do
      j = j + 1
    end
    -- Replay run [i..j]: same (material, mesh, split), original order preserved.
    local mat = first.material
    local mesh = first.mesh
    local split = first.split
    if mat.onStart ~= nil then
      -- Material has a per-draw callback; fall back to legacy per-object path for safety.
      for k = i, j do
        local rec = batch[k]
        mat:start()
        mat:setState(rec.entity)
        if rec.lod ~= nil then mesh:draw(rec.lod) else mesh:draw() end
        mat:stop()
      end
    else
      mat:start()
      if split then mesh:drawBind() end
      for k = i, j do
        local rec = batch[k]
        mat:setState(rec.entity)
        if split then
          mesh:drawBound()
        else
          mesh:draw(rec.lod)  -- LodMesh: full draw; program start/stop still amortized
        end
      end
      if split then mesh:drawUnbind() end
      mat:stop()
    end
    i = j + 1
  end
end

return Batcher
