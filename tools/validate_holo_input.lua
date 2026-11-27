#!/usr/bin/env luajit
-- HoloGraph interaction contracts with only the input/UI boundary stubbed.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_holo_input%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

function class (ctor)
  local cls = {}; cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end

_G.List = function ()
  local list = { items = {} }
  function list:append (v) self.items[#self.items + 1] = v end
  function list:last () return self.items[#self.items] end
  return list
end

local Container = {}
Container.__index = Container
Container.EState = { Enabled = 1 }
function Container:setStretch () end
function Container:setEState (state) self.eState = state; self.enabledT = 1 end
function Container:getRectGlobal () return 0, 0, 1000, 800 end
function Container:containsPoint (x, y) return x >= 0 and y >= 0 and x <= 1000 and y <= 800 end
function Container:input (state) self:onInput(state) end
package.loaded['UI.Container'] = Container
package.loaded['UI.HoloRenderer'] = { Create = function () return { draw = function () end } end }

local Button = {
  Keyboard = { Tab = 'tab', Backspace = 'backspace', Return = 'return', Escape = 'escape',
    Left = 'left', Right = 'right', Up = 'up', Down = 'down', F1 = 'f1', F2 = 'f2', F3 = 'f3',
    N0 = '0', N1 = '1',
    N2 = '2', Period = '.', Minus = '-' },
  Mouse = { Left = 'mouse-left', Right = 'mouse-right', Middle = 'mouse-middle', X1 = 'mouse-x1' },
  Gamepad = { LStickX = 'lstick-x', LStickY = 'lstick-y', A = 'pad-a', B = 'pad-b' },
}
_G.Button = Button
local pressed, down, values = {}, {}, {}
local mouse = { x = -100, y = -100 }
local scroll = { x = 0, y = 0 }
_G.Input = {
  GetPressed = function (key) return pressed[key] == true end,
  GetDown = function (key) return down[key] == true end,
  GetValue = function (key) return values[key] or 0 end,
  GetMousePosition = function () return mouse end,
  GetMouseScroll = function () return scroll end,
}
local engineTime = 1
_G.Engine = { GetTime = function () return engineTime end }
_G.DrawEx = { GetAlpha = function () return 1 end }

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end
local function finish ()
  if failures == 0 then print(string.format('holo input: %d checks passed', checks)); os.exit(0) end
  print(string.format('holo input: %d/%d checks failed', failures, checks)); os.exit(1)
end
local function clearInput ()
  pressed, down, values = {}, {}, {}
  mouse, scroll = { x = -100, y = -100 }, { x = 0, y = 0 }
end

local loaded, HoloGraph = pcall(require, 'UI.HoloGraph')
check('HoloGraph module loads', loaded, HoloGraph)
if not loaded then finish() end

local leaf = { id = 'rate', label = 'Fire Rate', editable = true, value = 7.25,
  getValue = function () return 7.25 end,
  setValue = function (_, value) leaf.value = value; return true end }
local ship = { id = 'ship', label = 'Falcon', childLayout = 'cardinal', children = {
  { id = 'inventory', label = 'Inventory', childLayout = 'radial', children = {
    { id = 'ore', label = 'Ore', getValue = function () return 12 end },
  } },
  { id = 'hardpoints', label = 'Hardpoints', childLayout = 'radial', children = { leaf } },
} }
local region = { id = 'region', label = 'Region', childLayout = 'spatial',
  preview = { layout = 'spatial', orbit = true }, children = {
  { id = 'system', label = 'System', wx = 100, wz = -50, childLayout = 'spatial', children = { ship } },
} }
local rootNode = { id = 'root', label = 'Cluster', childLayout = 'cardinal', children = {
  region, { id = 'other', label = 'Other', children = {} },
} }

local graph = HoloGraph.Create(rootNode)
check('construction initializes a full-screen graph', graph.context.id == rootNode.id
  and graph.context ~= rootNode and #graph.activeNodes == 2 and graph.enabledT == 1)
local scratchChild = { id = 'scratch', label = 'Original', wx = 10,
  children = { { id = 'nested', label = 'Nested' } } }
local scratchRoot = { id = 'scratch-root', children = { scratchChild } }
local snapshotGraph = HoloGraph.Create(scratchRoot)
scratchChild.label, scratchChild.wx = 'Mutated', 999
scratchChild.children[1].id = 'mutated-nested'
scratchRoot.children[2] = { id = 'later', label = 'Later' }
local snapChild = snapshotGraph.context.children[1]
check('provider scratch records and arrays are snapshotted on entry',
  snapChild ~= scratchChild and snapChild.label == 'Original' and snapChild.wx == 10
    and #snapshotGraph.context.children == 1 and snapChild.children[1].id == 'nested')
graph.selectedId = graph.activeNodes[1].id
check('selected visual and data are exposed to detail panels',
  graph:getSelectedVis() == graph.activeNodes[1]
    and graph:getSelectedNode() == graph.context.children[1])
graph.selectedId = nil
check('preview descriptors retain stable child ids',
  graph.activeNodes[1].previews and graph.activeNodes[1].previews[1]
  and graph.activeNodes[1].previews[1].id == region.children[1].id)
check('orbit-only preview descriptors retain child world coordinates',
  graph.activeNodes[1].previewSource.points[1].x == 100
    and graph.activeNodes[1].previewSource.points[1].z == -50,
  string.format('%.1f, %.1f', graph.activeNodes[1].previewSource.points[1].x,
    graph.activeNodes[1].previewSource.points[1].z))

clearInput(); pressed[Button.Keyboard.Tab] = true
local beforeLayout = graph.layoutMode
graph:inputFocused({ dt = 0.016 })
graph:input({ dt = 0.016 })
check('focused plus root dispatch cycles exactly one layout',
  graph.layoutMode ~= beforeLayout and graph.layoutMode == 'rectilinear',
  tostring(beforeLayout) .. ' -> ' .. tostring(graph.layoutMode))

clearInput(); pressed[Button.Keyboard.N1] = true
graph:drillInto(graph.activeNodes[1])
graph:drillInto(graph.activeNodes[1])
graph:drillInto(graph.activeNodes[1])
graph:drillInto(graph.activeNodes[2])
graph:drillInto(graph.activeNodes[1])
check('drilling into an editable leaf opens the inline editor',
  graph.editNode and graph.editNode.id == leaf.id and graph.editBuffer == '7.25',
  tostring(graph.context.label) .. ':' .. #graph.stack .. ':' .. tostring(graph.editNode))
graph:inputFocused({ dt = 0.016 })
graph:input({ dt = 0.016 })
check('editor characters are not duplicated by focus traversal',
  graph.editBuffer == '7.251', graph.editBuffer)

clearInput(); pressed[Button.Keyboard.Escape] = true
graph:input({ dt = 0.016 })
check('editor Escape is consumed without drilling back',
  graph.editNode == nil and graph.inputConsumed == true and #graph.stack == 4)
graph:drillOut()

clearInput(); graph.hoveredId = graph.activeNodes[1].id
pressed[Button.Gamepad.A] = true
local stackBefore = #graph.stack
graph:input({ dt = 0.016 })
check('gamepad A drills into the hovered node', #graph.stack == stackBefore + 1,
  tostring(graph.context.label) .. ':' .. stackBefore .. ':' .. #graph.stack)

clearInput(); pressed[Button.Gamepad.B] = true
graph:input({ dt = 0.016 })
check('gamepad B drills back one level', #graph.stack == stackBefore)

clearInput(); graph.hoveredId = '__parent'; pressed[Button.Keyboard.Return] = true
graph:input({ dt = 0.016 })
check('Return activates the parent breadcrumb', #graph.stack == stackBefore - 1)

clearInput(); scroll.y = 3
local zoom = graph.cam.targetZoom
graph:input({ dt = 0.016 })
check('wheel input is ignored outside the widget', graph.cam.targetZoom == zoom)

clearInput(); pressed[Button.Keyboard.F3] = true
graph:input({ dt = 0.016 })
check('F3 applies the 25-degree holographic tilt preset',
  math.abs(graph.cam.targetPitch - 0.436332) < 1e-5)
clearInput(); pressed[Button.Keyboard.F1] = true
graph:input({ dt = 0.016 })
check('F1 restores the flat zero-degree preset', graph.cam.targetPitch == 0)

clearInput(); graph.cam.targetZoom = 1.7; graph.focusId = graph.activeNodes[1].id
graph:drillInto(graph.activeNodes[1])
graph.cam.targetZoom = 2.4
graph:drillOut()
check('drill/back restores camera target and focus',
  graph.cam.targetZoom == 1.7 and graph.focusId ~= nil)

clearInput(); local expectedPreviewId = graph.activeNodes[1].previews[1].id
graph:drillInto(graph.activeNodes[1])
check('drilled children begin at preview scale', graph.activeNodes[1].scale == 0.12)
local previewIds = {}
for i = 1, #graph.activeNodes do previewIds[graph.activeNodes[i].id] = true end
check('preview points become the drilled child identities',
  previewIds[expectedPreviewId] == true)

-- Camera/input regressions found by read-only review.
local directionGraph = HoloGraph.Create({ id = 'directions', childLayout = 'cardinal',
  children = {
    { id = 'up', label = 'Up' }, { id = 'right', label = 'Right' },
    { id = 'down', label = 'Down' }, { id = 'left', label = 'Left' },
  } })
directionGraph:onUpdate({ dt = 0.016 })
clearInput(); values[Button.Gamepad.LStickY] = 1
directionGraph:gamepadSelection()
check('positive-up gamepad Y selects the upper screen node',
  directionGraph.hoveredId == 'up', tostring(directionGraph.hoveredId))

local panGraph = HoloGraph.Create(rootNode)
panGraph.cam.x, panGraph.cam.y = 123, -45
panGraph.cam.targetZoom = 1.4
panGraph.focusId = panGraph.activeNodes[1].id
panGraph:drillInto(panGraph.activeNodes[1])
panGraph.cam.x, panGraph.cam.y = 999, 888
panGraph:drillOut()
check('drill/back restores camera pan and target zoom',
  panGraph.cam.x == 123 and panGraph.cam.y == -45
    and panGraph.cam.targetZoom == 1.4,
  string.format('%.1f,%.1f zoom %.2f', panGraph.cam.x, panGraph.cam.y,
    panGraph.cam.targetZoom))

local dragGraph = HoloGraph.Create(rootNode)
dragGraph:drillInto(dragGraph.activeNodes[1])
local dragStack = #dragGraph.stack
local yawBefore = dragGraph.cam.targetYaw
clearInput(); mouse = { x = 500, y = 400 }; down[Button.Mouse.Right] = true
dragGraph:input({ dt = 0.016, focus = dragGraph })
for _ = 1, 3 do
  mouse.x = mouse.x + 2
  dragGraph:input({ dt = 0.016, focus = dragGraph })
end
check('slow right drags accumulate into tilt instead of clicks',
  math.abs(dragGraph.cam.targetYaw - yawBefore - 0.036) < 1e-6,
  string.format('yaw delta %.4f', dragGraph.cam.targetYaw - yawBefore))
down[Button.Mouse.Right] = false
dragGraph:input({ dt = 0.016, focus = dragGraph })
check('a classified right drag does not drill back on release',
  #dragGraph.stack == dragStack, tostring(#dragGraph.stack))

local editorGraph = HoloGraph.Create(rootNode)
editorGraph:drillInto({ data = leaf })
clearInput(); pressed[Button.Gamepad.B] = true
editorGraph:input({ dt = 0.016, focus = editorGraph })
check('gamepad B cancels the numeric editor without drilling back',
  editorGraph.editNode == nil and editorGraph.inputConsumed == true)

editorGraph:drillInto({ data = leaf })
editorGraph.editBuffer = 'not-a-number'
clearInput(); pressed[Button.Keyboard.Return] = true
editorGraph:input({ dt = 0.016, focus = editorGraph })
check('invalid numeric edits keep the editor open with an error',
  editorGraph.editNode == leaf and editorGraph.editError ~= nil,
  tostring(editorGraph.editError))

local rejected = { id = 'rejected', label = 'Rejected', editable = true, value = 3 }
rejected.getValue = function () return rejected.value end
rejected.setValue = function () return false end
editorGraph:drillInto({ data = rejected })
editorGraph.editBuffer = '8'
clearInput(); pressed[Button.Keyboard.Return] = true
editorGraph:input({ dt = 0.016, focus = editorGraph })
check('rejected edits keep the editor open and preserve the old value',
  editorGraph.editNode == rejected and rejected.value == 3
    and editorGraph.editError ~= nil)
editorGraph:drillOut()

local readOnly = { id = 'readonly', label = 'Read Only', editable = true, value = 1 }
editorGraph:drillInto({ data = readOnly })
check('editable records without setters remain read-only',
  editorGraph.editNode == nil)

local routingGraph = HoloGraph.Create(rootNode)
routingGraph.inputMode = 'focused'
local routingLayout = routingGraph.layoutMode
clearInput(); pressed[Button.Keyboard.Tab] = true
routingGraph:input({ dt = 0.016, focus = {} })
check('embedded graph ignores keyboard input while a sibling has focus',
  routingGraph.layoutMode == routingLayout)
routingGraph:input({ dt = 0.016, focus = routingGraph })
check('embedded graph accepts input while it owns focus',
  routingGraph.layoutMode ~= routingLayout)

local outsideGraph = HoloGraph.Create(rootNode)
outsideGraph:drillInto(outsideGraph.activeNodes[1])
local outsideStack = #outsideGraph.stack
clearInput(); mouse = { x = -100, y = -100 }; down[Button.Mouse.Right] = true
outsideGraph:input({ dt = 0.016, focus = outsideGraph })
down[Button.Mouse.Right] = false
outsideGraph:input({ dt = 0.016, focus = outsideGraph })
check('right presses outside the widget never drill back',
  #outsideGraph.stack == outsideStack)
outsideGraph.hoveredId = outsideGraph.activeNodes[1].id
clearInput(); mouse = { x = -100, y = -100 }
outsideGraph:input({ dt = 0.016, focus = outsideGraph })
check('hover selection clears when the pointer leaves the widget',
  outsideGraph.hoveredId == nil)

local selectionGraph = HoloGraph.Create(rootNode)
selectionGraph.selectedId = selectionGraph.activeNodes[1].id
selectionGraph.hoveredId = nil
local selectionStack = #selectionGraph.stack
clearInput(); mouse = { x = -100, y = -100 }; pressed[Button.Gamepad.A] = true
selectionGraph:input({ dt = 0.016, focus = selectionGraph })
check('gamepad confirm retains the last selection after mouse hover clears',
  #selectionGraph.stack == selectionStack + 1)

local clickGraph = HoloGraph.Create({ id = 'click-root', children = { region } })
clickGraph:onUpdate({ dt = 0.016 })
local clickVis = clickGraph.activeNodes[1]
engineTime = 10
clearInput(); mouse = { x = clickVis._sx, y = clickVis._sy }; pressed[Button.Mouse.Left] = true
clickGraph:input({ dt = 0.016, focus = clickGraph })
check('single click selects a drillable node without drilling',
  clickGraph.selectedId == clickVis.id and #clickGraph.stack == 0)
clearInput(); engineTime = 10.1; mouse = { x = clickVis._sx, y = clickVis._sy }
pressed[Button.Mouse.Left] = true
clickGraph:input({ dt = 0.016, focus = clickGraph })
check('double click drills into the selected node',
  #clickGraph.stack == 1 and clickGraph.context.id == region.id)

local manyChildren = {}
for i = 1, 100 do
  manyChildren[i] = { id = 'many_' .. i, label = 'Child ' .. i }
end
local previewGraph = HoloGraph.Create({ id = 'preview-root', children = {
  { id = 'many', label = 'Many Children', children = manyChildren },
} })
local manyVis = previewGraph.activeNodes[1]
check('preview snapshots cap stored child points',
  manyVis.previewSource and #manyVis.previewSource.points == 32
    and #manyVis.previews == 20,
  manyVis.previewSource and (#manyVis.previewSource.points .. ' cached / '
    .. #manyVis.previews .. ' drawn'))
previewGraph.cam.zoom = 0.4
previewGraph:onUpdate({ dt = 0.016 })
check('zooming out reduces preview detail', #manyVis.previews == 8)
previewGraph.cam.zoom = 2.0
previewGraph:onUpdate({ dt = 0.016 })
check('zooming in restores additional preview detail', #manyVis.previews == 32)

local fieldRoot = { id = 'field-root', childLayout = 'spatial', children = {
  { id = 'station', label = 'Station', wx = -500, wz = 0 },
  { id = 'rock_1', label = 'Rock 1', major = false, wx = 100, wz = 0 },
  { id = 'rock_2', label = 'Rock 2', major = false, wx = 180, wz = 80 },
  { id = 'rock_3', label = 'Rock 3', major = false, wx = -120, wz = 140 },
} }
local fieldGraph = HoloGraph.Create(fieldRoot)
check('minor children leave the major graph and enter the field layer',
  fieldGraph.field and #fieldGraph.activeNodes == 1 and #fieldGraph.field.points == 3)
if fieldGraph.field then
  fieldGraph.cam.zoom = 0.5
  fieldGraph:onUpdate({ dt = 0.016 })
  check('far field zoom renders clusters only',
    #fieldGraph.fieldState.points == 0 and #fieldGraph.fieldState.clusters > 0)
  fieldGraph.selectedId = 'rock_2'
  fieldGraph:onUpdate({ dt = 0.016 })
  local selectedField = fieldGraph:getSelectedVis()
  check('selected minor is promoted from the field at far zoom',
    selectedField and selectedField.id == 'rock_2' and selectedField.isFieldPoint)
  fieldGraph.cam.zoom = 2.0
  fieldGraph.selectedId = nil
  fieldGraph:onUpdate({ dt = 0.016 })
  check('close field zoom unpacks selectable points',
    #fieldGraph.fieldState.points == 3 and #fieldGraph.fieldState.clusters == 0)
  local point = fieldGraph.fieldState.points[1]
  check('field points participate in hit testing and selection',
    fieldGraph:hitTest(point._sx, point._sy) == point
      and fieldGraph:getSelectedNode() == nil)
  fieldGraph.selectedId = point.id
  check('selected field data is exposed to the info panel',
    fieldGraph:getSelectedNode() == point.data)
end

finish()
