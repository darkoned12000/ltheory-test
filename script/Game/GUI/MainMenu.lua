--[[ MainMenu -- the game's front door.

  THE OLD GAME'S MENU
  ===================
  The reference is the old game's splash: the nebula behind it, a title
  band across the middle with the logo, and a row of entries under it. This
  is that shape, on the framework, over the live world -- the world behind
  is dimmed and drifts slowly (see `GameView:updateMenuCamera`), so the
  menu has the game behind it rather than a black frame.

  It is opened two ways: at boot, and by ESC while playing. ESC closes it
  again, so ESC is a toggle. The EXIT entry is the way out -- the game is
  never quit by a stray keypress.

  IT IS ITS OWN PAGE
  ==================
  While the menu is up the game does not run: the world is not updated, the
  ship is not flown, the HUD feeds it zeros. What still moves is the
  camera, because a menu over a still frame looks like a still frame.

  WHAT IS AND IS NOT HERE
  =======================
  NEW GAME, CUSTOM GAME, INFO, HELP and EXIT work. LOAD and SAVE open a
  "coming soon" popup of their own -- the save format does not exist yet
  (ROADMAP item 17) -- rather than sitting dimmed: a dimmed entry with no
  explanation reads as a bug, and a popup explains itself.
]]

local Screen     = require('Game.GUI.Screen')
local Grid       = require('UI.Grid')
local MenuButton = require('UI.MenuButton')

local MainMenu = {}
MainMenu.__index = MainMenu
setmetatable(MainMenu, Screen)

MainMenu.name = 'Main Menu'

function MainMenu.Create (opts)
  opts = opts or {}
  local self = setmetatable({}, MainMenu)

  self.version = opts.version or ''

  -- SCREEN.INIT COPIES EVERY OPTION IT IS GIVEN onto the screen, so the
  -- callers' callbacks (onNewGame, onCustomGame, onInfo...) survive. That
  -- copy is useless if this constructor builds a SEPARATE table with only
  -- the fields it knows -- the first version did exactly that, and every
  -- entry the app wired was a silent no-op. So the caller's opts travel
  -- through with the defaults layered on top.
  local o = {}
  for k, v in pairs(opts) do o[k] = v end
  o.title     = o.title or 'LIMIT THEORY REBOOT'
  o.subtitle  = o.subtitle or 'WORK-IN-PROGRESS'
  o.bandAtTop = false
  -- NOT opaque: the world is behind this, dimmed. An opaque backdrop
  -- would make the menu a black frame with a menu on it.
  o.backdrop  = o.backdrop or Color(0.01, 0.02, 0.04, 0.72)

  Screen.init(self, o)

  -- The entries, in a row, the way the old game's were. A Grid with eight
  -- columns fills row by row, so eight entries in one row is one grid
  -- with eight columns.
  local row = Grid():setCols(8):setPadCellX(8):setAlign(0.5, 0)
  row:setStretch(0, 0)

  local function entry (label, onClick, disabled)
    local b = MenuButton(label, onClick)
    b:setDisabled(disabled or false)
    row:add(b)
    return b
  end

  entry('NEW GAME', function ()
    if self.onNewGame then self.onNewGame() end
  end)
  entry('CUSTOM GAME', function ()
    if self.onCustomGame then self.onCustomGame() end
  end)
  entry('LOAD', function ()
    if self.onLoad then self.onLoad() end
  end)
  entry('SAVE', function ()
    if self.onSave then self.onSave() end
  end)
  entry('INFO', function ()
    if self.onInfo then self.onInfo() end
  end)
  entry('HELP', function ()
    if self.onHelp then self.onHelp() end
  end)
  entry('SETTINGS', function ()
    if self.onSettings then self.onSettings() end
  end)
  entry('EXIT', function ()
    if self.onExit then self.onExit() end
  end)

  self.content:add(row)

  return self
end

-- The version, in the corner. It is the commit count, so it is never
-- stale and never has to be bumped.
function MainMenu:onDraw (focus, active)
  Screen.onDraw(self, focus, active)

  if self.version == '' then return end
  local x, y, sx, sy = self:getRectGlobal()
  local font = Config.ui.font.normal
  local bound = font:getSize(self.version)
  font:draw(self.version, x + sx - bound.z - 24, y + sy - bound.y - 20,
    0.5, 0.58, 0.68, 0.85)
end

return MainMenu
