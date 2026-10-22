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
  NEW GAME, CUSTOM GAME, INFO, HELP and EXIT work. LOAD and SAVE are
  "coming soon" -- the save format does not exist yet (ROADMAP item 17) --
  and they are SHOWN, dimmed, because a menu with visible gaps tells the
  player what the game is going to have, and a smaller menu just looks
  unfinished.
]]

local Screen     = require('Game.GUI.Screen')
local Grid       = require('UI.Grid')
local Label      = require('UI.Label')
local MenuButton = require('UI.MenuButton')

local MainMenu = {}
MainMenu.__index = MainMenu
setmetatable(MainMenu, Screen)

MainMenu.name = 'Main Menu'

function MainMenu.Create (opts)
  opts = opts or {}
  local self = setmetatable({}, MainMenu)

  self.version = opts.version or ''

  Screen.init(self, {
    title    = opts.title or 'LIMIT THEORY REBOOT',
    subtitle = opts.subtitle or 'WORK IN PROGRESS',
    onClose  = opts.onClose,
    bandAtTop = false,
    -- NOT opaque: the world is behind this, dimmed. An opaque backdrop
    -- would make the menu a black frame with a menu on it.
    backdrop = opts.backdrop or Color(0.01, 0.02, 0.04, 0.72),
  })

  -- The entries, in a row, the way the old game's were. A Grid with seven
  -- columns fills row by row, so seven entries in one row is one grid
  -- with seven columns.
  local row = Grid():setCols(7):setPadCellX(8):setAlign(0.5, 0)
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
  entry('LOAD', nil, true)
  entry('SAVE', nil, true)
  entry('INFO', function ()
    if self.onInfo then self.onInfo() end
  end)
  entry('HELP', function ()
    if self.onHelp then self.onHelp() end
  end)
  entry('EXIT', function ()
    if self.onExit then self.onExit() end
  end)

  self.content:add(row)

  -- The "coming soon" note, under the entries. LOAD and SAVE are dimmed
  -- because they do not work yet, and a dimmed entry with no explanation
  -- reads as a bug.
  local note = Label():setText('load and save are coming soon')
  note:setFontColor(Color(0.52, 0.58, 0.68, 0.85))
  note:setAlign(0.5, 0)
  self.content:add(note)

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
