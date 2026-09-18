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
local cSelected  = { r = 0.40, g = 0.85, b = 1.00, a = 1.00 }
local cEdge      = { r = 0.30, g = 0.55, b = 0.90, a = 0.50 }
local cTrade     = { r = 0.45, g = 0.75, b = 1.00, a = 0.95 }
local cLabel     = { r = 1.00, g = 1.00, b = 1.00, a = 0.90 }
local cReticle   = { r = 1.00, g = 1.00, b = 1.00, a = 0.90 }

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

function NodeGraph:addEdge (a, b, kind)
  self.edges[#self.edges + 1] = { a = a, b = b, kind = kind or 'solid' }
end

function NodeGraph:clearEdges ()
  self.edges = {}
end

-- Canvas space -> screen pixels (SystemMap math: centered, zoomed).
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

function NodeGraph:nodeAt (mx, my)
  local best, bestDist = nil, math.huge
  for id, n in pairs(self.nodes) do
    local sx, sy = self:toScreen(n.x, n.y)
    local dx, dy = sx - mx, sy - my
    local d = math.sqrt(dx * dx + dy * dy)
    local hit = math.max(12, n.r * self.zoom)
    if d <= hit and d < bestDist then
      best, bestDist = n, d
    end
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
  for i = 1, #self.edges do
    local e = self.edges[i]
    local a, b = self.nodes[e.a], self.nodes[e.b]
    if a and b then
      local ax, ay = self:toScreen(a.x, a.y)
      local bx, by = self:toScreen(b.x, b.y)
      if e.kind == 'trade' then
        -- Flowing dots toward B (dst): trade routes read as movement, not paint.
        DrawEx.Dash(ax, ay, bx, by, cTrade, 2, 9, Engine.GetTime() * 0.35)
      else
        DrawEx.Line(ax, ay, bx, by, cEdge)
      end
    end
  end

  for id, n in pairs(self.nodes) do
    local nx, ny = self:toScreen(n.x, n.y)
    local r = math.max(2, n.r * self.zoom)
    local selected = self.focus == id
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
  Draw.Color(1, 1, 1, 1)
end

function NodeGraph:onInput (state)
  self.zoom = self.zoom * math.exp(kZoomSpeed * Input.GetMouseScroll().y)
  -- Arrows only (no WASD): as an in-game overlay the ship owns WASD, and
  -- panning the map must never fly the ship. Standalone SystemMap keeps WASD
  -- because nothing else is listening there.
  local dt = math.max(1e-6, state.dt)
  local pan = kPanSpeed * dt / self.zoom
  self.pos.x = self.pos.x + pan * (
    Input.GetValue(Button.Keyboard.Right) - Input.GetValue(Button.Keyboard.Left))
  self.pos.y = self.pos.y + pan * (
    Input.GetValue(Button.Keyboard.Down) - Input.GetValue(Button.Keyboard.Up))

  local mp = Input.GetMousePosition()
  local down = Input.GetDown(Button.Mouse.Left)
  if down and not self._wasDown then
    -- Press edge: hit-test once; node => drag+select, empty => pan.
    self._drag = self:nodeAt(mp.x, mp.y)
    if self._drag then self.focus = self._drag.id end
    self._panAt = { x = mp.x, y = mp.y }
  end
  if down then
    if self._drag then
      self._drag.x, self._drag.y = self:toCanvas(mp.x, mp.y)
    elseif self._panAt then
      self.pos.x = self.pos.x - (mp.x - self._panAt.x) / self.zoom
      self.pos.y = self.pos.y - (mp.y - self._panAt.y) / self.zoom
      self._panAt = { x = mp.x, y = mp.y }
    end
  else
    self._drag, self._panAt = nil, nil
  end
  self._wasDown = down
end

function NodeGraph.Create ()
  local self = setmetatable(Window('Node Graph', false), NodeGraph)
  self:setStretch(1, 1)
  self:setPadUniform(0)
  self.nodes = {}
  self.edges = {}
  self.focus = nil
  self.pos = Vec2f(0, 0)
  self.zoom = 1.0
  return self
end

return NodeGraph
