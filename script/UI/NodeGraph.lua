-- NodeGraph -- retained node-graph / inventory canvas, Phase 1 skeleton.
-- Interactive canvas only (pan/zoom/drag/select); live game-data seeding lands
-- in Phase 2, which merges into the same id-keyed node table built here.
-- Mirrors SystemMap (framework use, math, focus-on-click); visual language
-- follows docs/ltheory-node-ui.md §12 (rings, straight solid/dotted edges, overlay).

local DrawEx = require('UI.DrawEx')
local Container = require('UI.Container')
local Window = require('UI.Window')
local Inspector = require('UI.NodeGraphInspector')
local Util = require('UI.NodeGraphUtil')
local GraphProvider = require('UI.GraphProvider')
local SectorGraph = require('Game.SectorGraph')

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

-- Reference blues (docs/ltheory-node-ui.md §12); Config wiring is Phase 5.
local cNode      = { r = 0.25, g = 0.60, b = 1.00, a = 0.90 }
local cCore      = { r = 0.70, g = 0.90, b = 1.00, a = 1.00 }
-- The minor dots are DIM on purpose. A field is two thousand asteroids and
-- they are drawn ADDITIVELY, so at the old alpha (0.55) the field summed
-- into a solid glowing blob rather than reading as a scatter of rocks.
local cMinor     = { r = 0.30, g = 0.55, b = 0.90, a = 0.30 }
local cPlayer    = { r = 1.00, g = 1.00, b = 1.00, a = 1.00 }
local cSelected  = { r = 1.00, g = 0.30, b = 0.35, a = 1.00 } -- red = selected (only red on screen)
local cEdge      = { r = 0.30, g = 0.55, b = 0.90, a = 0.50 }
local cMine      = { r = 0.25, g = 0.45, b = 0.75, a = 0.30 }
local cTrade     = { r = 0.45, g = 0.75, b = 1.00, a = 0.95 }
local cLabel     = { r = 1.00, g = 1.00, b = 1.00, a = 0.90 }
local cReticle   = { r = 1.00, g = 1.00, b = 1.00, a = 0.90 }
-- A JUMPGATE. Its own hue, so a gate never reads as an ordinary place --
-- the map's blue is for bodies, amber is for regions, and this is neither.
-- The two kinds of gate.
--
--   cJumpgate -- a gate that leaves the SECTOR. Cyan, and the brightest
--                thing on the map after the player.
--   cGate     -- an intra-sector gate: another place in the SAME sector.
--                Amber, the same family as the regions, because it leads to
--                one.
local cGate      = { r = 0.98, g = 0.76, b = 0.30, a = 0.95 }
local cJumpgate  = { r = 0.45, g = 0.80, b = 1.00, a = 0.95 }
-- A SECTOR, on the galaxy level of the map.
local cGalaxy    = { r = 0.55, g = 0.75, b = 1.00, a = 0.90 }
-- A JUMPGATE link, and the far end of a gate (a ghost node standing for the
-- other sector's side of the pair).
local cWarp      = { r = 0.45, g = 0.80, b = 1.00, a = 0.55 }
local cWarpFar   = { r = 0.45, g = 0.80, b = 1.00, a = 0.45 }
-- A RAIL: the amber line between two connected regions.
local cRail      = { r = 0.85, g = 0.62, b = 0.30, a = 0.55 }
-- The HUB: the sector's centre, where every lane starts. It is not a region
-- -- it is the junction the regions' roads all lead back to -- so it gets a
-- hue of its own, warm enough to be clearly not a region and not a body.
local cHub       = { r = 1.00, g = 0.58, b = 0.42, a = 0.95 }

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
-- How far past the fit zoom the view may zoom OUT (~3x). Prevents the
-- "everything collapses to one pixel" degenerate state.
local kZoomOutSlack = 0.35
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
  local units
  if self.galaxyLevel then
    -- The GALAXY level: the sectors are the nodes, and the gates are the
    -- links between them. The old Limit Theory's map was one graph with
    -- the galaxy at its outermost level; this is the same thing.
    local st = self.regionState
    units = self.provider.galaxyChildren(st and st.sectors, st and st.sectorIndex)
  else
    units = self.provider.children(sys, sys == self.system)
  end
  local seen = self._seen
  if not seen then seen = {}; self._seen = seen end
  for k in pairs(seen) do seen[k] = nil end
  -- When the map is drilled into a REGION, only the bodies whose dominant
  -- region is that one are shown. The rule is the same one the HUD uses to
  -- say which region you are in, so the map and the panel cannot disagree
  -- about what is where.
  local regionFilter = self.regionContext
  local inRegion = (regionFilter and self.regionState
                    and self.regionState.inRegion) or nil
  for i = 1, #units do
    local u = units[i]
    local e = u.entity
    -- A unit may have NO entity, as long as it has an id: the GALAXY
    -- level's nodes are SECTORS, which are places and not bodies.
    local id = u.id or (e and e.id)
    if id then
      -- The region filter needs the body's POSITION, which the unit record
      -- already carries (the map is a top-down X/Z projection, but the
      -- membership is a 3D question, so the full position is used).
      local keep = true
      if e and regionFilter and inRegion then
        keep = inRegion(regionFilter, u.x, u.wy or 0, u.y)
      end
      if not keep then
        -- Not in this region: drop it from the level entirely.
        seen[id] = nil
      else
      seen[id] = true
      local n = self.nodes[id]
      if not n then
        n = {
          id     = id,
          entity = e,
          cat    = u.cat or 'rock',
          x = u.x, y = u.y, tx = u.x, ty = u.y,
          r = u.r or 1,
          major = u.major,
          color = (e == self.focusEntity) and cPlayer
               or (u.cat == 'jumpgate' and cJumpgate)
               or (u.cat == 'gatefar' and cWarpFar)
               or (u.cat == 'gate' and cGate)
               or (u.cat == 'sector' and cGalaxy)
               or (u.major and cNode or cMinor),
          label = nil,
        }
        if u.major then n.label = u.label or (e and Util.resolveLabel(e)) end
        if e == self.focusEntity then n.label = n.label or 'YOU' end
        self.nodes[id] = n
      else
        n.entity = e
        n.cat = u.cat or n.cat or 'rock'
        -- A user-placed node stays where dropped (drag-to-rearrange wins over
        -- live tracking until Phase 3 pinning formalizes this).
        if not n.manual then n.tx, n.ty = u.x, u.y end
        n.major = u.major or (e == self.focusEntity)
        -- Promoted late: a node must never be a ring without a label.
        if n.major and not n.label then
          n.label = u.label or (e and Util.resolveLabel(e))
        end
      end
      -- P1.1: stamp drillability ONCE per node (it is stable; recomputing per
      -- frame would pcall over children for every entity). Drives the UI tell.
      if n.drillable == nil then n.drillable = self.provider.drillable(e) end
      if u.context then n.isContext = true end
      end
    end
  end
  for id, n in pairs(self.nodes) do
    -- Not "n.entity and": a node with no entity (a sector on the galaxy
    -- level) would never be pruned, and the table would grow for ever.
    if not seen[id] then
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
      local playerNode = nil
      for _, n in pairs(self.nodes) do
        if self.focusEntity and n.entity == self.focusEntity then playerNode = n end
      end
      -- Robust fit over ALL nodes (the display is 1:1 now, so the opening view
      -- must actually contain everything, not just majors). Trim FAR outliers
      -- by the 90th-percentile distance from the median: a chained-clump rock
      -- can sit ~1M out while its field spans ~10k, and including it would
      -- collapse the field into a pixel pile. Planets (r >= 5000) are excluded
      -- up front (they still draw as edge arrows). Trimmed outliers stay
      -- reachable as edge indicators.
      -- Fit ALL nodes: the robust p90 trim below already drops far outliers,
      -- so the old `r < 5000` "planet-scale" exclusion is obsolete — and it
      -- broke moon levels (moons are r >= 5000 too, leaving an empty fit).
      local fitSet = {}
      for _, n in pairs(self.nodes) do fitSet[#fitSet + 1] = n end
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
      -- The SECTOR view.
      --
      -- The fit above frames the node field, which is the asteroid field --
      -- a few thousand rocks within ~30k of the ship. That is not what a
      -- "sector map" should open on: the sector is 60k across and has
      -- NAMED PLACES in it, and the player opening the map wants to see
      -- where they are in the sector, not a dot cloud at their own feet.
      --
      -- So the sector wins, and the fit is only used when there is no sector
      -- (a test app, or a level that is not a sector at all).
      --
      -- Drilled into a REGION, the region is the frame instead -- the map is
      -- "the things in this place", so it frames the place.
      local st = self.regionState
      if st and not restoring then
        local rc = self.regionContext
        if rc then
          self.pos = Vec2f(rc.center.x, rc.center.z)
          self.zoom = clampZoom(math.min(sx, sy) / (2 * math.max(1, rc.reach)) * 0.9)
        elseif st.radius and st.radius > 0 then
          local o = st.origin or { x = 0, y = 0, z = 0 }
          self.pos = Vec2f(o.x, o.z)
          self.zoom = clampZoom(math.min(sx, sy) / (2 * st.radius) * 0.9)
        end
      end
      -- Compression frame for this level: centre + reference radius (the
      -- level's own extent), and the fit zoom the fade is measured against.
      -- Set BEFORE declutter, which projects through it. On drill-out the
      -- saved frame is restored verbatim, so a sector you had zoomed past the
      -- fade threshold stays uncompressed when you come back.
      if x0 then
        -- _zFit is the fit zoom, used as the zoom-OUT floor for this level.
        -- Restored verbatim on drill-out so returning to a level you had
        -- zoomed into does not re-impose a different floor.
        self._zFit = (restoring and restoring.frame and restoring.frame.zFit)
          or self.zoom
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
  local from
  if self.galaxyLevel then
    local st = self.regionState
    from = self.provider.galaxyLinks(st and st.sectors)
  else
    from = self.provider.links(ctx, self.nodes)
  end
  for i = 1, #from do edges[i] = from[i] end
end

function NodeGraph:onUpdate (state)
  -- The sector state, refreshed each frame from the app. The map reads the
  -- SAME state the HUD's panel reads, so the panel and the map can never
  -- disagree about which region you are in.
  if self.getSectorState then
    self.regionState = self.getSectorState()
  end
  -- The provider needs to know which sector the player is in: the gates it
  -- lists are this sector's, and the far end of each is a ghost node in
  -- another.
  if self.provider.setSectorIndex and self.regionState then
    self.provider:setSectorIndex(self.regionState.sectorIndex or 0)
  end
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
    -- Follow the selection: a selected body that MOVES (an orbiting moon, a
    -- flying ship) would otherwise drift out of the centred view. Exact
    -- assignment, not an ease — an ease would fight applyScroll's screen pin
    -- and reintroduce the old "works, then drifts" behaviour.
    if self.follow then
      local fn = self.nodes[self.follow]
      if fn then
        self.pos.x, self.pos.y = fn.x + (fn.jx or 0), fn.y + (fn.jy or 0)
      end
    end
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
--
-- A REGION is a drill context too, and it is not an entity -- it is a place,
-- and the things in it are the bodies whose dominant region it is. The stack
-- carries the region alongside the entity context, so drilling out of a
-- region returns to the sector view exactly as it was.
function NodeGraph:drillInto (entity, keepZoom)
  if entity == self.context then return false end
  -- Only contexts whose children can actually seed may be drilled into.
  -- Childless targets (asteroids) and bodyless-children targets (factory
  -- sockets) would produce a blank level. Provider decides.
  if not self.provider.drillable(entity) then return false end
  self.stack[#self.stack + 1] = {
    context = self.context,
    camera  = { zoom = self.zoom, pos = { x = self.pos.x, y = self.pos.y } },
    -- Fit zoom of the level we are leaving (the zoom-out floor on return).
    frame   = self._zFit and { zFit = self._zFit } or nil,
    focusId = self.focus,   -- re-selected on drillOut
    region  = self.regionContext,
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

-- Drill into a REGION: the map becomes "the things in this place".
--
-- The region's members are the bodies whose DOMINANT region is this one --
-- the same rule the HUD uses to decide which region you are in, so the map
-- and the panel cannot disagree about what is where.
function NodeGraph:drillIntoRegion (region)
  if not (region and self.regionState) then return false end
  local st = self.regionState
  if st.regionContext == region then return false end
  self.stack[#self.stack + 1] = {
    context = self.context,
    camera  = { zoom = self.zoom, pos = { x = self.pos.x, y = self.pos.y } },
    frame   = self._zFit and { zFit = self._zFit } or nil,
    focusId = self.focus,
    region  = self.regionContext,
  }
  self.regionContext = region
  self.nodes, self.edges = {}, {}
  self.focus, self.follow = nil, nil
  self._fitted = false
  -- Centre on the region and frame it.
  self.pos = Vec2f(region.center.x, region.center.z)
  self.zoom = 1.0
  return true
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
  self.regionContext = prev.region
  self.nodes, self.edges = {}, {}
  self.focus, self.follow = nil, nil
  self._fitted = false
  -- Applied after the level re-seeds: the fit would otherwise recentre (on the
  -- player) and there are no nodes yet to re-select.
  self._restore      = { zoom = prev.camera.zoom, pos = prev.camera.pos, frame = prev.frame }
  self._restoreFocus = prev.focusId
  return true
end

-- Home: recentre the view on the player's own node (after panning away).
function NodeGraph:centerOnPlayer ()
  if not self.focusEntity then return end
  local pn = nil
  for _, n in pairs(self.nodes) do
    if n.entity == self.focusEntity then pn = n break end
  end
  if not pn then return end
  self.focus, self.follow = pn.id, pn.id
  self.pos.x, self.pos.y = pn.x + (pn.jx or 0), pn.y + (pn.jy or 0)
  if self.inspector then self.inspector:show(pn) end
end

-- End: re-fit the whole level (recompute pos/zoom + compression frame).
function NodeGraph:refit ()
  self.follow = nil
  self._fitted = false   -- the next seed recomputes the fit
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
    ax = self.pos.x + (cx - self.x - vsx * 0.5) / self.zoom
    ay = self.pos.y + (cy - self.y - vsy * 0.5) / self.zoom
  end
  -- Zoom about the anchor with LINEAR world-space maths. (Inverting the display
  -- warp instead is exact under compression but diverges as the warp reference
  -- clamps to 1px at deep zoom-out, which flung the camera off to 1e8.) Bound
  -- the zoom-out too: the level is already framed at the fit zoom, so going
  -- past ~3x that only collapses everything into a point.
  local sx = self.x + vsx * 0.5 + (ax - self.pos.x) * self.zoom
  local sy = self.y + vsy * 0.5 + (ay - self.pos.y) * self.zoom
  local zmin = math.max(kZoomMin, (self._zFit or 0) * kZoomOutSlack)
  local z = self.zoom * math.exp(kZoomSpeed * scrolled)
  if z < zmin then z = zmin end
  self.zoom = clampZoom(z)
  self.pos.x = ax - (sx - self.x - vsx * 0.5) / self.zoom
  self.pos.y = ay - (sy - self.y - vsy * 0.5) / self.zoom
end

-- Projection: world -> screen, strictly LINEAR (no distance compression).
--
-- `pos`/`zoom` are world space, so pan, zoom-about-anchor and centre-on-node
-- are the classic linear operations. The earlier radial "compression" that
-- pulled far nodes toward the centre is GONE: it distorted distances, made
-- zooming feel wrong (nodes slid sideways as the warp faded), and inverting it
-- at deep zoom-out could fling the camera off to 1e8. True ranges are reported
-- textually now (inspector + lock readout), which is both clearer and stable.

-- world -> screen, for a bare world point.
function NodeGraph:toScreen (cx, cy)
  local _, _, sx, sy = self:getRectGlobal()
  return self.x + sx * 0.5 + (cx - self.pos.x) * self.zoom,
         self.y + sy * 0.5 + (cy - self.pos.y) * self.zoom
end

-- world -> screen for a NODE: base position + its declutter offset (world
-- units, so the fan/ring scales with zoom like everything else).
function NodeGraph:toScreenNode (n)
  local sx, sy = self:toScreen(n.x, n.y)
  return sx + (n.jx or 0) * self.zoom, sy + (n.jy or 0) * self.zoom
end

-- screen -> world (exact inverse of toScreen), for drag placement.
function NodeGraph:toCanvas (mx, my)
  local _, _, sx, sy = self:getRectGlobal()
  return (mx - self.x - sx * 0.5) / self.zoom + self.pos.x,
         (my - self.y - sy * 0.5) / self.zoom + self.pos.y
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

-- Bottom-row symbol key: decodes the map's shapes/colours. The text legend
-- only covers keys and filters, not what you are actually looking at.
local function drawSymbolKey (x, y)
  local entries = {
    { 'you', 'you' }, { 'selected', 'selected' }, { 'place', 'place' },
    { 'jumpgate', 'jumpgate' }, { 'gate', 'gate' },
    { 'rock', 'rock' }, { 'trade', 'trade' }, { 'mine', 'mine' },
    { 'warp', 'warp' }, { 'lane', 'lane' },
    { 'drill', 'drillable' },
  }
  local gx, tx = x + 6, x + 16
  for i = 1, #entries do
    local kind, label = entries[i][1], entries[i][2]
    if kind == 'you' then
      DrawEx.Ring(gx, y, 5, cLabel); DrawEx.Point(gx, y, 1.6, cLabel)
    elseif kind == 'selected' then
      DrawEx.Ring(gx, y, 5, cSelected)
    elseif kind == 'place' then
      DrawEx.Ring(gx, y, 5, cNode)
    elseif kind == 'jumpgate' then
      -- A JUMPGATE: a ring with a cross, in cyan. It leaves the sector.
      DrawEx.Ring(gx, y, 5, cJumpgate)
      DrawEx.Cross(gx, y, 3, cJumpgate)
    elseif kind == 'gate' then
      -- An INTRA-sector gate: the same shape, in amber. It leads to another
      -- place in this sector.
      DrawEx.Ring(gx, y, 5, cGate)
      DrawEx.Cross(gx, y, 3, cGate)
    elseif kind == 'rock' then
      DrawEx.Point(gx, y, 2.5, cMinor)
    elseif kind == 'trade' then
      DrawEx.Dash(gx - 8, y, gx + 8, y, cTrade, 2, 6, 0)
    elseif kind == 'mine' then
      DrawEx.Line(gx - 8, y, gx + 8, y, cMine)
    elseif kind == 'warp' then
      DrawEx.Dash(gx - 8, y, gx + 8, y, cWarp, 1, 5, 0)
    elseif kind == 'lane' then
      DrawEx.Dash(gx - 8, y, gx + 8, y, cGate, 1, 4, 0)
    elseif kind == 'drill' then
      Draw.Color(cCore.r, cCore.g, cCore.b, 0.9)
      Draw.Line(gx - 4, y, gx + 4, y)
      Draw.Line(gx, y - 4, gx, y + 4)
    end
    DrawEx.TextAlpha(kLabelFont, label, kLabelSize, tx, y - 8, 120, 18,
      1, 1, 1, 0.6, 0.0, 0.0)
    local w = 26 + #label * 7
    gx = gx + w
    tx = tx + w
  end
  Draw.Color(1, 1, 1, 1)
end

-- The regions: the sector's NAMED PLACES.
--
-- A region is an AREA, not a body, so it does not belong in the node table
-- (which holds bodies with a position and a radius). It gets its own layer,
-- drawn in two passes:
--
--   * the BOUNDARY of the region you are in, UNDER the nodes -- it is a
--     circle, because the boundary is a sphere in space and the map is a
--     top-down projection onto X/Z, so the sphere crosses the player's plane
--     in a circle. That circle is the line you cross to be somewhere else,
--     and showing it is the whole point of putting a region on a map.
--   * the region MARKERS, OVER the nodes -- a ring and a name at each
--     region's centre. They go over the top because the node field is dense
--     (an asteroid field is hundreds of labelled dots) and a place name that
--     is buried under them is a place name nobody can read.
--
-- The markers are clamped into the view: a place whose centre is off-screen
-- still reads, which matters because the regions are spread across a sector
-- and the map is usually zoomed in on the ship. A clamped marker gets a
-- leader line, so its name does not appear to belong to a place that is
-- somewhere else entirely.
--
-- The colour is AMBER, deliberately: the nodes are blue and the theme accent
-- is crimson, so a third hue is what makes a place read as a place and not
-- as another kind of body.
local cRegion      = { r = 0.98, g = 0.76, b = 0.30, a = 0.95 }
local cRegionOther = { r = 0.85, g = 0.62, b = 0.28, a = 0.60 }
local cRegionEdge  = { r = 0.98, g = 0.76, b = 0.30, a = 0.35 }
-- The region the map is DRILLED INTO. Green, so it cannot be mistaken for
-- the region the ship is in (amber) or for a region that is merely nearby
-- (dim amber).
local cRegionDrill = { r = 0.45, g = 0.95, b = 0.60, a = 0.95 }

function NodeGraph:drawRegionBoundary ()
  local st = self.regionState
  if not (st and st.boundaryCircle) then return end
  local c = st.boundaryCircle
  local bx, by = self:toScreen(c.x, c.z)
  local br = c.r * self.zoom
  if br > 3 then
    DrawEx.Ring(bx, by, br, cRegionEdge)
  end
end

function NodeGraph:drawRegionMarkers (vx, vy, vsx, vsy)
  local st = self.regionState
  if not (st and st.regions) then return end
  -- The RAILS: a line between each pair of connected regions.
  --
  -- This is the old game's map, which drew the region's structure as a graph
  -- of nodes joined by lines -- the lines being the connections. Here the
  -- regions are the nodes and the rails are the lines.
  local rails = st.rails
  if rails then
    for _, rail in ipairs(rails) do
      local ax, ay = self:toScreen(rail.aPos.x, rail.aPos.z)
      local bx, by = self:toScreen(rail.bPos.x, rail.bPos.z)
      DrawEx.Dash(ax, ay, bx, by, cRail, 1, 8, 0)
    end
  end

  -- The HUB: the sector's centre, where every lane starts. Drawn first, so
  -- the regions' pins sit over it.
  local hub = st.hub
  if hub then
    local hx, hy = self:toScreen(hub.x, hub.z)
    local mx = math.min(math.max(hx, vx + 44), vx + vsx - 44)
    local my = math.min(math.max(hy, vy + 34), vy + vsy - 24)
    if (mx ~= hx) or (my ~= hy) then
      DrawEx.Line(mx, my, hx, hy, { r = cHub.r, g = cHub.g, b = cHub.b, a = 0.25 })
    end
    local hname = hub.name or 'Hub'
    local tw = #hname * 7 + 12
    local pw = tw + 22
    Draw.Color(0.02, 0.03, 0.06, 0.90)
    Draw.Rect(mx - pw * 0.5, my - 11, pw, 22)
    DrawEx.Cross(mx - pw * 0.5 + 11, my, 6, cHub)
    DrawEx.TextAlpha(kLabelFont, hname, kLabelSize, mx + 8 - 110, my - 8, 220, 20,
      cHub.r, cHub.g, cHub.b, cHub.a, 0.5, 0.0)
  end

  for _, r in ipairs(st.regions) do
    local cur = (st.region == r)
    local drilled = (self.regionContext == r)
    local rx, ry = self:toScreen(r.center.x, r.center.z)
    local mx = math.min(math.max(rx, vx + 44), vx + vsx - 44)
    local my = math.min(math.max(ry, vy + 34), vy + vsy - 24)
    local clamped = (mx ~= rx) or (my ~= ry)
    local col = cur and cRegion or cRegionOther
    if drilled then col = cRegionDrill end
    if clamped then
      DrawEx.Line(mx, my, rx, ry, { r = col.r, g = col.g, b = col.b, a = 0.25 })
    end
    -- A PIN: an opaque chip carrying a cross and the name.
    --
    -- Everything in DrawEx blends ADDITIVELY, which is right for lines over a
    -- dark sky but useless over a bright one -- and the node field here is
    -- bright (an asteroid field is a dense blob of near-white labels), so an
    -- additive amber ring on top of it simply vanishes. The chip is OPAQUE
    -- and drawn with the normal blend, so the cross on it reads.
    --
    -- The chip is opaque for the same reason the plate had to be: even 20%
    -- of a near-white node label showing through is brighter than the ink.
    local tw = #r.name * 7 + 12
    local pw = tw + 22
    Draw.Color(0.02, 0.03, 0.06, cur and 1.0 or 0.85)
    Draw.Rect(mx - pw * 0.5, my - 11, pw, 22)
    DrawEx.Cross(mx - pw * 0.5 + 11, my, 6, col)
    -- The name is centred in the part of the chip to the RIGHT of the cross,
    -- and vertically centred in the chip -- the text's top edge is the y the
    -- draw call is given (the font's own height is added below it), so
    -- my - 8 puts the glyphs inside the chip rather than hanging out of it.
    local tcx = mx + 8
    DrawEx.TextAlpha(kLabelFont, r.name, kLabelSize, tcx - 110, my - 8, 220, 20,
      col.r, col.g, col.b, col.a, 0.5, 0.0)
  end
end

function NodeGraph:onDraw (focus, active)
  local x, y, sx, sy = self:getRectGlobal()

  -- Translucent canvas: the live scene stays visible behind (reference §12).
  Draw.Color(0.02, 0.03, 0.05, 0.55)
  Draw.Rect(x, y, sx, sy)
  DrawEx.RectOutline(x, y, sx, sy, { r = 0.2, g = 0.5, b = 0.8, a = 0.6 })


  -- The regions: the sector's NAMED PLACES. The boundary goes under the
  -- nodes (it is the ground they sit on); the markers go over them (a place
  -- name buried under hundreds of asteroid labels is a name nobody reads).
  --
  -- Not on the GALAXY level: that level's nodes are the SECTORS, and the
  -- regions belong to the sector level.
  if not self.galaxyLevel then
    self:drawRegionBoundary()
  end

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

  -- Minors are DOTS. Their labels appear only on the SELECTED one.
  --
  -- The legend says so: a rock is a dot. Labelling them anyway -- even only
  -- the ones near the centre, and even only when zoomed in -- turned the
  -- map into an unreadable pile of "Body #123" over the asteroid field, and
  -- it buried the things that matter (the region names, the ship, the
  -- places). A label on every body is the same as a label on none.
  -- The minor dots are CAPPED. A sector's asteroid field is a couple of
  -- thousand rocks, each drawn as an ADDITIVE dot -- so at the sector level
  -- they overlap into a solid glowing disc that hides the region names, the
  -- places and the gates underneath it. A few hundred of them still read as
  -- "there is a field here", which is the whole point of drawing them.
  local minorsDrawn = 0
  for id, n in pairs(self.nodes) do
    if self:isHidden(n) then
      -- filtered out: skip draw entirely
    else
      local nx, ny = self:toScreenNode(n)
      local selected = self.focus == id
      if not n.major then
        if not selected and minorsDrawn >= 400 then
          -- Too many rocks to draw them all: the rest are not more
          -- informative than the ones already down.
        else
        -- Minor bodies: fixed-size dim points (reference dot clouds). Fanned
        -- dots get a thin leader back toward truth (length varies, capped).
        local tx0, ty0 = self:toScreen(n.x, n.y)
        local ldx, ldy = nx - tx0, ny - ty0
        if not n.fanAnchor and ldx * ldx + ldy * ldy > 36 then
          Draw.Color(0.3, 0.5, 0.8, 0.35)
          Draw.Line(tx0, ty0, nx, ny)
        end
        DrawEx.Point(nx, ny, 2.2, n.color or cMinor)
        minorsDrawn = minorsDrawn + 1
        if selected then
          -- The selected body earns its label -- and a reticle, so a
          -- selected dot reads as selected.
          if not n.label then
            n.label = (n.entity and Util.resolveLabel(n.entity)) or ('Body #' .. tostring(id))
          end
          DrawEx.TextAlpha(kLabelFont, n.label, kLabelSize,
            nx - 100, ny + 6, 200, 20,
            cLabel.r, cLabel.g, cLabel.b, cLabel.a, 0.5, 0.0)
          local s = 9
          Draw.Color(cReticle.r, cReticle.g, cReticle.b, cReticle.a)
          Draw.Line(nx - s, ny - s, nx - s + 5, ny - s)
          Draw.Line(nx - s, ny - s, nx - s, ny - s + 5)
          Draw.Line(nx + s - 5, ny + s, nx + s, ny + s)
          Draw.Line(nx + s, ny + s, nx + s, ny + s - 5)
        end
        end -- the minor cap
      else
        local r = drawnRadius(n, self.zoom)
        local ring = selected and cSelected or (n.color or cNode)
        DrawEx.Ring(nx, ny, r, ring)
        DrawEx.Point(nx, ny, r * 0.35, selected and cLabel or cCore)
        if n.cat == 'gate' or n.cat == 'jumpgate' then
          -- Both kinds of gate get a cross through it, matching the symbol
          -- key: a gate is the one thing on the map you can FLY THROUGH, so
          -- it has to be distinguishable from a place you merely visit.
          --
          -- The two kinds differ in COLOUR (a jumpgate is cyan, an
          -- intra-sector gate is amber) and in the symbol key.
          DrawEx.Cross(nx, ny, r * 0.9, ring)
        end
        if n.isContext then
          -- The body you drilled INTO: an outer ring so it reads as "here".
          DrawEx.Ring(nx, ny, r * 1.7, cCore)
        end
        -- True physical extent: a huge planet's CENTRE can be far from a ship
        -- hugging its surface, so draw the body's real radius as a faint ring
        -- ("close to the surface" then reads as close on the map).
        local pr = (n.r or 0) * self.zoom
        if pr > r + 6 then
          if pr > 600 then pr = 600 end
          DrawEx.Ring(nx, ny, pr, { r = cNode.r, g = cNode.g, b = cNode.b, a = 0.20 })
        end
        if n.drillable and (n.major or selected) then
          -- "There is more inside": small + at the ring's lower-right.
          local gx, gy = nx + r + 7, ny + r + 7
          Draw.Color(cCore.r, cCore.g, cCore.b, 0.85)
          Draw.Line(gx - 4, gy, gx + 4, gy)
          Draw.Line(gx, gy - 4, gx, gy + 4)
        end
      if n.label then
        -- A GATE's label gets an opaque plate behind it.
        --
        -- The asteroid field is a dense blob of near-white dots, and a
        -- plain label drawn onto it is unreadable -- which is exactly where
        -- the gates are, because they sit on the sector's rim and the rim
        -- is where the field is densest. A gate is the one thing on the map
        -- the player has to be able to FIND, so it gets the same backing
        -- plate the region markers get.
        if n.cat == 'gate' or n.cat == 'jumpgate' then
          local tw = #n.label * 7 + 12
          Draw.Color(0.02, 0.03, 0.06, 0.92)
          Draw.Rect(nx - tw * 0.5, ny + r + 1, tw, 18)
        end
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
      if a and b then
        local ddx, ddy = a.x - b.x, a.y - b.y
        text = text .. '   ' .. Util.fmtShort(math.sqrt(ddx * ddx + ddy * ddy)) .. ' u'
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
  -- The sector and region, on the RIGHT of the breadcrumb.
  --
  -- The map says which PLACE it is a map of. Without it, a sector map is a
  -- field of dots with no indication of where in the galaxy you are, and
  -- the region's own name is the thing the HUD panel shows -- so it belongs
  -- on the map too.
  do
    local st = self.regionState
    if st then
      local txt = st.sectorName or ''
      -- Which region the map is showing: the drilled one if there is one,
      -- otherwise the one the player is in.
      local shown = self.regionContext or st.region
      if shown then txt = txt .. '  --  ' .. shown.name end
      if txt ~= '' then
        local tw = #txt * 7 + 16
        local tx = x + sx - tw - 16
        if tx < x + 16 then tx = x + 16 end
        DrawEx.TextAlpha(kLabelFont, txt, kLabelSize, tx, y + 14, tw, 20,
          0.75, 0.90, 1.00, 0.85, 0.0, 0.0)
      end
    end
  end
  -- Locked-target readout: always visible at top-centre while a node is
  -- selected, so range/bearing stay readable with or without the inspector.
  do
    local n = self.focus and self.nodes[self.focus] or nil
    if n then
      local txt = n.label or Util.kindTag(n.entity, 'short')
      local nav = Util.navTo(n.entity, self.focusEntity)
      if nav then
        txt = txt .. '   ' .. Util.fmtShort(nav.plane) .. ' u'
        if nav.bearing then txt = txt .. '   ' .. Util.bearingLabel(nav.bearing) end
      end
      local tw = #txt * 7 + 18
      local tx = x + (sx - tw) * 0.5
      if tx < x + 8 then tx = x + 8 end
      Draw.Color(0.02, 0.03, 0.06, 0.7)
      Draw.Rect(tx, y + 10, tw, 22)
      DrawEx.RectOutline(tx, y + 10, tw, 22, { r = 0.25, g = 0.6, b = 1.0, a = 0.7 })
      DrawEx.TextAlpha(kLabelFont, txt, kLabelSize, tx + 8, y + 13, tw - 16, 18,
        1, 1, 1, 0.9, 0.0, 0.0)
    end
  end
  -- Symbol key: decodes the shapes/colours (the text legend below only covers
  -- keys and filters).
  drawSymbolKey(x + 16, y + sy - 62)
  -- The region markers go LAST, over the node field.
  if not self.galaxyLevel then
    self:drawRegionMarkers(x, y, sx, sy)
  end
  -- Cursor readout: world X/Z under the pointer + range from YOU.
  do
    local mp = Input.GetMousePosition()
    if mp.x >= x and mp.x <= x + sx and mp.y >= y and mp.y <= y + sy then
      local wx, wz = self:toCanvas(mp.x, mp.y)
      local txt = string.format('x %s   z %s', Util.fmtShort(wx), Util.fmtShort(wz))
      local pe = self.focusEntity
      local okP, pp = pcall(function () return pe and pe:getPos() end)
      if okP and pp then
        local dx, dz = wx - pp.x, wz - pp.z
        txt = txt .. '   d ' .. Util.fmtShort(math.sqrt(dx * dx + dz * dz))
      end
      DrawEx.TextAlpha(kLabelFont, txt, kLabelSize,
        x + 16, y + sy - 88, 400, 18, 1, 1, 1, 0.55, 0.0, 0.0)
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
      '[dbl-click]/[Return] drill  [RMB]/[`] back  [Home] me  [End] fit',
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

-- The region marker under the cursor, if any.
--
-- Regions are not nodes -- they are places, and they have no entity -- so
-- they are hit-tested separately, against the same marker rectangle the
-- draw code uses.
function NodeGraph:regionAt (mx, my)
  local st = self.regionState
  if not (st and st.regions) then return nil end
  local vx, vy, vsx, vsy = self:getRectGlobal()
  local best, bestDist = nil, math.huge
  for _, r in ipairs(st.regions) do
    local rx, ry = self:toScreen(r.center.x, r.center.z)
    local cx = math.min(math.max(rx, vx + 44), vx + vsx - 44)
    local cy = math.min(math.max(ry, vy + 34), vy + vsy - 24)
    -- The marker is the cross plus the name plate beside it.
    local halfW = (#r.name * 7 + 34) * 0.5
    local dx = math.max(0, math.abs(mx - cx) - halfW)
    local dy = math.max(0, math.abs(my - cy) - 11)
    local d = math.sqrt(dx * dx + dy * dy)
    if d <= 6 and d < bestDist then best, bestDist = r, d end
  end
  return best
end

function NodeGraph:onInput (state)
  -- Arrows only (no WASD): as an in-game overlay the ship owns WASD, and
  -- panning the map must never fly the ship. Standalone SystemMap keeps WASD
  -- because nothing else is listening there.
  local dt = math.max(1e-6, state.dt)

  -- V (the galaxy level) is handled by the HUD, which runs whether or not
  -- the map is open -- so it is NOT handled here as well, or the level would
  -- toggle twice while the map is up.

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
  -- Home = recentre on YOU; End = re-fit the whole level.
  if Input.GetPressed(Button.Keyboard.Home) then self:centerOnPlayer() end
  if Input.GetPressed(Button.Keyboard.End) then self:refit() end

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
    -- Press edge: hit-test once; node => drag+select, region => select the
    -- place, empty => pan.
    self._drag = self:nodeAt(mp.x, mp.y)
    -- A region marker is a PLACE, not a body, so it is not in the node table
    -- and has to be hit-tested on its own.
    self._dragRegion = (not self._drag) and self:regionAt(mp.x, mp.y) or nil
    if self._dragRegion then
      -- A single click selects the region and centres the view on it; a
      -- double click drills into it, so the map shows what is IN that place.
      local now = Engine.GetTime()
      if self._lastRegionClick
        and now - self._lastRegionClick < 0.35
        and self._lastRegionClickName == self._dragRegion.name then
        self:drillIntoRegion(self._dragRegion)
        self._lastRegionClick = nil
      else
        self.pos.x, self.pos.y = self._dragRegion.center.x, self._dragRegion.center.z
        self._lastRegionClick = now
        self._lastRegionClickName = self._dragRegion.name
      end
    elseif self._drag then
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
    self._dragRegion = nil
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
  -- The sector state (which region you are in, and where its boundary is).
  -- A FUNCTION, not a value: the sector changes when the ship warps, and the
  -- map must not hold a stale copy of where you were.
  self.getSectorState = o.getSectorState
  self.regionState = nil
  -- The GALAXY LEVEL: the sectors are nodes and the gates are links. It is
  -- a level of the SAME graph, not a separate map -- see the old Limit
  -- Theory's map, where "Universe", "Region", "System" and "Wormhole" were
  -- all node types in one graph.
  self.galaxyLevel = false
  -- The REGION the map is drilled into, if any. A region is a place, not a
  -- body: it has no entity, so it lives beside the entity context rather
  -- than inside it.
  self.regionContext = nil
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
