-- NodeGraph -- retained node-graph / inventory canvas, Phase 1 skeleton.
-- Interactive canvas only (pan/zoom/drag/select); live game-data seeding lands
-- in Phase 2, which merges into the same id-keyed node table built here.
-- Mirrors SystemMap (framework use, math, focus-on-click); visual language
-- follows ltheory-node-ui.md §12 (rings, straight solid/dotted edges, overlay).

local DrawEx = require('UI.DrawEx')
local Container = require('UI.Container')
local Window = require('UI.Window')
local Inspector = require('UI.NodeGraphInspector')
local Util = require('UI.NodeGraphUtil')
local GraphProvider = require('UI.GraphProvider')

-- Stateless classifier provider for the module-level LOD contract.
-- Each NodeGraph instance gets its OWN provider (with its own scratch) so
-- multiple graphs cannot share per-frame scratch tables.
local classifyProvider = GraphProvider.system()

local NodeGraph = {}
NodeGraph.__index = NodeGraph
setmetatable(NodeGraph, Container)

NodeGraph.name = 'Node Graph'
NodeGraph.focusable  = true
NodeGraph.scrollable = true

local kPanSpeed  = 500
local kZoomSpeed = 0.1
local kLabelFont = 'Share'
local kLabelSize = 14

-- Reference blues (ltheory-node-ui.md §12); Config wiring is Phase 5.
local cNode      = { r = 0.25, g = 0.60, b = 1.00, a = 0.90 }
local cCore      = { r = 0.70, g = 0.90, b = 1.00, a = 1.00 }
local cMinor     = { r = 0.30, g = 0.55, b = 0.90, a = 0.55 }
local cPlayer    = { r = 1.00, g = 1.00, b = 1.00, a = 1.00 }
local cSelected  = { r = 1.00, g = 0.30, b = 0.35, a = 1.00 } -- red = selected (only red on screen)
local cEdge      = { r = 0.30, g = 0.55, b = 0.90, a = 0.50 }
local cMine      = { r = 0.25, g = 0.45, b = 0.75, a = 0.30 }
local cTrade     = { r = 0.45, g = 0.75, b = 1.00, a = 0.95 }
local cLabel     = { r = 1.00, g = 1.00, b = 1.00, a = 0.90 }
local cReticle   = { r = 1.00, g = 1.00, b = 1.00, a = 0.90 }

-- LOD classifier: delegates to the default (system) provider. Kept as a
-- module function because it is the documented LOD contract and unit-tested.
function NodeGraph.isGraphWorthy (entity)
  return classifyProvider.classify(entity)
end

-- Live seeding (Phase 2): merge the system's children into the id-keyed table.
-- New entities snap in; live ones retarget (lerp in onUpdate tracks ships);
-- unseen/destroyed nodes are pruned. Never replaces the table (drag, focus,
-- and per-node state survive).
-- Zoom bounds. Unbounded `zoom * exp(k*scrolled)` ran to ~3e5 in a headless
-- autopilot run; clamp after every change (scroll, drill, fit, ease).
local kZoomMin = 1e-4
local kZoomMax = 5e5
local function clampZoom (z)
  if z ~= z or z < kZoomMin then return kZoomMin end -- NaN guard
  if z > kZoomMax then return kZoomMax end
  return z
end

function NodeGraph:seedFromSystem ()
  local sys = self.context or self.system  -- drill levels change the context
  if not sys then return end
  -- Some drill targets are childless (asteroids): show the empty level rather
  -- than assert in iterChildren (crash was: asteroid selected -> no children).
  local ctxHas = (sys.hasChildren and sys:hasChildren()) or false
  if not ctxHas then return end
  -- Region membership: entities grouped inside a named zone (ore fields)
  -- are represented BY the zone node at sector level, not individually.
  -- Zone:add is loose grouping (no reparent), so collect member ids first.
  -- Zone-member suppression is a SECTOR-level rule: at the sector view each
  -- zone's members hide behind their zone node. Drilled INTO a zone, its
  -- members are the level's children and MUST show (Parnell region reveal).
  -- A zone context IS its members' level: do not suppress them.
  -- Provider supplies the units at this context; NodeGraph owns the merge.
  -- isRoot tells the provider not to treat a named sector root as a zone.
  local units = self.provider.children(sys, sys == self.system)
  local seen = self._seen
  if not seen then seen = {}; self._seen = seen end
  for k in pairs(seen) do seen[k] = nil end
  for i = 1, #units do
    local u = units[i]
    local e = u.entity
    if e then
      seen[e.id] = true
      local n = self.nodes[e.id]
      if not n then
        n = {
          id     = e.id,
          entity = e,
          cat    = u.cat or 'rock',
          x = u.x, y = u.y, tx = u.x, ty = u.y,
          r = u.r or 1,
          major = u.major,
          color = (e == self.focusEntity) and cPlayer or (u.major and cNode or cMinor),
          label = nil,
        }
        if u.major then n.label = u.label or Util.resolveLabel(e) end
        if e == self.focusEntity then n.label = n.label or 'YOU' end
        self.nodes[e.id] = n
      else
        n.entity = e
        n.cat = u.cat or n.cat or 'rock'
        -- A user-placed node stays where dropped (drag-to-rearrange wins over
        -- live tracking until Phase 3 pinning formalizes this).
        if not n.manual then n.tx, n.ty = u.x, u.y end
        n.major = u.major or (e == self.focusEntity)
        -- Promoted late: a node must never be a ring without a label.
        if n.major and not n.label then n.label = Util.resolveLabel(e) end
      end
      -- P1.1: stamp drillability ONCE per node (it is stable; recomputing per
      -- frame would pcall over children for every entity). Drives the UI tell.
      if n.drillable == nil then n.drillable = self.provider.drillable(e) end
    end
  end
  for id, n in pairs(self.nodes) do
    if n.entity and not seen[id] then
      self.nodes[id] = nil
    end
  end
  if self.focus and not self.nodes[self.focus] then self.focus = nil end
  -- First non-empty seed fits the sector to the viewport (needs layout done).
  if not self._fitted and next(self.nodes) ~= nil then
    local _, _, sx, sy = self:getRectGlobal()
    if sx > 0 and sy > 0 then
      -- Fit MAJORS only: a far planet/field in the full set collapses the
      -- whole gameplay area into one pixel pile (the "stacked" bug).
      -- Bounding box over majors (planets excluded: r >= 5000 counts as
      -- planet-scale) PLUS the player's own node, so the opening view shows
      -- the whole level instead of a deep zoom on 'YOU' that had to be
      -- scrolled out of at every launch.
      local x0, x1, y0, y1 = nil, nil, nil, nil
      local function acc (n)
        x0, x1 = x0 and math.min(x0, n.x) or n.x, x1 and math.max(x1, n.x) or n.x
        y0, y1 = y0 and math.min(y0, n.y) or n.y, y1 and math.max(y1, n.y) or n.y
      end
      local majors, playerNode = false, nil
      for _, n in pairs(self.nodes) do
        if n.major then majors = true end
        if self.focusEntity and n.entity == self.focusEntity then playerNode = n end
      end
      -- Robust fit: collect the candidates, then trim FAR outliers before
      -- taking the bounding box. A chained-clump rock can sit ~1M out while
      -- its field spans ~10k; including it collapses the field into a pixel
      -- pile (the zone drill's "didn't display properly"). Trim by the
      -- 90th-percentile distance from the median, so a tight set (the sector
      -- view: majors + the player, a handful of nodes) has p90 == its max and
      -- is unchanged. Trimmed outliers still draw as edge indicators.
      local fitSet = {}
      for _, n in pairs(self.nodes) do
        if (n.major or not majors) and (n.r or 0) < 5000 then fitSet[#fitSet + 1] = n end
      end
      if playerNode then fitSet[#fitSet + 1] = playerNode end
      local nFit = #fitSet
      if nFit > 0 then
        local xs, ys = {}, {}
        for i, n in ipairs(fitSet) do xs[i], ys[i] = n.x, n.y end
        table.sort(xs); table.sort(ys)
        local medx = xs[math.ceil(nFit * 0.5)] or xs[1]
        local medy = ys[math.ceil(nFit * 0.5)] or ys[1]
        local ds = {}
        for i, n in ipairs(fitSet) do
          local dx, dy = n.x - medx, n.y - medy
          ds[i] = math.sqrt(dx * dx + dy * dy)
        end
        table.sort(ds)
        local radius = (ds[math.min(nFit, math.max(1, math.ceil(nFit * 0.90)))] or ds[nFit] or 0) * 1.5
        local r2, kept = radius * radius, 0
        for _, n in ipairs(fitSet) do
          local dx, dy = n.x - medx, n.y - medy
          if dx * dx + dy * dy <= r2 then acc(n); kept = kept + 1 end
        end
        if kept == 0 then for _, n in ipairs(fitSet) do acc(n) end end
      end
      local restoring = self._restore
      if x0 then
        local w, h = math.max(1, x1 - x0), math.max(1, y1 - y0)
        if restoring then
          -- Drill-out: the level's saved camera wins over the recomputed fit.
          self.zoom = clampZoom(restoring.zoom)
          self.pos = Vec2f(restoring.pos.x, restoring.pos.y)
        else
          self.pos = Vec2f((x0 + x1) * 0.5, (y0 + y1) * 0.5)
          self.zoom = clampZoom(math.min(sx / w, sy / h) * 0.85)
        end
      end
      -- Compression frame for this level: centre + reference radius (the
      -- level's own extent), and the fit zoom the fade is measured against.
      -- Set BEFORE declutter, which projects through it. On drill-out the
      -- saved frame is restored verbatim, so a sector you had zoomed past the
      -- fade threshold stays uncompressed when you come back.
      if x0 then
        if restoring and restoring.frame and restoring.frame.refC then
          self._refC, self._dRef, self._zFit =
            restoring.frame.refC, restoring.frame.dRef, restoring.frame.zFit
        else
          local cxm, cym = (x0 + x1) * 0.5, (y0 + y1) * 0.5
          self._refC = { x = cxm, y = cym }
          local rad = 0.5 * math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0))
          -- 0.5 x radius: strong enough to cluster the overview, gentle enough
          -- that shapes/directions still read (ratio ~0.55 at the rim).
          self._dRef = math.max(1000, rad * 0.5)
          self._zFit = self.zoom
        end
      end
      self._restore = nil
      -- First open: 'YOU' is SELECTED (red highlight) but the view fits the
      -- whole level, not centred on the player.
      if not self.focus and playerNode then self.focus = playerNode.id end
      -- Build edges FIRST (declutter reads them for the mine-ring fan), then
      -- declutter. This block only runs when _fitted was false, so it fires
      -- exactly once per level — including after every drillInto/drillOut,
      -- which reset _fitted. (A separate _ringDone flag used to gate this and
      -- was never reset, so levels after the first were never decluttered.)
      self:seedEdges()
      self:declutter()
      self._fitted = true
      -- Drill-out: re-select the node we came from and reopen its inspector.
      if self._restoreFocus then
        local n = self.nodes[self._restoreFocus]
        self._restoreFocus = nil
        if n then
          self.focus = n.id
          if self.inspector then self.inspector:show(n) end
        end
      end
    end
  end
end

-- Economy + socket + hierarchy edges, both endpoints seeded only. A parent
-- link to the unseeded context root (the system itself) never draws, so the
-- sector level cannot become a starburst hairball.
function NodeGraph:seedEdges ()
  -- Reuse the persistent table: this runs every frame, and allocating a fresh
  -- edge list each frame was pure GC churn.
  local edges = self.edges
  for i = #edges, 1, -1 do edges[i] = nil end
  local ctx = self.context or self.system
  if not ctx then return end
  local from = self.provider.links(ctx, self.nodes)
  for i = 1, #from do edges[i] = from[i] end
end

function NodeGraph:onUpdate (state)
  if (self.context or self.system) then
    self:seedFromSystem()
    self:seedEdges()
    -- Lerp live nodes toward their targets (ships glide, banks sit still).
    local dt = math.max(1e-6, state.dt or 0.016)
    local k = 1 - math.exp(-8 * dt)
    for _, n in pairs(self.nodes) do
      if n.tx and (n.x ~= n.tx or n.y ~= n.ty) then
        n.x = n.x + (n.tx - n.x) * k
        n.y = n.y + (n.ty - n.y) * k
      end
    end
    -- Locked-node handling: NO positional easing. The selected node is the
    -- zoom anchor — the only camera motion during a locked gesture is
    -- applyScroll pinning its screen position exactly. Any ease here would
    -- fight the pin and walk the node away ("works, then drifts").
    if self.targetZoom then
      local fn = self.follow and self.nodes[self.follow] or nil
      if fn then
        local fk = 1 - math.exp(-4 * dt)
        self.zoom = clampZoom(self.zoom + (self.targetZoom - self.zoom) * fk)
      end
    end
  end
end

-- The map toggle lifecycle: opening (or closing) resets to the sector level.
-- Without this, F10-open after a drill left the EMPTY drilled level on screen.
function NodeGraph:onEnable ()
  while self:drillOut() do end  -- pop any drill levels
  if self.inspector then self.inspector:hide() end
end

-- Drill context (Phase 4): swap the seeding target without touching the
-- lens. The stack carries {context, camera{zoom,pos}} so Back restores the
-- level you came FROM exactly (per-level camera, per-the-plan §7).
function NodeGraph:drillInto (entity, keepZoom)
  if entity == self.context then return false end
  -- Only contexts whose children can actually seed may be drilled into.
  -- Childless targets (asteroids) and bodyless-children targets (factory
  -- sockets) would produce a blank level. Provider decides.
  if not self.provider.drillable(entity) then return false end
  self.stack[#self.stack + 1] = {
    context = self.context,
    camera  = { zoom = self.zoom, pos = { x = self.pos.x, y = self.pos.y } },
    -- Compression frame of the level we are leaving (restored verbatim on
    -- drillOut so its zoom-dependent fade state comes back too).
    frame   = self._refC and { refC = self._refC, dRef = self._dRef, zFit = self._zFit } or nil,
    focusId = self.focus,   -- re-selected on drillOut
  }
  self.context = entity
  self.nodes, self.edges = {}, {}
  self.focus, self.follow = nil, nil
  self._fitted = false
  if keepZoom then
    -- Reuse the current zoom for a component/level whose coordinates live in
    -- the same frame (zone members, ship children); the refit in onUpdate is a
    -- no-op once _fitted, so this is a pure relabel of the same field.
  else
    -- Fresh level, fresh fit: the new DOF comes from fit_VIEW, not a climbing
    -- zoom (Claude's point - and the Parnell reveal, per zoom-into-a-region).
    self.zoom = 1.0
    self.pos = Vec2f(0, 0)
  end
  return self.stack[#self.stack]
end

-- Attempts the drill for a node. Uses the stamped `drillable` (computed once
-- at seed) and asks the provider why not when it fails, so the UI can say
-- "nothing to explore here" instead of doing nothing.
function NodeGraph:tryDrill (n)
  if not (n and n.entity) then return false end
  if n.drillable and self:drillInto(n.entity, false) then return true end
  if self.provider.noDrillReason and self.provider.noDrillReason(n.entity) then
    self._drillFail = { id = n.id, t = Engine.GetTime() }
  end
  return false
end

function NodeGraph:drillOut ()
  if #self.stack == 0 then return false end
  local prev = self.stack[#self.stack]
  self.stack[#self.stack] = nil
  self.context = prev.context
  self.nodes, self.edges = {}, {}
  self.focus, self.follow = nil, nil
  self._fitted = false
  -- Applied after the level re-seeds: the fit would otherwise recentre (on the
  -- player) and there are no nodes yet to re-select.
  self._restore      = { zoom = prev.camera.zoom, pos = prev.camera.pos, frame = prev.frame }
  self._restoreFocus = prev.focusId
  return true
end

-- Visual declutter (Phase 3 precursor): majors sharing nearly the same world
-- position (escort wings, docked groups) get small draw-time offsets so rings
-- and labels separate. Computed in SCREEN pixels (fixed 100px separation) so
-- a far-zoomed-out fit can never fan them into giant rings; converted back to
-- world units for the projection path. True x/y (and tracking targets) are
-- untouched. Deterministic id order; majors only.
function NodeGraph:declutter ()
  local _, _, sx, sy = self:getRectGlobal()
  if sx <= 0 or sy <= 0 then return end
  local ids = {}
  for id, n in pairs(self.nodes) do
    if n.major then ids[#ids + 1] = id
    else n.jx, n.jy, n.fanAnchor = 0, 0, nil end
  end
  table.sort(ids)
  local scr = {}
  for _, id in ipairs(ids) do
    local n = self.nodes[id]
    local tX, tY = self:toScreen(n.x, n.y)
    scr[id] = { x = tX, y = tY }
  end
  local sep, stepPx, done, ox, oy = 100, 55, {}, {}, {}
  for _, id in ipairs(ids) do
    local px, py = 0, 0
    for step = 1, 8 do
      local clear = true
      for _, pid in ipairs(done) do
        local dx = (scr[id].x + px) - (scr[pid].x + (ox[pid] or 0))
        local dy = (scr[id].y + py) - (scr[pid].y + (oy[pid] or 0))
        if dx * dx + dy * dy < sep * sep then clear = false break end
      end
      if clear then break end
      local a = step * 2.39996 -- golden angle: even fan-out, no clumping
      px = px + math.cos(a) * stepPx
      py = py + math.sin(a) * stepPx
    end
    ox[id], oy[id] = px, py
    done[#done + 1] = id
  end
  -- Fan-anchor rings: mine-linked minors arrange in a FULL 360° ring band
  -- around their hub (golden-angle order, radii alternating 105/130/155 so
  -- spokes vary and dots stay clickable). The ring is constant screen size at
  -- every zoom, so pushing in refines it instead of collapsing back to a pile.
  local groups = {}
  if not self._fitted then
    for _, e in ipairs(self.edges) do
      if e.kind == 'mine' then
        local a, b = self.nodes[e.a], self.nodes[e.b]
        local rock, hub = nil, nil
        if a and b then
          if not a.major and b.major then rock, hub = a, b
          elseif not b.major and a.major then rock, hub = b, a end
        end
        if rock and hub then
          rock.fanAnchor = hub.id
          local g = groups[hub.id] or {}
          groups[hub.id] = g
          g[#g + 1] = rock.id
        end
      end
    end
  end
  for hubId, members in pairs(groups) do
    table.sort(members)
    local hub = self.nodes[hubId]
    if hub then
      local hx, hy = self:toScreenNode(hub)
      for k, rid in ipairs(members) do
        local rock = self.nodes[rid]
        if rock then
          local ang = k * 2.39996
          local ringR = 105 + ((k - 1) % 3) * 25
          local rx, ry = self:toScreen(rock.x, rock.y)
          rock.jx = (hx + math.cos(ang) * ringR - rx) / self.zoom
          rock.jy = (hy + math.sin(ang) * ringR - ry) / self.zoom
        end
      end
    end
  end
  local inv = 1 / math.max(1e-6, self.zoom)
  for _, id in ipairs(ids) do
    local n = self.nodes[id]
    n.jx = (ox[id] or 0) * inv
    n.jy = (oy[id] or 0) * inv
  end
  -- Dense-dot fan: co-located minors (ore fields) spiral onto a capped disc.
  -- Grid-hashed (16px cells, 3x3 neighbourhood) so 90+ dots stay cheap.
  -- Zoom-gated: up close their true positions already separate.
  -- Majors seed the grid first so fans never cover rings.
  if self.zoom < 0.15 and not self._fitted then
    local grid = {}
    local function gkey (cx, cy)
      return math.floor(cx / 16) .. ':' .. math.floor(cy / 16)
    end
    local function occupied (fx, fy, exclude)
      local cx, cy = math.floor(fx / 16), math.floor(fy / 16)
      for gx = cx - 1, cx + 1 do
        for gy = cy - 1, cy + 1 do
          local cell = grid[gx .. ':' .. gy]
          if cell then
            for _, q in ipairs(cell) do
              if q ~= exclude then
                local dx, dy = fx - q[1], fy - q[2]
                if dx * dx + dy * dy < 256 then return true end
              end
            end
          end
        end
      end
      return false
    end
    local function occupy (fx, fy)
      local k = gkey(fx, fy)
      grid[k] = grid[k] or {}
      grid[k][#grid[k] + 1] = { fx, fy }
    end
    for _, id in ipairs(ids) do
      local n = self.nodes[id]
      occupy(self:toScreenNode(n))
    end
    local mids = {}
    for id, n in pairs(self.nodes) do
      if not n.major then mids[#mids + 1] = id end
    end
    table.sort(mids)
    for _, id in ipairs(mids) do
      local n = self.nodes[id]
      if n.fanAnchor then
        occupy(self:toScreenNode(n))
      end
    end
    for _, id in ipairs(mids) do
      local n = self.nodes[id]
      if n.fanAnchor then -- ringed already: skip the grid fan
      else
      local bx, by = self:toScreen(n.x, n.y)
      local px, py = 0, 0
      for step = 1, 10 do
        if not occupied(bx + px, by + py, nil) then break end
        if px * px + py * py >= 16900 then break end
        local a = step * 2.39996
        px = px + math.cos(a) * 10
        py = py + math.sin(a) * 10
      end
      n.jx = (n.jx or 0) + px * inv
      n.jy = (n.jy or 0) + py * inv
      occupy(bx + px, by + py)
      end
    end
  end
end

-- Zoom application, shared by real scroll input and the headless autopilot.
-- Anchor: followed node when locked (never moves under any scroll), else the
-- cursor (standard map UX). Single anchor means the follow-ease below can
-- never fight the zoom.
function NodeGraph:applyScroll (scrolled, mx, my, anchor)
  local _, _, vsx, vsy = self:getRectGlobal()
  if vsx <= 0 then return end
  self.targetZoom = nil -- hands on the wheel now
  -- Declutter offsets are computed once per level fit and never recomputed
  -- (see seedFromSystem), so zoom no longer has to freeze them.
  local ax, ay
  if anchor then
    ax, ay = anchor[1], anchor[2]
  else
    local cx = math.min(math.max(mx, self.x), self.x + vsx)
    local cy = math.min(math.max(my, self.y), self.y + vsy)
    ax, ay = self:toCanvas(cx, cy)   -- world point under the cursor
  end
  -- Pin the anchor's WARPED screen position across the zoom change (both the
  -- warp strength and the scale change with zoom, so solve pos at the new one).
  local sxp, syp = self:toScreen(ax, ay)
  self.zoom = clampZoom(self.zoom * math.exp(kZoomSpeed * scrolled))
  local cxS, cyS = self:_viewCentre()
  local wux, wuy = self:_unwarp(sxp - cxS, syp - cyS)
  self.pos.x = ax - wux / self.zoom
  self.pos.y = ay - wuy / self.zoom
end

-- Projection pipeline: world -> LINEAR screen -> RADIAL WARP -> screen.
--
-- `self.pos` and `self.zoom` are plain WORLD space and strictly linear, so
-- pan, zoom and "centre on this node" are the classic linear operations and a
-- zoom change can never invalidate the camera. Distance compression is applied
-- afterwards in SCREEN space, as a radial warp about the view centre: strong
-- at the overview, fading to identity by `_zFit * 12` ("distance starts to
-- show as you zoom in"). Direction is preserved (radial only).
--
-- (An earlier version stored `pos` in the compressed frame itself; because the
-- compression depends on zoom, easing the zoom toward a clicked node then slid
-- the whole map off-screen. This keeps the camera linear instead.)
--
-- At the fit the camera sits on the level centre, so this is IDENTICAL to
-- compressing about that centre — the opening view is unchanged.

-- Compression strength: 0 = fully compressed, 1 = true distance.
function NodeGraph:_compressT ()
  local zFit = self._zFit
  if not zFit or zFit <= 0 then return 1 end
  local t = self.zoom / (zFit * 12)
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return t
end

function NodeGraph:_viewCentre ()
  local _, _, sx, sy = self:getRectGlobal()
  return self.x + sx * 0.5, self.y + sy * 0.5
end

-- Screen-space reference radius for the warp, in pixels.
function NodeGraph:_warpRef ()
  local ref = (self._dRef or 1) * self.zoom
  if ref < 1 then ref = 1 end
  return ref
end

-- Linear screen offset from the view centre -> warped offset.
function NodeGraph:_warp (dx, dy)
  local t = self:_compressT()
  if t >= 1 then return dx, dy end
  local r = math.sqrt(dx * dx + dy * dy)
  if r < 1e-6 then return dx, dy end
  local ref = self:_warpRef()
  local rw = (ref * math.log(1 + r / ref)) * (1 - t) + r * t
  local k = rw / r
  return dx * k, dy * k
end

-- Warped offset -> linear screen offset (inverse; bisection on the monotonic
-- radial curve).
function NodeGraph:_unwarp (dx, dy)
  local t = self:_compressT()
  if t >= 1 then return dx, dy end
  local rw = math.sqrt(dx * dx + dy * dy)
  if rw < 1e-6 then return dx, dy end
  local ref = self:_warpRef()
  local lo, hi = 0, rw + ref * 4 + 1e4
  for _ = 1, 24 do
    local mid = 0.5 * (lo + hi)
    local b = (ref * math.log(1 + mid / ref)) * (1 - t) + mid * t
    if b < rw then lo = mid else hi = mid end
  end
  local r = 0.5 * (lo + hi)
  local k = r / rw
  return dx * k, dy * k
end

-- world -> screen, for a bare world point.
function NodeGraph:toScreen (cx, cy)
  local cxS, cyS = self:_viewCentre()
  local dx, dy = (cx - self.pos.x) * self.zoom, (cy - self.pos.y) * self.zoom
  dx, dy = self:_warp(dx, dy)
  return cxS + dx, cyS + dy
end

-- world -> screen for a NODE: warped base position + the declutter offset in
-- SCREEN pixels (a fixed-pixel fan/ring must not be squashed by the warp).
function NodeGraph:toScreenNode (n)
  local sx, sy = self:toScreen(n.x, n.y)
  return sx + (n.jx or 0) * self.zoom, sy + (n.jy or 0) * self.zoom
end

-- screen -> world (exact inverse of toScreen), for drag placement.
function NodeGraph:toCanvas (mx, my)
  local cxS, cyS = self:_viewCentre()
  local dx, dy = self:_unwarp(mx - cxS, my - cyS)
  return self.pos.x + dx / self.zoom, self.pos.y + dy / self.zoom
end

-- Whether a node's category is currently filtered out. One definition for
-- draw, hit-testing and edge drawing, so they cannot disagree.
function NodeGraph:isHidden (n)
  local cat = (n and n.cat) or 'rock'
  if cat == 'ship'  then return not self.filter.ships end
  if cat == 'rock'  then return not self.filter.rocks end
  return not self.filter.places
end

-- Perpendicular distance from (px,py) to segment (ax,ay)-(bx,by).
local function segDist (px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local len2 = dx * dx + dy * dy
  local t = 0
  if len2 > 1e-6 then
    t = ((px - ax) * dx + (py - ay) * dy) / len2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
  end
  local qx, qy = ax + dx * t, ay + dy * t
  return math.sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy))
end

-- Nearest drawn edge to the cursor within `maxDist` px (for the hover readout).
function NodeGraph:edgeAt (mx, my, maxDist)
  local best, bestD = nil, maxDist or 8
  for i = 1, #self.edges do
    local e = self.edges[i]
    local a, b = self.nodes[e.a], self.nodes[e.b]
    if a and b and not self:isHidden(a) and not self:isHidden(b) then
      local ax, ay = self:toScreenNode(a)
      local bx, by = self:toScreenNode(b)
      local d = segDist(mx, my, ax, ay, bx, by)
      if d < bestD then best, bestD = e, d end
    end
  end
  return best
end

-- Drawn radius of a node ring (mirrors onDraw clamping).
local function drawnRadius (n, zoom)
  return math.min(40, math.max(6, (n.r or 1) * zoom))
end

function NodeGraph:nodeAt (mx, my)
  -- Majors first (rings are the click targets); minors only if nothing major
  -- is near, so dot clouds never steal clicks from stations. Hit-testing uses
  -- DRAWN size (a planet's world scale would otherwise make a 3000px+ click
  -- black hole); off-screen majors are hittable at their edge indicators.
  local x0, y0, vsx, vsy = self:getRectGlobal()
  local best, bestDist = nil, math.huge
  for _, majorOnly in ipairs({ true, false }) do
    for id, n in pairs(self.nodes) do
      if not self:isHidden(n) and (n.major or false) == majorOnly then
        local nx, ny = self:toScreenNode(n)
        local gx, gy, hit = nx, ny, 0
        if majorOnly then
          hit = math.max(14, drawnRadius(n, self.zoom) + 6)
        else
          hit = (n.fanAnchor and 14 or 8)
        end
        -- Off-screen major: clamped to the frame edge in GLOBAL coords (was
        -- mixing global node coords with a local 24..vsx range, which only
        -- worked because the map happens to start at the window origin).
        if vsx > 0 and (nx < x0 - 40 or ny < y0 - 40 or nx > x0 + vsx + 40 or ny > y0 + vsy + 40) then
          gx = math.min(math.max(nx, x0 + 24), x0 + vsx - 24)
          gy = math.min(math.max(ny, y0 + 24), y0 + vsy - 24)
          hit = 20
        end
        local dx, dy = gx - mx, gy - my
        local d = math.sqrt(dx * dx + dy * dy)
        if d <= hit and d < bestDist then
          best, bestDist = n, d
        end
      end
    end
    if best then return best end
  end
  return best
end

function NodeGraph:onDraw (focus, active)
  local x, y, sx, sy = self:getRectGlobal()

  -- Translucent canvas: the live scene stays visible behind (reference §12).
  Draw.Color(0.02, 0.03, 0.05, 0.55)
  Draw.Rect(x, y, sx, sy)
  DrawEx.RectOutline(x, y, sx, sy, { r = 0.2, g = 0.5, b = 0.8, a = 0.6 })

  -- Edges under nodes. Solid rides the shared batch; dotted uses Dash (§6).
  -- Routes toggle hides trade lanes for a clean spatial read.
  if self.filter.routes then
    for i = 1, #self.edges do
      local e = self.edges[i]
      local a, b = self.nodes[e.a], self.nodes[e.b]
      if a and b and not self:isHidden(a) and not self:isHidden(b) then
        local ax, ay = self:toScreenNode(a)
        local bx, by = self:toScreenNode(b)
        if e.kind == 'trade' then
          -- Flowing dots toward B (dst): trade routes read as movement, not paint.
          DrawEx.Dash(ax, ay, bx, by, cTrade, 2, 9, Engine.GetTime() * 0.35)
        elseif e.kind == 'mine' then
          DrawEx.Line(ax, ay, bx, by, cMine)
        else
          DrawEx.Line(ax, ay, bx, by, cEdge)
        end
      end
    end
  end

  -- Minors earn labels when zoomed close or focused (100 ships can't all
  -- carry text at sector zoom — the reference shows dots for the same reason).
  -- Minor labels: only when zoomed in AND near the view centre. Labelling
  -- every minor (100 ships) produced an unreadable pile.
  local showMinorLabels = self.zoom > 0.3
  local cxScreen, cyScreen = x + sx * 0.5, y + sy * 0.5
  local labelRadius = math.min(sx, sy) * 0.34
  for id, n in pairs(self.nodes) do
    if self:isHidden(n) then
      -- filtered out: skip draw entirely
    else
      local nx, ny = self:toScreenNode(n)
      local selected = self.focus == id
      if not n.major then
        -- Minor bodies: fixed-size dim points (reference dot clouds). Fanned
        -- dots get a thin leader back toward truth (length varies, capped).
        local tx0, ty0 = self:toScreen(n.x, n.y)
        local ldx, ldy = nx - tx0, ny - ty0
        if not n.fanAnchor and ldx * ldx + ldy * ldy > 36 then
          Draw.Color(0.3, 0.5, 0.8, 0.35)
          Draw.Line(tx0, ty0, nx, ny)
        end
        DrawEx.Point(nx, ny, 2.5, n.color or cMinor)
        local ddx, ddy = nx - cxScreen, ny - cyScreen
        local nearCentre = (ddx * ddx + ddy * ddy) < labelRadius * labelRadius
        if selected or (showMinorLabels and nearCentre) then
          if not n.label then
            n.label = (n.entity and Util.resolveLabel(n.entity)) or ('Body #' .. tostring(id % 1000))
          end
          DrawEx.TextAlpha(kLabelFont, n.label, kLabelSize,
            nx - 100, ny + 6, 200, 20,
            cLabel.r, cLabel.g, cLabel.b, cLabel.a, 0.5, 0.0)
        end
        if selected then -- small reticle so a selected dot reads as selected
          local s = 9
          Draw.Color(cReticle.r, cReticle.g, cReticle.b, cReticle.a)
          Draw.Line(nx - s, ny - s, nx - s + 5, ny - s)
          Draw.Line(nx - s, ny - s, nx - s, ny - s + 5)
          Draw.Line(nx + s - 5, ny + s, nx + s, ny + s)
          Draw.Line(nx + s, ny + s, nx + s, ny + s - 5)
        end
      else
        local r = drawnRadius(n, self.zoom)
        local ring = selected and cSelected or (n.color or cNode)
        DrawEx.Ring(nx, ny, r, ring)
        DrawEx.Point(nx, ny, r * 0.35, selected and cLabel or cCore)
        if n.drillable and (n.major or selected) then
          -- "There is more inside": small + at the ring's lower-right.
          local gx, gy = nx + r + 7, ny + r + 7
          Draw.Color(cCore.r, cCore.g, cCore.b, 0.85)
          Draw.Line(gx - 4, gy, gx + 4, gy)
          Draw.Line(gx, gy - 4, gx, gy + 4)
        end
      if n.label then
        DrawEx.TextAlpha(kLabelFont, n.label, kLabelSize,
          nx - 100, ny + r + 2, 200, 20,
          cLabel.r, cLabel.g, cLabel.b, cLabel.a, 0.5, 0.0)
      end
      if selected then -- corner-bracket reticle (reference §12)
        local g, s = 4, r + 8
        Draw.Color(cReticle.r, cReticle.g, cReticle.b, cReticle.a)
        Draw.Line(nx - s, ny - s + g, nx - s, ny - s)
        Draw.Line(nx - s, ny - s, nx - s + g, ny - s)
        Draw.Line(nx + s - g, ny - s, nx + s, ny - s)
        Draw.Line(nx + s, ny - s, nx + s, ny - s + g)
        Draw.Line(nx - s, ny + s - g, nx - s, ny + s)
        Draw.Line(nx - s, ny + s, nx - s + g, ny + s)
        Draw.Line(nx + s - g, ny + s, nx + s, ny + s)
        Draw.Line(nx + s, ny + s, nx + s, ny + s - g)
      end
    end
    end -- filter else
  end
  -- Off-screen majors (a planet 250k out lives here): edge triangle + label
  -- at the clamped frame position nodeAt() hit-tests. Clicking one selects
  -- and follow flies the view there — distant bodies stay reachable.
  do
    for id, n in pairs(self.nodes) do
      if n.major and not self:isHidden(n) then
        local nx, ny = self:toScreenNode(n)
        if nx < -40 or ny < -40 or nx > sx + 40 or ny > sy + 40 then
          local gx = math.min(math.max(nx, x + 24), x + sx - 24)
          local gy = math.min(math.max(ny, y + 24), y + sy - 24)
          local selected = self.focus == id
          local col = selected and cSelected or (n.color or cNode)
          Draw.Color(1, 1, 1, 0.9)
          Draw.Line(gx - 10, gy, gx + 10, gy)
          Draw.Line(gx, gy - 10, gx, gy + 10)
          Draw.Color(col.r, col.g, col.b, col.a)
          Draw.Line(gx - 6, gy, gx + 6, gy)
          Draw.Line(gx, gy - 6, gx, gy + 6)
          if n.label then
            DrawEx.TextAlpha(kLabelFont, n.label, kLabelSize,
              gx - 100, gy + 12, 200, 20,
              cLabel.r, cLabel.g, cLabel.b, cLabel.a, 0.5, 0.0)
          end
        end
      end
    end
  end
  -- Failed-drill feedback: a short red ring so a dead double-click/Enter is
  -- not silent.
  if self._drillFail then
    local age = Engine.GetTime() - self._drillFail.t
    if age > 0.45 or not self.nodes[self._drillFail.id] then
      self._drillFail = nil
    else
      local n = self.nodes[self._drillFail.id]
      local nx, ny = self:toScreenNode(n)
      local a = 0.85 * (1 - age / 0.45)
      DrawEx.Ring(nx, ny, drawnRadius(n, self.zoom) + 8,
        { r = 1.0, g = 0.25, b = 0.25, a = a })
    end
  end
  -- Edge hover readout: describe the route under the cursor (item + endpoints
  -- via the job, when we have one). Cheap point-to-segment test.
  do
    local mp = Input.GetMousePosition()
    local edge = self.filter.routes and self:edgeAt(mp.x, mp.y, 9) or nil
    if edge then
      local a, b = self.nodes[edge.a], self.nodes[edge.b]
      local text = nil
      if edge.job then
        local ok, nm = pcall(edge.job.getName, edge.job)
        if ok and nm then text = nm end
      end
      if not text then
        text = (edge.kind or 'link') .. '  ' ..
          ((a and a.label) or '?') .. ' -> ' .. ((b and b.label) or '?')
      end
      local tw = #text * 7 + 18
      local tx = math.min(mp.x + 14, x + sx - tw - 8)
      local ty = math.max(y + 8, mp.y - 26)
      Draw.Color(0.02, 0.03, 0.06, 0.85)
      Draw.Rect(tx, ty, tw, 22)
      DrawEx.RectOutline(tx, ty, tw, 22, { r = 0.25, g = 0.6, b = 1.0, a = 0.8 })
      DrawEx.TextAlpha(kLabelFont, text, kLabelSize, tx + 8, ty + 3, tw - 16, 18,
        1, 1, 1, 0.9, 0.0, 0.0)
    end
  end
  -- Breadcrumb: current context path (Parnell video keeps a level indicator).
  do
    local crumbs = {}
    local cur = self.context
    while cur do
      local name = nil
      if cur.getName then
        local ok, nm = pcall(cur.getName, cur)
        if ok and nm and nm ~= '' then name = nm end
      end
      if name then
        crumbs[#crumbs + 1] = name
      elseif cur == self.system then
        crumbs[#crumbs + 1] = 'System'
      end
      cur = (cur.getParent and cur:getParent()) or nil
    end
    if #crumbs > 0 then
      local path = table.concat(crumbs, ' / ')
      DrawEx.TextAlpha(kLabelFont, path, kLabelSize,
        x + 16, y + 14, 400, 20,
        1, 1, 1, 0.75, 0.0, 0.0)
    end
  end
  -- Scale bar (map units are world units: screen px / zoom) + filter legend.
  do
    local targetPx, mag, pow10 = 120, nil, nil
    local raw = targetPx / math.max(1e-6, self.zoom)
    pow10 = 10 ^ math.floor(math.log10(math.max(1e-9, raw)))
    for _, m in ipairs({ 5, 2, 1 }) do
      if m * pow10 <= raw then mag = m * pow10 break end
    end
    mag = mag or pow10
    local barW = mag * self.zoom
    Draw.Color(1, 1, 1, 0.7)
    Draw.Line(x + 16, y + sy - 16, x + 16 + barW, y + sy - 16)
    Draw.Line(x + 16, y + sy - 20, x + 16, y + sy - 12)
    Draw.Line(x + 16 + barW, y + sy - 20, x + 16 + barW, y + sy - 12)
    DrawEx.TextAlpha(kLabelFont, tostring(mag) .. ' u', kLabelSize,
      x + 16, y + sy - 40, 200, 20,
      1, 1, 1, 0.7, 0.0, 0.0)
    local f = self.filter
    local legend = string.format(
      '[F5] ships %s  [F6] rocks %s  [F7] places %s  [F8] routes %s   ' ..
      '[dbl-click] or [Return] drill   [RMB] or [`] back',
      f.ships and 'on' or 'off', f.rocks and 'on' or 'off',
      f.places and 'on' or 'off', f.routes and 'on' or 'off')
    local legendW = math.min(720, sx - 40)
    DrawEx.TextAlpha(kLabelFont, legend, kLabelSize,
      x + sx - legendW - 8, y + sy - 40, legendW, 20,
      1, 1, 1, 0.55, 1.0, 0.0)
  end
  if self.inspector then
    self.inspector:draw(x, y, sx, sy, Engine.GetTime())
  end
  Draw.Color(1, 1, 1, 1)
end

function NodeGraph:onInput (state)
  -- Arrows only (no WASD): as an in-game overlay the ship owns WASD, and
  -- panning the map must never fly the ship. Standalone SystemMap keeps WASD
  -- because nothing else is listening there.
  local dt = math.max(1e-6, state.dt)
  local pan = kPanSpeed * dt / self.zoom
  self.pos.x = self.pos.x + pan * (
    Input.GetValue(Button.Keyboard.Right) - Input.GetValue(Button.Keyboard.Left))
  self.pos.y = self.pos.y + pan * (
    Input.GetValue(Button.Keyboard.Down) - Input.GetValue(Button.Keyboard.Up))

  -- Category filters (F5 ships / F6 rocks / F7 places / F8 routes). F-keys are
  -- otherwise unused (F9 debug, F10 map); N-keys drive ship groups, M mutes.
  if Input.GetPressed(Button.Keyboard.F5) then self.filter.ships = not self.filter.ships end
  if Input.GetPressed(Button.Keyboard.F6) then self.filter.rocks = not self.filter.rocks end
  if Input.GetPressed(Button.Keyboard.F7) then self.filter.places = not self.filter.places end
  if Input.GetPressed(Button.Keyboard.F8) then self.filter.routes = not self.filter.routes end

  if Input.GetPressed(Button.Keyboard.Return) and self.focus then
    self:tryDrill(self.nodes[self.focus])
  end
  if Input.GetPressed(Button.Keyboard.Backtick) then
    self:drillOut()
  end
  if Input.GetPressed(Button.Mouse.Right) then
    self:drillOut()
  end
  local mp = Input.GetMousePosition()
  local down = Input.GetDown(Button.Mouse.Left)
  do
    local scrolled = Input.GetMouseScroll().y
    if scrolled ~= 0 then
      -- Locked node wins over the cursor: after clicking, any mouse motion
      -- before/during scrolling must not move the anchor (the drift bug).
      local lock = self.follow and self.nodes[self.follow] or nil
      if lock then
        local fx = lock.x + (lock.jx or 0)
        local fy = lock.y + (lock.jy or 0)
        self:applyScroll(scrolled, mp.x, mp.y, { fx, fy })
      else
        self:applyScroll(scrolled, mp.x, mp.y)
      end
    end
  end  if down and not self._wasDown then
    -- Press edge: hit-test once; node => drag+select, empty => pan.
    self._drag = self:nodeAt(mp.x, mp.y)
    if self._drag then
      local dn = self._drag
      self.focus = dn.id
      self.follow = dn.id -- ease the view onto the selection (§13)
      if self.inspector then self.inspector:show(dn) end
      -- CLICK = center the map on this node and zoom toward it. Centered
      -- anchor = no drift possible: scroll re-anchors at dead center every
      -- tick, so "works a little then moves" cannot happen. Also fixes the
      -- planet: 40px ring or not, it stays centered and scrolled-in.
      -- DRILL = double-click on a node with children (sector -> zone members).
      local now = Engine.GetTime()
      if self._lastClick
        and now - self._lastClick < 0.35
        and self._lastClickNode == dn.id
        and dn.entity ~= self.context then
        self:tryDrill(dn)   -- double-click
        self._lastClick = nil
      else
        -- Centre the camera on the node. pos is WORLD space and linear, so
        -- this is exact and stays centred through the zoom easing below.
        self.pos.x, self.pos.y = dn.x + (dn.jx or 0), dn.y + (dn.jy or 0)
        -- Absolute, size-appropriate target: never relative to the current
        -- zoom (that compounded x4 per click, making fixed-world links appear
        -- to grow), and robust to how wide the level fit happens to be.
        -- Big things (regions) stay wide; small ones come close.
        local rr = math.max(1, dn.r or 10)
        self.targetZoom = clampZoom(math.min(1.0, math.max(0.2, 40 / rr)))
        self._lastClick = now
        self._lastClickNode = dn.id
      end
    end
    self._panAt = { x = mp.x, y = mp.y }
    self._pressAt = { x = mp.x, y = mp.y }
    self._dragFrom = { x = mp.x, y = mp.y }
    self._dragMoved = false
  end
  if down then
    if self._drag then
      -- A press only becomes a genuine DRAG once the cursor actually moves.
      -- A plain click must NOT relocate the node: the click already centres
      -- the camera on it, and the same-frame drag used to fight that (and
      -- map-space compression amplified the resulting jump several-fold).
      local fx = self._dragFrom and self._dragFrom.x or mp.x
      local fy = self._dragFrom and self._dragFrom.y or mp.y
      local ddx, ddy = mp.x - fx, mp.y - fy
      if self._dragMoved or ddx * ddx + ddy * ddy > 16 then
        self._dragMoved = true
        self.follow, self.targetZoom = nil, nil
        -- Drop the node where the cursor is (toCanvas inverts the warp).
        local wx, wy = self:toCanvas(mp.x, mp.y)
        self._drag.x, self._drag.y = wx - (self._drag.jx or 0), wy - (self._drag.jy or 0)
        self._drag.tx, self._drag.ty = self._drag.x, self._drag.y
      end
    elseif self._panAt then
      self.follow, self.targetZoom = nil, nil -- manual pan breaks follow too
      self.pos.x = self.pos.x - (mp.x - self._panAt.x) / self.zoom
      self.pos.y = self.pos.y - (mp.y - self._panAt.y) / self.zoom
      self._panAt = { x = mp.x, y = mp.y }
    end
  else
    -- Only a real drag pins the node where it was dropped; a click leaves it
    -- tracked (it was selected/centred, not moved).
    if self._drag and self._dragMoved then self._drag.manual = true end
    if self._pressAt and not self._drag then
      local dx, dy = mp.x - self._pressAt.x, mp.y - self._pressAt.y
      if dx * dx + dy * dy < 36 then
        self.focus, self.follow, self.targetZoom = nil, nil, nil
        if self.inspector then self.inspector:hide() end
      end
    end
    self._drag, self._panAt, self._pressAt = nil, nil, nil
    self._dragFrom, self._dragMoved = nil, false
  end
  self._wasDown = down
end

function NodeGraph.Create (system, opts)
  local self = setmetatable(Window('Node Graph', false), NodeGraph)
  self:setStretch(1, 1)
  self:setPadUniform(0)
  self.system = system
  local o = opts or {}
  self.provider = o.provider or GraphProvider.system()
  self.focusEntity = o.focusEntity
  self.nodes = {}
  self.edges = {}
  self.context = system
  self.stack  = {}    -- drill levels: {context, camera{zoom,pos}}
  self.focus = nil
  -- Category filters (F5 ships / F6 rocks / F7 places / F8 routes).
  self.filter = { ships = true, rocks = true, places = true, routes = true }
  self.inspector = Inspector.Create(self)
  self.pos = Vec2f(0, 0)
  self.zoom = 1.0
  return self
end

return NodeGraph
