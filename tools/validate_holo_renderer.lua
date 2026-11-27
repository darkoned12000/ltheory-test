#!/usr/bin/env luajit
-- HoloRenderer batching, culling, and active-accent contracts.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_holo_renderer%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

local widgetRects, lines, texts, shaderModes, panels = {}, {}, {}, {}, {}
local shaderStarts, shaderStops, rawRects = 0, 0, 0
local clipPushes, clipPops, clipRects = 0, 0, {}
local shader = {}
function shader:start () shaderStarts = shaderStarts + 1 end
function shader:stop () shaderStops = shaderStops + 1 end
_G.Cache = { Shader = function () return shader end }
_G.Shader = {
  SetInt = function (name, value) if name == 'mode' then shaderModes[#shaderModes + 1] = value end end,
  SetFloat = function () end, SetFloat2 = function () end,
  SetFloat4 = function () end,
}
_G.BlendMode = {
  Alpha = 1, Additive = 0,
  Push = function () end, Pop = function () end,
  PushAdditive = function () end,
}
_G.Draw = { Rect = function () rawRects = rawRects + 1 end,
  Point = function () end, Color = function () end }
_G.DrawEx = {
  GetAlpha = function () return 1 end,
  Line = function (...) lines[#lines + 1] = { ... } end,
  TextAlpha = function (...) texts[#texts + 1] = { ... } end,
  Panel = function (...) panels[#panels + 1] = { ... } end,
}
_G.ClipRect = {
  PushCombined = function (...) clipPushes = clipPushes + 1; clipRects[#clipRects + 1] = { ... } end,
  Pop = function () clipPops = clipPops + 1 end,
}
package.loaded['UI.DrawEx'] = DrawEx
local originalWidgetRect = Draw.WidgetRect
Draw.WidgetRect = function (...) widgetRects[#widgetRects + 1] = { ... } end
local engineTime = 2
_G.Engine = { GetTime = function () return engineTime end }

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end
local function finish ()
  Draw.WidgetRect = originalWidgetRect
  if failures == 0 then print(string.format('holo renderer: %d checks passed', checks)); os.exit(0) end
  print(string.format('holo renderer: %d/%d checks failed', failures, checks)); os.exit(1)
end

local loaded, Renderer = pcall(require, 'UI.HoloRenderer')
check('HoloRenderer module loads', loaded, Renderer)
if not loaded then finish() end

local graph = {
  mock = true,
  cam = { zoom = 1, pitch = 0.26, yaw = 0 },
  context = { id = 'root', label = 'Cluster' },
  stack = {},
  layoutMode = 'radial',
  hubVis = { id = '__hub', data = { label = 'Cluster' }, _sx = 500, _sy = 400,
    _sr = 26, _depth = 900, x = 0, y = 0, z = 0, radius = 26, scale = 1 },
  parentVis = nil,
  hoveredId = 'hot',
  selectedId = nil,
  editNode = { label = 'Fire Rate' },
  editBuffer = 'bad',
  editError = 'Enter a valid number',
  explicitEdges = {},
  activeNodes = {
    { id = 'normal', data = { label = 'Normal', color = { r = 0.2, g = 0.7, b = 1, a = 1 } },
      _sx = 250, _sy = 300, _sr = 12, _depth = 900, x = -250, y = -100, z = 0,
      radius = 12, scale = 1, previews = { { dx = 10, dy = 0, dz = 0 } } },
    { id = 'hot', data = { label = 'Hot', color = { r = 0.2, g = 0.7, b = 1, a = 1 },
      modifiers = {
        { good = true, text = '+20% Hull' }, { good = false, text = '+25% Mass' },
        { good = true, text = '+1 Hardpoint' }, { good = false, text = '-1 Thruster' },
      } },
      _sx = 750, _sy = 780, _sr = 14, _depth = 900, x = 250, y = 380, z = 0,
      radius = 14, scale = 1 },
    { id = 'offscreen', data = { label = 'Offscreen' }, _sx = 2000, _sy = 400,
      _sr = 12, _depth = 900, x = 1500, y = 0, z = 0, radius = 12, scale = 1 },
  },
}
function graph:getRectGlobal () return 0, 0, 1000, 800 end

local testRenderer = Renderer.Create()
testRenderer:draw(graph)
check('normal nodes and previews use batched widget rings', #widgetRects >= 5,
  tostring(#widgetRects) .. ' widget rects')
local offscreenLabel = false
for i = 1, #texts do if texts[i][2] == 'Offscreen' then offscreenLabel = true end end
check('offscreen nodes are culled', not offscreenLabel)
check('only active node/path accents start the custom shader',
  shaderStarts == 2 and shaderStops == 2,
  tostring(shaderStarts) .. ' starts')
local hasNodeMode, hasBeamMode = false, false
for i = 1, #shaderModes do
  if shaderModes[i] == 0 then hasNodeMode = true end
  if shaderModes[i] == 1 then hasBeamMode = true end
end
check('custom passes include both node and beam modes',
  hasNodeMode and hasBeamMode, table.concat(shaderModes, ','))
check('normal spokes remain batched line primitives', #lines >= 1)
check('labels and the mock-data header are drawn', #texts >= 3)
check('shader start/stop stays balanced', shaderStarts == shaderStops)
check('raw quads are used only under the explicit Holo shader',
  rawRects == shaderStarts, tostring(rawRects) .. ' raw / ' .. tostring(shaderStarts) .. ' shader')
check('graph drawing pushes and pops one combined widget clip',
  clipPushes == 1 and clipPops == 1 and clipRects[1]
    and clipRects[1][1] == 0 and clipRects[1][2] == 0
    and clipRects[1][3] == 1000 and clipRects[1][4] == 800)
local tooltipClamped, editErrorVisible = false, false
for i = 1, #panels do
  local p = panels[i]
  if p[3] == 240 then tooltipClamped = p[2] >= 16 and p[2] + p[4] <= 784 end
end
for i = 1, #texts do
  if texts[i][2] == 'Enter a valid number' then editErrorVisible = true end
end
check('modifier tooltips stay inside the widget vertically', tooltipClamped)
check('numeric editor errors are visible', editErrorVisible)

testRenderer.fontScale = 1.5
testRenderer:draw(graph)
local scaledText = false
for i = 1, #texts do
  if texts[i][3] == 21 then scaledText = true end
end
check('renderer font scale affects explicit text sizes', scaledText)

graph.editNode = nil
graph.explicitEdges = {}
for _ = 1, 40 do graph.explicitEdges[#graph.explicitEdges + 1] = { 'normal', 'hot' } end
local startsBefore = shaderStarts
Renderer.Create():draw(graph)
check('dense hot paths have a bounded custom-shader pass count',
  shaderStarts - startsBefore <= 9,
  tostring(shaderStarts - startsBefore) .. ' starts')
check('dense graph shader starts and stops stay balanced',
  shaderStarts == shaderStops and clipPushes == clipPops)

local orbitGraph = {
  cam = { zoom = 1, pitch = 0, yaw = 0, fovDist = 900 },
  context = { label = 'Orbit Root' }, stack = {}, layoutMode = 'radial',
  hubVis = nil, parentVis = nil, hoveredId = nil, selectedId = nil,
  editNode = nil, explicitEdges = {},
  activeNodes = {
    { id = 'parent', data = { label = 'Parent' }, _sx = 500, _sy = 400,
      _sr = 18, _depth = 900, x = 0, y = 0, z = 0, radius = 18, scale = 1,
      previewSource = { orbit = true },
      previews = { { id = 'child', dx = 20, dy = 0, dz = 0 } } },
  },
}
function orbitGraph:getRectGlobal () return 0, 0, 1000, 800 end
local orbitRenderer = Renderer.Create({ showGrid = false, showStars = false })
local function ringCenter (radius, first)
  for i = first, #widgetRects do
    local r = widgetRects[i]
    if math.abs(r[11] - radius) < 1e-6 then
      return r[3] + r[5] * 0.5, r[4] + r[6] * 0.5
    end
  end
end
engineTime = 0
local first = #widgetRects + 1
orbitRenderer:draw(orbitGraph)
local previewX0, previewY0 = ringCenter(2.6, first)
local nodeX0, nodeY0 = ringCenter(18, first)
orbitGraph.selectedId = 'parent'
first = #widgetRects + 1
orbitRenderer:draw(orbitGraph)
local previewColor
for i = first, #widgetRects do
  if math.abs(widgetRects[i][11] - 2.6) < 1e-6 then
    previewColor = widgetRects[i]
    break
  end
end
check('selected system previews remain distinct cyan markers',
  previewColor and previewColor[8] > previewColor[7]
    and previewColor[9] > previewColor[7])
orbitGraph.selectedId = nil
engineTime = 4
first = #widgetRects + 1
orbitRenderer:draw(orbitGraph)
local previewX4, previewY4 = ringCenter(2.6, first)
local nodeX4, nodeY4 = ringCenter(18, first)
local previewTravel = math.sqrt((previewX4 - previewX0)^2 + (previewY4 - previewY0)^2)
check('preview micro-nodes slowly orbit their parent',
  previewTravel ~= nil and previewTravel > 1,
  previewTravel and string.format('%.2f px in 4 s', previewTravel) or 'missing ring')
check('orbiting previews leave the parent node stationary',
  nodeX0 ~= nil and nodeX4 ~= nil
    and math.abs(nodeX4 - nodeX0) < 1e-6 and math.abs(nodeY4 - nodeY0) < 1e-6)
engineTime = 45
first = #widgetRects + 1
orbitRenderer:draw(orbitGraph)
local previewX45, previewY45 = ringCenter(2.6, first)
check('system preview orbit completes one revolution in 45 seconds',
  previewX45 ~= nil and math.abs(previewX45 - previewX0) < 1e-6
    and math.abs(previewY45 - previewY0) < 1e-6)

orbitRenderer.previewOrbitSpeed = 0
engineTime = 4
first = #widgetRects + 1
orbitRenderer:draw(orbitGraph)
local stoppedX4, stoppedY4 = ringCenter(2.6, first)
engineTime = 8
first = #widgetRects + 1
orbitRenderer:draw(orbitGraph)
local stoppedX8, stoppedY8 = ringCenter(2.6, first)
check('zero preview orbit speed disables the animation',
  stoppedX4 ~= nil and stoppedX8 ~= nil
    and math.abs(stoppedX8 - stoppedX4) < 1e-6
    and math.abs(stoppedY8 - stoppedY4) < 1e-6)

local staticGraph = {
  cam = { zoom = 1, pitch = 0, yaw = 0, fovDist = 900 },
  context = { label = 'Static Root' }, stack = {}, layoutMode = 'radial',
  hubVis = nil, parentVis = nil, hoveredId = nil, selectedId = nil,
  editNode = nil, explicitEdges = {},
  activeNodes = {
    { id = 'static-parent', data = { label = 'Components' }, _sx = 500, _sy = 400,
      _sr = 18, _depth = 900, x = 0, y = 0, z = 0, radius = 18, scale = 1,
      previewSource = { orbit = false },
      previews = { { id = 'component', dx = 20, dy = 0, dz = 0 } } },
  },
}
function staticGraph:getRectGlobal () return 0, 0, 1000, 800 end
local staticRenderer = Renderer.Create({ showGrid = false, showStars = false })
engineTime = 0
first = #widgetRects + 1
staticRenderer:draw(staticGraph)
local staticX0, staticY0 = ringCenter(2.6, first)
engineTime = 4
first = #widgetRects + 1
staticRenderer:draw(staticGraph)
local staticX4, staticY4 = ringCenter(2.6, first)
check('non-system previews do not orbit',
  staticX0 ~= nil and staticX4 ~= nil
    and math.abs(staticX4 - staticX0) < 1e-6
    and math.abs(staticY4 - staticY0) < 1e-6)

local minorGraph = {
  cam = { zoom = 1, pitch = 0, yaw = 0, fovDist = 900 },
  context = { label = 'System' }, stack = {}, layoutMode = 'spatial',
  hubVis = { id = '__hub', data = {}, _sx = 500, _sy = 400, _sr = 26,
    x = 0, y = 0, z = 0, radius = 26, scale = 1 },
  parentVis = nil, hoveredId = nil, selectedId = nil, editNode = nil,
  explicitEdges = {},
  activeNodes = {
    { id = 'rock', data = { label = 'Asteroid', major = false },
      _sx = 700, _sy = 400, _sr = 8, x = 200, y = 0, z = 0,
      radius = 8, scale = 1 },
  },
}
function minorGraph:getRectGlobal () return 0, 0, 1000, 800 end
local linesBeforeMinor = #lines
Renderer.Create({ showGrid = false, showStars = false }):draw(minorGraph)
check('minor asteroids do not receive default hub spokes', #lines == linesBeforeMinor,
  tostring(#lines - linesBeforeMinor) .. ' new lines')

local batchFieldGraph = {
  cam = { zoom = 2, pitch = 0, yaw = 0, fovDist = 900 },
  context = { label = 'Asteroid Field' }, stack = {}, layoutMode = 'spatial',
  hubVis = nil, parentVis = nil, hoveredId = nil, selectedId = nil,
  editNode = nil, explicitEdges = {}, activeNodes = {},
  fieldState = { points = {}, clusters = {}, pointAlpha = 1, clusterAlpha = 0 },
}
for i = 1, 2000 do
  batchFieldGraph.fieldState.points[i] = {
    id = 'field_' .. i, data = { label = 'Rock ' .. i },
    _sx = (i % 50) * 20, _sy = math.floor(i / 50) * 20, _sr = 1.2,
    x = 0, y = 0, z = 0, radius = 2,
  }
end
function batchFieldGraph:getRectGlobal () return 0, 0, 1000, 800 end
local rectsBeforeField, startsBeforeField = #widgetRects, shaderStarts
Renderer.Create({ showGrid = false, showStars = false }):draw(batchFieldGraph)
check('2,000 field points render as batched widget geometry',
  #widgetRects - rectsBeforeField == 2000,
  tostring(#widgetRects - rectsBeforeField) .. ' widget rects')
local fieldRadius = widgetRects[rectsBeforeField + 1] and widgetRects[rectsBeforeField + 1][11]
check('asteroid field markers use the reduced 75-percent radius',
  fieldRadius ~= nil and math.abs(fieldRadius - 0.9) < 1e-6,
  tostring(fieldRadius))
check('field points never start the custom shader', shaderStarts == startsBeforeField)
local fieldLabelLeak = false
for i = 1, #texts do if texts[i][2] == 'Rock 1' then fieldLabelLeak = true end end
check('unselected field points do not draw labels', not fieldLabelLeak)

local selectedFieldGraph = {
  cam = { zoom = 2, pitch = 0, yaw = 0, fovDist = 900 },
  context = { label = 'Asteroid Field' }, stack = {}, layoutMode = 'spatial',
  hubVis = nil, parentVis = nil, hoveredId = nil, selectedId = 'field_1',
  editNode = nil, explicitEdges = {}, activeNodes = {},
  fieldState = { pointAlpha = 1, clusterAlpha = 0, clusters = {}, points = {
    { id = 'field_1', data = { label = 'Selected Rock' }, _sx = 400, _sy = 400,
      _sr = 1.2, x = 0, y = 0, z = 0, radius = 2 },
    { id = 'field_2', data = { label = 'Other Rock' }, _sx = 500, _sy = 400,
      _sr = 1.2, x = 0, y = 0, z = 0, radius = 2 },
  } },
}
function selectedFieldGraph:getRectGlobal () return 0, 0, 1000, 800 end
startsBeforeField = shaderStarts
Renderer.Create({ showGrid = false, showStars = false }):draw(selectedFieldGraph)
check('only the selected field point uses an active accent',
  shaderStarts - startsBeforeField == 1)
local selectedFieldLabel = false
for i = 1, #texts do if texts[i][2] == 'Selected Rock' then selectedFieldLabel = true end end
check('selected field point is labeled', selectedFieldLabel)

local clusterGraph = {
  cam = { zoom = 0.5, pitch = 0, yaw = 0, fovDist = 900 },
  context = { label = 'Asteroid Field' }, stack = {}, layoutMode = 'spatial',
  hubVis = nil, parentVis = nil, hoveredId = nil, selectedId = nil,
  editNode = nil, explicitEdges = {}, activeNodes = {},
  fieldState = { pointAlpha = 0, clusterAlpha = 1, points = {}, clusters = {
    { id = 'cluster_1', data = { label = 'Asteroid Cluster', sublabel = '12 objects' },
      count = 12, _sx = 400, _sy = 400, _sr = 9, x = 0, y = 0, z = 0, radius = 9 },
  } },
}
function clusterGraph:getRectGlobal () return 0, 0, 1000, 800 end
Renderer.Create({ showGrid = false, showStars = false }):draw(clusterGraph)
local clusterLabel = false
for i = 1, #texts do if texts[i][2] == '12 objects' then clusterLabel = true end end
check('far field clusters display aggregate counts', clusterLabel)

finish()
