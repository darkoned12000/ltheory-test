--[[ Screen -- a full-screen UI layer over the live game.

  THE FRAME EVERY GAME SCREEN USES
  =================================
  A screen is not a separate app and not a dialog in the corner: it is a
  layer over the world, the way the station interface in the old game was
  (the market screen is the reference -- see docs/ltheory-ui-gui-research.md).

  Three things make a screen a screen, and this module owns all three so
  that a screen only has to supply its CONTENT:

  1. IT TAKES THE INPUT. The framework already has the mechanism and
     nothing was using it: `Panel:setModal(true)` sets the canvas's
     `modalFocus`, and `Canvas:findMouseFocus` then gives the mouse to
     the modal and nobody else. `Bindings.Cancel` (ESC, right-click) is
     routed to `modalFocus:cancel()`, which calls this screen's `onCancel`
     -- so ESC closes the screen for free, as long as `onCancel` is set.

  2. IT DIMS THE WORLD. The old game's station screen sat over a dimmed
     hangar. A screen draws a translucent backdrop first (alpha blended,
     not additive -- an additive "dim" would brighten what it covers).

  3. IT FADES. The framework's own enable/disable fade is used, so a
     screen opens and closes the same way every panel does.

  WHAT A SUBCLASS DOES
  ====================
  Fill `self.content` (a one-column Grid) and set `onClose`. That is the
  whole contract:

      local MyScreen = {}
      MyScreen.__index = MyScreen
      setmetatable(MyScreen, Screen)

      function MyScreen.Create (opts)
        local self = setmetatable({}, MyScreen)
        Screen.init(self, opts)
        self.content:add(UI.Label('hello'))
        return self
      end

  THE SHIP MUST NOT FLY WHILE A SCREEN IS UP
  ===========================================
  A screen blocks the UI's input, but the ship's thrust is read directly
  from the key bindings in `HUD:controlThrust` -- it is NOT part of the UI
  input tree. So `HUD:controlThrust` asks the app whether a screen is open
  and feeds the ship zeros when one is. That check lives in one place
  (the HUD), and every screen gets it for free.
]]

local Panel   = require('UI.Panel')
local Grid    = require('UI.Grid')
local Widget  = require('UI.Widget')
local DrawEx  = require('UI.DrawEx')

-- The widget shader ids and blend modes, from Draw.h / BlendMode.h. They
-- are duplicated in UI/DrawEx.lua; they are the same numbers the C++ widget
-- batch is keyed on, so a mismatch would silently draw the wrong shape.
local WidgetShader_Box = 0
local BlendMode_Alpha  = 1

local Screen = {}
Screen.__index = Screen
setmetatable(Screen, Panel)

Screen.name = 'Screen'

-- The default look. A screen is a plate over the world, not a window in
-- the middle of it: the old game's station screen filled the screen, and a
-- panel floating in the middle of a 3D scene reads as a debug overlay.
Screen.defaultBackdrop = Color(0.01, 0.015, 0.03, 0.82)
Screen.defaultAccent   = Color(0.35, 0.62, 0.95, 1.0)
Screen.defaultText     = Color(0.86, 0.90, 0.96, 1.0)

-- ---------------------------------------------------------------------------
-- The title band
-- ---------------------------------------------------------------------------

-- The band is its own widget, because it draws itself: a plate a shade
-- lighter than the backdrop, a hairline under it, the title centred in the
-- heaviest face the font directory has, and the subtitle beside it.
local Band = {}
Band.__index = Band
setmetatable(Band, Widget)

Band.name      = 'Screen Band'
Band.focusable = false

function Band.Create (screen)
  local self = setmetatable({ screen = screen }, Band)
  self:setStretch(0, 0)
  self.desiredSX = 0
  self.desiredSY = 96
  return self
end

function Band:onLayoutSize ()
  -- The band's height follows the window, so it is the same proportion of
  -- the screen at 720p and at 4K. The screen's own size is known by now:
  -- a container lays its children out AFTER its own size is resolved.
  local h = self.screen.sy or 900
  self.desiredSY = Math.Clamp(Math.Round(h * 0.11), 56, 150)
end

function Band:onDraw (focus, active)
  local screen = self.screen
  local x, y, sx, sy = self:getRectGlobal()

  -- The band plate: the widget shader, alpha blended. NOT DrawEx.Panel --
  -- that draws 64 pixels of padding beyond the rect, and the glow shows at
  -- the screen's edge as a bright blob.
  Draw.WidgetRect(WidgetShader_Box, BlendMode_Alpha,
    x, y, sx, sy,
    0.03, 0.05, 0.09, 0.88,
    0, 0, 0, 0,
    0, 0, 0, 0)
  -- The hairline under the band. DrawEx.LINE, not DrawEx.Rect: the rect
  -- helper goes through the BOX shader, whose corner radius is the rect's
  -- own size, so a full-width "line" comes out with 40-pixel round caps
  -- at the screen's edge.
  -- Inset by the line shader's cap radius, or the cap shows at the screen's
  -- edge as a bright arc.
  DrawEx.Line(x + 40, y + sy - 1, x + sx - 40, y + sy - 1, screen.accent)

  -- The title, centred. The font is cached on the band (not re-fetched
  -- every frame) so the Font object -- and its glyph atlas texture --
  -- stays alive for the screen's whole lifetime instead of being
  -- dropped on a Cache.Clear() and re-created mid-flight (which left
  -- the title drawing from a stale/freed atlas after a few opens).
  local titleSize = Math.Round(sy * 0.52)
  if self.titleFont == nil or self.titleFontSize ~= titleSize then
    self.titleFont = Cache.Font('Exo2Black', titleSize)
    self.titleFontSize = titleSize
  end
  local font = self.titleFont
  local bound = font:getSize(screen.title or '')
  local titleY = y + 0.5 * (sy + bound.y) - bound.y + 5
  font:draw(screen.title or '',
    x + (sx - bound.z) * 0.5 - bound.x,
    titleY,
    screen.text.r, screen.text.g, screen.text.b, screen.text.a)

  -- The subtitle, ABOVE the title by five pixels -- level with it, it
  -- sits in the title's ink.
  if screen.subtitle and screen.subtitle ~= '' then
    local subSize = Math.Round(sy * 0.22)
    if self.subFont == nil or self.subFontSize ~= subSize then
      self.subFont = Cache.Font('Exo2', subSize)
      self.subFontSize = subSize
    end
    local sfont = self.subFont
    local sb = sfont:getSize(screen.subtitle)
    sfont:draw(screen.subtitle,
      x + (sx - sb.z) * 0.5 - sb.x,
      titleY - bound.w - 5,
      screen.accent.r, screen.accent.g, screen.accent.b, 0.9)
  end
end

-- ---------------------------------------------------------------------------
-- A spacer
-- ---------------------------------------------------------------------------

-- An empty row that eats the leftover space. A Panel will not do: the
-- widget base class has a minimum size of 128x128, so an empty Panel is
-- 128x128 and would push the layout around.
local Spacer = {}
Spacer.__index = Spacer
setmetatable(Spacer, Widget)

Spacer.name      = 'Spacer'
Spacer.focusable = false

function Spacer.Create (stretchY)
  local self = setmetatable({}, Spacer)
  self:setStretch(0, stretchY or 1)
  self.desiredSX = 0
  self.desiredSY = 0
  return self
end

function Spacer:onLayoutSize ()
  self.desiredSX = 0
  self.desiredSY = 0
end

-- ---------------------------------------------------------------------------
-- The screen
-- ---------------------------------------------------------------------------

-- Set up a screen. `opts`:
--   title      -- the band title
--   subtitle   -- the small text beside it
--   onClose    -- called when the screen closes (ESC, a button, ...)
--   backdrop   -- the dim colour
--   accent     -- the accent colour
--   bandAtTop  -- true for a screen whose band is a header (the station
--                 screens); false centres it (the splash)
function Screen.init (self, opts)
  opts = opts or {}

  self.title    = opts.title or 'Screen'
  self.subtitle = opts.subtitle or ''
  self.accent   = opts.accent or Screen.defaultAccent
  self.text     = opts.text or Screen.defaultText
  self.backdrop = opts.backdrop or Screen.defaultBackdrop
  self.onClose  = opts.onClose

  -- EVERYTHING ELSE THE CALLER PASSED IS KEPT AS IT IS.
  --
  -- A main menu carries onNewGame / onCustomGame / onInfo / onHelp / onExit;
  -- a station screen will carry its own similar set. `Screen.init` cannot
  -- enumerate them -- and if it tried, the FIRST callback it forgot to copy
  -- would be a silent no-op button: clicked, a stack trace that never
  -- happens, and a menu that looks alive and does nothing. (Found the hard
  -- way: the very first version of this file dropped every callback except
  -- onClose, because init only copied the fields it knew about.)
  for k, v in pairs(opts) do
    if self[k] == nil then self[k] = v end
  end

  -- Panel's own fields. A screen is a Panel so that it inherits
  -- `cancel()` -- which is how ESC finds its way to `onCancel`.
  self.children = List()
  self.isModal  = false
  self.onCancel = nil

  -- The screen fills the screen.
  self:setStretch(1, 1)
  self:setAlign(0, 0)

  -- The layout, in three rows: space above the band, the band, and the
  -- content below it. A Grid, because a container does not flow its
  -- children -- it hands them all the same rect and lets each child's own
  -- align place it.
  --
  -- `bandAtTop` decides where the band sits. With it, the space above the
  -- band is zero and the band is a header; without it, the space above
  -- and the space below share the leftover, and the band lands in the
  -- middle of the screen -- which is where the old game's splash put it.
  local root = Grid():setCols(1):setStretch(1, 1)
  self.band = Band.Create(self)
  -- The band spans the WIDTH of the screen: the grid's column takes the
  -- leftover width, and a band that only spans its title reads as a label
  -- that drifted off to the left.
  self.band:setStretch(1, 0)
  -- The content sizes to itself and centres in the screen. A Grid puts its
  -- columns at the LEFT unless something stretches them, so the thing that
  -- centres itself is the content grid, not the row inside it.
  self.content = Grid():setCols(1):setStretch(0, 1):setPadCellY(10)
  self.content:setAlign(0.5, 0)

  self.topSpace = Spacer.Create(opts.bandAtTop and 0 or 1)

  root:add(self.topSpace):add(self.band):add(self.content)
  self.root = root

  self:add(root)

  -- ESC (and right-click) close the screen. `Panel:cancel` calls it.
  self:setOnCancel(function ()
    if self:isOpen() then self:close() end
  end)

  return self
end

-- Open the screen: fade it in and take the input.
--
-- The modal focus is set HERE rather than at creation, because
-- `setModal` needs the canvas's state -- and a screen only has one once
-- it is in the canvas's tree. The game adds screens to the GameView,
-- which is a child of the canvas, so `getState()` finds it.
function Screen:open ()
  self:setModal(true)
  self:setEnabled(true)
  return self
end
-- NOTE : open() may only be called from a widget that is ALREADY IN THE
-- CANVAS'S TREE: `setModal` needs the canvas state, and it is found by
-- walking `parent`. The app flushes its deferred adds (a `canvas:update`)
-- before opening anything at boot -- see LTheory:onInit.

-- Close the screen: give the input back and fade out.
function Screen:close ()
  self:setModal(false)
  self:setEnabled(false)
  if self.onClose then self.onClose(self) end
  return self
end

function Screen:isOpen ()
  return self:isEnabled()
end

-- The dim over the world. Drawn before the children, so the content sits
-- on top of it.
function Screen:onDraw (focus, active)
  local x, y, sx, sy = self:getRectGlobal()
  local c = self.backdrop
  -- The dim over the world.
  --
  -- DrawEx.Panel, which is the ALPHA blended one: DrawEx.Rect is additive,
  -- and an additive dim would brighten what it covers instead of pushing it
  -- back. And not a raw Draw.WidgetRect -- the widget shaders expect the
  -- rect's PADDING (the box shader takes 64 pixels off the size to compute
  -- its shape), and a padding of zero draws the wrong shape entirely.
  DrawEx.Panel(x, y, sx, sy, c, 1.0)
  Panel.onDraw(self, focus, active)
end

return Screen
