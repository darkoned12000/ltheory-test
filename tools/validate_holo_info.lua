#!/usr/bin/env luajit
-- Holo selected-node preview/action-panel contracts with only UI boundaries stubbed.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_holo_info%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

_G.List = function ()
  local list = {}
  function list:append (v) self[#self + 1] = v end
  function list:remove (v)
    for i = #self, 1, -1 do
      if self[i] == v then table.remove(self, i) end
    end
  end
  return list
end

local Container = { EState = { Enabled = 2, Disabled = 4 } }
Container.__index = Container
function Container:setEState (state) self.eState = state; self.enabledT = state == Container.EState.Enabled and 1 or 0 end
function Container:setSize (sx, sy) self.fixedSX, self.fixedSY = sx, sy; self.sx, self.sy = sx, sy end
function Container:setPos (x, y) self.x, self.y = x, y end
function Container:layoutPos (ox, oy, px, py, psx, psy)
  self.originX, self.originY = ox, oy
  if self.align ~= false then
    self.x = px + (self.alignX or 0) * (psx - self.sx)
    self.y = py + (self.alignY or 0) * (psy - self.sy)
  end
end
function Container:getPosGlobal () return self.originX + self.x, self.originY + self.y end
function Container:getRectGlobal () return self.originX + self.x, self.originY + self.y, self.sx, self.sy end
function Container:addImmediate (child) self.children:append(child); child.parent = self end
function Container:removeImmediate (child) self.children:remove(child); child.parent = nil end

local Panel = {}
Panel.__index = Panel
setmetatable(Panel, Container)
package.loaded['UI.Container'] = Container
package.loaded['UI.Panel'] = Panel

local Button = {}
Button.__index = Button
setmetatable(Button, Container)
function Button:setOnClick (fn) self.onClick = fn end
function Button:click () if self.onClick then self.onClick(self, {}) end end
package.loaded['UI.Button'] = Button

local panels, lines, texts, rings = {}, {}, {}, {}
_G.DrawEx = {
  Panel = function (...) panels[#panels + 1] = { ... } end,
  Line = function (...) lines[#lines + 1] = { ... } end,
  TextAlpha = function (...) texts[#texts + 1] = { ... } end,
  Ring = function (...) rings[#rings + 1] = { ... } end,
  GetAlpha = function () return 1 end,
}
package.loaded['UI.DrawEx'] = DrawEx
_G.Engine = { GetTime = function () return 3 end }
_G.Color = function (r, g, b, a) return { r = r, g = g, b = b, a = a } end

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end
local function finish ()
  if failures == 0 then print(string.format('holo info: %d checks passed', checks)); os.exit(0) end
  print(string.format('holo info: %d/%d checks failed', failures, checks)); os.exit(1)
end

local loaded, InfoPanel = pcall(require, 'UI.HoloInfoPanel')
check('HoloInfoPanel module loads', loaded, InfoPanel)
if not loaded then finish() end

local actionCalls, closeCalls = {}, 0
local panel = InfoPanel.Create({
  onAction = function (action, node) actionCalls[#actionCalls + 1] = { action, node } end,
  onClose = function () closeCalls = closeCalls + 1 end,
})
local node = {
  id = 'station:1', label = 'Tyle Rig', sublabel = 'Station',
  info = {
    title = 'Tyle Sprawl Mining Rig', subtitle = 'Station / Market',
    description = 'A fortified mining and refining platform with an active commodity exchange.',
    preview = 'station',
    stats = { { label = 'Credits', value = '18,240' }, { label = 'Docking', value = 'Open' } },
  },
  actions = {
    { id = 'goto', label = 'Goto' },
    { id = 'dock', label = 'Dock', enabled = false, reason = 'Already docked' },
    { id = 'trade', label = 'Trade', submenu = { title = 'Commodity Exchange', actions = {
      { id = 'buy_energy', label = 'Buy Energy Cells' },
      { id = 'sell_ore', label = 'Sell Rochalite Ore' },
    } } },
  },
}
panel:setSubject(node)
check('subject enables the panel and normalizes preview data',
  panel.subject == node and panel.enabledT == 1 and panel.title == node.info.title)
check('provider actions become interactive menu buttons',
  #panel.actionButtons == 3 and panel.actionButtons[1].action.id == 'goto'
    and panel.actionButtons[3].action.id == 'trade')
panel.actionButtons[1]:click()
check('action click returns the provider action and selected node',
  #actionCalls == 1 and actionCalls[1][1] == node.actions[1]
    and actionCalls[1][2] == node)
panel.actionButtons[2]:click()
check('disabled actions do not execute', #actionCalls == 1)

panel.actionButtons[3]:click()
check('actions with submenus open a nested menu without executing',
  #panel.menuStack == 1 and panel.menuTitle == 'Commodity Exchange'
    and #panel.actionButtons == 2 and #actionCalls == 1)
panel.actionButtons[2]:click()
check('submenu actions execute against the same selected node',
  #actionCalls == 2 and actionCalls[2][1].id == 'sell_ore'
    and actionCalls[2][2] == node)
panel:menuBack()
check('submenu back restores the parent action list',
  #panel.menuStack == 0 and #panel.actionButtons == 3)

panel:onLayoutPos(0, 0, 1280, 800)
check('panel anchors in the upper-right with a viewport margin',
  panel.x == 940 and panel.y == 20 and panel.sx == 320 and panel.sy == 430,
  string.format('%.0f,%.0f %.0fx%.0f', panel.x, panel.y, panel.sx, panel.sy))
panel:onLayoutPosChildren()
check('action menu stays at the bottom and close stays top-right',
  panel.actionButtons[1].y == 318 and panel.closeButton.x == 286
    and panel.closeButton.y == 8,
  string.format('action y %.0f, close %.0f,%.0f', panel.actionButtons[1].y,
    panel.closeButton.x, panel.closeButton.y))
panel:onDraw(nil, nil)
panel.actionButtons[2]:onDraw(nil, nil)
check('preview screen draws holographic frame, schematic, and text',
  #panels >= 1 and #rings >= 1 and #texts >= 4)
local disabledReason = false
for i = 1, #texts do
  if texts[i][2] == 'Already docked' then disabledReason = true end
end
check('disabled action reason is visible', disabledReason)

node.info.preview = { kind = 'station', entity = { id = 'live-station' } }
panel:setSubject(nil)
panel:setSubject(node)
panel:onDraw(nil, nil)
local descriptorPreview = false
for i = 1, #texts do
  if texts[i][2] == 'STATION / LIVE SCHEMATIC' then descriptorPreview = true end
end
check('preview descriptors accept a live entity reference', descriptorPreview)

panel:close()
check('close hides the panel, resets submenus, and notifies the owner',
  panel.subject == nil and panel.enabledT == 0 and #panel.menuStack == 0
    and closeCalls == 1)

finish()
