#!/usr/bin/env luajit
-- NPC info panel placement contract: top-right with the SectorPanel inset.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_panel%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

local Widget = {}
Widget.__index = Widget
function Widget:setAlign (x, y) self.alignX, self.alignY = x, y; return self end
function Widget:setStretch () return self end
function Widget:setPadUniform () return self end
function Widget:add (child) self.children = self.children or {}; self.children[#self.children + 1] = child; return self end
function Widget:onLayoutPos (px, py, psx, psy)
  self.x = px + self.alignX * (psx - self.sx)
  self.y = py + self.alignY * (psy - self.sy)
end
function Widget:getRectGlobal () return self.rx or 0, self.ry or 0, self.rsx or 148, self.rsy or 112 end
local Container = Widget
local function chain ()
  local object = { children = {} }
  return setmetatable(object, { __index = function (_, name)
    if name == 'add' then
      return function (self, child)
        self.children[#self.children + 1] = child
        return self
      end
    end
    return function (self) return self end
  end })
end
local Grid = function () return chain() end
local Label = function () return chain() end
package.loaded['UI.Container'] = Container
package.loaded['UI.Grid'] = Grid
package.loaded['UI.Label'] = Label
package.loaded['UI.Widget'] = Widget
package.loaded['UI.DrawEx'] = {}
package.loaded['Game.ScannerDB'] = {}
package.loaded['Game.TargetInfo'] = {}
package.loaded['ffi'] = {}
_G.List = function () return {} end
_G.Config = { ui = { color = {} } }
local drawnLines = 0
_G.Draw = {
  Color = function () end,
  Line = function () drawnLines = drawnLines + 1 end,
}
_G.Color = function (...) return { ... } end
package.loaded['UI.DrawEx'] = { RectOutline = function () end, Panel = function () end }

local Panel = dofile(root .. '/script/Game/GUI/NpcInfoPanel.lua')
local panel = Panel.Create(nil)
panel.sx, panel.sy = 300, 200
panel:onLayoutPos(0, 0, 1920, 1080)

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. detail) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or '')) end
end
check('panel aligns to top-right', panel.alignX == 1 and panel.alignY == 0,
  string.format('align=(%.1f,%.1f)', panel.alignX, panel.alignY))
check('panel is inset 10px from right edge', panel.x == 1920 - 300 - 10,
  string.format('x=%.0f', panel.x))
check('panel is inset 10px from top edge', panel.y == 10,
  string.format('y=%.0f', panel.y))
local body = panel.children[1].children[2]
local preview = body.children[1]
panel.subject = { isWormhole = true }
preview:onDraw(false, true)
check('bodyless wormhole renders a portal preview', drawnLines > 0,
  string.format('%d schematic strokes', drawnLines))

if failures == 0 then
  print(string.format('npc panel: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('npc panel: %d/%d checks failed', failures, checks))
  os.exit(1)
end
