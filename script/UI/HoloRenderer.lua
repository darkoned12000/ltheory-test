local DrawEx = require('UI.DrawEx')
local HoloLayout = require('UI.HoloLayout')

local Renderer = {}

local WidgetShader_Ring = 3
local BlendMode_Additive = 0

local CYAN = { r = 0.22, g = 0.68, b = 1.00, a = 0.95 }
local HUB = { r = 0.55, g = 0.85, b = 1.00, a = 1.00 }
local PARENT = { r = 0.35, g = 0.55, b = 0.80, a = 0.65 }
local CRIMSON = { r = 1.00, g = 0.18, b = 0.32, a = 1.00 }
local PREVIEW = { r = 0.30, g = 0.72, b = 1.00, a = 0.42 }
local EDGE = { r = 0.18, g = 0.52, b = 0.88, a = 0.62 }
local FIELD = { r = 0.20, g = 0.55, b = 1.00, a = 0.55 }
local FIELD_CLUSTER = { r = 0.28, g = 0.68, b = 1.00, a = 0.70 }
local GRID = { r = 0.12, g = 0.30, b = 0.55, a = 0.16 }
local STAR = { r = 0.55, g = 0.75, b = 1.00, a = 1.00 }
local TOOLTIP_BORDER = { r = 1.00, g = 0.25, b = 0.35, a = 0.85 }
local EDIT_BORDER = { r = 0.30, g = 0.75, b = 1.00, a = 0.95 }
local MAX_ACTIVE_BEAMS = 8

local function fontSize (size, scale)
  return math.max(8, math.floor(size * (scale or 1) + 0.5))
end

local function ring (x, y, r, color, pad)
  if not x or not y or not r then return end
  pad = pad or 6
  local sx = math.max(2.0, r * 2 + pad * 2)
  local sy = sx
  local a = color.a * DrawEx.GetAlpha()
  Draw.WidgetRect(
    WidgetShader_Ring, BlendMode_Additive,
    x - sx * 0.5, y - sy * 0.5, sx, sy,
    color.r, color.g, color.b, a,
    r, sx, sy, 0,
    0, 0, 0, 0)
end

local function clipSegment (ax, ay, bx, by, minX, minY, maxX, maxY)
  local dx, dy = bx - ax, by - ay
  local t0, t1 = 0.0, 1.0
  local function edge (p, q)
    if math.abs(p) < 1e-9 then return q >= 0 end
    local r = q / p
    if p < 0 then
      if r > t1 then return false end
      if r > t0 then t0 = r end
    else
      if r < t0 then return false end
      if r < t1 then t1 = r end
    end
    return true
  end
  if not edge(-dx, ax - minX) then return nil end
  if not edge( dx, maxX - ax) then return nil end
  if not edge(-dy, ay - minY) then return nil end
  if not edge( dy, maxY - ay) then return nil end
  return ax + dx * t0, ay + dy * t0, ax + dx * t1, ay + dy * t1
end

local function activeNode (shader, time, x, y, r, color, state, drillable)
  if not x or not y then return end
  if not shader then ring(x, y, r, state > 0.5 and CRIMSON or color); return end
  local pad = r * 2.4 + 12
  BlendMode.PushAdditive()
  shader:start()
    Shader.SetInt('mode', 0)
    Shader.SetFloat('time', time)
    Shader.SetFloat('state', state)
    Shader.SetFloat('drillable', drillable and 1 or 0)
    Shader.SetFloat('radius', r)
    Shader.SetFloat4('colPrimary', color.r, color.g, color.b,
      color.a * DrawEx.GetAlpha())
    Shader.SetFloat4('colAccent', CRIMSON.r, CRIMSON.g, CRIMSON.b, CRIMSON.a)
    Shader.SetFloat2('quadSize', pad * 2, pad * 2)
    Shader.SetFloat('thickness', math.max(1.3, r * 0.11))
    Draw.Rect(x - pad, y - pad, pad * 2, pad * 2)
  shader:stop()
  BlendMode.Pop()
end

local function activeBeam (shader, time, ax, ay, bx, by, color, state, thick)
  if not shader or not ax or not bx then return false end
  local pad = 18
  local x0, y0 = math.min(ax, bx) - pad, math.min(ay, by) - pad
  local w = math.max(1, math.max(ax, bx) + pad - x0)
  local h = math.max(1, math.max(ay, by) + pad - y0)
  BlendMode.PushAdditive()
  shader:start()
    Shader.SetInt('mode', 1)
    Shader.SetFloat('time', time)
    Shader.SetFloat('state', state)
    Shader.SetFloat4('colPrimary', color.r, color.g, color.b,
      color.a * DrawEx.GetAlpha())
    Shader.SetFloat4('colAccent', CRIMSON.r, CRIMSON.g, CRIMSON.b, CRIMSON.a)
    Shader.SetFloat2('quadSize', w, h)
    Shader.SetFloat2('segA', ax - x0, ay - y0)
    Shader.SetFloat2('segB', bx - x0, by - y0)
    Shader.SetFloat('thickness', thick or 1.4)
    Draw.Rect(x0, y0, w, h)
  shader:stop()
  BlendMode.Pop()
  return true
end

local function visible (vis, vx, vy, vsx, vsy, margin)
  return vis and vis._sx and vis._sy
    and vis._sx >= vx - margin and vis._sx <= vx + vsx + margin
    and vis._sy >= vy - margin and vis._sy <= vy + vsy + margin
end

local function label (vis, hot, zoom, fontScale)
  if not vis or not vis._sx then return end
  local data = vis.data or {}
  local alpha = math.max(0, math.min(1, (zoom - 0.35) * 2.2))
  if hot then alpha = 1 end
  if alpha <= 0.05 then return end
  local text = data.getLabel and data:getLabel() or data.label or vis.id
  local r = vis._sr or 12
  local cr, cg, cb = 0.85, 0.94, 1.0
  if hot then cr, cg, cb = 1.0, 0.55, 0.62 end
  DrawEx.TextAlpha('Share', text, fontSize(14, fontScale), vis._sx - 110, vis._sy + r + 5, 220, 18,
    cr, cg, cb, alpha * 0.95, 0.5, 0)
  if data.sublabel or data.getValue then
    local sub = data.getValue and tostring(data:getValue()) or data.sublabel
    DrawEx.TextAlpha('Share', sub, fontSize(12, fontScale), vis._sx - 110, vis._sy + r + 21, 220, 16,
      0.55, 0.85, 1.0, alpha * 0.75, 0.5, 0)
  end
end

function Renderer.Create (opts)
  opts = opts or {}
  return setmetatable({
    shader = Cache.Shader('ui', 'ui/holonode'),
    showGrid = opts.showGrid ~= false,
    showStars = opts.showStars ~= false,
    fontScale = opts.fontScale or 1,
    previewOrbitSpeed = opts.previewOrbitSpeed or (math.pi * 2 / 45),
  }, { __index = Renderer })
end

function Renderer:draw (graph, focus, active)
  local vx, vy, vsx, vsy = graph:getRectGlobal()
  local time = Engine.GetTime()
  local fontScale = self.fontScale or 1
  ClipRect.PushCombined(vx, vy, vsx, vsy)

  DrawEx.Panel(vx, vy, vsx, vsy, { r = 0.01, g = 0.02, b = 0.05, a = 0.72 }, 0.72)

  if self.showStars then
    for i = 1, 72 do
      local a = i * 2.399963229728653
      local radius = 40 + (i * 97) % math.max(1, math.floor(math.min(vsx, vsy) * 0.48))
      local x = vx + vsx * 0.5 + math.cos(a) * radius
      local y = vy + vsy * 0.5 + math.sin(a) * radius * 0.72
      local alpha = 0.10 + (i % 5) * 0.025
      STAR.a = alpha
      ring(x, y, 0.7 + (i % 3) * 0.25, STAR, 2)
    end
  end

  if self.showGrid then
    for _, gridRadius in ipairs({ 160, 320, 480 }) do
      local px, py
      for s = 0, 48 do
        local a = s / 48 * math.pi * 2
        local gx, gy = HoloLayout.project(graph.cam, math.cos(a) * gridRadius,
          math.sin(a) * gridRadius, 0, vx, vy, vsx, vsy)
        if gx and px then
          local cx1, cy1, cx2, cy2 = clipSegment(px, py, gx, gy,
            vx, vy, vx + vsx, vy + vsy)
          if cx1 then DrawEx.Line(cx1, cy1, cx2, cy2, GRID) end
        end
        px, py = gx, gy
      end
    end
  end

  if graph.fieldState then
    FIELD.a = graph.fieldState.pointAlpha or 1
    FIELD_CLUSTER.a = graph.fieldState.clusterAlpha or 1
    local clusterLabels = 0
    for i = 1, #graph.fieldState.clusters do
      local cluster = graph.fieldState.clusters[i]
      if visible(cluster, vx, vy, vsx, vsy, 40) then
        ring(cluster._sx, cluster._sy, cluster._sr or 8, FIELD_CLUSTER, 3)
        if clusterLabels < 32 then
          local text = cluster.data and cluster.data.sublabel
            or string.format('%d objects', cluster.count or 0)
          DrawEx.TextAlpha('Share', text, fontSize(11, fontScale),
            cluster._sx - 70, cluster._sy + (cluster._sr or 8) + 4, 140, 14,
            0.48, 0.76, 0.96, FIELD_CLUSTER.a * 0.85, 0.5, 0)
          clusterLabels = clusterLabels + 1
        end
      end
    end
    for i = 1, #graph.fieldState.points do
      local point = graph.fieldState.points[i]
      if visible(point, vx, vy, vsx, vsy, 20) then
        local hot = graph.hoveredId == point.id or graph.selectedId == point.id
        local radius = math.max(0.8, (point._sr or 1.2) * 0.75)
        if hot then
          activeNode(self.shader, time, point._sx, point._sy, radius, CYAN, 1, false)
        else
          ring(point._sx, point._sy, radius, FIELD, 1.5)
        end
      end
    end
  end

  local byId = {}
  for i = 1, #graph.activeNodes do byId[graph.activeNodes[i].id] = graph.activeNodes[i] end
  if graph.fieldState then
    for i = 1, #graph.fieldState.clusters do byId[graph.fieldState.clusters[i].id] = graph.fieldState.clusters[i] end
    for i = 1, #graph.fieldState.points do byId[graph.fieldState.points[i].id] = graph.fieldState.points[i] end
  end
  local hub = graph.hubVis
  local activeBeams = 0

  local function beam (ax, ay, bx, by, hot)
    if not ax or not bx then return end
    local cx1, cy1, cx2, cy2 = clipSegment(ax, ay, bx, by,
      vx, vy, vx + vsx, vy + vsy)
    if not cx1 then return end
    if hot and activeBeams < MAX_ACTIVE_BEAMS
      and activeBeam(self.shader, time, cx1, cy1, cx2, cy2, EDGE, 1, 2.0) then
      activeBeams = activeBeams + 1
      return
    end
    DrawEx.Line(cx1, cy1, cx2, cy2, EDGE)
  end

  if #graph.explicitEdges > 0 then
    for i = 1, #graph.explicitEdges do
      local edge = graph.explicitEdges[i]
      local aId, bId
      if edge.a then aId, bId = edge.a, edge.b
      else aId, bId = edge[1], edge[2] end
      local a, b = byId[aId], byId[bId]
      if a and b and visible(a, vx, vy, vsx, vsy, 80) and visible(b, vx, vy, vsx, vsy, 80) then
        local hot = graph.hoveredId == aId or graph.hoveredId == bId
          or graph.selectedId == aId or graph.selectedId == bId
        beam(a._sx, a._sy, b._sx, b._sy, hot)
      end
    end
  elseif hub and hub._sx then
    for i = 1, #graph.activeNodes do
      local node = graph.activeNodes[i]
      if node.data.major ~= false and visible(node, vx, vy, vsx, vsy, 80) then
        local hot = graph.hoveredId == node.id or graph.selectedId == node.id
        beam(hub._sx, hub._sy, node._sx, node._sy, hot)
      end
    end
  end

  if graph.parentVis and graph.parentVis._sx and hub and hub._sx then
    local hot = graph.hoveredId == '__parent'
    beam(graph.parentVis._sx, graph.parentVis._sy, hub._sx, hub._sy, hot)
  end

  -- Previews are batched rings, never per-point shader starts.
  for i = 1, #graph.activeNodes do
    local node = graph.activeNodes[i]
    if visible(node, vx, vy, vsx, vsy, 120) and node.previews then
      local orbitCos, orbitSin = 1, 0
      if node.previewSource and node.previewSource.orbit then
        local angle = time * (self.previewOrbitSpeed or (math.pi * 2 / 45))
        orbitCos, orbitSin = math.cos(angle), math.sin(angle)
      end
      for j = 1, #node.previews do
        local p = node.previews[j]
        -- Opt-in renderer-only orbit keeps preview IDs and drill origins stable.
        local dx = p.dx * orbitCos - p.dy * orbitSin
        local dy = p.dx * orbitSin + p.dy * orbitCos
        local sx, sy, scale = HoloLayout.project(graph.cam,
          node.x + dx, node.y + dy, node.z + p.dz, vx, vy, vsx, vsy)
        if sx then
          ring(sx, sy, math.max(1.8, 2.6 * scale), PREVIEW, 3)
        end
      end
    end
  end

  local ordered = {}
  for i = 1, #graph.activeNodes do ordered[#ordered + 1] = graph.activeNodes[i] end
  table.sort(ordered, function (a, b) return (a._depth or 0) > (b._depth or 0) end)
  for i = 1, #ordered do
    local node = ordered[i]
    if visible(node, vx, vy, vsx, vsy, 120) then
      local hot = graph.hoveredId == node.id or graph.selectedId == node.id
      local color = node.data.color or CYAN
      if hot then
        activeNode(self.shader, time, node._sx, node._sy, node._sr, color, 1,
          node.data.children and #node.data.children > 0)
      else
        ring(node._sx, node._sy, node._sr, color)
        ring(node._sx, node._sy, math.max(1.5, node._sr * 0.28), HUB, 2)
      end
    end
  end

  if graph.parentVis and visible(graph.parentVis, vx, vy, vsx, vsy, 120) then
    local hot = graph.hoveredId == '__parent'
    if hot then activeNode(self.shader, time, graph.parentVis._sx, graph.parentVis._sy,
      graph.parentVis._sr, PARENT, 1, true)
    else ring(graph.parentVis._sx, graph.parentVis._sy, graph.parentVis._sr, PARENT) end
    DrawEx.TextAlpha('Share', '<< ' .. (graph.parentVis.data.label or 'Back'), fontSize(13, fontScale),
      graph.parentVis._sx - 90, graph.parentVis._sy + graph.parentVis._sr + 6,
      180, 18, 0.65, 0.82, 1.0, 0.8, 0.5, 0)
  end

  if hub and visible(hub, vx, vy, vsx, vsy, 120) then
    ring(hub._sx, hub._sy, hub._sr, HUB)
    ring(hub._sx, hub._sy, math.max(2, hub._sr * 0.32), CYAN, 3)
    DrawEx.TextAlpha('Exo2Bold', graph.context.label or 'ROOT', fontSize(15, fontScale),
      hub._sx - 120, hub._sy - hub._sr - 24, 240, 20,
      0.85, 0.95, 1.0, 0.95, 0.5, 0)
  end

  for i = 1, #graph.activeNodes do
    local node = graph.activeNodes[i]
    if visible(node, vx, vy, vsx, vsy, 120) then
      label(node, graph.hoveredId == node.id or graph.selectedId == node.id,
        graph.cam.zoom, fontScale)
    end
  end
  if graph.fieldState then
    for i = 1, #graph.fieldState.clusters do
      local cluster = graph.fieldState.clusters[i]
      if (graph.hoveredId == cluster.id or graph.selectedId == cluster.id)
        and visible(cluster, vx, vy, vsx, vsy, 120) then
        label(cluster, true, graph.cam.zoom, fontScale)
      end
    end
    for i = 1, #graph.fieldState.points do
      local point = graph.fieldState.points[i]
      if (graph.hoveredId == point.id or graph.selectedId == point.id)
        and visible(point, vx, vy, vsx, vsy, 120) then
        label(point, true, graph.cam.zoom, fontScale)
      end
    end
  end

  local hovered = graph.hoveredId and byId[graph.hoveredId]
  if hovered and hovered.data.modifiers and hovered._sx then
    local mods = hovered.data.modifiers
    local w, h = 240, 34 + #mods * 18
    local x = math.min(vx + vsx - w - 16, hovered._sx + hovered._sr + 16)
    local y = math.max(vy + 16, math.min(vy + vsy - h - 16, hovered._sy - h * 0.5))
    DrawEx.Panel(x, y, w, h, { r = 0.02, g = 0.04, b = 0.08, a = 0.94 }, 0.94)
    DrawEx.Line(x, y, x + w, y, TOOLTIP_BORDER)
    DrawEx.Line(x + w, y, x + w, y + h, TOOLTIP_BORDER)
    DrawEx.Line(x + w, y + h, x, y + h, TOOLTIP_BORDER)
    DrawEx.Line(x, y + h, x, y, TOOLTIP_BORDER)
    DrawEx.TextAlpha('Exo2Bold', hovered.data.label, fontSize(14, fontScale), x + 10, y + 6, w - 20, 18,
      1, 1, 1, 0.95, 0, 0)
    for i = 1, #mods do
      local mod = mods[i]
      local cr, cg, cb = 0.35, 0.95, 0.55
      if not mod.good then cr, cg, cb = 1.0, 0.35, 0.38 end
      DrawEx.TextAlpha('Share', mod.text, fontSize(13, fontScale), x + 12, y + 28 + (i - 1) * 18,
        w - 24, 16, cr, cg, cb, 0.95, 0, 0)
    end
  end

  if graph.editNode then
    local w, h = 360, graph.editError and 98 or 78
    local x, y = vx + (vsx - w) * 0.5, vy + vsy - h - 70
    DrawEx.Panel(x, y, w, h, { r = 0.02, g = 0.04, b = 0.09, a = 0.96 }, 0.96)
    DrawEx.Line(x, y, x + w, y, EDIT_BORDER)
    DrawEx.Line(x + w, y, x + w, y + h, EDIT_BORDER)
    DrawEx.Line(x + w, y + h, x, y + h, EDIT_BORDER)
    DrawEx.Line(x, y + h, x, y, EDIT_BORDER)
    DrawEx.TextAlpha('Share', 'Edit Data (' .. (graph.editNode.label or 'Value')
      .. ')  [Enter] Apply  [Esc/B] Cancel', fontSize(13, fontScale),
      x + 12, y + 10, w - 24, 18,
      0.7, 0.9, 1.0, 0.9, 0, 0)
    DrawEx.TextAlpha('Exo2Bold', graph.editBuffer .. '_', fontSize(17, fontScale),
      x + 12, y + 38, w - 24, 22, 1.0, 0.4, 0.45, 1.0, 0, 0)
    if graph.editError then
      DrawEx.TextAlpha('Share', graph.editError, fontSize(13, fontScale),
        x + 12, y + 66, w - 24, 18,
        1.0, 0.45, 0.48, 1.0, 0, 0)
    end
  end

  local path = { graph.context.label or 'Universe' }
  for i = #graph.stack, 1, -1 do table.insert(path, 1, graph.stack[i].node.label) end
  DrawEx.TextAlpha('Share', table.concat(path, '  >  '), fontSize(14, fontScale),
    vx + 20, vy + 16, 700, 20, 0.75, 0.92, 1.0, 0.9, 0, 0)
  local rightInset = graph.infoPanelOpen and 340 or 0
  DrawEx.TextAlpha('Share', string.format('Layout: %s   Tilt: %.0f deg   Zoom: %.2f',
    string.upper(graph.layoutMode), math.deg(graph.cam.pitch), graph.cam.zoom),
    fontSize(14, fontScale), vx + vsx - 540 - rightInset, vy + 16, 520, 20,
    0.65, 0.85, 1.0, 0.85, 1, 0)
  if graph.mock then
    DrawEx.TextAlpha('Exo2Bold', 'MOCK DATA / VISUAL PROTOTYPE', fontSize(12, fontScale),
      vx + 20, vy + 44, 360, 18, 1.0, 0.65, 0.25, 0.85, 0, 0)
  end
  DrawEx.TextAlpha('Share',
    '[Click/Enter/A] Drill   [RMB/Backspace/X1/B] Back   [MMB] Pan   [Wheel] Zoom   [Arrows/RMB] Tilt   [F1/F2/F3] 0/15/25 deg   [Tab] Layout',
    fontSize(13, fontScale), vx + 20, vy + vsy - 30, vsx - 40, 18,
    1, 1, 1, 0.6, 0.5, 0)

  Draw.Color(1, 1, 1, 1)
  ClipRect.Pop()
end

return Renderer
