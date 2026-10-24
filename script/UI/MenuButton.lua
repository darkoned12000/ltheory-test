--[[ MenuButton -- the button the menus use.

  The old game's menus had a look: a small dark plate, a round bullet, and
  a label. It reads as a menu without needing chrome, and it is what
  `MenuButton` reproduces -- so the splash and the station screen look like
  they belong to the same game.

  It is a plain widget (not the framework's `UI.Button`), because the
  framework's button has no DISABLED state, and the splash needs one: the
  entries that are not built yet are shown dimmed and cannot be clicked,
  which is more honest than hiding them.

  USAGE
  =====
      local b = MenuButton('NEW GAME', function () ... end)
      b:setDisabled(true)
]]

local Widget = require('UI.Widget')
local DrawEx = require('UI.DrawEx')

local MenuButton = {}
MenuButton.__index = MenuButton
setmetatable(MenuButton, Widget)

MenuButton.name      = 'Menu Button'
MenuButton.focusable = true

MenuButton.defaultAccent = Color(0.45, 0.75, 1.0, 1.0)

function MenuButton.Create (text, onClick)
  local self = setmetatable({ text = text, onClick = onClick }, MenuButton)
  self:setStretch(0, 0)
  self:setText(text)
  return self
end

function MenuButton:setText (text)
  self.text = text or ''
  self.name = string.format('Menu Button %s', tostring(self.text))
  local font = Config.ui.font.normal
  local bound = font:getSize(self.text)
  -- The plate carries the bullet, the gap and the label, with padding
  -- around it.
  self.desiredSX = bound.z + 34
  self.desiredSY = math.max(bound.y + 14, 30)
  return self
end

-- A disabled entry is dimmed and cannot be clicked. It still shows, so the
-- menu reads as a menu with gaps in it rather than a smaller menu.
function MenuButton:setDisabled (disabled)
  self.disabled = disabled
  if disabled then self.focusable = false else self.focusable = true end
  return self
end

-- A SELECTED entry (the active tab of a set): the plate reads the way a
-- focused one does and STAYS that way until deselected -- the player
-- knows without a doubt which page they are on, hover or not.
function MenuButton:setSelected (selected)
  self.selected = selected
  return self
end

function MenuButton:onFindMouseFocus (mx, my, foci)
  if self.disabled then return end
  Widget.onFindMouseFocus(self, mx, my, foci)
end

function MenuButton:onClick (state)
  if self.disabled then return end
  if self.onClick then self.onClick(self, state) end
end

function MenuButton:onDraw (focus, active)
  local x, y, sx, sy = self:getRectGlobal()
  local font = Config.ui.font.normal
  local bound = font:getSize(self.text)

  local accent = self.accent or MenuButton.defaultAccent
  local alpha = self.disabled and 0.28 or 1.0
  local on = self.selected or focus == self

  -- The plate.
  local bg = on and Color(0.16, 0.30, 0.46, 0.95)
                 or Color(0.06, 0.09, 0.14, 0.85)
  DrawEx.Panel(x, y, sx, sy, Color(bg.r, bg.g, bg.b, bg.a * alpha), 0.5)
  DrawEx.RectOutline(x, y, sx, sy,
    Color(accent.r, accent.g, accent.b, (on and 0.85 or 0.25) * alpha))

  -- The bullet.
  DrawEx.Point(x + 12, y + sy * 0.5, 3.5,
    Color(accent.r, accent.g, accent.b, (on and 1.0 or 0.7) * alpha))

  -- The label. The draw y is the same formula `Widget:drawText` and the
  -- framework's Button use (`y + (sy + bound.y) * 0.5 - bound.y`) -- one
  -- early version read `(sy - bound.y)` and the text hung below the plate
  -- by exactly one glyph ascent. See libphx/src/Font.cpp on centering.
  local textCol = on and Color(1, 1, 1, alpha) or Color(0.82, 0.87, 0.94, alpha)
  font:draw(self.text,
    x + 24 - bound.x,
    y + (sy + bound.y) * 0.5 - bound.y,
    textCol.r, textCol.g, textCol.b, textCol.a)
end

return MenuButton
