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
_G.Input = { GetMousePosition = function () return { x = 0, y = 0 } end, GetDown = function () return false end }
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
g2.zoom, g2.pos = 12.5, Vec2f(7, -3)
local target = drillable()
local pushed = g2:drillInto(target, false)
ok(pushed ~= nil and g2.context == target, 'drillInto switches the seeding context')
ok(g2.stack[#g2.stack].context == root, 'drillInto pushed the previous context')
ok(g2.stack[#g2.stack].camera.zoom == 12.5, 'drillInto saved the prior zoom')

-- mutate the new level, then back out and confirm exact restore
g2.zoom, g2.pos = 999, Vec2f(50, 60)
ok(g2:drillOut() == true, 'drillOut returns true with a level on the stack')
ok(g2.context == root, 'drillOut restores the previous context')
ok(g2.zoom == 12.5 and g2.pos.x == 7 and g2.pos.y == -3, 'drillOut restores the exact camera')
ok(g2.context.hasChildren() == true, 'root is drillable again after pop')

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

  -- and its drill policy is respected
  local okDrill = g:drillInto({ id = 3 }, false)
  ok(okDrill == false, 'custom provider: non-drillable target refused')
end

print(string.format('\n[NodeGraph] %d checks, %d failure(s)', checks, failures))
os.exit(failures == 0 and 0 or 1)
