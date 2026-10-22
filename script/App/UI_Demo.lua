--[[ UI_Demo -- a live tour of the script/UI framework, and the game screens
  the project still owes: a radar, a reticle with target brackets, ship
  status, an inventory and a sector map.

  WHY THIS APP EXISTS
  ===================
  `docs/ltheory-ui-gui-research.md` describes the three GUI systems and then
  offers a "complete working example" that was never written and did not
  compile: it called a `UI.Column` widget that does not exist, constructed
  sliders with the wrong signature, used a `setTitle` that no widget has,
  and drew circles with a `Draw.Circle` the engine does not have (the
  engine's Draw API is Line/Rect/Tri; the circle helpers live in
  `UI.DrawEx` as Ring/Point/Wedge/Cross).

  This app is the corrected version of that example, and it RUNS. Every
  widget here is a real widget from `script/UI/`, and every drawing call is
  a real one -- so the document can point at this file instead of at a
  sketch.

  It is also the honest starting point for ROADMAP item 8 (game screens):
  a main menu and a settings screen are the same kind of work, on the same
  framework, and this is the reference for how a screen is put together.

  RUN IT
  ======
      ./run.sh UI_Demo

  The world is SIMULATED -- there is no entity system here. That is the
  point: the screen layout, the widgets and the interaction are the
  subject, and a screen should not need a live sector behind it to be
  judged.

  THE LAYOUT IDIOM (the thing that is easy to get wrong)
  =======================================================
  Three rules, and every panel in this app follows them:

  1. A CONTAINER DOES NOT FLOW ITS CHILDREN. `Container:onLayoutPosChildren`
     hands every child the SAME rect and lets the child's own `align`
     decide where it lands. To stack things vertically you want a GRID with
     one column, not a plain container.

  2. A WIDGET THAT SHOULD SIZE TO ITS CONTENT NEEDS `setStretch(0, 0)`.
     The default stretch is 1, which means "fill the parent" -- so a panel
     added to the canvas fills the whole screen, and the grid inside it
     spreads its columns across the monitor.

  3. THE CANVAS IS A LAYOUT PARENT. Its children are positioned with
     `setAlign(ax, ay)` -- a FRACTION of the canvas -- so a panel sits in
     the top-right corner at any window size, with no pixel positions to
     keep in sync.

  WHAT TO LOOK AT
  ===============
  * The widgets are the framework's own, not hand-rolled panels: Grids of
    Labels, a Slider, a Checkbox, an OptionSlider, a Collapsible, a
    ScrollView -- and three custom widgets that draw themselves (Radar,
    TargetBrackets, SectorMap) plus a focusable one (Slot). That is the
    pattern `UI/SectorPanel.lua` uses in the game.
  * The custom widgets are real widgets: they extend `UI.Widget`, and Slot
    is focusable, so it takes mouse focus and fires `onClick` like any
    other.
  * Nothing is drawn with raw `Draw` calls except the backdrop: the theme
    colours come from `Config.ui.color`, the fonts from `Config.ui.font`,
    and the shapes from `UI.DrawEx`.
]]

local Canvas        = require('UI.Canvas')
local Widget        = require('UI.Widget')
local Grid          = require('UI.Grid')
local Button        = require('UI.Button')
local Label         = require('UI.Label')
local Slider        = require('UI.Slider')
local Checkbox      = require('UI.Checkbox')
local OptionSlider  = require('UI.OptionSlider')
local Collapsible   = require('UI.Collapsible')
local ScrollView    = require('UI.ScrollView')
local DrawEx        = require('UI.DrawEx')

-- ---------------------------------------------------------------------------
-- The simulated world
-- ---------------------------------------------------------------------------

-- The ship. Everything on the status panel reads from here, so the sliders
-- and the checkboxes have something visible to do.
local function makeShip ()
  return {
    hull       = 87.5, hullMax    = 100,
    shields    = 62.0, shieldsMax = 100,
    fuel       = 71.0, fuelMax    = 100,
    throttle   = 0.60,
    speed      = 0,
    autopilot  = false,
    quality    = 3,          -- an INDEX into QUALITIES, not the string
    heading    = 0.0,
    mapX       = 60,
    mapY       = 55,
    sector     = 'The Vexing Reach',
    region     = 'Hogatuge Drift',
    archetype  = 'Belt',
    boundary   = 1240,
    radarRange = 5000,
  }
end

-- The OptionSlider works in INDICES: its value is a position in its list of
-- elements, and it draws elems[value]. Handing it the string 'High' is a
-- type error in onUpdate -- the same trap the settings panel fell into.
local QUALITIES = { 'Low', 'Medium', 'High' }

-- The contacts. `angle` is the bearing from the ship in radians, `dist` in
-- units, `hp` 0..1.
local function makeContacts ()
  return {
    { name = 'Hogger',    kind = 'hostile',  angle = 0.35, dist = 1200, hp = 0.80 },
    { name = 'Krell',     kind = 'hostile',  angle = 2.10, dist = 3400, hp = 0.45 },
    { name = 'Wreck',     kind = 'debris',   angle = 4.05, dist = 2600, hp = 0.20 },
    { name = 'Freighter', kind = 'neutral',  angle = 5.40, dist = 4300, hp = 1.00 },
    { name = 'Relay 7',   kind = 'friendly', angle = 0.95, dist = 800,  hp = 1.00 },
  }
end

local CONTACT_COLORS = {
  hostile  = Color(1.00, 0.35, 0.30, 0.95),
  neutral  = Color(0.95, 0.80, 0.35, 0.95),
  friendly = Color(0.40, 0.95, 0.75, 0.95),
  debris   = Color(0.60, 0.65, 0.75, 0.75),
}

local INVENTORY = {
  { name = 'Isotope', qty = 12, kind = 'ore'    },
  { name = 'Silver',  qty = 3,  kind = 'ore'    },
  { name = 'Cell',    qty = 8,  kind = 'energy' },
  { name = 'Plate',   qty = 2,  kind = 'hull'   },
  { name = 'Relay',   qty = 1,  kind = 'part'   },
  { name = 'Core',    qty = 1,  kind = 'part'   },
}

-- The regions of the sector, as circles in the map's own coordinates. The
-- real ones are Apollonius spheres with exact boundaries; the demo only
-- needs something to draw.
local REGIONS = {
  { name = 'Hogatuge Drift', x =  40, y =  30, r = 34, hue = 'belt' },
  { name = 'Ashen Marches',  x = 120, y =  60, r = 40, hue = 'ash' },
  { name = 'Violet Veil',    x =  70, y = 110, r = 38, hue = 'veil' },
}

local REGION_COLORS = {
  belt = Color(0.85, 0.70, 0.35, 0.30),
  ash  = Color(0.60, 0.45, 0.40, 0.30),
  veil = Color(0.55, 0.40, 0.85, 0.32),
}

-- ---------------------------------------------------------------------------
-- Radar -- a custom widget that draws itself
-- ---------------------------------------------------------------------------

local Radar = {}
Radar.__index = Radar
setmetatable(Radar, Widget)

Radar.name      = 'Radar'
Radar.focusable = false

function Radar.Create (app)
  local self = setmetatable({ app = app, sweep = 0 }, Radar)
  self:setStretch(0, 0)
  self.desiredSX = 240
  self.desiredSY = 240
  return self
end

function Radar:onUpdate (state)
  -- The sweep turns once every two seconds.
  self.sweep = (self.sweep + state.dt * 0.5) % 1.0
end

function Radar:onDraw (focus, active)
  local x, y, sx, sy = self:getRectGlobal()
  local cx, cy = x + sx * 0.5, y + sy * 0.5
  local r = math.min(sx, sy) * 0.44

  DrawEx.Panel(x, y, sx, sy, Color(0.02, 0.04, 0.07, 0.78), 0.55)
  DrawEx.RectOutline(x, y, sx, sy, Color(0.30, 0.50, 0.70, 0.45))

  -- The range rings, at a third and two thirds of the range.
  DrawEx.Ring(cx, cy, r,        Color(0.30, 0.50, 0.70, 0.40))
  DrawEx.Ring(cx, cy, r * 0.66, Color(0.30, 0.50, 0.70, 0.25))
  DrawEx.Ring(cx, cy, r * 0.33, Color(0.30, 0.50, 0.70, 0.18))

  -- The cross hairs.
  DrawEx.Line(cx - r, cy, cx + r, cy, Color(0.30, 0.50, 0.70, 0.22))
  DrawEx.Line(cx, cy - r, cx, cy + r, Color(0.30, 0.50, 0.70, 0.22))

  -- The sweep. `to` is a fraction of a full turn, `tw` its width.
  DrawEx.Wedge(cx, cy, r * 0.15, r, self.sweep, 0.06,
    Color(0.35, 1.00, 0.65, 0.30), 1)

  -- The contacts, at their bearing and range.
  local range = self.app.ship.radarRange
  for _, c in ipairs(self.app.contacts) do
    local rr = r * math.min(1, c.dist / range)
    local tx = cx + math.cos(c.angle) * rr
    local ty = cy + math.sin(c.angle) * rr
    local col = CONTACT_COLORS[c.kind] or CONTACT_COLORS.debris
    DrawEx.Point(tx, ty, 3.5, col)
    -- A short tick so the bearing reads even without the label.
    DrawEx.Line(tx - 4, ty, tx + 4, ty, col)
    DrawEx.Line(tx, ty - 4, tx, ty + 4, col)
  end

  -- The ship, at the centre.
  DrawEx.Cross(cx, cy, 6, Color(1, 1, 1, 0.95))

  -- The legend and the range.
  local font = Config.ui.font.normal
  local bound = font:getSize('RADAR')
  -- The baseline is the text's BOTTOM, so the title has to sit a full line
  -- down or the top of it is outside the box.
  font:draw('RADAR', cx - bound.z * 0.5, y + bound.y + 4, 0.55, 0.75, 0.95, 0.9)
  local rangeText = string.format('%d km', math.floor(range / 1000))
  local rb = font:getSize(rangeText)
  font:draw(rangeText, cx - rb.z * 0.5, y + sy - rb.y - 4, 0.55, 0.75, 0.95, 0.7)
end

-- ---------------------------------------------------------------------------
-- TargetBrackets -- the reticle and the brackets over what you are aiming at
-- ---------------------------------------------------------------------------

local TargetBrackets = {}
TargetBrackets.__index = TargetBrackets
setmetatable(TargetBrackets, Widget)

TargetBrackets.name      = 'Targets'
TargetBrackets.focusable = false

function TargetBrackets.Create (app)
  local self = setmetatable({ app = app }, TargetBrackets)
  self:setStretch(0, 0)
  self.desiredSX = 320
  self.desiredSY = 200
  return self
end

-- A bracket is four corner strokes, which reads as a target marker without
-- closing into a box.
local function drawBracket (x, y, sx, sy, color, size)
  local h = size
  DrawEx.Line(x,         y,         x + h,     y,         color)
  DrawEx.Line(x,         y,         x,         y + h,     color)
  DrawEx.Line(x + sx - h, y,         x + sx,    y,         color)
  DrawEx.Line(x + sx,     y,         x + sx,    y + h,     color)
  DrawEx.Line(x,         y + sy - h, x,         y + sy,    color)
  DrawEx.Line(x,         y + sy,    x + h,     y + sy,    color)
  DrawEx.Line(x + sx,     y + sy - h, x + sx,    y + sy,    color)
  DrawEx.Line(x + sx,     y + sy,    x + sx - h, y + sy,    color)
end

function TargetBrackets:onDraw (focus, active)
  local x, y, sx, sy = self:getRectGlobal()
  local font = Config.ui.font.normal

  -- The reticle: a broken cross at the centre, which is what the game uses.
  local cx, cy = x + sx * 0.5, y + sy * 0.5
  local col = Color(0.85, 0.95, 1.0, 0.55)
  local g = 5
  DrawEx.Line(cx - 14, cy, cx - g, cy, col)
  DrawEx.Line(cx + g,  cy, cx + 14, cy, col)
  DrawEx.Line(cx, cy - 14, cx, cy - g, col)
  DrawEx.Line(cx, cy + g,  cx, cy + 14, col)

  -- Each contact, at a simulated screen position. The offsets are fixed
  -- per contact, so the picture is stable frame to frame -- a demo that
  -- jittered would be harder to read, not easier.
  for i, c in ipairs(self.app.contacts) do
    local ox = ((i * 37) % 100) / 100 - 0.5
    local oy = ((i * 61 + 20) % 100) / 100 - 0.5
    local tx = cx + ox * sx * 0.8
    local ty = cy + oy * sy * 0.8
    local ccol = CONTACT_COLORS[c.kind] or CONTACT_COLORS.debris
    local size = 22

    drawBracket(tx - size, ty - size, size * 2, size * 2, ccol, 7)

    -- The name and the distance.
    local label = string.format('%s  %dkm', c.name, math.floor(c.dist / 1000))
    local bound = font:getSize(label)
    font:draw(label, tx - bound.z * 0.5, ty + size + 2, ccol.r, ccol.g, ccol.b, 0.9)

    -- The health bar, under the name.
    if c.hp < 1.0 then
      local bw = size * 2
      DrawEx.Rect(tx - bw * 0.5, ty + size + 4 + bound.y, bw, 3, Color(0.15, 0.15, 0.18, 0.8))
      DrawEx.Rect(tx - bw * 0.5, ty + size + 4 + bound.y, bw * c.hp, 3, ccol)
    end
  end

  -- The locked target's name, at the top of the panel.
  local lock = self.app.contacts[1]
  if lock then
    local text = string.format('LOCKED: %s', lock.name)
    local bound = font:getSize(text)
    font:draw(text, x + 6, y + 4, 1.0, 0.75, 0.35, 0.95)
  end
end

-- ---------------------------------------------------------------------------
-- SectorMap -- a custom widget that draws a map
-- ---------------------------------------------------------------------------

local SectorMap = {}
SectorMap.__index = SectorMap
setmetatable(SectorMap, Widget)

SectorMap.name      = 'Sector Map'
SectorMap.focusable = false

function SectorMap.Create (app)
  local self = setmetatable({ app = app }, SectorMap)
  self:setStretch(0, 0)
  self.desiredSX = 280
  self.desiredSY = 220
  return self
end

function SectorMap:onDraw (focus, active)
  local x, y, sx, sy = self:getRectGlobal()
  local font = Config.ui.font.normal

  DrawEx.Panel(x, y, sx, sy, Color(0.02, 0.03, 0.06, 0.80), 0.55)
  DrawEx.RectOutline(x, y, sx, sy, Color(0.30, 0.50, 0.70, 0.45))

  -- The map's world extent, in the demo's own coordinates.
  local worldSize = 180
  local scale = math.min(sx, sy) / worldSize
  local ox = x + sx * 0.5
  local oy = y + sy * 0.5
  local function toScreen (wx, wy)
    -- The world is centred on its own middle, not on its origin.
    return ox + (wx - worldSize * 0.5) * scale,
           oy + (wy - worldSize * 0.5) * scale
  end

  -- A grid, so the movement of the ship marker is legible.
  for g = -90, 90, 30 do
    local gx = select(1, toScreen(g, 0))
    local gy = select(1, toScreen(0, g))
    DrawEx.Line(gx, y + 4, gx, y + sy - 4, Color(0.25, 0.35, 0.45, 0.12))
    DrawEx.Line(x + 4, gy, x + sx - 4, gy, Color(0.25, 0.35, 0.45, 0.12))
  end

  -- The regions.
  for _, r in ipairs(REGIONS) do
    local rx, ry = toScreen(r.x, r.y)
    local col = REGION_COLORS[r.hue] or Color(0.5, 0.5, 0.5, 0.25)
    DrawEx.Ring(rx, ry, r.r * scale, col)
    local bound = font:getSize(r.name)
    font:draw(r.name, rx - bound.z * 0.5, ry - bound.y * 0.5, col.r, col.g, col.b, 0.85)
  end

  -- The jumpgates: the way out of the sector.
  local gx1, gy1 = toScreen(20, 20)
  local gx2, gy2 = toScreen(150, 140)
  DrawEx.Ring(gx1, gy1, 6, Color(0.45, 0.85, 1.0, 0.9))
  DrawEx.Ring(gx2, gy2, 6, Color(0.45, 0.85, 1.0, 0.9))
  DrawEx.Line(gx1, gy1, gx2, gy2, Color(0.45, 0.85, 1.0, 0.18))

  -- The ship: a marker with a heading line.
  local sx0, sy0 = toScreen(self.app.ship.mapX, self.app.ship.mapY)
  local h = self.app.ship.heading
  DrawEx.Line(sx0, sy0, sx0 + math.cos(h) * 14, sy0 + math.sin(h) * 14,
    Color(1, 1, 1, 0.9))
  DrawEx.Point(sx0, sy0, 4, Color(1, 1, 1, 0.95))

  -- The scale bar.
  local barText = '10 km'
  local bound = font:getSize(barText)
  local barLen = 10 * scale
  DrawEx.Line(x + 8, y + sy - 10, x + 8 + barLen, y + sy - 10, Color(0.6, 0.75, 0.9, 0.6))
  font:draw(barText, x + 8, y + sy - 10 - bound.y - 2, 0.6, 0.75, 0.9, 0.7)
end

-- ---------------------------------------------------------------------------
-- Slot -- a focusable custom widget (an inventory slot)
-- ---------------------------------------------------------------------------

local Slot = {}
Slot.__index = Slot
setmetatable(Slot, Widget)

Slot.name      = 'Slot'
Slot.focusable = true

function Slot.Create (item, onSelect)
  local self = setmetatable({ item = item, onSelect = onSelect }, Slot)
  self:setStretch(0, 0)
  self.desiredSX = 104
  self.desiredSY = 44
  return self
end

function Slot:onFindMouseFocus (mx, my, foci)
  if self.focusable and self:containsPoint(mx, my) then
    foci.focus = self
  end
end

function Slot:onClick (state)
  if self.onSelect then self.onSelect(self.item) end
end

function Slot:onDraw (focus, active)
  local x, y, sx, sy = self:getRectGlobal()
  local bg
  if focus == self then
    bg = Color(0.20, 0.60, 1.00, 0.35)
  elseif active == self then
    bg = Color(0.80, 0.40, 0.30, 0.30)
  else
    bg = Color(0.06, 0.08, 0.12, 0.65)
  end
  DrawEx.Panel(x, y, sx, sy, bg, 0.45)
  DrawEx.RectOutline(x, y, sx, sy, Color(0.35, 0.55, 0.75, 0.45))

  local font = Config.ui.font.normal
  local bound = font:getSize(self.item.name)
  font:draw(self.item.name, x + 6, y + sy - bound.y - 6, 0.85, 0.88, 0.95, 0.95)

  local qty = string.format('x%d', self.item.qty)
  local qb = font:getSize(qty)
  font:draw(qty, x + sx - qb.z - 6, y + 6, 0.55, 0.75, 0.95, 0.85)
end

-- ---------------------------------------------------------------------------
-- The app
-- ---------------------------------------------------------------------------

local UIDemo = Application()

function UIDemo:getTitle ()
  return 'UI Demo'
end

function UIDemo:onInit ()
  self.ship = makeShip()
  self.contacts = makeContacts()
  self.selected = INVENTORY[1]
  self.logLines = { 'UI framework demo: every widget here is real.' }

  self.canvas = Canvas()
  self:buildUI()
end

-- A helper for the panels: size to the content, and place with an ALIGN
-- FRACTION of the canvas, so the layout holds at any window size.
local function panel (grid, ax, ay)
  grid:setStretch(0, 0)
  grid:setAlign(ax, ay)
  return grid
end

function UIDemo:buildUI ()
  -- 1. SHIP STATUS -- a Grid of Labels. Each Label polls the ship, so the
  --    panel updates without anybody telling it to.
  self.statusGrid = Grid():setCols(2):setPadCellX(10)
  self.statusGrid
    :add(Label('HULL'))
    :add(Label():setMinWidth(80):setFormat('%.1f%%')
      :setPollFn(function () return self.ship.hull end))
    :add(Label('SHIELDS'))
    :add(Label():setMinWidth(80):setFormat('%.1f%%')
      :setPollFn(function () return self.ship.shields end))
    :add(Label('FUEL'))
    :add(Label():setMinWidth(80):setFormat('%.1f%%')
      :setPollFn(function () return self.ship.fuel end))
    :add(Label('SPEED'))
    :add(Label():setMinWidth(80):setFormat('%.0f u/s')
      :setPollFn(function () return self.ship.speed end))
    :add(Label('SECTOR'))
    :add(Label():setMinWidth(140)
      :setPollFn(function () return self.ship.sector end))
    :add(Label('REGION'))
    :add(Label():setMinWidth(140)
      :setPollFn(function () return self.ship.region end))
    :add(Label('CHARACTER'))
    :add(Label():setMinWidth(140)
      :setPollFn(function () return self.ship.archetype end))
    :add(Label('NEXT BOUNDARY'))
    :add(Label():setMinWidth(80):setFormat('%.0f m')
      :setPollFn(function () return self.ship.boundary end))

  -- 2. FLIGHT -- the controls. These do something, on purpose.
  local controls = Grid():setCols(2):setPadCellX(10)
    :add(Label('THROTTLE'))
    :add(Slider(
      function () return self.ship.throttle end,
      function (v) self.ship.throttle = v end,
      0, 1))
    :add(Label('AUTOPILOT'))
    :add(Checkbox(
      function () return self.ship.autopilot end,
      function (v) self.ship.autopilot = v end))
    :add(Label('QUALITY'))
    :add(OptionSlider(
      function () return self.ship.quality end,
      function (v) self.ship.quality = v end,
      QUALITIES,
      self.ship.quality))

  local more = Grid():setCols(2):setPadCellX(10)
    :add(Label('TARGETS'))
    :add(Label():setMinWidth(60):setFormat('%d')
      :setPollFn(function () return #self.contacts end))
    :add(Label('REGION'))
    :add(Label():setMinWidth(120)
      :setPollFn(function () return self.ship.region end))

  self.flightGrid = Grid():setCols(1)
  self.flightGrid
    :add(controls)
    :add(Button('DOUBLE THE RADAR RANGE', function ()
      self.ship.radarRange = self.ship.radarRange * 2
      self:addLog(string.format('Radar range now %d km',
        math.floor(self.ship.radarRange / 1000)))
    end))
    :add(Button('SCAN', function ()
      self.contacts[#self.contacts + 1] = {
        name = 'Ping ' .. #self.contacts,
        kind = 'neutral',
        angle = (self.t or 0) * 1.7 % (2 * math.pi),
        dist = 1500 + 400 * (#self.contacts % 5),
        hp = 1.0,
      }
      self:addLog('Scan: one new contact.')
    end))
    :add(Collapsible('MORE', true):add(more))

  -- 3. INVENTORY -- a Grid of focusable custom widgets, and a readout of
  --    whatever is selected.
  local slotGrid = Grid():setCols(3):setPadCellX(6)
  for _, item in ipairs(INVENTORY) do
    slotGrid:add(Slot(item, function (it)
      self.selected = it
      self:addLog('Selected ' .. it.name)
    end))
  end

  self.invGrid = Grid():setCols(1)
  self.invGrid
    :add(slotGrid)
    :add(Label():setPollFn(function ()
      local it = self.selected
      if not it then return 'nothing selected' end
      return string.format('%s  x%d  (%s)', it.name, it.qty, it.kind)
    end))

  -- 4. The log -- a ScrollView, because the log grows.
  self.logGrid = Grid():setCols(1)
  self.logContent = Grid():setCols(1)
  local scroll = ScrollView():setScrollable(false, true):setSize(430, 110)
  scroll:add(self.logContent)
  self.logGrid:add(scroll)
  for _, line in ipairs(self.logLines) do
    self.logContent:add(Label(line))
  end
  self.logPanel = self.logGrid

  -- 5. The custom widgets.
  self.radar = Radar(self)
  self.brackets = TargetBrackets(self)
  self.map = SectorMap(self)
  -- Centred in the column's cell, which is as wide as the widest of them.
  self.radar:setAlign(0.5, 0.5)
  self.brackets:setAlign(0.5, 0.5)
  self.map:setAlign(0.5, 0.5)

  -- 6. THE COLUMNS.
  --
  -- The panels are ROWS of a one-column Grid, not loose canvas children.
  -- A container does not flow its children -- it hands every child the same
  -- rect and lets each child's own align decide where it lands -- so loose
  -- children overlap as soon as two of them want the same corner. A grid
  -- stacks its rows, so a column cannot collide with itself.
  local leftColumn = panel(Grid():setCols(1):setPadCellY(12):setPad(14, 14, 10, 10), 0, 0.01)
  leftColumn
    :add(self.statusGrid)
    :add(self.flightGrid)
    :add(self.invGrid)
    :add(self.logPanel)

  local rightColumn = panel(Grid():setCols(1):setPadCellY(12):setPad(14, 14, 10, 10), 1, 0.01)
  rightColumn
    :add(self.radar)
    :add(self.brackets)
    :add(self.map)

  self.canvas:add(leftColumn)
  self.canvas:add(rightColumn)
end

function UIDemo:addLog (line)
  self.logLines[#self.logLines + 1] = line
  self.logContent:add(Label(line))
end

function UIDemo:onInput ()
  self.canvas:input()
end

function UIDemo:onUpdate (dt)
  self.t = (self.t or 0) + dt

  -- The simulated ship: the throttle drives the speed, and the autopilot
  -- turns it. Nothing here is the game's physics -- it is a screen with
  -- something moving on it.
  local ship = self.ship
  ship.speed = 500 * ship.throttle
  if ship.autopilot then
    ship.heading = ship.heading + dt * 0.6
    ship.mapX = ship.mapX + math.cos(ship.heading) * ship.speed * dt * 0.001
    ship.mapY = ship.mapY + math.sin(ship.heading) * ship.speed * dt * 0.001
  end
  ship.boundary = ship.boundary - dt * ship.speed * 0.1
  if ship.boundary < 0 then ship.boundary = 2400 end

  -- The contacts drift, so the radar is not a still picture.
  for _, c in ipairs(self.contacts) do
    c.angle = c.angle + dt * 0.08
    c.dist = math.max(200, c.dist - dt * 30)
  end

  self.canvas:update(dt)

end

function UIDemo:onDraw ()
  -- The backdrop. This has to be Draw.Clear and not a rectangle: a raw
  -- Draw.Rect needs a shader and a texture already bound, and with none
  -- bound it walks into Tex2D_GetHandle with a null texture and takes the
  -- process down with it. DrawEx is safe -- it starts its own shader.
  local w, h = self.resX, self.resY
  Draw.Clear(0.015, 0.02, 0.035, 1.0)

  -- A few stars, so the backdrop is not flat.
  for i = 1, 120 do
    local sx = ((i * 7919) % 1000) / 1000 * w
    local sy = ((i * 6271) % 1000) / 1000 * h
    local b = 0.10 + ((i * 37) % 100) / 100 * 0.35
    DrawEx.Point(sx, sy, 1.5, Color(b, b, b * 1.1, 1.0))
  end

  self.canvas:draw(self.resX, self.resY)

end

function UIDemo:onDraw ()
  -- The backdrop. This has to be Draw.Clear and not a rectangle: a raw
  -- Draw.Rect needs a shader and a texture already bound, and with none
  -- bound it walks into Tex2D_GetHandle with a null texture and takes the
  -- process down with it. DrawEx is safe -- it starts its own shader.
  local w, h = self.resX, self.resY
  Draw.Clear(0.015, 0.02, 0.035, 1.0)

  -- A few stars, so the backdrop is not flat.
  for i = 1, 120 do
    local sx = ((i * 7919) % 1000) / 1000 * w
    local sy = ((i * 6271) % 1000) / 1000 * h
    local b = 0.10 + ((i * 37) % 100) / 100 * 0.35
    DrawEx.Point(sx, sy, 1.5, Color(b, b, b * 1.1, 1.0))
  end

  self.canvas:draw(self.resX, self.resY)

  -- TEMP probe
  if not self.__probed2 then
    self.__probed2 = true
    print(string.format('[PROBE] resX=%s resY=%s', tostring(self.resX), tostring(self.resY)))
    for name, w in pairs({status=self.statusGrid, flight=self.flightGrid, inv=self.invGrid,
                          log=self.logPanel, radar=self.radar, brackets=self.brackets, map=self.map}) do
      local x, y, sx, sy = w:getRectGlobal()
      print(string.format('[PROBE] %-9s x=%s y=%s sx=%s sy=%s align=(%s,%s) stretch=(%s,%s)',
        name, tostring(x), tostring(y), tostring(sx), tostring(sy),
        tostring(w.alignX), tostring(w.alignY), tostring(w.stretchX), tostring(w.stretchY)))
    end
  end
end

return UIDemo
