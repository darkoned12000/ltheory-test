#!/usr/bin/env luajit
--[[----------------------------------------------------------------------------
  Offline NodeGraph validator (node-ui).

  Exercises the pure logic in script/UI/NodeGraph.lua with NO GL/Engine
  context. The widget's UI/entity dependencies are stubbed via package.loaded,
  so this runs under the vendored luajit in `configure.py test`.

  What it covers (regression surface behind the map's behavior):
    - isGraphWorthy classification (station/ship/rock, deleted entities)
    - zoom clamping (applyScroll bounds, NaN guard) — the runaway that hit
      zoom 3e5 before clampZoom existed
    - drill stack: drillInto pushes {context, camera}, drillOut restores the
      EXACT context + camera it came from (the per-level back contract)
    - childless targets refuse to drill (the asteroid crash regression)
  Exit code non-zero on any failure. Wired into `configure.py test`.
----------------------------------------------------------------------------]]--

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1,1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.')..'/'..src end
local root = src:gsub('/tools/validate_nodegraph%.lua$', '')
if root == src then root = '.' end
package.path = root..'/script/?.lua;'..root..'/script/?/init.lua;'..package.path

-- Stubs: the widget only needs these to LOAD; behavior under test is pure.
local function stub (name, tbl) package.loaded[name] = tbl end

local Window = setmetatable({}, { __call = function () return {} end })
stub('UI.Window', Window)
-- Container is the class metatable for NodeGraph (setmetatable(NodeGraph,
-- Container)), so it needs a self-referential __index for method lookup.
local ContainerStub = {
  setStretch = function () end,
  setPadUniform = function () end,
}
ContainerStub.__index = ContainerStub
stub('UI.Container', ContainerStub)
stub('UI.DrawEx', {
  Rect = function () end, RectOutline = function () end, Line = function () end,
  Ring = function () end, Point = function () end, Dash = function () end,
  TextAlpha = function () end,
})
stub('UI.NodeGraphInspector', {
  Create = function ()
    return { show = function () end, hide = function () end, draw = function () end }
  end,
})

_G.Vec2f = function (x, y) return { x = x or 0, y = y or 0 } end
_G.Engine = { GetTime = function () return 0 end }
_G.Settings = { get = function () return nil end }
-- Controllable input so onInput() paths can be driven from a test.
_G.Button = {
  Keyboard = { Right = 1, Left = 2, Up = 3, Down = 4, F5 = 5, F6 = 6, F7 = 7,
               F8 = 8, Return = 9, Backtick = 10 },
  Mouse = { Left = 20, Right = 21 },
}
_G.__input = { down = false, mouse = { x = 0, y = 0 }, pressed = {} }
_G.Input = {
  GetMousePosition = function () return _G.__input.mouse end,
  GetDown = function (b) return _G.__input.down and b == _G.Button.Mouse.Left end,
  GetValue = function () return 0 end,
  GetPressed = function (b) return _G.__input.pressed[b] == true end,
  GetMouseScroll = function () return { x = 0, y = 0 } end,
}
_G.Draw = setmetatable({}, { __index = function () return function () end end })
_G.Math = setmetatable({}, { __index = function () return function () end end })

local NodeGraph = require('UI.NodeGraph')

local failures, checks = 0, 0
local function ok (cond, msg)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print('FAIL - ' .. msg)
  else
    print('ok   - ' .. msg)
  end
end

-- Minimal entity mocks (capability predicates are plain functions). ---------
local function entity (opts)
  local e = opts or {}
  e.deleted = e.deleted or false
  if e.scale then e.getScale = function () return e.scale end end
  return e
end

-- 1. isGraphWorthy classification -------------------------------------------
local w, m, c
w, m, c = NodeGraph.isGraphWorthy(entity{ hasFactory = function () return true end })
ok(w == true and m == true and c == 'station', 'factory classified station/major')

w, m, c = NodeGraph.isGraphWorthy(entity{ hasTrader = function () return true end })
ok(w == true and m == true and c == 'station', 'trader classified station/major')

w, m, c = NodeGraph.isGraphWorthy(entity{ hasMarket = function () return true end })
ok(w == true and m == true and c == 'station', 'market classified station/major')

w, m, c = NodeGraph.isGraphWorthy(entity{ scale = 100 })
ok(w == true and m == true and c == 'station', 'large scale body classified station/major')

w, m, c = NodeGraph.isGraphWorthy(entity{ name = 'X Field', children = { 1, 2, 3, 4, 5 },
  getChildren = function (s) return s.children end })
ok(w == true and m == true and c == 'station', 'named 5+ member region classified major')

w, m, c = NodeGraph.isGraphWorthy(entity{ hasActions = function () return true end })
ok(w == true and m == false and c == 'ship', 'actions entity classified ship/minor')

w, m, c = NodeGraph.isGraphWorthy(entity{ hasSockets = function () return true end })
ok(w == true and m == false and c == 'ship', 'sockets entity classified ship/minor')

w, m, c = NodeGraph.isGraphWorthy(entity{})
ok(w == true and m == false and c == 'rock', 'plain entity classified rock/minor')

w, m, c = NodeGraph.isGraphWorthy(entity{ deleted = true })
ok(w == false, 'deleted entity is not graph-worthy')

-- 2. zoom clamping (the runaway guard) --------------------------------------
-- Provider stub matching the drill contract used by fakeGraph-based tests.
local testProvider = {
  children = function () return {} end,
  links = function () return {} end,
  drillable = function (e)   -- dot-called: provider.drillable(entity)
    return (e and e.hasChildren and e:hasChildren()) and true or false
  end,
}

local function fakeGraph ()
  local g = setmetatable({
    zoom = 1, pos = Vec2f(0, 0), nodes = {}, follow = nil,
    x = 0, y = 0, provider = testProvider,
  }, { __index = NodeGraph })
  g.getRectGlobal = function () return 0, 0, 1000, 1000 end
  g.nodeXY = function (_, n) return n.x, n.y end
  return g
end

local g = fakeGraph()
for _ = 1, 60 do g:applyScroll(1, 500, 500) end
ok(g.zoom <= 5e5 + 1e-6, 'zoom clamps at the ceiling (accumulated scroll)')
local hi = g.zoom
for _ = 1, 200 do g:applyScroll(-1, 500, 500) end
ok(g.zoom >= 1e-4 - 1e-12, 'zoom clamps at the floor (accumulated scroll)')
ok(g.zoom < hi, 'zoom decreases when scrolling out')

-- 3. drill stack contract ---------------------------------------------------
local childWithPos = { getPos = function () return { x = 1, y = 2, z = 3 } end }
local function drillable ()
  return entity{
    name = 'Region',
    children = { childWithPos },
    getChildren = function (s) return s.children end,
    hasChildren = function (s) return true end,
  }
end

local g2 = fakeGraph()
local root = { name = 'Root', hasChildren = function () return true end }
g2.context = root
g2.stack = {}
g2.edges = {}
-- root re-seeds one node (id 99) so the deferred camera/focus restore can be
-- observed on the next fit.
g2.provider = {
  children = function ()
    return { { entity = { id = 99 }, major = true, cat = 'station', x = 0, y = 0, r = 10 } }
  end,
  links = function () return {} end,
  drillable = function () return true end,
}
g2.zoom, g2.pos = 12.5, Vec2f(7, -3)
g2.focus = 99
local target = drillable()
local pushed = g2:drillInto(target, false)
ok(pushed ~= nil and g2.context == target, 'drillInto switches the seeding context')
ok(g2.stack[#g2.stack].context == root, 'drillInto pushed the previous context')
ok(g2.stack[#g2.stack].camera.zoom == 12.5, 'drillInto saved the prior zoom')
ok(g2.stack[#g2.stack].focusId == 99, 'drillInto saved the inspected node (for re-select)')

-- mutate the new level, then back out; the camera+focus restore is DEFERRED
-- until the level re-seeds (the fit would otherwise recentre on the player)
g2.zoom, g2.pos = 999, Vec2f(50, 60)
ok(g2:drillOut() == true, 'drillOut returns true with a level on the stack')
ok(g2.context == root, 'drillOut restores the previous context')
ok(g2._restore ~= nil and g2._restore.zoom == 12.5, 'drillOut defers the prior camera')
ok(g2._restoreFocus == 99, 'drillOut defers the prior focus id')
ok(g2.context.hasChildren() == true, 'root is drillable again after pop')

-- applying on the next seed: camera restored AND the node re-selected
g2:seedFromSystem()
ok(g2.zoom == 12.5 and g2.pos.x == 7 and g2.pos.y == -3,
   're-seed applies the restored camera (not a player recentre)')
ok(g2.focus == 99, 're-seed re-selects the node we drilled from')
ok(g2._restore == nil and g2._restoreFocus == nil, 'deferred restore is consumed once')

-- childless targets must NOT drill (the asteroid crash regression)
local g3 = fakeGraph()
g3.context = root
g3.stack = {}
local childless = entity{ hasChildren = function () return false end }
local r = g3:drillInto(childless, false)
ok(r == false and g3.context == root, 'childless target refuses to drill (no crash)')

-- 4. Provider seam: a custom provider drives seeding ----------------------
local GraphProvider = require('UI.GraphProvider')

do
  -- grid layout is deterministic and spaced
  local nodes = { [10] = { id = 10 }, [20] = { id = 20 }, [30] = { id = 30 } }
  GraphProvider.grid(2, 100)(nodes)
  ok(nodes[10].x == -50 and nodes[10].y == 0 and nodes[20].x == 50 and nodes[20].y == 0,
     'grid layout: first row spaced by pad, centred')
  ok(nodes[30].x == -50 and nodes[30].y == 100, 'grid layout: wraps to the next row')
  local again = { [10] = { id = 10 }, [20] = { id = 20 }, [30] = { id = 30 } }
  GraphProvider.grid(2, 100)(again)
  ok(again[10].x == nodes[10].x and again[30].y == nodes[30].y, 'grid layout is deterministic')
end

do
  -- system provider classify matches the module-level LOD contract
  local P = GraphProvider.system()
  local e = { hasMarket = function () return true end }
  local w, m, c = P.classify(e)
  ok(w == true and m == true and c == 'station', 'provider classify: market -> station/major')
  local w2, m2, c2 = NodeGraph.isGraphWorthy(e)
  ok(w2 == w and m2 == m and c2 == c, 'provider classify matches NodeGraph.isGraphWorthy')
end

do
  -- swapping the provider reseeds the graph from the provider's units
  local ctx = { hasChildren = function () return true end }
  local fake = {}
  function fake.children (c)
    return {
      { entity = { id = 1 }, major = true,  cat = 'station', x = 5, y = 6, r = 10 },
      { entity = { id = 2 }, major = false, cat = 'ship',    x = 7, y = 8, r = 1 },
    }
  end
  function fake.links () return {} end
  function fake.drillable () return false end

  local g = NodeGraph.Create(ctx, { provider = fake })
  g.x, g.y = 0, 0   -- the real Widget initialises these in layout
  g.getRectGlobal = function () return 0, 0, 1000, 1000 end
  g:seedFromSystem()
  ok(g.nodes[1] and g.nodes[1].major == true, 'custom provider: major unit seeded')
  ok(g.nodes[2] and g.nodes[2].minor == nil and g.nodes[2].major == false,
     'custom provider: minor unit seeded')
  ok(g.nodes[1].x == 5 and g.nodes[1].y == 6, 'custom provider: world coords taken from unit')
  ok(g.nodes[1].drillable == false and g.nodes[2].drillable == false,
     'custom provider: drillable stamped from the provider (UI tell input)')

  -- and its drill policy is respected
  local okDrill = g:drillInto({ id = 3 }, false)
  ok(okDrill == false, 'custom provider: non-drillable target refused')
end

-- 5. Regression: declutter runs on EVERY level, not just the first ---------
do
  local function unit (id)
    return { entity = { id = id, deleted = false }, major = true, cat = 'station',
             x = 0, y = 0, r = 10 }
  end
  local root = { hasChildren = function () return true end }
  local child = { hasChildren = function () return true end }

  local fake = {}
  function fake.children (ctx)
    if ctx == child then return { unit(101), unit(102) } end
    return { unit(1), unit(2) }
  end
  function fake.links () return {} end
  function fake.drillable (e) return e == child end

  local g = NodeGraph.Create(root, { provider = fake })
  g.x, g.y = 0, 0
  g.getRectGlobal = function () return 0, 0, 1000, 1000 end
  g:seedFromSystem()
  ok(g.nodes[1] and g.nodes[1].jx ~= nil, 'level 1: declutter ran (majors have offsets)')

  -- drill and refit: before the fix, _ringDone stayed true so declutter was
  -- skipped here and the new nodes had jx == nil (stacked on top of each other)
  g:drillInto(child, false)
  g:seedFromSystem()
  ok(g.nodes[101] and g.nodes[101].jx ~= nil,
     'level 2 (post-drill): declutter runs again (offsets present)')
  ok(g.nodes[101].jx ~= g.nodes[102].jx,
     'level 2: two co-located majors get DIFFERENT offsets (no stacking)')
end

-- 6. Regression: named ROOT must not be mistaken for a zone ----------------
do
  local P = GraphProvider.system()
  local function member (id)
    return { id = id, deleted = false,
             getPos = function () return { x = id, y = 0, z = 0 } end,
             getScale = function () return 2 end }
  end
  local members = { member(11), member(12), member(13), member(14), member(15) }
  local zone = {
    id = 50, name = 'X Field', deleted = false, pos = { x = 0, y = 0, z = 0 },
    getPos = function (self) return self.pos end,
    getChildren = function () return members end,
    hasChildren = function () return true end,
  }
  -- The root also CONTAINS the members as loose children (Zone:add does not
  -- reparent, System:addChild does), which is exactly the leak case.
  local rootChildren = { zone, members[1], members[2], members[3], members[4], members[5] }
  local root = {
    id = 1, name = 'Sector Nine', deleted = false,
    hasChildren = function () return true end,
    iterChildren = function () return ipairs(rootChildren) end,
    getPos = function () return { x = 0, y = 0, z = 0 } end,
  }

  local function hasMember (units)
    for _, u in ipairs(units) do
      if u.entity and u.entity.id >= 11 and u.entity.id <= 15 then return true end
    end
    return false
  end

  ok(not hasMember(P.children(root, true)),
     'named ROOT (isRoot=true): zone members suppressed (no hairball)')
  ok(hasMember(P.children(root, false)),
     'named ZONE (isRoot=false): members revealed (Parnell region step)')

  ok(P.drillable(zone) == true,
     'provider.drillable: zone with positioned members is drillable')
  ok(P.drillable({ hasChildren = function () return false end }) == false,
     'provider.drillable: childless entity is not drillable')
end

-- 7. Regions (zones) are seeded as drillable major nodes -------------------
do
  local P = GraphProvider.system()
  local members = {}
  for i = 1, 6 do
    members[i] = { id = 200 + i, deleted = false,
      getPos = function () return { x = i * 50, y = 0, z = 0 } end,
      getScale = function () return 3 end }
  end
  local zone = {
    id = 200, name = 'Rine Field', deleted = false, pos = { x = 500, y = 0, z = 500 },
    getPos = function (self) return self.pos end,
    getChildren = function () return members end,
    hasChildren = function () return true end,
    iterChildren = function () return ipairs(members) end,  -- Entity provides this
  }
  local root = {
    id = 1, name = 'Sector', deleted = false,
    hasChildren = function () return true end,
    iterChildren = function () return ipairs({}) end,
    getZones = function () return { zone } end,
  }

  local units = P.children(root, true)
  local found = nil
  for _, u in ipairs(units) do if u.entity == zone then found = u end end
  ok(found ~= nil and found.major == true,
     'region: zone from getZones() seeded as a major at the root')
  ok(found and found.r and found.r >= 600 and found.r <= 4000,
     'region: unit carries a bounded radius (fit-safe)')
  ok(P.drillable(zone) == true, 'region: zone is drillable (reveals its members)')

  -- zone context: members are parented to the SYSTEM, yet must seed
  local zunits = P.children(zone, false)
  ok(#zunits == 6, 'region: drilling the zone reveals its members (parent is the system)')
end

-- 8. Ships are not map drill targets (that is the ship-systems view) ---------
do
  local P = GraphProvider.system()
  local child = { getPos = function () return { x = 0, y = 0, z = 0 } end }
  local ship = { hasActions = function () return true end,
                 hasChildren = function () return true end,
                 getChildren = function () return { child } end }
  ok(P.drillable(ship) == false, 'provider.drillable: ships are not map drill targets')
  ok(P.noDrillReason(ship) == nil, 'provider.noDrillReason: ships do not flash')
  local emptyStation = { hasChildren = function () return true end,
                         getChildren = function () return {} end }
  ok(P.noDrillReason(emptyStation) == 'empty',
     'provider.noDrillReason: empty child set -> flash "nothing to explore"')
end

-- 9. Regression: a far outlier must not collapse the level fit --------------
-- A chained-clump ore rock can sit ~1M out while its field spans ~5k. Before
-- the robust trim the fit included it, so the field rendered as a ~3px pile
-- (the zone drill "didn't display properly").
do
  local root = { hasChildren = function () return true end }
  local fake = {}
  function fake.children ()
    local out = {}
    for i = 1, 40 do
      out[i] = { entity = { id = i, deleted = false }, major = false, cat = 'rock',
                 x = (i % 8) * 400, y = math.floor(i / 8) * 400, r = 3 }
    end
    out[41] = { entity = { id = 999, deleted = false }, major = false, cat = 'rock',
                x = 1000000, y = 0, r = 3 }
    return out
  end
  function fake.links () return {} end
  function fake.drillable () return false end

  local g = NodeGraph.Create(root, { provider = fake })
  g.x, g.y = 0, 0
  g.getRectGlobal = function () return 0, 0, 1000, 1000 end
  g:seedFromSystem()
  ok(g.nodes[999] ~= nil, 'robust fit: the far outlier is still seeded (draws as an indicator)')
  ok(g.zoom > 0.1,
     'robust fit: far outlier does not collapse the level zoom (cluster stays readable)')
  ok(g._refC and math.abs(g._refC.x) < 5000,
     'robust fit: level centre sits on the cluster, not the outlier')
  local ox, oy = g:toScreenNode(g.nodes[999])
  ok(ox < 0 or oy < 0 or ox > 1000 or oy > 1000,
     'robust fit: the far outlier projects off-screen (edge-indicator territory)')
end

-- 10. Regression: click-centre must use MAP space, not raw world coords -----
-- `self.pos` lives in compressed map space; the press-edge used to snap it to
-- raw n.x/n.y, so clicking a node no longer pulled it to the middle.
do
  local root = { hasChildren = function () return true end }
  local fake = {}
  function fake.children ()
    local out = {}
    for i = 1, 20 do
      out[i] = { entity = { id = i, deleted = false }, major = false, cat = 'rock',
                 x = i * 300, y = 0, r = 4 }
    end
    out[21] = { entity = { id = 500, deleted = false }, major = false, cat = 'rock',
                x = 200000, y = 0, r = 4 }
    return out
  end
  function fake.links () return {} end
  function fake.drillable () return false end

  local g = NodeGraph.Create(root, { provider = fake })
  g.x, g.y = 0, 0
  g.getRectGlobal = function () return 0, 0, 1000, 1000 end
  g:seedFromSystem()
  ok(g:_compressT() < 1, 'click-centre: compression is active at this fit (non-identity)')

  -- Drive the real press-edge path with the cursor exactly on the node.
  local far = g.nodes[20]
  local nx, ny = g:toScreenNode(far)
  _G.__input.mouse = { x = nx, y = ny }
  _G.__input.down = true
  g:onInput({ dt = 0.016 })
  _G.__input.down = false
  ok(g.focus == far.id, 'click-centre: the press-edge selected the node under the cursor')
  ok(far.x == 6000 and far.y == 0,
     'click-centre: a plain click does NOT move the node (drag needs cursor motion)')
  local sx, sy = g:toScreenNode(far)
  ok(math.abs(sx - 500) < 1 and math.abs(sy - 500) < 1,
     'click-centre: the clicked node lands at the viewport centre')

  -- The real failure: the click sets a zoom target, and EASING the zoom must
  -- not slide the node out of frame (the camera is world-space, not stored in
  -- the zoom-dependent compressed frame).
  local zsave, tsave = g.zoom, g.targetZoom
  g.zoom = g.targetZoom or g.zoom
  local ezx, ezy = g:toScreenNode(g.nodes[20])
  ok(math.abs(ezx - 500) < 1 and math.abs(ezy - 500) < 1,
     'click-centre: the node stays centred as the click-zoom eases')
  g.zoom, g.targetZoom = zsave, tsave

  -- ...but a genuine drag (press + cursor motion) still relocates the node.
  _G.__input.down = false
  g:onInput({ dt = 0.016 })          -- release frame clears the press state
  g._lastClick = nil                 -- avoid the stub clock's double-click
  local cx2, cy2 = g:toScreenNode(far)
  _G.__input.mouse = { x = cx2, y = cy2 }
  _G.__input.down = true
  g:onInput({ dt = 0.016 })
  _G.__input.mouse = { x = cx2 + 60, y = cy2 }
  g:onInput({ dt = 0.016 })          -- move past the threshold -> drag
  _G.__input.down = false
  g:onInput({ dt = 0.016 })
  ok(far.x ~= 6000, 'drag still works: cursor motion relocates the node')
  ok(g.follow == nil and g.targetZoom == nil,
     'drag: cursor motion pins the view (follow cleared)')
end

-- 11. Representation glyphs: an asteroid field gets a rock cluster, not a box.
do
  local U = require('UI.NodeGraphUtil')
  local function member (i, ship)
    return { id = i, deleted = false,
             getPos = function () return { x = i, y = 0, z = 0 } end,
             hasActions = function () return ship or false end }
  end
  local function zone (n, ship)
    local ch = {}
    for i = 1, n do ch[i] = member(i, ship) end
    return { id = 900, name = 'Rine Field', deleted = false,
             getPos = function () return { x = 0, y = 0, z = 0 } end,
             getChildren = function () return ch end }
  end

  local kind, cnt = U.repKind(zone(6, false))
  ok(kind == 'field' and cnt == 6,
     'repKind: an asteroid field is a field representation (member count)')
  ok(U.repKind(zone(4, false)) == nil, 'repKind: <5 members is not a representation')
  ok(U.repKind(zone(6, true)) == nil, 'repKind: a group of ships is not a field')

  local lines = U.fieldSchematic(7, 6)
  ok(type(lines) == 'table' and #lines > 0 and #lines % 4 == 0,
     'fieldSchematic: returns a flat segment list')
  local again = U.fieldSchematic(7, 6)
  ok(#again == #lines and again[1] == lines[1] and again[#again] == lines[#lines],
     'fieldSchematic: deterministic for a given seed')
  ok(U.fieldSchematic(8, 6)[1] ~= lines[1],
     'fieldSchematic: different seeds give different fields')
  local minx, maxx = 1e9, -1e9
  for i = 1, #lines, 2 do
    if lines[i] < minx then minx = lines[i] end
    if lines[i] > maxx then maxx = lines[i] end
  end
  ok(maxx - minx > 0.5, 'fieldSchematic: rocks scatter across the view (not one blob)')
end

-- 12. Range readings relative to the player -------------------------------
do
  local U = require('UI.NodeGraphUtil')
  local function body (x, y, z)
    return { getPos = function () return { x = x, y = y, z = z } end }
  end
  local d3, plane, dy = U.rangeBetween(body(3, 4, 0), body(0, 0, 0))
  ok(math.abs(plane - 3) < 1e-9 and math.abs(d3 - 5) < 1e-9 and math.abs(dy - 4) < 1e-9,
     'rangeBetween: plane (map), 3D range and vertical components')
  local d0 = U.rangeBetween(body(1, 1, 1), body(1, 1, 1))
  ok(d0 == 0, 'rangeBetween: zero for coincident bodies (the player itself)')
  ok(U.rangeBetween({}, body(0, 0, 0)) == nil, 'rangeBetween: nil when a body has no pos')
end

print(string.format('\n[NodeGraph] %d checks, %d failure(s)', checks, failures))
os.exit(failures == 0 and 0 or 1)
