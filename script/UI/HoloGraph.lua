local Container = require('UI.Container')
local HoloLayout = require('UI.HoloLayout')
local HoloField = require('UI.HoloField')
local HoloRenderer = require('UI.HoloRenderer')

local HoloGraph = {}
HoloGraph.__index = HoloGraph
setmetatable(HoloGraph, Container)

HoloGraph.name = 'Holo Graph'
HoloGraph.focusable = true

local LAYOUT_CYCLE = { 'radial', 'cardinal', 'rectilinear', 'spiral', 'spatial' }
local clamp = math.max and function (v, lo, hi) return math.max(lo, math.min(hi, v)) end
  or function (v, lo, hi) if v < lo then return lo end; if v > hi then return hi end; return v end

local PREVIEW_MAX_POINTS = 32

local function previewBudget (zoom)
  if zoom < 0.5 then return 8 end
  if zoom < 1.25 then return 20 end
  return PREVIEW_MAX_POINTS
end

local function previewSource (node)
  local spec = type(node.preview) == 'table' and node.preview or nil
  local children = node.children or {}
  local inputPoints = spec and spec.points or children
  local points = {}
  for i = 1, math.min(#inputPoints, PREVIEW_MAX_POINTS) do
    local point = inputPoints[i]
    points[i] = {
      id = point.id,
      x = point.x or point.wx or 0,
      y = point.y or point.wy or 0,
      z = point.z or point.wz or 0,
    }
  end
  return {
    layout = spec and spec.layout or node.childLayout or 'radial',
    radius = spec and spec.radius or nil,
    orbit = spec and spec.orbit or false,
    points = points,
  }
end

local function snapshotNode (node, seen)
  if type(node) ~= 'table' then return node end
  if seen[node] then return seen[node] end
  local copy = {}
  seen[node] = copy
  for key, value in pairs(node) do
    if key == 'children' then
      local children = {}
      for i = 1, #value do children[i] = snapshotNode(value[i], seen) end
      copy.children = children
    elseif key == 'edges' then
      local edges = {}
      for i = 1, #value do
        local edge = {}
        for k, v in pairs(value[i]) do edge[k] = v end
        edges[i] = edge
      end
      copy.edges = edges
    elseif key == 'preview' then
      local preview = {}
      for k, v in pairs(value) do
        if k == 'points' then
          local points = {}
          for i = 1, #v do
            local point = {}
            for pk, pv in pairs(v[i]) do point[pk] = pv end
            points[i] = point
          end
          preview.points = points
        else
          preview[k] = v
        end
      end
      copy.preview = preview
    elseif key == 'actions' then
      local function copyActions (actions)
        local out = {}
        for i = 1, #actions do
          local action = {}
          for k, v in pairs(actions[i]) do
            if k == 'submenu' then
              action.submenu = { title = v.title, actions = copyActions(v.actions or {}) }
            else
              action[k] = v
            end
          end
          out[i] = action
        end
        return out
      end
      copy.actions = copyActions(value)
    elseif key == 'info' then
      local info = {}
      for k, v in pairs(value) do
        if k == 'stats' then
          local stats = {}
          for i = 1, #v do
            local stat = {}
            for sk, sv in pairs(v[i]) do stat[sk] = sv end
            stats[i] = stat
          end
          info.stats = stats
        else
          info[k] = v
        end
      end
      copy.info = info
    else
      -- Entity handles, live state tables, getters/setters, and other domain
      -- objects intentionally remain references; structural provider arrays
      -- and records are what must be owned by Holo.
      copy[key] = value
    end
  end
  return copy
end

function HoloGraph.Create (rootNode, opts)
  opts = opts or {}
  local rootSnapshot = snapshotNode(rootNode, {})
  local self = setmetatable({
    children = List(),
    rootNode = rootSnapshot,
    stack = {},
    activeNodes = {},
    field = nil,
    fieldState = nil,
    fieldVisById = {},
    inputConsumed = false,
    inputMode = opts.inputMode or 'auto',
    fieldOptions = opts.field or {},
    renderer = HoloRenderer.Create(opts.renderer),
  }, HoloGraph)
  self:setStretch(1, 1)
  self:setEState(Container.EState.Enabled)
  self.cam = {
    x = 0, y = 0, zoom = 1, targetZoom = 1,
    pitch = opts.pitch or 0.26, targetPitch = opts.pitch or 0.26,
    yaw = 0, targetYaw = 0, fovDist = 900,
  }
  self:enterContext(rootSnapshot, nil)
  return self
end

function HoloGraph:enterContext (contextNode, fromVis)
  self.context = contextNode
  self.layoutMode = contextNode.childLayout or 'radial'
  self.activeNodes = {}
  self.hoveredId, self.selectedId, self.focusId = nil, nil, nil
  self.explicitEdges = contextNode.edges or {}

  local sx0 = fromVis and fromVis.x or 0
  local sy0 = fromVis and fromVis.y or 0
  local sz0 = fromVis and fromVis.z or 0
  self.hubVis = {
    id = '__hub', data = contextNode, isHub = true,
    x = sx0, y = sy0, z = sz0, tx = 0, ty = 0, tz = 0,
    scale = fromVis and 0.12 or 1, targetScale = 1,
    radius = contextNode.radius or 26,
  }

  local previous = self.stack[#self.stack]
  if previous then
    self.parentVis = {
      id = '__parent', data = previous.node, isParent = true,
      x = sx0, y = sy0, z = sz0, tx = -360, ty = -110, tz = 30,
      scale = 0.35, targetScale = 1, radius = 18,
    }
  else
    self.parentVis = nil
  end

  local children = contextNode.children or {}
  local majorChildren, minorChildren = {}, {}
  local fieldScale, fieldHeightScale = 1, 1
  if self.layoutMode == 'spatial' then
    local maxRadius = 1
    for i = 1, #children do
      local child = children[i]
      local distance = math.sqrt((child.wx or child.x or 0)^2 + (child.wz or child.z or 0)^2)
      if distance > maxRadius then maxRadius = distance end
    end
    fieldScale, fieldHeightScale = 320 / maxRadius, 0.35
  end
  for i = 1, #children do
    local child = children[i]
    if child.major == false or child.minor then
      minorChildren[#minorChildren + 1] = child
    else
      majorChildren[#majorChildren + 1] = child
    end
  end
  local fieldOpts = self.fieldOptions or {}
  self.field = HoloField.Build(minorChildren, {
    contextId = contextNode.id or 'context',
    cellSize = fieldOpts.cellSize or 420,
    scale = fieldScale,
    heightScale = fieldHeightScale,
  })
  self.fieldVisById = {}
  self:refreshFieldLOD(true)

  for i = 1, #majorChildren do
    local child = majorChildren[i]
    local source = previewSource(child)
    local budget = previewBudget(self.cam.zoom)
    local previews = HoloLayout.previewOffsets(source, budget)
    local startX, startY, startZ = sx0, sy0, sz0
    if fromVis then
      for j = 1, #previews do
        if previews[j].id == child.id then
          startX = sx0 + previews[j].dx
          startY = sy0 + previews[j].dy
          startZ = sz0 + previews[j].dz
          break
        end
      end
    end
    self.activeNodes[i] = {
      id = child.id or tostring(i), data = child,
      wx = child.wx, wy = child.wy, wz = child.wz,
      x = startX, y = startY, z = startZ,
      tx = startX, ty = startY, tz = startZ,
      scale = fromVis and 0.12 or 1, targetScale = 1,
      radius = child.radius or ((child.children and #child.children > 0) and 18 or 12),
      previewSource = source,
      previews = previews,
      _previewBudget = budget,
    }
  end
  HoloLayout.apply(self.layoutMode, self.activeNodes)
end

function HoloGraph:drillInto (visNode)
  local data = visNode and visNode.data
  if not data then return false end
  if (not data.children or #data.children == 0) and data.editable and data.setValue then
    self.editNode = data
    self.editBuffer = tostring(data.getValue and data.getValue() or data.value or '')
    self.editError = nil
    self.inputConsumed = true
    return true
  end
  if not data.children or #data.children == 0 then return false end

  self.stack[#self.stack + 1] = {
    node = self.context,
    cam = {
      x = self.cam.x, y = self.cam.y,
      zoom = self.cam.zoom, targetZoom = self.cam.targetZoom,
      pitch = self.cam.pitch, targetPitch = self.cam.targetPitch,
      yaw = self.cam.yaw, targetYaw = self.cam.targetYaw,
    },
    focusId = self.focusId,
    selectedId = self.selectedId,
    layoutMode = self.layoutMode,
  }
  self:enterContext(data, visNode)
  return true
end

function HoloGraph:cancelEdit ()
  if not self.editNode then return false end
  self.editNode, self.editBuffer, self.editError = nil, nil, nil
  return true
end

function HoloGraph:commitEdit ()
  if not self.editNode then return false end
  local value = tonumber(self.editBuffer)
  if not value then
    self.editError = 'Enter a valid number'
    return false
  end
  if not self.editNode.setValue then
    self.editError = 'Value is read-only'
    return false
  end
  if self.editNode.setValue(value) == false then
    self.editError = 'Value rejected'
    return false
  end
  self:cancelEdit()
  return true
end

function HoloGraph:drillOut ()
  if self.editNode then return self:cancelEdit() end
  if #self.stack == 0 then return false end
  local previous = self.stack[#self.stack]
  self.stack[#self.stack] = nil
  self:enterContext(previous.node, self.hubVis)
  self.layoutMode = previous.layoutMode or self.context.childLayout or 'radial'
  HoloLayout.apply(self.layoutMode, self.activeNodes)
  local cam = previous.cam
  if cam then
    self.cam.x, self.cam.y = cam.x, cam.y
    self.cam.targetZoom = cam.targetZoom
    self.cam.targetPitch = cam.targetPitch
    self.cam.targetYaw = cam.targetYaw
  end
  self.focusId = previous.focusId
  self.selectedId = previous.selectedId
  self:refreshFieldLOD(true)
  return true
end

function HoloGraph:setLayout (mode)
  for i = 1, #LAYOUT_CYCLE do
    if LAYOUT_CYCLE[i] == mode then
      self.layoutMode = mode
      HoloLayout.apply(mode, self.activeNodes)
      return true
    end
  end
  return false
end

function HoloGraph:cycleLayout ()
  local index = 1
  for i = 1, #LAYOUT_CYCLE do
    if LAYOUT_CYCLE[i] == self.layoutMode then index = i + 1; break end
  end
  self.layoutMode = LAYOUT_CYCLE[((index - 1) % #LAYOUT_CYCLE) + 1]
  HoloLayout.apply(self.layoutMode, self.activeNodes)
end

function HoloGraph:setTilt (pitch, yaw)
  self.cam.targetPitch = clamp(pitch, -1.15, 1.15)
  if yaw then self.cam.targetYaw = yaw end
end

function HoloGraph:refreshFieldLOD (force)
  if not self.field then return end
  local key = string.format('%.4f|%s', self.cam.zoom, self.selectedId or '')
  if not force and key == self._fieldLODKey then return end
  local opts = self.fieldOptions or {}
  self.fieldState = HoloField.LOD(self.field, self.cam.zoom, self.selectedId, {
    maxPoints = opts.maxPoints or 4096,
    maxClusters = opts.maxClusters or 256,
  })
  self.fieldVisById = {}
  for i = 1, #self.fieldState.clusters do
    local cluster = self.fieldState.clusters[i]
    if not cluster.data then
      cluster.data = {
        id = cluster.id, label = 'Asteroid Cluster',
        sublabel = string.format('%d objects', cluster.count), major = false,
        info = { title = 'Asteroid Cluster', subtitle = 'Aggregate field',
          description = 'A deterministic spatial cluster of minor asteroids. Zoom in to unpack selectable objects.',
          preview = 'asteroid', stats = {
            { label = 'Objects', value = tostring(cluster.count) },
            { label = 'Class', value = 'field cluster' },
          } },
        actions = { { id = 'unpack', label = 'Unpack Cluster' } },
      }
    end
    self.fieldVisById[cluster.id] = cluster
  end
  for i = 1, #self.fieldState.points do
    local point = self.fieldState.points[i]
    self.fieldVisById[point.id] = point
  end
  self._fieldLODKey = key
end

function HoloGraph:refreshPreviewLOD ()
  local budget = previewBudget(self.cam.zoom)
  for i = 1, #self.activeNodes do
    local vis = self.activeNodes[i]
    if vis._previewBudget ~= budget then
      vis.previews = HoloLayout.previewOffsets(vis.previewSource, budget)
      vis._previewBudget = budget
    end
  end
end

function HoloGraph:onUpdate (state)
  local dt = clamp(state.dt or 0.016, 0.0001, 0.05)
  local kCam = 1 - math.exp(-8 * dt)
  local kNode = 1 - math.exp(-10 * dt)
  self.cam.zoom = self.cam.zoom + (self.cam.targetZoom - self.cam.zoom) * kCam
  self.cam.pitch = self.cam.pitch + (self.cam.targetPitch - self.cam.pitch) * kCam
  self.cam.yaw = self.cam.yaw + (self.cam.targetYaw - self.cam.yaw) * kCam
  self:refreshPreviewLOD()
  self:refreshFieldLOD()

  local function step (vis)
    if not vis then return end
    vis.x = vis.x + (vis.tx - vis.x) * kNode
    vis.y = vis.y + (vis.ty - vis.y) * kNode
    vis.z = vis.z + (vis.tz - vis.z) * kNode
    vis.scale = vis.scale + (vis.targetScale - vis.scale) * kNode
  end
  step(self.hubVis)
  step(self.parentVis)
  for i = 1, #self.activeNodes do step(self.activeNodes[i]) end

  local vx, vy, vsx, vsy = self:getRectGlobal()
  local function project (vis)
    if not vis then return end
    local sx, sy, scale, depth = HoloLayout.project(self.cam,
      vis.x, vis.y, vis.z, vx, vy, vsx, vsy)
    vis._sx, vis._sy = sx, sy
    vis._scale = scale
    vis._depth = depth
    vis._sr = sx and HoloLayout.projectRadius(self.cam,
      (vis.radius or 12) * (vis.scale or 1), scale) or nil
  end
  project(self.hubVis)
  project(self.parentVis)
  for i = 1, #self.activeNodes do project(self.activeNodes[i]) end
  if self.fieldState then
    for i = 1, #self.fieldState.clusters do project(self.fieldState.clusters[i]) end
    for i = 1, #self.fieldState.points do project(self.fieldState.points[i]) end
  end
end

function HoloGraph:onDraw (focus, active)
  self.renderer:draw(self, focus, active)
end

function HoloGraph:hitTest (mx, my)
  if self.parentVis and self.parentVis._sx then
    local dx, dy = mx - self.parentVis._sx, my - self.parentVis._sy
    local r = (self.parentVis._sr or 18) + 10
    if dx * dx + dy * dy <= r * r then return self.parentVis end
  end
  local best, bestDistance = nil, math.huge
  local function consider (vis, minRadius)
    if not vis._sx then return end
    local r = math.max(minRadius, (vis._sr or 1) + 5)
    local dx, dy = mx - vis._sx, my - vis._sy
    local d2 = dx * dx + dy * dy
    if d2 <= r * r and d2 < bestDistance then best, bestDistance = vis, d2 end
  end
  for i = 1, #self.activeNodes do consider(self.activeNodes[i], 16) end
  if self.fieldState then
    for i = 1, #self.fieldState.clusters do consider(self.fieldState.clusters[i], 8) end
    for i = 1, #self.fieldState.points do consider(self.fieldState.points[i], 5) end
  end
  return best
end

function HoloGraph:getSelectedVis ()
  if self.selectedId == '__parent' then return self.parentVis end
  for i = 1, #self.activeNodes do
    if self.activeNodes[i].id == self.selectedId then return self.activeNodes[i] end
  end
  return self.fieldVisById and self.fieldVisById[self.selectedId] or nil
end

function HoloGraph:getSelectedNode ()
  local vis = self:getSelectedVis()
  return vis and vis.data or nil
end

function HoloGraph:activateHovered ()
  local id = self.hoveredId or self.selectedId
  if id == '__parent' then return self:drillOut() end
  for i = 1, #self.activeNodes do
    if self.activeNodes[i].id == id then
      self.focusId = id
      self.selectedId = id
      return self:drillInto(self.activeNodes[i])
    end
  end
  local fieldVis = self.fieldVisById and self.fieldVisById[id]
  if fieldVis then
    self.focusId, self.selectedId = id, id
    return self:drillInto(fieldVis)
  end
  return false
end

function HoloGraph:gamepadSelection ()
  local gx = Input.GetValue(Button.Gamepad.LStickX)
  local gy = Input.GetValue(Button.Gamepad.LStickY)
  if gx * gx + gy * gy <= 0.15 then return end
  local vx, vy, vsx, vsy = self:getRectGlobal()
  local hx, hy = HoloLayout.project(self.cam, 0, 0, 0, vx, vy, vsx, vsy)
  if not hx then return end
  local gl = math.sqrt(gx * gx + gy * gy)
  local bestScore, bestId = -2, nil
  local function consider (vis)
    local sx, sy = vis._sx, vis._sy
    if not sx then sx, sy = HoloLayout.project(self.cam, vis.x, vis.y, vis.z, vx, vy, vsx, vsy) end
    if sx then
      local dx, dy = sx - hx, sy - hy
      local nl = math.sqrt(dx * dx + dy * dy)
      if nl > 1e-3 then
        -- Engine gamepad Y is positive-up; screen-space dy is positive-down.
        local score = (gx * dx - gy * dy) / (gl * nl)
        if score > bestScore then bestScore, bestId = score, vis.id end
      end
    end
  end
  for i = 1, #self.activeNodes do consider(self.activeNodes[i]) end
  if self.fieldState then
    for i = 1, #self.fieldState.clusters do consider(self.fieldState.clusters[i]) end
    for i = 1, #self.fieldState.points do consider(self.fieldState.points[i]) end
  end
  if bestId then self.hoveredId, self.selectedId = bestId, bestId end
end

local function hasWidget (widget, target)
  while widget do
    if widget == target then return true end
    widget = widget.parent
  end
  return false
end

function HoloGraph:hasInputFocus (state)
  if not state then return true end
  local focus = state.active or state.focus or state.navFocus or state.panelFocus
  return focus ~= nil and hasWidget(focus, self)
end

function HoloGraph:acceptsInput (state)
  if state and state.modalFocus and not hasWidget(state.modalFocus, self) then
    return false
  end
  if self.inputMode == 'always' then return true end
  if self.inputMode == 'focused' then return self:hasInputFocus(state) end

  -- A sole Canvas child is the standalone demo. Nested widgets and Canvases
  -- with siblings use normal UI focus routing so Holo cannot steal input.
  local parent = self.parent
  if not parent then return true end
  if parent.isCanvas and #parent.children == 1 then return true end
  return self:hasInputFocus(state)
end

function HoloGraph:inputFocused (state)
  -- Standalone root children already receive Container:input/onInput once.
end

function HoloGraph:onInput (state)
  self.inputConsumed = false
  if not self:acceptsInput(state) then
    self.hoveredId = nil
    self._lastRMB, self._rmbOrigin, self._rmbApplied = nil, nil, nil
    self._rmbMoved = false
    self._lastMMB = nil
    return
  end

  local dt = clamp(state.dt or 0.016, 0.0001, 0.05)
  if self.editNode then
    if Input.GetPressed(Button.Keyboard.Escape) or Input.GetPressed(Button.Gamepad.B) then
      self:cancelEdit()
      self.inputConsumed = true
      return
    elseif Input.GetPressed(Button.Keyboard.Return) then
      self:commitEdit()
      self.inputConsumed = true
      return
    elseif Input.GetPressed(Button.Keyboard.Backspace) then
      self.editBuffer = self.editBuffer:sub(1, math.max(0, #self.editBuffer - 1))
      self.editError = nil
      return
    end
    local digits = {
      { Button.Keyboard.N0, '0' }, { Button.Keyboard.N1, '1' }, { Button.Keyboard.N2, '2' },
      { Button.Keyboard.N3, '3' }, { Button.Keyboard.N4, '4' }, { Button.Keyboard.N5, '5' },
      { Button.Keyboard.N6, '6' }, { Button.Keyboard.N7, '7' }, { Button.Keyboard.N8, '8' },
      { Button.Keyboard.N9, '9' }, { Button.Keyboard.Period, '.' }, { Button.Keyboard.Minus, '-' },
    }
    for i = 1, #digits do
      if Input.GetPressed(digits[i][1]) then
        self.editBuffer = self.editBuffer .. digits[i][2]
        self.editError = nil
      end
    end
    return
  end

  if Input.GetPressed(Button.Keyboard.Tab) then self:cycleLayout() end
  if Input.GetPressed(Button.Keyboard.F1) then self:setTilt(0, 0) end
  if Input.GetPressed(Button.Keyboard.F2) then self:setTilt(math.rad(15), 0) end
  if Input.GetPressed(Button.Keyboard.F3) then self:setTilt(math.rad(25), 0) end
  if Input.GetPressed(Button.Keyboard.Backspace) or Input.GetPressed(Button.Mouse.X1) then
    self:drillOut()
  end

  self.cam.targetPitch = clamp(self.cam.targetPitch
    + (Input.GetValue(Button.Keyboard.Down) - Input.GetValue(Button.Keyboard.Up)) * 1.4 * dt,
    -1.15, 1.15)
  self.cam.targetYaw = self.cam.targetYaw
    + (Input.GetValue(Button.Keyboard.Right) - Input.GetValue(Button.Keyboard.Left)) * 1.4 * dt

  local vx, vy, vsx, vsy = self:getRectGlobal()
  local mp = Input.GetMousePosition()
  local inside = self:containsPoint(mp.x, mp.y)
  local wheel = Input.GetMouseScroll().y
  if inside and wheel ~= 0 then
    HoloLayout.zoomAt(self.cam, mp.x, mp.y, math.exp(wheel * 0.12), vx, vy, vsx, vsy)
    self.cam.targetZoom = self.cam.zoom
  end

  local rightDown = Input.GetDown(Button.Mouse.Right)
  if rightDown then
    if not self._lastRMB then
      if inside then
        self._lastRMB = { x = mp.x, y = mp.y }
        self._rmbOrigin = { x = mp.x, y = mp.y }
        self._rmbApplied = { x = mp.x, y = mp.y }
        self._rmbMoved = false
      end
    else
      local totalX, totalY = mp.x - self._rmbOrigin.x, mp.y - self._rmbOrigin.y
      if totalX * totalX + totalY * totalY > 16 then self._rmbMoved = true end
      if self._rmbMoved then
        local dx, dy = mp.x - self._rmbApplied.x, mp.y - self._rmbApplied.y
        self.cam.targetYaw = self.cam.targetYaw + dx * 0.006
        self.cam.targetPitch = clamp(self.cam.targetPitch + dy * 0.006, -1.15, 1.15)
        self._rmbApplied = { x = mp.x, y = mp.y }
      end
      self._lastRMB = { x = mp.x, y = mp.y }
    end
  else
    if self._lastRMB and not self._rmbMoved and inside then self:drillOut() end
    self._lastRMB, self._rmbOrigin, self._rmbApplied = nil, nil, nil
    self._rmbMoved = false
  end

  local middleDown = Input.GetDown(Button.Mouse.Middle)
  if middleDown then
    if not self._lastMMB then
      if inside then self._lastMMB = { x = mp.x, y = mp.y } end
    else
      HoloLayout.pan(self.cam, self._lastMMB.x, self._lastMMB.y,
        mp.x, mp.y, vx, vy, vsx, vsy)
      self._lastMMB = { x = mp.x, y = mp.y }
    end
  else
    self._lastMMB = nil
  end

  -- Keyboard/gamepad activation uses the current selection even when the
  -- pointer is outside; mouse hover is updated afterwards.
  self:gamepadSelection()
  if Input.GetPressed(Button.Gamepad.A) then self:activateHovered() end
  if Input.GetPressed(Button.Gamepad.B) then self:drillOut() end
  if Input.GetPressed(Button.Keyboard.Return)
    and (self.hoveredId or self.selectedId) then self:activateHovered() end

  local hit = inside and self:hitTest(mp.x, mp.y) or nil
  self.hoveredId = hit and hit.id or nil
  if Input.GetPressed(Button.Mouse.Left) and hit then
    self.focusId = hit.id
    self.selectedId = hit.id
    local now = Engine.GetTime()
    if hit.isParent then
      self:drillOut()
      self._lastClickId, self._lastClickTime = nil, nil
    elseif self._lastClickId == hit.id and self._lastClickTime
      and now - self._lastClickTime <= 0.35 then
      self:drillInto(hit)
      self._lastClickId, self._lastClickTime = nil, nil
    else
      self._lastClickId, self._lastClickTime = hit.id, now
    end
  end
end

return HoloGraph
