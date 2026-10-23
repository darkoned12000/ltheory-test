--[[ MenuPanelScreen -- a popup over the menu.

  The popups the main menu opens -- the release milestones, the how-to-play,
  the custom seed -- are screens in their own right, not panels painted
  into the menu. That is the whole point of the Screen frame: a screen is a
  PAGE, it takes the input, and the thing behind it is not the page.

  So a popup is a screen with a header band, a content area and a CLOSE
  entry. When it closes, the menu takes the input back -- see
  `Screen:open`, which is how the menu re-takes the modal focus.

  The content is supplied by the caller: a one-column Grid's worth of
  widgets, in `self.content`.
]]

local Screen = require('Game.GUI.Screen')
local Grid   = require('UI.Grid')
local Label  = require('UI.Label')
local MenuButton = require('UI.MenuButton')

local MenuPanelScreen = {}
MenuPanelScreen.__index = MenuPanelScreen
setmetatable(MenuPanelScreen, Screen)

MenuPanelScreen.name = 'Menu Panel'

-- opts:
--   title    -- the band title
--   onClose  -- called when the popup closes (so the menu can re-open)
function MenuPanelScreen.Create (opts)
  opts = opts or {}
  local self = setmetatable({}, MenuPanelScreen)

  -- Like MainMenu: copy the caller's opts and layer the defaults on top.
  -- Screen.init keeps every option it is given; a constructor that rebuilt
  -- the table field-by-field was how main-menu buttons lost their
  -- callbacks and clicked to nothing.
  local o = {}
  for k, v in pairs(opts) do o[k] = v end
  o.title    = o.title or ''
  o.subtitle = o.subtitle or ''
  -- A header, not a centred band: this is a page with a title.
  o.bandAtTop = true
  -- OPAQUE. The menu is already dimming the world; this is a PAGE over
  -- the menu, and a translucent one lets the menu's title and entries
  -- show through the text.
  o.backdrop = o.backdrop or Color(0.012, 0.016, 0.03, 1.0)

  Screen.init(self, o)

  -- The content is a one-column grid, and the CLOSE entry is under it.
  self.content:setAlign(0.5, 0)
  self.content:setStretch(0, 0)

  return self
end

-- The CLOSE entry goes UNDER whatever the popup put in the content, so
-- it is added last rather than in Create.
function MenuPanelScreen:addCloseButton ()
  self.closeButton = MenuButton('CLOSE', function ()
    self:close()
  end)
  local row = Grid():setCols(1):setAlign(0.5, 0)
  row:setStretch(0, 0)
  row:add(self.closeButton)
  self.content:add(row)
  return self
end

-- A line of text in the popup.
function MenuPanelScreen:addLine (text, color)
  local l = Label():setText(text)
  if color then l:setFontColor(color) end
  self.content:add(l)
  return l
end

return MenuPanelScreen
