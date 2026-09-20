-- GraphProvider -- data-source seam for NodeGraph (node-ui extensibility).
--
-- NodeGraph owns the *view* (table merge, fit, declutter, draw, input, drill
-- stack). A provider owns the *data*: which units exist at a context, how they
-- are classified/labeled, which links join them, and whether a node can be
-- drilled into. Swapping the provider is how the same widget becomes a system
-- map, a ship-systems tree, an inventory, a crafting tree, a comms view.
--
-- Provider contract (all methods optional; defaults below are no-ops):
--   provider.classify(entity)   -> worthy, major, cat   (cat: 'station'|'ship'|'rock')
--   provider.children(ctx)      -> array of unit records:
--        { entity = e, major = bool, cat = string, x = number, y = number,
--          r = number, label = string|nil }
--   provider.links(ctx, nodes)  -> array of { a = id, b = id, kind = string, job = any }
--   provider.drillable(entity)  -> bool  (may this node become a context?)
--   provider.layout(nodes)      -> optional; assign node x/y for logical views
--                                  (world views leave this nil: x/y are world coords)

local GraphProvider = {}

-- Default system/sector provider: entities as nodes, sockets + parent links +
-- economy jobs as edges. Extracted verbatim from NodeGraph (behavior-preserving).
function GraphProvider.system ()
  local P = {}

  -- Returns worthy, major, cat ('station' | 'ship' | 'rock').
  function P.classify (entity)
    if entity.deleted then return false end
    local scale = 0
    if entity.getScale then
      local ok, s = pcall(entity.getScale, entity)
      if ok and type(s) == 'number' then scale = s end
    end
    -- Regions (Zones): named + 5+ children = drill-down anchors, always major.
    if entity.name then
      local okC, ch = pcall(entity.getChildren, entity)
      if okC and ch and #ch >= 5 then return true, true, 'station' end
    end
    -- Big bodies (stations ~100, planets ~1e5) are places, always major.
    if scale >= 50 then return true, true, 'station' end
    if entity.hasFactory and entity:hasFactory() then return true, true, 'station' end
    if entity.hasTrader and entity:hasTrader() then return true, true, 'station' end
    if entity.hasMarket and entity:hasMarket() then return true, true, 'station' end
    -- Yield alone is minor: whole ore fields carry yield, and 60 labeled rocks
    -- are an unreadable band. Mineables are dots labeled on zoom/focus.
    if entity.hasActions and entity:hasActions() then return true, false, 'ship' end
    if entity.hasSockets and entity:hasSockets() then return true, false, 'ship' end
    return true, false, 'rock'
  end

  -- Units to seed at this context: top-level children only (ship components
  -- stay hidden until drill-down); zone members hide behind their zone node at
  -- sector level but ARE the level when the zone itself is the context.
  -- Scratch tables live on the provider (per NodeGraph) so this per-frame call
  -- does not allocate.
  --
  -- `isRoot` is passed by NodeGraph (ctx == system). Zone-ness must NOT be
  -- inferred from `.name` alone: a named sector root would then be treated as
  -- a zone and skip member suppression (leaking every zone member into the
  -- sector view).
  function P.children (ctx, isRoot)
    local out = P._units
    if not out then out = {}; P._units = out end
    for i = #out, 1, -1 do out[i] = nil end
    local ctxIsZone = (not isRoot) and ctx.name ~= nil
    local memberOfZone = P._memberOfZone
    if not memberOfZone then memberOfZone = {}; P._memberOfZone = memberOfZone end
    for k in pairs(memberOfZone) do memberOfZone[k] = nil end
    if not ctxIsZone then
      for _, z in ctx:iterChildren() do
        if z and not z.deleted and z.name then
          local okC, ch = pcall(z.getChildren, z)
          if okC and ch and #ch >= 5 then
            for _, m in ipairs(ch) do
              if m and m.id and m ~= ctx then memberOfZone[m.id] = true end
            end
          end
        end
      end
    end
    for _, e in ctx:iterChildren() do
      if e and not e.deleted then
        local parent = e.getParent and e:getParent()
        -- Zone members are parented to the SYSTEM (Zone:add is loose, no
        -- reparent), so when the zone IS the context its members are top-level.
        local topLevel = (parent == nil or parent == ctx or ctxIsZone)
        local worthy, major, cat = P.classify(e)
        if worthy and topLevel and not memberOfZone[e.id] then
          -- Not every child has a body (particles, markers): no pos, no node.
          local okP, p = pcall(e.getPos, e)
          if okP and p then
            local okS, s = pcall(e.getScale, e)
            out[#out + 1] = {
              entity = e,
              major  = major,
              cat    = cat or 'rock',
              x = p.x, y = p.z,
              r = (okS and type(s) == 'number') and s or 1,
            }
          end
        end
      end
    end
    -- Regions: zones live in `system.zones`, NOT in the child tree, so they
    -- never appear via iterChildren. At the sector level add each zone as a
    -- major region node (bounding radius over its members) so the field has a
    -- drill anchor — the ore view the map was missing.
    if isRoot and ctx.getZones then
      local okZ, zones = pcall(ctx.getZones, ctx)
      if okZ and zones then
        for _, z in ipairs(zones) do
          local okP, zp = pcall(z.getPos, z)
          if okP and zp then
            local rr = 600
            local okC, ch = pcall(z.getChildren, z)
            if okC and ch then
              local r2 = 0
              for _, m in ipairs(ch) do
                local okM, mp = pcall(m.getPos, m)
                if okM and mp then
                  local dx, dy = mp.x - zp.x, mp.z - zp.z
                  local d2 = dx * dx + dy * dy
                  if d2 > r2 then r2 = d2 end
                end
              end
              if r2 > 0 then rr = math.sqrt(r2) end
            end
            -- Squared distances can be dominated by a far outlier member;
            -- clamp so the region's size is sane and it still contributes to
            -- the fit (the fit skips r >= 5000 as "planet-scale").
            if rr < 600 then rr = 600 end
            if rr > 4000 then rr = 4000 end
            out[#out + 1] = {
              entity = z, major = true, cat = 'station',
              x = zp.x, y = zp.z, r = rr,
            }
          end
        end
      end
    end
    return out
  end

  -- Edges: sockets (child plugs) + parent hierarchy + economy jobs. Only links
  -- whose BOTH endpoints are seeded draw, so the sector root cannot starburst.
  function P.links (ctx, nodes)
    local out, n = {}, 0
    local function link (a, b, kind, job)
      if a and b and nodes[a.id] and nodes[b.id] and a.id ~= b.id then
        n = n + 1
        out[n] = { a = a.id, b = b.id, kind = kind, job = job }
      end
    end
    for _, node in pairs(nodes) do
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
    if ctx.hasEconomy and ctx:hasEconomy() then
      local eco = ctx:getEconomy()
      for _, job in ipairs(eco.jobs or {}) do
        if job.src and job.dst then
          link(job.src, job.dst, job.item and 'trade' or 'mine', job)
        end
      end
    end
    return out
  end

  -- Why a node cannot be drilled (for the UI's failed-drill feedback).
  -- nil = don't flash (childless rock, or a ship that belongs to another view).
  function P.noDrillReason (entity)
    if not (entity and entity.hasChildren and entity:hasChildren()) then return nil end
    if entity.hasActions and entity:hasActions() then return nil end
    if P.drillable(entity) then return nil end
    return 'empty'
  end

  -- Drillable: has children AND at least one child can seed (has a body).
  -- Factory socket children (turrets/thrusters) are bodyless -> no drill.
  function P.drillable (entity)
    if not (entity and entity.hasChildren and entity:hasChildren()) then return false end
    -- Ships drill into components -> that belongs to the ship-systems /
    -- inventory view, not the sector map. Ships are not drill targets here.
    if entity.hasActions and entity:hasActions() then return false end
    local okC, ch = pcall(entity.getChildren, entity)
    if not (okC and ch) then return false end
    for _, c in ipairs(ch) do
      if c and not c.deleted and c.getPos then
        local okP, p = pcall(c.getPos, c)
        if okP and p then return true end
      end
    end
    return false
  end

  return P
end

-- A deterministic grid layout for LOGICAL views (inventory, crafting, comms)
-- where nodes have no world position. `cols` nodes per row, `pad` spacing.
-- Returns a function(nodes) that assigns n.x / n.y in canvas units.
function GraphProvider.grid (cols, pad)
  cols = cols or 6
  pad = pad or 400
  return function (nodes)
    -- Deterministic order by id so the layout is stable frame to frame.
    local ids = {}
    for id in pairs(nodes) do ids[#ids + 1] = id end
    table.sort(ids)
    for i, id in ipairs(ids) do
      local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
      local n = nodes[id]
      n.x = (col - (cols - 1) * 0.5) * pad
      n.y = row * pad
    end
  end
end

-- A single-node/aggregate provider stub, for future views (inventory stacks,
-- comms threads). Kept here as the documented starting point:
--   P.children(ctx) -> { { entity = <item>, major = ..., cat = ... } }
--   P.links(ctx, nodes) -> quantity/recipe edges
--   P.layout = GraphProvider.grid(...)   -- logical, no world coords

return GraphProvider
