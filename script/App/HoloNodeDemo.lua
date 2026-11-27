local HoloGraph = require('UI.HoloGraph')
local HoloInfoPanel = require('UI.HoloInfoPanel')

local HoloNodeDemo = Application()

local function findNode (nodes, id)
  for i = 1, #nodes do
    if nodes[i].id == id then return nodes[i] end
  end
  return nil
end

local function demoKind (node)
  local id = node.id or ''
  local label = string.lower(node.label or '')
  if id:find('_rock_', 1, true) then return 'asteroid' end
  if id:find('_rig', 1, true) or label:find('rig', 1, true)
    or label:find('station', 1, true) then return 'station' end
  if id:find('_hp', 1, true) then return 'system' end
  if id:find('_inv', 1, true) or label:find('inventory', 1, true) then return 'inventory' end
  if id:find('_research', 1, true) or id:find('tech_', 1, true)
    or label:find('research', 1, true) then return 'research' end
  if id:find('_type', 1, true) then return 'object' end
  if id:find('_you', 1, true) or id:find('_npc', 1, true)
    or label:find('falcon', 1, true) or label:find('harpy', 1, true)
    or label:find('viper', 1, true) then return 'ship' end
  if id:find('wep_', 1, true) or label:find('laser', 1, true)
    or label:find('turret', 1, true) then return 'weapon' end
  if id:match('^reg_') then return 'region' end
  if id:match('^sys_') then return 'system' end
  return 'object'
end

local DEMO_DESCRIPTIONS = {
  region = 'A named region containing linked star systems, routes, and points of interest.',
  system = 'A live star-system view containing planets, stations, ships, and resource fields.',
  station = 'An industrial platform providing docking, refining, and commodity-market services.',
  ship = 'A spacecraft with installed systems, hardpoints, cargo, and technology metadata.',
  asteroid = 'A resource-rich asteroid with a deterministic composition and finite deposit.',
  weapon = 'An installed weapon module with editable performance and munition parameters.',
  inventory = 'A cargo hold containing live quantities of resources, equipment, and consumables.',
  research = 'A technology branch showing variants, modifiers, and unlocked specializations.',
  object = 'A selectable object in the Holo graph with live metadata and context actions.',
}

local function decorateDemoNode (node)
  local kind = demoKind(node)
  node.cat = kind
  if not node.info then
    local stats = {}
    if node.factory then
      stats[#stats + 1] = { label = 'Production', getValue = function ()
        return node.factory.running and 'Running' or 'Idle' end }
      stats[#stats + 1] = { label = 'Market', value = 'Open' }
    else
      if node.getValue then stats[#stats + 1] = { label = 'Value', getValue = node.getValue } end
      if node.children then stats[#stats + 1] = { label = 'Entries', value = tostring(#node.children) } end
      stats[#stats + 1] = { label = 'Class', value = kind }
    end
    node.info = {
      title = node.label or node.id or 'Object',
      subtitle = node.sublabel or string.upper(kind),
      description = DEMO_DESCRIPTIONS[kind] or DEMO_DESCRIPTIONS.object,
      preview = kind,
      stats = stats,
    }
  end
  if not node.actions then
    local actions = {}
    local function add (id, label, submenu, enabled, reason)
      actions[#actions + 1] = { id = id, label = label, submenu = submenu,
        enabled = enabled, reason = reason }
    end
    local hasChildren = node.children and #node.children > 0
    if kind == 'station' then
      add('goto', 'Goto')
      add('dock', 'Dock')
      add('trade', 'Trade', { title = 'Commodity Exchange', actions = {
        { id = 'buy_energy', label = 'Buy Energy Cells', detail = '18 cr' },
        { id = 'buy_parts', label = 'Buy Machine Parts', detail = '24 cr' },
        { id = 'sell_ore', label = 'Sell Rochalite Ore', detail = '14 cr' },
        { id = 'sell_isotopes', label = 'Sell Isotopes', detail = '22 cr' },
      } })
      add('factory', 'Factory', { title = node.factory and node.factory.name or 'Production', actions = {
        { id = 'view_inputs', label = 'View Inputs' },
        { id = 'view_outputs', label = 'View Outputs' },
        { id = 'start_production', label = 'Start Production' },
        { id = 'stop_production', label = 'Stop Production' },
      } })
    elseif kind == 'ship' then
      if hasChildren then add('drill', 'Inspect Ship') end
      add('goto', 'Goto')
      add('target', 'Target')
      add('hail', 'Hail')
    elseif kind == 'asteroid' then
      add('goto', 'Goto')
      add('scan', 'Scan')
      add('mine', 'Mine')
      add('composition', 'Composition', { title = 'Asteroid Composition', actions = {
        { id = 'view_rochalite', label = 'Rochalite Deposit' },
        { id = 'view_silicates', label = 'Silicate Trace' },
        { id = 'view_ice', label = 'Water Ice Trace' },
      } })
    elseif kind == 'system' then
      if hasChildren then add('drill', 'Open System') end
      add('goto', 'Goto')
      add('scan', 'Scan')
      add('jumpgates', 'Jumpgates', { title = 'Jumpgate Routes', actions = {
        { id = 'route_1', label = 'Aurelia Hub' },
        { id = 'route_2', label = 'Kora Belt' },
        { id = 'route_3', label = 'Nyx Frontier' },
      } })
    elseif kind == 'region' then
      if hasChildren then add('drill', 'Open Region') end
      add('scan', 'Scan')
      add('routes', 'Routes', { title = 'Regional Routes', actions = {
        { id = 'route_tyl', label = 'Tyle Sprawl' },
        { id = 'route_aur', label = 'Aurelia Hub' },
        { id = 'route_kora', label = 'Kora Belt' },
      } })
    elseif kind == 'weapon' then
      add('configure', 'Configure')
      if node.editable then add('edit', 'Edit Value') end
      add('reload', 'Reload')
    elseif kind == 'inventory' then
      if hasChildren then add('drill', 'Open Cargo') end
      add('use', 'Use / Equip')
      add('drop', 'Drop')
    elseif kind == 'research' then
      if hasChildren then add('drill', 'Open Research') end
      add('research', 'Research')
      add('modifiers', 'View Modifiers', { title = 'Technology Modifiers', actions = {
        { id = 'modifier_positive', label = 'Positive Modifiers' },
        { id = 'modifier_negative', label = 'Tradeoffs' },
      } })
    elseif node.editable then
      add('edit', 'Edit Value')
    elseif hasChildren then
      add('drill', 'Inspect')
    end
    node.actions = actions
  end
  if node.children then
    for i = 1, #node.children do decorateDemoNode(node.children[i]) end
  end
end

function HoloNodeDemo:anyScreenOpen ()
  return true
end

local SCAN_RANGE = 3000
local SERVICE_RANGE = 1600
local RANGE_REASON = 'You are not within range to perform action.'

function HoloNodeDemo:updateActionAvailability (node)
  if not node or not node.actions then return end
  local pos = self.mockPlayerPos or { x = 400, y = 0, z = 1200 }
  local nx, ny, nz = node.wx or node.x or 0, node.wy or node.y or 0, node.wz or node.z or 0
  local distance = math.sqrt((nx - pos.x)^2 + (ny - pos.y)^2 + (nz - pos.z)^2)
  local changed = false
  local function apply (actions)
    for i = 1, #actions do
      local action = actions[i]
      local range
      if action.id == 'scan' then range = SCAN_RANGE
      elseif action.id == 'dock' or action.id == 'trade'
        or action.id:match('^buy_') or action.id:match('^sell_') then range = SERVICE_RANGE end
      if range then
        local enabled = distance <= range
        local reason = enabled and nil or RANGE_REASON
        if action.enabled ~= enabled or action.reason ~= reason then changed = true end
        action.enabled, action.reason = enabled, reason
      end
      if action.submenu then apply(action.submenu.actions or {}) end
    end
  end
  apply(node.actions)
  if changed and self.infoPanel and self.infoPanel.subject == node then
    self.infoPanel:rebuildActions()
  end
end

function HoloNodeDemo:onHoloAction (action, node)
  if not action or not node then return false end
  self.lastHoloAction = action.id
  local message
  if action.id == 'drill' or action.id == 'edit' then
    local vis = self.holo and self.holo:getSelectedVis()
    if vis and vis.data == node then
      local ok = self.holo:drillInto(vis)
      message = ok and ('Opening ' .. (node.label or node.id) .. '...') or 'Cannot open this node.'
    else
      message = 'Select the node before opening it.'
    end
  elseif action.id == 'goto' or action.id == 'target' then
    self.mockTarget = node
    self.mockRoute = { targetId = node.id, label = node.label or node.id }
    message = (action.id == 'goto' and 'Course set: ' or 'Target locked: ')
      .. (node.label or node.id) .. ' (mock)'
  elseif action.id == 'dock' then
    self.mockMessage = 'Dock request sent to ' .. (node.label or node.id) .. ' (mock).'
    message = self.mockMessage
  elseif action.id == 'trade' then
    self.mockMessage = 'Opening market for ' .. (node.label or node.id) .. ' (mock).'
    message = self.mockMessage
  elseif action.id == 'buy_energy' or action.id == 'buy_parts'
    or action.id == 'sell_ore' or action.id == 'sell_isotopes' then
    self.mockCredits = self.mockCredits or 18240
    self.simOre = self.simOre or 118
    self.mockEnergy = self.mockEnergy or 65
    self.mockParts = self.mockParts or 0
    self.mockIsotopes = self.mockIsotopes or 18
    if action.id == 'buy_energy' then
      if self.mockCredits >= 18 then
        self.mockCredits = self.mockCredits - 18
        self.mockEnergy = self.mockEnergy + 1
        message = 'Bought 1 Energy Cell for 18 cr.'
      else message = 'Insufficient credits.' end
    elseif action.id == 'buy_parts' then
      if self.mockCredits >= 24 then
        self.mockCredits = self.mockCredits - 24
        self.mockParts = self.mockParts + 1
        message = 'Bought 1 Machine Part for 24 cr.'
      else message = 'Insufficient credits.' end
    elseif action.id == 'sell_ore' then
      if self.simOre >= 1 then
        self.simOre = self.simOre - 1
        self.mockCredits = self.mockCredits + 14
        message = 'Sold 1 Rochalite Ore for 14 cr.'
      else message = 'No Rochalite Ore in cargo.' end
    else
      if self.mockIsotopes >= 1 then
        self.mockIsotopes = self.mockIsotopes - 1
        self.mockCredits = self.mockCredits + 22
        message = 'Sold 1 Isotope for 22 cr.'
      else message = 'No Isotopes in cargo.' end
    end
    self.mockMessage = message
  elseif action.id == 'view_inputs' or action.id == 'view_outputs' then
    local factory = node.factory or { inputs = {}, outputs = {} }
    local values = action.id == 'view_inputs' and factory.inputs or factory.outputs
    message = string.format('%s: %s', action.id == 'view_inputs' and 'Inputs' or 'Outputs',
      table.concat(values or {}, ', '))
    self.mockMessage = message
  elseif action.id == 'start_production' or action.id == 'stop_production' then
    if node.factory then
      node.factory.running = action.id == 'start_production'
      message = string.format('Refinery production %s.', node.factory.running and 'started' or 'stopped')
    else message = 'No production facility installed.' end
    self.mockMessage = message
  elseif action.id == 'unpack' then
    if self.holo and self.holo.cam then self.holo.cam.targetZoom = 1.7 end
    self.mockMessage = 'Unpacking asteroid cluster (mock).'
    message = self.mockMessage
  elseif action.id == 'mine' then
    self.mockMessage = 'Mining approach queued for ' .. (node.label or node.id) .. ' (mock).'
    message = self.mockMessage
  elseif action.id == 'scan' then
    self.mockMessage = 'Scanning ' .. (node.label or node.id) .. ' (mock).'
    message = self.mockMessage
  elseif action.id == 'hail' then
    self.mockMessage = 'Hailing ' .. (node.label or node.id) .. ' (mock).'
    message = self.mockMessage
  elseif action.id == 'configure' or action.id == 'use' or action.id == 'reload'
    or action.id == 'drop' or action.id == 'research' or action.id == 'modifier_positive'
    or action.id == 'modifier_negative' or action.id == 'view_rochalite'
    or action.id == 'view_silicates' or action.id == 'view_ice' then
    self.mockMessage = string.format('%s requested for %s (mock).', action.label or action.id,
      node.label or node.id)
    message = self.mockMessage
  elseif action.id:match('^route_') then
    self.mockRoute = { targetId = node.id, label = action.label }
    message = 'Route plotted: ' .. (action.label or action.id) .. ' (mock).'
    self.mockMessage = message
  else
    message = 'Action unavailable in the mock demo.'
  end
  if self.infoPanel and self.infoPanel.subject == node then self.infoPanel:setStatus(message) end
  return true
end

function HoloNodeDemo:updateInfoPanel ()
  if not self.infoPanel then return end
  local node = self.holo:getSelectedNode()
  if self.infoDismissedId and (not node or node.id ~= self.infoDismissedId) then
    self.infoDismissedId = nil
  end
  if node and node.id ~= self.infoDismissedId then
    self:updateActionAvailability(node)
    self.infoPanel:setSubject(node)
    self.holo.infoPanelOpen = true
  else
    self.infoPanel:setSubject(nil)
    self.holo.infoPanelOpen = false
  end
end

function HoloNodeDemo:updateFonts ()
  local w = self.window:getSize()
  local scale = Math.Clamp(w.y / 900, 0.7, 1.8)
  Config.ui.font.normal = Cache.Font('Share', max(12, Math.Round(14 * scale)))
  Config.ui.font.normalSize = max(12, Math.Round(14 * scale))
  Config.ui.font.title = Cache.Font('Exo2Bold', max(12, Math.Round(16 * scale)))
  Config.ui.font.titleSize = max(12, Math.Round(16 * scale))
  self.holoFontScale = scale
  if self.holo and self.holo.renderer then self.holo.renderer.fontScale = scale end
end

function HoloNodeDemo:onInit ()
  self:updateFonts()
  Input.SetMouseVisible(false)
  Directory.Create('./screenshot')
  self.canvas = UI.Canvas()
  self.canvas.showCursor = true
  self.holo = HoloGraph.Create(self:buildDemoGraph())
  self.holo.renderer.fontScale = self.holoFontScale
  self.canvas:add(self.holo)
  self.infoPanel = HoloInfoPanel.Create({
    onAction = function (action, node) self:onHoloAction(action, node) end,
    onClose = function ()
      local node = self.holo:getSelectedNode()
      self.infoDismissedId = node and node.id or nil
    end,
  })
  self.canvas:add(self.infoPanel, false)
end

function HoloNodeDemo:onResize ()
  self:updateFonts()
end

function HoloNodeDemo:onInput ()
  self.canvas:input()
  if Input.GetPressed(Button.Keyboard.Escape) and not self.holo.inputConsumed then
    if not self.holo:drillOut() then self:quit() end
  end
  self.holo.inputConsumed = false
end

function HoloNodeDemo:onUpdate (dt)
  self.simOre = (self.simOre or 118) + dt * 1.5
  self.canvas:update(dt)
  self:updateInfoPanel()
  if os.getenv('PHX_HOLOTEST') then self:updateHoloTest(dt) end
end

function HoloNodeDemo:onDraw ()
  Draw.Clear(0.01, 0.015, 0.03, 1.0)
  self.canvas:draw(self.resX, self.resY)
  if self.holoCaptureRequested then
    self.holoCaptureRequested = false
    ScreenCap()
  end
end

function HoloNodeDemo:holoTestFail (message)
  if self.holoTestFailed then return false end
  self.holoTestFailed = true
  printf('[HOLOTEST] FAIL: ' .. message)
  self:quit()
  return false
end

function HoloNodeDemo:holoTestCheck (ok, message)
  if ok then return true end
  return self:holoTestFail(message)
end

function HoloNodeDemo:updateHoloTest (dt)
  if self.holoTestFailed then return end
  self.holoTestT = (self.holoTestT or 0) + dt
  local t = self.holoTestT
  local graph = self.holo
  local function selectPreview (id)
    local vis = findNode(graph.activeNodes, id)
    if not vis then return false end
    graph.focusId, graph.selectedId = id, id
    self:updateInfoPanel()
    return self.infoPanel and self.infoPanel.subject == vis.data
  end
  local function actionButton (id)
    for i = 1, #self.infoPanel.actionButtons do
      if self.infoPanel.actionButtons[i].action.id == id then
        return self.infoPanel.actionButtons[i]
      end
    end
  end
  if self.holoCaptureAt and t >= self.holoCaptureAt then
    self.holoCaptureAt = nil
    self.holoCaptureRequested = true
  end
  if self.holoTestStage == nil and t >= 1.0 then
    if not self:holoTestCheck(graph.context and graph.context.id == 'cluster'
      and #graph.stack == 0 and graph:setLayout('radial')
      and graph.layoutMode == 'radial', 'boot/radial layout contract failed') then return end
    if not self:holoTestCheck(selectPreview('reg_1'),
      'selected-node preview panel did not open') then return end
    self.holoTestStage = 1
    printf('[HOLOTEST] PASS: boot, radial layout, and region preview')
    self.holoCaptureAt = t + 0.35
  elseif self.holoTestStage == 1 and t >= 2.0 then
    local node = findNode(graph.activeNodes, 'reg_1')
    if not self:holoTestCheck(node and graph:drillInto(node)
      and graph.context == node.data and #graph.stack == 1,
      'drill into region failed') then return end
    self.holoTestStage = 2
    printf('[HOLOTEST] PASS: drill into region')
    self.holoCaptureAt = t + 0.35
  elseif self.holoTestStage == 2 and t >= 3.0 then
    local node = findNode(graph.activeNodes, 'sys_1')
    if not self:holoTestCheck(node and graph:drillInto(node)
      and graph.context == node.data and #graph.stack == 2,
      'drill into system failed') then return end
    graph:setTilt(math.rad(25), 0)
    if not self:holoTestCheck(math.abs(graph.cam.targetPitch - math.rad(25)) < 1e-6,
      '25-degree tilt preset failed') then return end
    local fieldPoint = graph.fieldState and graph.fieldState.points[1]
    if not self:holoTestCheck(fieldPoint ~= nil, 'asteroid field did not unpack points') then return end
    graph.selectedId = fieldPoint.id
    self:updateInfoPanel()
    if not self:holoTestCheck(self.infoPanel.subject == fieldPoint.data,
      'selected asteroid preview panel did not open') then return end
    if not self:holoTestCheck(selectPreview('sys_1_rig'),
      'station preview panel did not open') then return end
    local gotoButton = actionButton('goto')
    if gotoButton then gotoButton:click() end
    if not self:holoTestCheck(gotoButton and self.mockTarget
      and self.mockTarget.id == 'sys_1_rig', 'station Goto menu action failed') then return end
    local tradeButton = actionButton('trade')
    if tradeButton then tradeButton:click() end
    if not self:holoTestCheck(tradeButton and #self.infoPanel.menuStack == 1
      and self.infoPanel.menuTitle == 'Commodity Exchange',
      'station Trade submenu did not open') then return end
    local creditsBefore = self.mockCredits or 18240
    local oreBefore = self.simOre
    local sellButton = actionButton('sell_ore')
    if sellButton then sellButton:click() end
    if not self:holoTestCheck(sellButton and self.mockCredits == creditsBefore + 14
      and self.simOre == oreBefore - 1, 'station Sell Ore action failed') then return end
    self.holoTestStage = 3
    printf('[HOLOTEST] PASS: spatial preview and station Trade submenu')
    self.holoCaptureAt = t + 0.35
  elseif self.holoTestStage == 3 and t >= 4.0 then
    local node = findNode(graph.activeNodes, 'sys_1_you')
    if not self:holoTestCheck(node and graph:drillInto(node)
      and graph.context == node.data and #graph.stack == 3,
      'drill into player ship failed') then return end
    self.holoTestStage = 4
    printf('[HOLOTEST] PASS: ship cardinal view')
    self.holoCaptureAt = t + 0.35
  elseif self.holoTestStage == 4 and t >= 5.0 then
    local hardpoints = findNode(graph.activeNodes, 'sys_1_you_hp')
    if not self:holoTestCheck(hardpoints and graph:drillInto(hardpoints)
      and graph.context == hardpoints.data and #graph.stack == 4,
      'drill into hardpoints failed') then return end
    local weapon = findNode(graph.activeNodes, 'wep_1')
    if not self:holoTestCheck(weapon and graph:drillInto(weapon)
      and graph.context == weapon.data and #graph.stack == 5,
      'preview drill into weapon failed') then return end
    local rate = findNode(graph.activeNodes, 'rate')
    if not self:holoTestCheck(rate and graph:drillInto(rate)
      and graph.editNode == rate.data and #graph.stack == 5,
      'numeric editor did not open') then return end
    graph.editBuffer = '9.5'
    graph.hoveredId, graph.selectedId = 'rate', 'rate'
    self.holoTestStage = 5
    printf('[HOLOTEST] PASS: preview drill and live numeric editor')
    self.holoCaptureAt = t + 0.35
  elseif self.holoTestStage == 5 and t >= 6.0 then
    if not self:holoTestCheck(graph:commitEdit() and graph.editNode == nil
      and self.laserStats and self.laserStats.rate == 9.5,
      'numeric editor commit failed') then return end
    local expected = { 'sys_1_you_hp', 'sys_1_you', 'sys_1', 'reg_1', 'cluster' }
    for i = 1, #expected do
      if not self:holoTestCheck(graph:drillOut() and graph.context
        and graph.context.id == expected[i] and #graph.stack == 5 - i,
        'back step ' .. i .. ' failed') then return end
    end
    graph:setTilt(0, 0)
    graph.hoveredId, graph.selectedId = 'reg_1', 'reg_1'
    if not self:holoTestCheck(selectPreview('reg_1'),
      'restored root preview panel did not open') then return end
    self.holoTestStage = 6
    printf('[HOLOTEST] PASS: back restores root context')
    self.holoCaptureAt = t + 0.35
  elseif self.holoTestStage == 6 and t >= 7.0 then
    if not self:holoTestCheck(#graph.stack == 0 and graph.context
      and graph.context.id == 'cluster', 'final root context check failed') then return end
    self.holoTestStage = 7
    printf('[HOLOTEST] ALL CHECKS PASSED')
    self:quit()
  end
end

function HoloNodeDemo:buildDemoGraph ()
  self.simOre = 118
  self.mockPlayerPos = { x = 400, y = 0, z = 1200 }
  self.laserStats = { r = 0.2, g = 1.0, b = 0.3, rate = 7.25, spread = 0.065,
    damage = 40, range = 1000 }

  local function field (id, name, key)
    return {
      id = id, label = name, editable = true,
      color = { r = 0.30, g = 0.80, b = 1.00, a = 0.95 },
      getValue = function () return self.laserStats[key] end,
      setValue = function (value) self.laserStats[key] = value; return true end,
    }
  end

  local pulseLaser = {
    id = 'wep_1', label = 'Pulse Laser Mk.II', sublabel = 'WeaponImpl',
    childLayout = 'radial',
    color = { r = 1.0, g = 0.55, b = 0.22, a = 0.95 },
    children = {
      field('rate', 'Fire Rate', 'rate'),
      field('spread', 'Spread', 'spread'),
      field('damage', 'Damage', 'damage'),
      field('range', 'Range', 'range'),
      {
        id = 'munition', label = 'Munition', sublabel = 'Color & Light',
        childLayout = 'cardinal',
        color = { r = 1.0, g = 0.55, b = 0.22, a = 0.95 },
        children = {
          field('col_x', 'Color R (x)', 'r'),
          field('col_y', 'Color G (y)', 'g'),
          field('col_z', 'Color B (z)', 'b'),
        },
      },
    },
  }

  local function makeShipNode (id, name, wx, wy, wz, isMiner)
    return {
      id = id, label = name, sublabel = isMiner and 'Mining Capital' or 'Interceptor',
      color = not isMiner and { r = 1.0, g = 0.72, b = 0.18, a = 1.0 } or nil,
      wx = wx, wy = wy, wz = wz, radius = 18, childLayout = 'cardinal',
      children = {
        {
          id = id .. '_inv', label = 'Inventory', sublabel = 'Cargo Hold',
          childLayout = 'radial',
          children = {
            { id = id .. '_ore', label = 'Rochalite Ore',
              getValue = function () return isMiner and math.floor(self.simOre) or 42 end },
            { id = id .. '_iso', label = 'Isotopes', sublabel = 'x 18' },
            { id = id .. '_nrg', label = 'Energy Cells', sublabel = 'x 65' },
            { id = id .. '_ag', label = 'Silver', sublabel = 'x 12' },
          },
        },
        {
          id = id .. '_hp', label = 'Hardpoints', sublabel = '6 Sockets',
          childLayout = 'radial',
          color = { r = 1.0, g = 0.55, b = 0.22, a = 0.95 },
          children = {
            pulseLaser,
            { id = id .. '_t2', label = 'Pulse Turret Mk.II', sublabel = 'Turret #2' },
            { id = id .. '_th1', label = 'Ion Thruster', sublabel = 'Thruster #1' },
            { id = id .. '_th2', label = 'Ion Thruster', sublabel = 'Thruster #2' },
            { id = id .. '_shd', label = 'Shield Generator', sublabel = 'Capacitor 100' },
            { id = id .. '_scn', label = 'Deep Scanner', sublabel = 'Range 4000u' },
          },
        },
        {
          id = id .. '_research', label = 'Research Tree', sublabel = 'Procedural Tech',
          childLayout = 'radial',
          children = {
            {
              id = 'tech_fighter', label = 'Fighter Chassis', sublabel = 'Base Blueprint',
              childLayout = 'radial',
              children = {
                { id = 'tech_heavy', label = 'Heavy Fighter', sublabel = 'Researched Variant',
                  modifiers = {
                    { good = true, text = '+20% Hull Integrity' },
                    { good = false, text = '+25% Hull Mass (Slower)' },
                  } },
                { id = 'tech_mil', label = 'Military Fighter', sublabel = 'Researched Variant',
                  childLayout = 'cardinal',
                  modifiers = {
                    { good = true, text = '+1 Turret Hardpoint' },
                    { good = false, text = '+25% Hull Mass' },
                  },
                  children = {
                    { id = 'tech_hmf', label = 'Heavy Military Fighter',
                      sublabel = 'Tier-2 Specialization',
                      modifiers = {
                        { good = true, text = '+1 Turret Hardpoint' },
                        { good = true, text = '+20% Hull Integrity' },
                        { good = false, text = '+25% Hull Mass' },
                        { good = false, text = '-1 Thruster Hardpoint' },
                      } },
                  } },
              },
            },
            { id = 'tech_extract', label = 'Efficient Extraction',
              sublabel = 'Mining Specialization',
              modifiers = {
                { good = true, text = '+25% Mining Yield Rate' },
                { good = false, text = '+15% Capacitor Drain' },
              } },
          },
        },
        {
          id = id .. '_type', label = 'Type Info', sublabel = 'Live Statistics',
          childLayout = 'cardinal',
          children = {
            { id = id .. '_hull', label = 'Hull Integrity', sublabel = '2500 / 2500' },
            { id = id .. '_shield', label = 'Shield', sublabel = '2500 / 2500' },
            { id = id .. '_mass', label = 'Mass', sublabel = '50,000 kg' },
            { id = id .. '_speed', label = 'Top Speed', sublabel = '500 u/s' },
          },
        },
      },
    }
  end

  local rng = RNG.Create(42):managed()
  local function makeSystem (id, name, wx, wz)
    local bodies = {
      { id = id .. '_planet', label = name .. ' Prime', sublabel = 'Planet',
        wx = -4200, wy = 200, wz = -3100, radius = 24 },
      { id = id .. '_rig', label = name .. ' Mining Rig', sublabel = 'Station / Factory',
        wx = 1800, wy = -100, wz = 900, radius = 18, childLayout = 'radial',
        factory = { name = 'Refinery', running = false,
          inputs = { '2 Iron', '1 Copper' }, outputs = { '1 Machine Parts' } },
        children = {
          { id = id .. '_bid1', label = 'Buy: Rochalite Ore', sublabel = '14 cr / unit (200)' },
          { id = id .. '_bid2', label = 'Buy: Isotopes', sublabel = '22 cr / unit (200)' },
          { id = id .. '_ask1', label = 'Sell: Energy Cells', sublabel = '18 cr / unit (50)' },
        } },
      makeShipNode(id .. '_you', 'Falcon (YOU)', 400, 0, 1200, false),
      makeShipNode(id .. '_npc1', 'Ruby Harpy', 2900, 150, -1800, true),
      makeShipNode(id .. '_npc2', 'Prototype Viper', -1500, -120, 2600, true),
    }
    local asteroidCount = 18
    if id == 'sys_1' then
      asteroidCount = tonumber(os.getenv('PHX_HOLO_ASTEROIDS') or '') or 18
      asteroidCount = math.min(10000, math.max(0, math.floor(asteroidCount)))
    end
    for r = 1, asteroidCount do
      local a = r / asteroidCount * math.pi * 1.3
      local distance = 3600 + (rng:getUniform() - 0.5) * 600
      bodies[#bodies + 1] = {
        id = id .. '_rock_' .. r, label = 'Rich Asteroid #' .. r,
        sublabel = 'Rochalite Deposit', major = false,
        wx = math.cos(a) * distance, wy = (rng:getUniform() - 0.5) * 300,
        wz = math.sin(a) * distance, radius = 8,
      }
    end
    local points = {}
    for i = 1, #bodies do
      points[i] = { id = bodies[i].id, x = bodies[i].wx or 0,
        y = bodies[i].wy or 0, z = bodies[i].wz or 0 }
    end
    return {
      id = id, label = name, sublabel = 'Star System',
      wx = wx, wy = 0, wz = wz, radius = 22, childLayout = 'spatial',
      preview = { layout = 'spatial', points = points },
      children = bodies,
    }
  end

  local region = {
    id = 'reg_1', label = 'KAMW-3533X', sublabel = '5 Star Systems',
    childLayout = 'spatial',
    preview = { layout = 'spatial', orbit = true },
    edges = {
      { 'sys_1', 'sys_2' }, { 'sys_2', 'sys_3' }, { 'sys_2', 'sys_4' },
      { 'sys_4', 'sys_5' }, { 'sys_1', 'sys_4' },
    },
    children = {
      makeSystem('sys_1', 'Tyle Sprawl', -320, -140),
      makeSystem('sys_2', 'Aurelia Hub', 0, 0),
      makeSystem('sys_3', 'Vespera Reach', 340, -110),
      makeSystem('sys_4', 'Kora Belt', 110, 260),
      makeSystem('sys_5', 'Nyx Frontier', 390, 220),
    },
  }

  local root = {
    id = 'cluster', label = 'Kinhuscant Cluster', sublabel = 'Nodal UI Prototype',
    childLayout = 'cardinal',
    children = {
      region,
      { id = 'reg_2', label = 'Ophiuchus Veil', sublabel = 'Unexplored Region',
        childLayout = 'radial',
        children = { makeSystem('sys_6', 'Cinder Gate', 0, 0) } },
      { id = 'reg_3', label = 'Zenith Core', sublabel = 'Industrial Sector',
        childLayout = 'radial',
        children = { makeSystem('sys_7', 'Forge Alpha', 0, 0) } },
    },
  }

  local stress = tonumber(os.getenv('PHX_HOLO_STRESS') or '') or 0
  if stress > 0 then
    root.childLayout = 'radial'
    for i = 1, math.min(5000, math.floor(stress)) do
      root.children[#root.children + 1] = {
        id = 'stress_' .. i, label = 'Stress Node ' .. i,
        sublabel = string.format('%.1f', i * 0.25), radius = 8,
      }
    end
  end
  decorateDemoNode(root)
  return root
end

return HoloNodeDemo
