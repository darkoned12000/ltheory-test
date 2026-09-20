-- NodeGraph -- retained node-graph / inventory canvas, Phase 1 skeleton.
-- Interactive canvas only (pan/zoom/drag/select); live game-data seeding lands
-- in Phase 2, which merges into the same id-keyed node table built here.
-- Mirrors SystemMap (framework use, math, focus-on-click); visual language
-- follows ltheory-node-ui.md §12 (rings, straight solid/dotted edges, overlay).

local DrawEx = require('UI.DrawEx')
local Container = require('UI.Container')
local Window = require('UI.Window')

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

-- LOD: majors get rings + labels; everything else seeded is a minor point.
-- Capability predicates (SystemMap-style); asteroids/NPC hulls fall through
-- to minor automatically. Types with NYI getName (Job/Action) are excluded.
-- Returns worthy, major, cat ('station' | 'ship' | 'rock').
function NodeGraph.isGraphWorthy (entity)
  if entity.deleted then return false end
  local scale = 0
  if entity.getScale then
    local ok, s = pcall(entity.getScale, entity)
    if ok and type(s) == 'number' then scale = s end
  end
  -- Regions (Zones): named + children = drill-down anchors, always major.
  -- (Ships carry component children but no names; stations get major below.)
  if entity.name then
    local okC, ch = pcall(entity.getChildren, entity)
    if okC and ch and #ch >= 5 then return true, true, 'station' end
  end
  -- Big bodies (stations at 100, planets at 1e5) are places, always major.
  if scale >= 50 then return true, true, 'station' end
  if entity.hasFactory and entity:hasFactory() then return true, true, 'station' end
  if entity.hasTrader and entity:hasTrader() then return true, true, 'station' end
  if entity.hasMarket and entity:hasMarket() then return true, true, 'station' end
  -- Yield alone is minor: whole ore fields carry yield (60 labeled rocks =
  -- an unreadable band), so mineables are dots labeled on zoom/focus.
  if entity.hasActions and entity:hasActions() then return true, false, 'ship' end
  if entity.hasSockets and entity:hasSockets() then return true, false, 'ship' end
  return true, false, 'rock'
end

-- Human tag for nodes with no proper name (raw `Entity @ %p` pointers are
-- useless on screen). Derived from capabilities, never invented.
local function kindTag (e)
  if e.hasFactory and e:hasFactory() then return 'Factory' end
  if e.hasTrader and e:hasTrader() then return 'Trader' end
  if e.hasMarket and e:hasMarket() then return 'Market' end
  if e.hasYield and e:hasYield() then return 'Ore' end
  if e.hasActions and e:hasActions() then return 'Ship' end
  if e.hasSockets and e:hasSockets() then return 'Ship' end
  return 'Body'
end

local function resolveLabel (e)
  if e.name and e.name ~= '' then
    local ok, name = pcall(e.getName, e)
    if ok and name then return name end
  end
  return kindTag(e) .. ' #' .. tostring(e.id % 1000)
end

function NodeGraph:addNode (id, x, y, opts)
  local o = opts or {}
  local n = {
    id    = id,
    x     = x,
    y     = y,
    r     = o.r or 10,
    color = o.color or cNode,
    label = o.label,
  }
  self.nodes[id] = n
  return n
end

function NodeGraph:removeNode (id)
  self.nodes[id] = nil
end

-- Live seeding (Phase 2): merge the system's children into the id-keyed table.
-- New entities snap in; live ones retarget (lerp in onUpdate tracks ships);
-- unseen/destroyed nodes are pruned. Never replaces the table (drag, focus,
-- and per-node state survive).
-- Zoom bounds. Unbounded `zoom * exp(k*scrolled)` ran to ~3e5 in a headless
-- autopilot run; clamp after every change (scroll, drill, fit, ease).
local kZoomMin = 1e-4
local kZoomMax = 5e5
local kDrillRadius = 140   -- drill in when a major's drawn radius passes this
local kUndrillRadius = 40  -- pop back only below this (hysteresis, no flicker)

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
  local ctxIsZone = sys ~= self.system and sys.name ~= nil
  local suppressMembers = not ctxIsZone
  local memberOfZone = {}
  if suppressMembers then
    -- Only named zones with bodies group (Zone:getPos overrides; sub-5-member
    -- groups are spurious blobs until Phase 5 clustering decides otherwise).
    for _, z in sys:iterChildren() do
      if z and not z.deleted and z.name then
        local okC, ch = pcall(z.getChildren, z)
        if okC and ch and #ch >= 5 then
          for _, m in ipairs(ch) do
            if m and m.id and m ~= sys then memberOfZone[m.id] = true end
          end
        end
      end
    end
  end
  local seen = {}
  for _, e in sys:iterChildren() do
    if e and not e.deleted then
      -- Only top-level children seed: components (turrets/thrusters, parented
      -- to ships) stay hidden until drill-down (Phase 4). Zone members: hidden
      -- behind their zone node at sector level, shown when the zone is drilled.
      local parent = e.getParent and e:getParent()
      local topLevel = (parent == nil or parent == sys)
      local worthy, major, cat = NodeGraph.isGraphWorthy(e)
      if worthy and topLevel and not memberOfZone[e.id] then
        -- Not every child has a body (particles, markers): no pos, no node.
        local okP, p = pcall(e.getPos, e)
        if okP and p then
          seen[e.id] = true
          local okS, s = pcall(e.getScale, e)
          local r = (okS and type(s) == 'number') and s or 1
          local n = self.nodes[e.id]
          if not n then
            n = {
              id     = e.id,
              entity = e,
              cat    = cat or 'rock',
              x = p.x, y = p.z, tx = p.x, ty = p.z,
              r = r,
              major = major,
              color = (e == self.focusEntity) and cPlayer or (major and cNode or cMinor),
              label = nil,
            }
            if major then n.label = resolveLabel(e) end
            if e == self.focusEntity then n.label = n.label or 'YOU' end
            self.nodes[e.id] = n
          else
            n.entity = e
            n.cat = cat or n.cat or 'rock'
            -- A user-placed node stays where dropped (drag-to-rearrange wins
            -- over live tracking until Phase 3 pinning formalizes this).
            if not n.manual then n.tx, n.ty = p.x, p.z end
            n.major = major or (e == self.focusEntity)
            -- Promoted late (major flag flipped after first sighting): a node
            -- must never be a ring without a label.
            if n.major and not n.label then n.label = resolveLabel(e) end
          end
        end
      end
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
      local x0, x1, y0, y1 = nil, nil, nil, nil
      local majors = false
      for _, n in pairs(self.nodes) do
        if n.major then majors = true break end
      end
      for _, n in pairs(self.nodes) do
        -- Planets (scale 1e5, possibly a full sector away) don't drive the
        -- fit, or stations collapse into a pile again. They still draw.
        if (n.major or not majors) and (n.r or 0) < 5000 then
          x0, x1 = x0 and math.min(x0, n.x) or n.x, x1 and math.max(x1, n.x) or n.x
          y0, y1 = y0 and math.min(y0, n.y) or n.y, y1 and math.max(y1, n.y) or n.y
        end
      end
      local w, h = math.max(1, x1 - x0), math.max(1, y1 - y0)
      -- Center the player's ship when present (player-centric map).
      local centered = false
      if self.context == self.system and self.focusEntity then
        for _, n in pairs(self.nodes) do
          if n.entity == self.focusEntity then
            self.pos = Vec2f(n.x, n.y)
            centered = true
            break
          end
        end
      end
      if not centered then
        self.pos = Vec2f((x0 + x1) * 0.5, (y0 + y1) * 0.5)
      end
      self.zoom = clampZoom(math.min(sx / w, sy / h) * 0.85)
      -- Declutter runs THIS frame: ring branch checks `not self._fitted`,
      -- so it must see the pre-fit state. Offsets freeze from the next frame
      -- (_ringDone), and _fitted gates further declutter entirely.
      if not self._ringDone then self:declutter() end
      self._fitted = true
      self._ringDone = true
    end
  end
end

-- Economy + socket + hierarchy edges, both endpoints seeded only. A parent
-- link to the unseeded context root (the system itself) never draws, so the
-- sector level cannot become a starburst hairball.
function NodeGraph:seedEdges ()
  local edges, n = {}, 0
  local function link (a, b, kind)
    if a and b and self.nodes[a.id] and self.nodes[b.id] and a.id ~= b.id then
      n = n + 1
      edges[n] = { a = a.id, b = b.id, kind = kind }
    end
  end
  for id, node in pairs(self.nodes) do
    local e = node.entity
    if e and not e.deleted then
      if e.hasSockets and e:hasSockets() then
        for _, s in ipairs(e:getSockets()) do
          if s.child then link(e, s.child, 'solid') end
        end
      end
      if e.getParent then
        local p = e:getParent()
        if p then link(p, e, 'solid') end
      end
    end
  end
  if self.context and self.context.hasEconomy and self.context:hasEconomy() then
    local eco = self.context:getEconomy()
    for _, job in ipairs(eco.jobs or {}) do
      if job.src and job.dst then
        link(job.src, job.dst, job.item and 'trade' or 'mine')
      end
    end
  end
  self.edges = edges
end

function NodeGraph:onUpdate (state)
  if self._offsetHold and self._offsetHold > 0 then
    self._offsetHold = self._offsetHold - 1
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
end

function NodeGraph:addEdge (a, b, kind)
  self.edges[#self.edges + 1] = { a = a, b = b, kind = kind or 'solid' }
end

function NodeGraph:clearEdges ()
  self.edges = {}
end

-- Drill context (Phase 4): swap the seeding target without touching the
-- lens. The stack carries {context, camera{zoom,pos}} so Back restores the
-- level you came FROM exactly (per-level camera, per-the-plan §7).
function NodeGraph:drillInto (entity, keepZoom)
  if entity == self.context then return end
  -- Only entities that can actually be a seeding context: a node with no
  -- children CANNOT be one. Clicking a childless node must zoom, never blank.
  if not (entity and entity.hasChildren and entity:hasChildren()) then
    return false
  end
  -- A drill context is only useful if at least one child can SEED (has a
  -- body/map position). Factory socket children (turrets/thrusters) are
  -- parented and bodyless at map scale -> empty reveal (the blank bug).
  local okC, ch = pcall(entity.getChildren, entity)
  local seedable = false
  if okC and ch then
    for _, c in ipairs(ch) do
      if c and not c.deleted and (c.getPos) then
        local okP, p = pcall(c.getPos, c)
        if okP and p then seedable = true break end
      end
    end
  end
  if not seedable then return false end
  self.stack[#self.stack + 1] = {
    context = self.context,
    camera  = { zoom = self.zoom, pos = { x = self.pos.x, y = self.pos.y } },
  }
  self.context = entity
  self.nodes, self.edges = self._prevNodes or {}, {}
  self.focus, self.follow = nil, nil
  self._fitted = false
  self._prevNodes = nil
  self.nucleus = nil
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

function NodeGraph:drillOut ()
  if #self.stack == 0 then return false end
  local prev = self.stack[#self.stack]
  self.stack[#self.stack] = nil
  self.context = prev.context
  self.nodes, self.edges = {}, {}
  self.focus, self.follow = nil, nil
  self._fitted = false
  self.zoom = prev.camera.zoom
  self.pos = Vec2f(prev.camera.pos.x, prev.camera.pos.y)
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
    scr[id] = {
      x = self.x + sx * 0.5 + (n.x - self.pos.x) * self.zoom,
      y = self.y + sy * 0.5 + (n.y - self.pos.y) * self.zoom,
    }
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
      local hx = self.x + sx * 0.5 + ((hub.x + (hub.jx or 0)) - self.pos.x) * self.zoom
      local hy = self.y + sy * 0.5 + ((hub.y + (hub.jy or 0)) - self.pos.y) * self.zoom
      for k, rid in ipairs(members) do
        local rock = self.nodes[rid]
        if rock then
          local ang = k * 2.39996
          local ringR = 105 + ((k - 1) % 3) * 25
          rock.jx = (hx + math.cos(ang) * ringR - (self.x + sx * 0.5 + (rock.x - self.pos.x) * self.zoom)) / self.zoom
          rock.jy = (hy + math.sin(ang) * ringR - (self.y + sy * 0.5 + (rock.y - self.pos.y) * self.zoom)) / self.zoom
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
      occupy(self.x + sx * 0.5 + ((n.x + (n.jx or 0)) - self.pos.x) * self.zoom,
             self.y + sy * 0.5 + ((n.y + (n.jy or 0)) - self.pos.y) * self.zoom)
    end
    local mids = {}
    for id, n in pairs(self.nodes) do
      if not n.major then mids[#mids + 1] = id end
    end
    table.sort(mids)
    for _, id in ipairs(mids) do
      local n = self.nodes[id]
      if n.fanAnchor then
        occupy(self.x + sx * 0.5 + ((n.x + (n.jx or 0)) - self.pos.x) * self.zoom,
               self.y + sy * 0.5 + ((n.y + (n.jy or 0)) - self.pos.y) * self.zoom)
      end
    end
    for _, id in ipairs(mids) do
      local n = self.nodes[id]
      if n.fanAnchor then -- ringed already: skip the grid fan
      else
      local bx = self.x + sx * 0.5 + (n.x - self.pos.x) * self.zoom
      local by = self.y + sy * 0.5 + (n.y - self.pos.y) * self.zoom
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

-- Projected position (true pos + visual offset) for draw/hit/edges.
function NodeGraph:nodeXY (n)
  return n.x + (n.jx or 0), n.y + (n.jy or 0)
end
-- Zoom application, shared by real scroll input and the headless autopilot.
-- Anchor: followed node when locked (never moves under any scroll), else the
-- cursor (standard map UX). Single anchor means the follow-ease below can
-- never fight the zoom.
function NodeGraph:applyScroll (scrolled, mx, my, anchor)
  local _, _, vsx, vsy = self:getRectGlobal()
  if vsx <= 0 then return end
  self.targetZoom = nil -- hands on the wheel now
  -- Freeze declutter offsets for the gesture (+6 settle frames): recomputing
  -- them from the shifting screen layout mid-zoom moves the anchor out from
  -- under the zoom (the 02->06 drift). Computed once, they stay exact.
  self._offsetHold = 6
  local ax, ay
  if anchor then
    ax, ay = anchor[1], anchor[2]
  else
    local cx = math.min(math.max(mx, self.x), self.x + vsx)
    local cy = math.min(math.max(my, self.y), self.y + vsy)
    ax = self.pos.x + (cx - self.x - vsx * 0.5) / self.zoom
    ay = self.pos.y + (cy - self.y - vsy * 0.5) / self.zoom
  end
  local sx = self.x + vsx * 0.5 + (ax - self.pos.x) * self.zoom
  local sy = self.y + vsy * 0.5 + (ay - self.pos.y) * self.zoom
  self.zoom = clampZoom(self.zoom * math.exp(kZoomSpeed * scrolled))
  self.pos.x = ax - (sx - self.x - vsx * 0.5) / self.zoom
  self.pos.y = ay - (sy - self.y - vsy * 0.5) / self.zoom
end

function NodeGraph:toScreen (cx, cy)
  local _, _, sx, sy = self:getRectGlobal()
  return self.x + sx * 0.5 + (cx - self.pos.x) * self.zoom,
         self.y + sy * 0.5 + (cy - self.pos.y) * self.zoom
end

function NodeGraph:toCanvas (mx, my)
  local _, _, sx, sy = self:getRectGlobal()
  return (mx - self.x - sx * 0.5) / self.zoom + self.pos.x,
         (my - self.y - sy * 0.5) / self.zoom + self.pos.y
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
  local _, _, vsx, vsy = self:getRectGlobal()
  local best, bestDist = nil, math.huge
  for _, majorOnly in ipairs({ true, false }) do
    for id, n in pairs(self.nodes) do
      local cat = n.cat or 'rock'
      local hidden = (cat == 'ship' and not self.filter.ships)
        or (cat == 'rock' and not self.filter.rocks)
        or (cat ~= 'ship' and cat ~= 'rock' and not self.filter.places)
      if not hidden and (n.major or false) == majorOnly then
        local nx, ny = self:toScreen(self:nodeXY(n))
        local gx, gy, hit = nx, ny, 0
        if majorOnly then
          hit = math.max(14, drawnRadius(n, self.zoom) + 6)
        else
          hit = (n.fanAnchor and 14 or 8)
        end
        if vsx > 0 and (nx < -40 or ny < -40 or nx > vsx + 40 or ny > vsy + 40) then
          -- Off-screen major: clamp to the frame edge (matches its indicator).
          gx = math.min(math.max(nx, 24), vsx - 24)
          gy = math.min(math.max(ny, 24), vsy - 24)
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
      if a and b then
        local ax, ay = self:toScreen(self:nodeXY(a))
        local bx, by = self:toScreen(self:nodeXY(b))
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
  local showMinorLabels = self.zoom > 0.3
  for id, n in pairs(self.nodes) do
    local cat = n.cat or 'rock'
    if (cat == 'ship' and not self.filter.ships)
    or (cat == 'rock' and not self.filter.rocks)
    or (cat ~= 'ship' and cat ~= 'rock' and not self.filter.places) then
      -- filtered out: skip draw entirely
    else
      local nx, ny = self:toScreen(self:nodeXY(n))
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
        if selected or showMinorLabels then
          if not n.label then
            n.label = (n.entity and resolveLabel(n.entity)) or ('Body #' .. tostring(id % 1000))
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
      local cat = n.cat or 'rock'
      local hidden = (cat == 'ship' and not self.filter.ships)
        or (cat == 'rock' and not self.filter.rocks)
        or (cat ~= 'ship' and cat ~= 'rock' and not self.filter.places)
      if n.major and not hidden then
        local nx, ny = self:toScreen(self:nodeXY(n))
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
    local legend = string.format('[F5] ships %s  [F6] rocks %s  [F7] places %s  [F8] routes %s',
      f.ships and 'on' or 'off', f.rocks and 'on' or 'off',
      f.places and 'on' or 'off', f.routes and 'on' or 'off')
    DrawEx.TextAlpha(kLabelFont, legend, kLabelSize,
      x + sx - 360, y + sy - 40, 344, 20,
      1, 1, 1, 0.55, 1.0, 0.0)
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
        local fx, fy = self:nodeXY(lock)
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
      -- CLICK = center the map on this node and zoom toward it. Centered
      -- anchor = no drift possible: scroll re-anchors at dead center every
      -- tick, so "works a little then moves" cannot happen. Also fixes the
      -- planet: 40px ring or not, it stays centered and scrolled-in.
      -- DRILL = double-click on a node with children (sector -> zone members).
      local now = Engine.GetTime()
      if self._lastClick
        and now - self._lastClick < 0.35
        and self._lastClickNode == dn.id
        and dn.entity
        and dn.entity.hasChildren and dn.entity:hasChildren()
        and dn.entity ~= self.context then
        self:drillInto(dn.entity, false)
        self._lastClick = nil
      else
        self.pos.x = dn.x + (dn.jx or 0)
        self.pos.y = dn.y + (dn.jy or 0)
        self.targetZoom = clampZoom(self.zoom * 4)
        self._lastClick = now
        self._lastClickNode = dn.id
      end
    end
    self._panAt = { x = mp.x, y = mp.y }
    self._pressAt = { x = mp.x, y = mp.y }
  end
  if down then
    if self._drag then
      -- Drag writes position AND target (a dragged node stays put). Subtract
      -- the visual offset: drops land in true coordinates. Dragging pins the
      -- view (follow would fight the cursor).
      self.follow, self.targetZoom = nil, nil
      local cx, cy = self:toCanvas(mp.x, mp.y)
      self._drag.x = cx - (self._drag.jx or 0)
      self._drag.y = cy - (self._drag.jy or 0)
      self._drag.tx, self._drag.ty = self._drag.x, self._drag.y
    elseif self._panAt then
      self.follow, self.targetZoom = nil, nil -- manual pan breaks follow too
      self.pos.x = self.pos.x - (mp.x - self._panAt.x) / self.zoom
      self.pos.y = self.pos.y - (mp.y - self._panAt.y) / self.zoom
      self._panAt = { x = mp.x, y = mp.y }
    end
  else
    if self._drag then self._drag.manual = true end -- dropped here: keep it
    if self._pressAt and not self._drag then
      local dx, dy = mp.x - self._pressAt.x, mp.y - self._pressAt.y
      if dx * dx + dy * dy < 36 then
        self.focus, self.follow, self.targetZoom = nil, nil, nil
      end
    end
    self._drag, self._panAt, self._pressAt = nil, nil, nil
  end
  self._wasDown = down
end

function NodeGraph.Create (system, opts)
  local self = setmetatable(Window('Node Graph', false), NodeGraph)
  self:setStretch(1, 1)
  self:setPadUniform(0)
  self.system = system
  local o = opts or {}
  self.focusEntity = o.focusEntity
  self.nodes = {}
  self.edges = {}
  self.context = system
  self.stack  = {}    -- drill levels: {context, camera{zoom,pos}}
  self.focus = nil
  -- Category filters (F5 ships / F6 rocks / F7 places / F8 routes).
  self.filter = { ships = true, rocks = true, places = true, routes = true }
  self.pos = Vec2f(0, 0)
  self.zoom = 1.0
  return self
end

return NodeGraph
