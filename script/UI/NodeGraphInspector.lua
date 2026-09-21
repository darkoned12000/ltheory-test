-- NodeGraphInspector -- Phase 5 vector detail panel for NodeGraph.
-- Companion widget drawn inside NodeGraph's onDraw (screen pixel space, after
-- the post chain): a holographic wireframe of the selected entity's actual
-- mesh + a real-data identity/stat block. No mesh -> stylized box fallback, so
-- ANY entity gets a schematic even before universe gen fills them in.

local DrawEx = require('UI.DrawEx')
local Util = require('UI.NodeGraphUtil')
local ffi = require('ffi')   -- global in-engine, but never rely on that

local NodeGraphInspector = {}
NodeGraphInspector.__index = NodeGraphInspector

-- Base metrics at a 900px-tall window; the panel scales with resolution like
-- the debug panel does (LTheory scales Config.ui.font by window height), so
-- it stays readable on 4K.
local PANEL_W, PANEL_H = 312, 300          -- base panel size (900px reference)
local WIRE_W, WIRE_H   = 150, 120          -- base vector-view size
local BAR_W            = 150               -- base HP bar width
local REF_H            = 900

local function resScale (sy)
  local sc = (sy or REF_H) / REF_H
  if sc < 1.0 then sc = 1.0 end
  if sc > 2.4 then sc = 2.4 end
  return sc
end
local WIRE    = { r = 0.35, g = 0.65, b = 1.0, a = 0.9 }
local OK      = { r = 0.45, g = 0.95, b = 0.65, a = 0.95 }
local CRIT    = { r = 1.00, g = 0.35, b = 0.30, a = 0.95 }
local TEXT    = { r = 1.00, g = 1.00, b = 1.00, a = 0.85 }
local HEAD    = { r = 0.40, g = 0.85, b = 1.00, a = 1.00 }
local kFont   = 'Share'
local kTSize  = 15
local kSSize  = 13

-- Pull whatever geometry the entity heads with (asteroids/ships/stations/
-- planets all store a Gen mesh on `self.mesh` via VisibleMesh/LodMesh).
local function entityMesh (e)
  local mesh = e and e.mesh
  if not mesh then return nil end
  -- Asteroid fields store a LodMesh (per-LOD Mesh wrappers) whose getCenter
  -- has no meaning; resolve LOD 0 to the real Mesh. `:get` only exists on
  -- LodMesh, and indexing it on a plain `struct Mesh` errors at cdata level,
  -- so the probe MUST be pcall-guarded (a bare `mesh.get` aborts).
  for _ = 1, 4 do
    local okGet, res = pcall(function () return mesh:get(0) end)
    if not (okGet and res) then break end
    mesh = res
  end
  local ok = pcall(function () return mesh:getCenter() end)
  if not ok then return nil end
  return mesh
end

-- Build a unitized copy of an entity mesh: real meshes live at world scale
-- (a planet is a 1e5-unit sphere 200k units out) so drawing them directly
-- under the inspector's small camera frames a mesh that escapes the viewport
-- box ("the image enters and leaves the box"). A normalized copy keeps the
-- vector view self-contained: max radius maps to 1, camera at fixed range.
local function unitizedMeshCopy (mesh)
  local okV, cnt = pcall(function () return mesh:getVertexCount() end)
  if not (okV and cnt and cnt > 0) then return nil end
  local data = mesh:getVertexData()
  if not data then return nil end
  -- C++ Vertex is Vec3f p, Vec3f n, Vec2f uv = 8 floats, 32 bytes flat (no
  -- tail padding); the cdef mirrors exactly that layout.
  local f32 = ffi.cast('float*', data)
  local rmax = 0
  for i = 0, cnt - 1 do
    local o = i * 8
    local r = math.sqrt(f32[o] * f32[o] + f32[o + 1] * f32[o + 1] + f32[o + 2] * f32[o + 2])
    if r > rmax then rmax = r end
  end
  if rmax < 1e-6 then return nil end
  local out = ffi.gc(Mesh.Create(), Mesh.Free)
  for i = 0, cnt - 1 do
    local o = i * 8
    local v = ffi.new('struct Vertex')
    v.px, v.py, v.pz = f32[o] / rmax, f32[o + 1] / rmax, f32[o + 2] / rmax
    v.nx, v.ny, v.nz = f32[o + 3], f32[o + 4], f32[o + 5]
    v.uvx, v.uvy   = f32[o + 6], f32[o + 7]
    out:addVertexRaw(v)
  end
  local okI, icnt = pcall(function () return mesh:getIndexCount() end)
  if okI and icnt and icnt > 0 then
    local idx = mesh:getIndexData()
    if idx then
      local i32 = ffi.cast('int32_t*', idx)
      for i = 0, icnt - 1 do out:addIndex(i32[i]) end
    end
  end
  return out
end

-- Stylized wireframe box (all axes) around a scaled center position.
local function boxWire (sx, sy, sz)
  local hx, hy, hz = sx * 0.5, sy * 0.5, sz * 0.5
  local c = {
    { -hx, -hy, -hz }, {  hx, -hy, -hz }, {  hx,  hy, -hz }, { -hx,  hy, -hz },
    { -hx, -hy,  hz }, {  hx, -hy,  hz }, {  hx,  hy,  hz }, { -hx,  hy,  hz },
  }
  local e = {
    { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 },
    { 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 },
    { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 },
  }
  return c, e
end

function NodeGraphInspector.Create (owner)
  local self = setmetatable({}, NodeGraphInspector)
  self.owner = owner
  self.active = false
  self.node = nil
  -- Cached vector projection: the wireframe is STATIC (no animation), so it
  -- is built once per selected node instead of re-copying the mesh and
  -- re-projecting ~1400 triangles every frame (was 14k+21k FFI calls/frame).
  self._linesNode = nil
  self._lines = nil
  self._linesResolved = false
  return self
end

-- Projected (yaw/pitch, ortho) normalized edge list for a node's mesh, cached
-- per node. Returns a flat array {x1,y1,x2,y2, ...} in roughly [-1,1] units,
-- or nil (fallback to the schematic box). The draw maps it to box pixels.
function NodeGraphInspector:_linesForNode (node)
  if self._linesResolved and self._linesNode == node then return self._lines end
  self._linesNode = node
  self._linesResolved = true
  self._lines = nil
  local mesh = entityMesh(node and node.entity)
  if not mesh then
    -- Representation node (an asteroid field / region): no mesh of its own, so
    -- draw the aggregate glyph instead of the generic box fallback.
    if self._repKind == 'field' then
      local seed = (node.entity and node.entity.id) or node.id or 1
      self._lines = Util.fieldSchematic(seed, self._repCount)
      return self._lines
    end
    return nil
  end
  local snap = unitizedMeshCopy(mesh)
  if not snap then return nil end
  local okI, icnt = pcall(function () return snap:getIndexCount() end)
  local okV, vcnt = pcall(function () return snap:getVertexCount() end)
  local vd = okV and vcnt and vcnt > 0 and snap:getVertexData() or nil
  if not (okI and icnt and icnt > 0 and vd) then return nil end
  local idx = snap:getIndexData()
  if not idx then return nil end
  local i32 = ffi.cast('int32_t*', idx)
  local verts = ffi.cast('struct Vertex*', vd)
  local step = 6
  local ntri = math.floor(icnt / 3)
  if ntri / step > 1400 then step = math.ceil(ntri / 1400) end
  local yaw, pitch = 0.7, 0.4
  local cyR, syR = math.cos(yaw), math.sin(yaw)
  local cp, sp = math.cos(pitch), math.sin(pitch)
  local lines, n = {}, 0
  local function pj (v)
    local rx = v.px * cyR + v.pz * syR
    local rz = -v.px * syR + v.pz * cyR
    return rx, v.py * cp - rz * sp
  end
  local ti = 0
  while ti * 3 + 2 < icnt do
    local i0 = ti * 3
    local ia, ib, ic = i32[i0], i32[i0 + 1], i32[i0 + 2]
    local ax, ay = pj(verts[ia])
    local bx, by = pj(verts[ib])
    local cx2, cy2 = pj(verts[ic])
    n = n + 1; lines[n*4 - 3], lines[n*4 - 2], lines[n*4 - 1], lines[n*4] = ax, ay, bx, by
    n = n + 1; lines[n*4 - 3], lines[n*4 - 2], lines[n*4 - 1], lines[n*4] = bx, by, cx2, cy2
    n = n + 1; lines[n*4 - 3], lines[n*4 - 2], lines[n*4 - 1], lines[n*4] = cx2, cy2, ax, ay
    ti = ti + step
  end
  self._lines = lines
  return lines
end

function NodeGraphInspector:show (node)
  self.active = true
  self.node = node
  if self._linesNode ~= node then
    self._linesResolved = false
    -- Classify representations once per selection (drives both the glyph and
    -- the stat block): 'field' + member count for an aggregate, else nil.
    self._repKind, self._repCount = Util.repKind(node and node.entity)
  end
end

-- Live range + bearing to the player for the selected node (recomputed every
-- frame: both the player and the target move). nil for the player's own node
-- or when either body lacks a position.
function NodeGraphInspector:_playerRange ()
  local owner = self.owner
  return Util.navTo(self.node and self.node.entity, owner and owner.focusEntity)
end

function NodeGraphInspector:hide ()
  self.active = false
  self.node = nil
  self._linesNode = nil
  self._linesResolved = false
  self._lines = nil
  self._repKind, self._repCount = nil, nil
end

-- Screen-space (px) draw. x,y = canvas origin; sx,sy = canvas size. The panel
-- sits top-right inside the canvas.
function NodeGraphInspector:draw (x, y, sx, sy, now)
  if not self.active or not self.node then return end
  local sc = resScale(sy)
  local panelW, panelH = math.floor(PANEL_W * sc), math.floor(PANEL_H * sc)
  local tSize = math.max(kTSize, math.floor(kTSize * sc + 0.5))
  local sSize = math.max(kSSize, math.floor(kSSize * sc + 0.5))
  local lineH = math.floor(17 * sc)
  local px = math.max(x + 8, x + sx - panelW - 12)
  local py = math.min(math.max(y + 12, y + 8), y + math.max(0, sy - panelH - 8))
  local e = self.node.entity

  -- Panel backdrop (fills top-right; text/wire draw over it)
  Draw.Color(0.02, 0.03, 0.06, 0.60)
  Draw.Rect(px, py, panelW, panelH)
  DrawEx.RectOutline(px, py, panelW, panelH, { r = 0.25, g = 0.6, b = 1.0, a = 0.8 })

  local title = self.node.label or Util.kindTag(e, 'short')
  DrawEx.TextAlpha(kFont, title, tSize, px + 10, py + 6, panelW - 20, 22 * sc,
    HEAD.r, HEAD.g, HEAD.b, HEAD.a, 0.0, 0.0)

  -- Identity block (top, full width; short numbers so it cannot reach across)
  local lx = px + 10
  local ly = py + math.floor(30 * sc)
  local colW = panelW - 20
  local function line (text, col)
    DrawEx.TextAlpha(kFont, text, sSize, lx, ly, colW, lineH, col.r, col.g, col.b, col.a, 0.0, 0.0)
    ly = ly + lineH
  end

  local okP, p = pcall(function () return e and e.getPos and e:getPos() or nil end)
  if okP and p then
    line('pos ' .. Util.fmtShort(p.x) .. ' ' .. Util.fmtShort(p.y) .. ' ' .. Util.fmtShort(p.z), TEXT)
  else
    line('pos --', TEXT)
  end
  -- NOTE: do NOT name this `sc` — that is the resolution scale above, and
  -- shadowing it turns every later size into the entity's WORLD scale
  -- (station 100 -> whole-box HP bar; planet 1e5 -> off-screen image).
  local okS, scaleVal = pcall(function () return e and e.getScale and e:getScale() or nil end)
  if okS and scaleVal then line('scale ' .. Util.fmtShort(scaleVal), TEXT) end
  line(Util.kindTag(e), HEAD)
  -- Representation nodes have no scale; the meaningful number is what they
  -- stand for (an asteroid field's member count).
  if self._repKind == 'field' and self._repCount then
    line(string.format('%d asteroids', self._repCount), HEAD)
  end
  -- Range + relative bearing from 'YOU' (the absolute `pos` line above is not
  -- a usable navigation number). Live: the player and the target both move.
  local r = self:_playerRange()
  if r then
    local txt = 'dist ' .. Util.fmtShort(r.plane) .. ' u from you'
    if math.abs(r.d3 - r.plane) > 0.05 * math.max(1, r.d3) then
      txt = 'dist ' .. Util.fmtShort(r.plane) .. ' u (map)   rng ' ..
            Util.fmtShort(r.d3) .. ' u'
    end
    line(txt, TEXT)
    if r.bearing then
      line(string.format('brg %03d deg  %s', math.floor(r.bearing + 0.5),
        Util.bearingLabel(r.bearing)), TEXT)
    end
  end

  -- Health bar: narrowed (was full-width and overlapped the vector view),
  -- kept above the image on its own row.
  if e and e.health and e.healthMax then
    local ratio = math.max(0, math.min(1, e.health / e.healthMax))
    local cbar = ratio > 0.5 and OK or (ratio > 0.25 and { r = 1, g = 0.8, b = 0.2, a = 1 } or CRIT)
    local barW = math.floor(BAR_W * sc)
    local barH = math.max(8, math.floor(8 * sc))
    Draw.Color(0.10, 0.10, 0.12, 0.85)
    Draw.Rect(lx, ly + 3, barW, barH)
    Draw.Color(cbar.r, cbar.g, cbar.b, 0.95)
    Draw.Rect(lx, ly + 3, barW * ratio, barH)
    DrawEx.TextAlpha(kFont, string.format('%d / %d', math.floor(e.health + 0.5), math.floor(e.healthMax + 0.5)),
      sSize, lx + barW + 8, ly, colW - barW - 8, 16 * sc, cbar.r, cbar.g, cbar.b, cbar.a, 0.0, 0.0)
    ly = ly + math.floor(22 * sc)
  end

  -- Vector view: BELOW the identity/HP block (was beside it and collided).
  local wireW, wireH = math.floor(WIRE_W * sc), math.floor(WIRE_H * sc)
  local wx = px + (panelW - wireW) * 0.5
  local wy = ly + math.floor(8 * sc)
  local lines = self:_linesForNode(self.node)
  if lines then
    -- Deterministic wireframe: cached normalized edges (see _linesForNode),
    -- mapped to box pixels here. Static projection => no per-frame mesh copy.
    local cxs, cys = wx + wireW * 0.5, wy + wireH * 0.5
    local scale = math.min(wireW, wireH) * 0.34
    Draw.Color(WIRE.r, WIRE.g, WIRE.b, 0.8)
    for i = 1, #lines, 4 do
      Draw.Line(cxs + lines[i] * scale,     cys - lines[i + 1] * scale,
                cxs + lines[i + 2] * scale, cys - lines[i + 3] * scale)
    end
    Draw.Color(1, 1, 1, 1)
  else
    local c, ed = boxWire(1.4, 1.4, 1.4)
    local cxs, cys = wx + wireW * 0.5, wy + wireH * 0.5
    Draw.Color(WIRE.r, WIRE.g, WIRE.b, WIRE.a)
    for _, edg in ipairs(ed) do
      local a, b = c[edg[1]], c[edg[2]]
      Draw.Line(cxs + a[1] * 30 - a[3] * 6, cys - a[2] * 30,
                cxs + b[1] * 30 - b[3] * 6, cys - b[2] * 30)
    end
    Draw.Color(1, 1, 1, 1)
  end

  -- Caption under the image: the node's own label/kind (never the raw
  -- `Entity @ 0x...` pointer fallback).
  DrawEx.TextAlpha(kFont, self.node.label or Util.kindTag(e, 'short'), sSize,
    wx, wy + wireH + 6, wireW, 16 * sc,
    TEXT.r, TEXT.g, TEXT.b, TEXT.a, 0.5, 0.0)

  -- Dismiss hint
  DrawEx.TextAlpha(kFont, '[click empty space to close]', sSize, px + 8, py + panelH - math.floor(20 * sc),
    panelW - 16, 14 * sc, 1, 1, 1, 0.55, 1.0, 0.0)
end

return NodeGraphInspector