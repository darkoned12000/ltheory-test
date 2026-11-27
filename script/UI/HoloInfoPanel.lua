local Container = require('UI.Container')
local Panel = require('UI.Panel')
local Button = require('UI.Button')
local DrawEx = require('UI.DrawEx')
local HoloPreview = require('UI.HoloPreview')
local HoloProvider = require('UI.HoloProvider')

local InfoPanel = {}
InfoPanel.__index = InfoPanel
setmetatable(InfoPanel, Panel)

local HoloButton = {}
HoloButton.__index = HoloButton
setmetatable(HoloButton, Button)

local CYAN = { r = 0.30, g = 0.78, b = 1.00, a = 0.95 }
local DIM = { r = 0.18, g = 0.42, b = 0.62, a = 0.75 }
local CRIMSON = { r = 1.00, g = 0.30, b = 0.40, a = 0.95 }
local TEXT = { r = 0.86, g = 0.94, b = 1.00, a = 0.96 }
local MUTED = { r = 0.55, g = 0.72, b = 0.84, a = 0.88 }
local GREEN = { r = 0.35, g = 0.95, b = 0.55, a = 0.95 }
local MAX_ACTIONS = 4

function HoloButton:click (state)
  if self.action and self.action.enabled == false then return end
  Button.click(self, state)
end

function HoloButton:onDraw (focus, active)
  local x, y, sx, sy = self:getRectGlobal()
  local disabled = self.action and self.action.enabled == false
  local hot = focus == self or active == self
  local border = disabled and DIM or (hot and CRIMSON or CYAN)
  local fill = disabled and { r = 0.02, g = 0.04, b = 0.07, a = 0.90 }
    or { r = 0.04, g = 0.13, b = 0.20, a = 0.94 }
  DrawEx.Panel(x, y, sx, sy, fill, 0.92)
  DrawEx.Line(x, y, x + sx, y, border)
  DrawEx.Line(x + sx, y, x + sx, y + sy, border)
  DrawEx.Line(x + sx, y + sy, x, y + sy, border)
  DrawEx.Line(x, y + sy, x, y, border)
  DrawEx.TextAlpha('Exo2Bold', self.text, 13, x + 10, y + 7, sx - 20, 18,
    disabled and 0.38 or 0.90, disabled and 0.48 or 0.96, disabled and 0.58 or 1.0,
    1, 0, 0)
  if disabled and self.action.reason then
    DrawEx.TextAlpha('Share', self.action.reason, 9, x + sx * 0.42, y + 9,
      sx * 0.54 - 10, 12, 0.55, 0.62, 0.68, 0.90, 1, 0)
  end
end

local function wrapText (text, maxChars, maxLines)
  local lines, line = {}, ''
  for word in tostring(text or ''):gmatch('%S+') do
    local candidate = line == '' and word or (line .. ' ' .. word)
    if #candidate > maxChars and line ~= '' then
      lines[#lines + 1] = line
      line = word
    else
      line = candidate
    end
  end
  if line ~= '' then lines[#lines + 1] = line end
  if #lines > maxLines then
    lines[maxLines] = lines[maxLines]:sub(1, math.max(1, maxChars - 3)) .. '...'
    for i = #lines, maxLines + 1, -1 do lines[i] = nil end
  end
  return lines
end

local function schematic (kind, x, y, w, h, time, descriptor)
  local cx, cy = x + w * 0.5, y + h * 0.5
  DrawEx.Panel(x, y, w, h, { r = 0.008, g = 0.025, b = 0.045, a = 0.96 }, 0.96)
  DrawEx.Line(x, y, x + w, y, CYAN)
  DrawEx.Line(x + w, y, x + w, y + h, CYAN)
  DrawEx.Line(x + w, y + h, x, y + h, CYAN)
  DrawEx.Line(x, y + h, x, y, CYAN)

  for i = 1, 5 do
    local gx = x + 12 + (i - 1) * (w - 24) * 0.25
    DrawEx.Line(gx, y + 8, gx, y + h - 8, { r = 0.08, g = 0.25, b = 0.38, a = 0.35 })
  end
  for i = 1, 3 do
    local gy = y + 10 + (i - 1) * (h - 20) * 0.5
    DrawEx.Line(x + 8, gy, x + w - 8, gy, { r = 0.08, g = 0.25, b = 0.38, a = 0.35 })
  end

  local drewMesh = false
  if descriptor and descriptor.entity then
    drewMesh = HoloPreview.Draw(x + 8, y + 8, w - 16, h - 28, descriptor)
  end
  if not drewMesh then
    DrawEx.Ring(cx, cy, 38, CYAN)
    DrawEx.Ring(cx, cy, 25, DIM)
    if kind == 'station' or kind == 'factory' then
      local s = 30
      DrawEx.Line(cx - s, cy - s, cx + s, cy - s, CYAN)
      DrawEx.Line(cx + s, cy - s, cx + s, cy + s, CYAN)
      DrawEx.Line(cx + s, cy + s, cx - s, cy + s, CYAN)
      DrawEx.Line(cx - s, cy + s, cx - s, cy - s, CYAN)
      for i = 1, 4 do
        local a = i * math.pi * 0.5 + time * 0.08
        DrawEx.Ring(cx + math.cos(a) * 48, cy + math.sin(a) * 48, 3, GREEN)
      end
    elseif kind == 'ship' or kind == 'weapon' then
      DrawEx.Line(cx, cy - 28, cx + 24, cy + 20, CYAN)
      DrawEx.Line(cx + 24, cy + 20, cx, cy + 10, CYAN)
      DrawEx.Line(cx, cy + 10, cx - 24, cy + 20, CYAN)
      DrawEx.Line(cx - 24, cy + 20, cx, cy - 28, CYAN)
      DrawEx.Line(cx, cy - 20, cx, cy + 26, CRIMSON)
    elseif kind == 'asteroid' then
      for i = 1, 14 do
        local a = i * 2.399963229728653
        local r = 8 + (i * 17) % 42
        DrawEx.Ring(cx + math.cos(a) * r, cy + math.sin(a) * r * 0.65,
          2 + (i % 3), CYAN)
      end
    else
      for i = 1, 3 do
        local a = i * math.pi * 2 / 3 + time * 0.10
        DrawEx.Ring(cx + math.cos(a) * 48, cy + math.sin(a) * 48, 4, GREEN)
      end
    end
  end

  local scanY = y + 6 + (time * 22) % math.max(1, h - 12)
  DrawEx.Line(x + 6, scanY, x + w - 6, scanY, { r = 0.30, g = 0.85, b = 1.00, a = 0.38 })
  local caption = drewMesh and 'MESH / LIVE PREVIEW'
    or (string.upper(kind or 'object') .. ' / LIVE SCHEMATIC')
  DrawEx.TextAlpha('Share', caption, 10,
    x + 10, y + h - 18, w - 20, 14, 0.45, 0.78, 0.95, 0.85, 0, 0)
end

function InfoPanel.Create (opts)
  opts = opts or {}
  local self = setmetatable({
    children = List(),
    actionButtons = {},
    subject = nil,
    title = '',
    subtitle = '',
    description = '',
    stats = {},
    actions = {},
    menuStack = {},
    menuTitle = '',
    status = '',
    onAction = opts.onAction,
    onClose = opts.onClose,
    player = opts.player,
    originX = 0, originY = 0, x = 0, y = 0,
  }, InfoPanel)
  self:setSize(320, 430)
  self:setEState(Container.EState.Disabled)
  self.closeButton = setmetatable({
    text = 'X', action = { id = 'close', label = 'Close', enabled = true },
    originX = 0, originY = 0, x = 0, y = 0, sx = 24, sy = 24,
    fixedSX = 24, fixedSY = 24, align = false, clamp = false,
  }, HoloButton)
  self.closeButton:setOnClick(function () self:close() end)
  self.backButton = setmetatable({
    text = '< Back', action = { id = '__back', label = 'Back', enabled = true },
    originX = 0, originY = 0, x = 0, y = 0, sx = 72, sy = 24,
    fixedSX = 72, fixedSY = 24, align = false, clamp = false,
  }, HoloButton)
  self.backButton:setOnClick(function () self:menuBack() end)
  return self
end

function InfoPanel:currentActions ()
  if #self.menuStack > 0 then return self.menuStack[#self.menuStack].actions end
  return self.actions
end

function InfoPanel:activateAction (action)
  if not action or action.enabled == false then return false end
  if action.submenu then
    self.menuStack[#self.menuStack + 1] = {
      title = action.submenu.title or action.label or 'Actions',
      actions = action.submenu.actions or {},
    }
    self.menuTitle = self.menuStack[#self.menuStack].title
    self.status = ''
    self:rebuildActions()
    return true
  end
  if self.onAction then self.onAction(action, self.subject) end
  return true
end

function InfoPanel:menuBack ()
  if #self.menuStack == 0 then return false end
  self.menuStack[#self.menuStack] = nil
  self.menuTitle = #self.menuStack > 0 and self.menuStack[#self.menuStack].title or ''
  self.status = ''
  self:rebuildActions()
  return true
end

function InfoPanel:setSubject (node)
  if node == self.subject then return self end
  if node and node.entity then HoloProvider.Enrich(node, self.player) end
  self.subject = node
  self.previewDescriptor = node and node.info and node.info.preview or nil
  self.menuStack, self.menuTitle = {}, ''
  if not node then
    self.title, self.subtitle, self.description = '', '', ''
    self.stats, self.actions, self.status = {}, {}, ''
    self:setEState(Container.EState.Disabled)
    self:rebuildActions()
    return self
  end

  local info = node.info or {}
  self.title = info.title or node.label or node.id or 'Object'
  self.subtitle = info.subtitle or node.sublabel or node.cat or 'Node'
  self.description = info.description or ''
  self.stats = info.stats or {}
  self.actions = node.actions or {}
  self.status = info.status or ''
  self:setEState(Container.EState.Enabled)
  self:rebuildActions()
  return self
end

function InfoPanel:setStatus (text)
  self.status = tostring(text or '')
  return self
end

function InfoPanel:rebuildActions ()
  for i = #self.children, 1, -1 do self:removeImmediate(self.children[i]) end
  self.actionButtons = {}
  if not self.subject then return end

  self:addImmediate(self.closeButton)
  if #self.menuStack > 0 then self:addImmediate(self.backButton) end
  local actions = self:currentActions()
  local count = math.min(#actions, MAX_ACTIONS)
  for i = 1, count do
    local action = actions[i]
    local button = setmetatable({
      text = action.label or action.id,
      action = action,
      originX = 0, originY = 0, x = 16, y = 0, sx = 288, sy = 28,
      fixedSX = 288, fixedSY = 28, align = false, clamp = false,
    }, HoloButton)
    button:setOnClick(function () self:activateAction(action) end)
    self.actionButtons[i] = button
    self:addImmediate(button)
  end
  if #actions > MAX_ACTIONS then
    self.status = string.format('%s  (+%d more actions)', self.status, #actions - MAX_ACTIONS)
  end
end

function InfoPanel:close ()
  self:setSubject(nil)
  if self.onClose then self.onClose(self) end
  return self
end

function InfoPanel:onLayoutPos (px, py, psx, psy)
  self.sx, self.sy = self.fixedSX, self.fixedSY
  self.x = px + psx - self.sx - 20
  self.y = py + 20
end

function InfoPanel:onLayoutPosChildren ()
  local ox, oy = self:getPosGlobal()
  self.closeButton.x, self.closeButton.y = self.sx - 34, 8
  self.closeButton:layoutPos(ox, oy, 0, 0, self.sx, self.sy)
  self.backButton.x, self.backButton.y = 16, 8
  self.backButton:layoutPos(ox, oy, 0, 0, self.sx, self.sy)
  local startY = self.sy - 16 - #self.actionButtons * 32
  for i = 1, #self.actionButtons do
    local button = self.actionButtons[i]
    button.x, button.y = 16, startY + (i - 1) * 32
    button:layoutPos(ox, oy, 0, 0, self.sx, self.sy)
  end
end

function InfoPanel:onDraw (focus, active)
  local node = self.subject
  if not node then return end
  local x, y, sx, sy = self:getRectGlobal()
  DrawEx.Panel(x, y, sx, sy, { r = 0.008, g = 0.020, b = 0.038, a = 0.96 }, 0.96)
  DrawEx.Line(x, y, x + sx, y, CYAN)
  DrawEx.Line(x + sx, y, x + sx, y + sy, CYAN)
  DrawEx.Line(x + sx, y + sy, x, y + sy, CYAN)
  DrawEx.Line(x, y + sy, x, y, CYAN)

  local inMenu = #self.menuStack > 0
  local titleX = inMenu and 100 or 16
  DrawEx.TextAlpha('Exo2Bold', self.title, 16, x + titleX, y + 12,
    sx - titleX - 56, 22, 0.88, 0.97, 1.0, 1, 0, 0)
  local subtitle = inMenu and (self.subtitle .. ' > ' .. self.menuTitle) or self.subtitle
  DrawEx.TextAlpha('Share', subtitle, 12, x + 16, y + 34, sx - 32, 16,
    0.40, 0.78, 0.96, 0.92, 0, 0)
  local preview = node.info and node.info.preview or nil
  local previewKind = type(preview) == 'table' and preview.kind or preview
  schematic(previewKind or node.cat or 'object',
    x + 16, y + 54, sx - 32, 120, Engine.GetTime(), preview)

  local lines = wrapText(self.description, 42, 3)
  for i = 1, #lines do
    DrawEx.TextAlpha('Share', lines[i], 12, x + 16, y + 182 + (i - 1) * 16,
      sx - 32, 16, 0.72, 0.84, 0.92, 0.92, 0, 0)
  end
  for i = 1, math.min(2, #self.stats) do
    local stat = self.stats[i]
    local value = stat.getValue and stat.getValue() or stat.value
    DrawEx.TextAlpha('Share', stat.label, 11, x + 16, y + 236 + (i - 1) * 17,
      sx * 0.5 - 20, 14, 0.45, 0.68, 0.82, 0.90, 0, 0)
    DrawEx.TextAlpha('Exo2Bold', tostring(value), 11, x + sx * 0.5, y + 236 + (i - 1) * 17,
      sx * 0.5 - 16, 14, 0.72, 0.94, 1.0, 0.96, 1, 0)
  end
  if self.status ~= '' then
    DrawEx.TextAlpha('Share', self.status, 11, x + 16, y + 274, sx - 32, 16,
      0.40, 0.95, 0.62, 0.95, 0, 0)
  end
end

return InfoPanel
