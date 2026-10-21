--[[ SectorPanel -- the upper-left readout of where you are.

  Phase A of the region work: NAME the place you are in.

  Without it, a region is a number in a field: crossing one changes nothing
  you can see or read. With it, the region becomes a place, and the map (F10)
  and the bearing arrow have something to refer to.

  WHY IT IS A WIDGET AND NOT DRAWEX CALLS
  ======================================
  This is built out of the UI framework's own pieces -- a Panel with Label
  children -- rather than raw DrawEx calls, because the framework already
  solves the things a hand-rolled panel gets wrong: layout (the panel sizes
  itself to its content), the font metrics, the colour theme (Config.ui.color),
  and the enable/disable fade. The other HUD elements that draw themselves
  (the atmosphere warning) do it by hand because they are a single transient
  alert; this one is persistent chrome with several lines of text that change
  when you cross a boundary, which is exactly what a Label with a poll
  function is for.

  The panel is deliberately in the upper LEFT: the centre of the screen is
  where the reticle, the target brackets and the dock prompt live, and a
  readout there would fight them.
]]

local Container = require('UI.Container')
local Widget = require('UI.Widget')
local Label = require('UI.Label')
local DrawEx = require('UI.DrawEx')

local SectorPanel = {}
SectorPanel.__index = SectorPanel
setmetatable(SectorPanel, Container)

SectorPanel.name = 'Sector Panel'

-- The two shades the readout is drawn in.
--
-- THREE shades, because the panel carries three kinds of thing and they
-- should not all shout:
--
--   * TITLE  -- the field name ("Sector"). The theme's accent, DEEP and
--     saturated. It is the "bold" of the panel: the bitmap font has no bold
--     face, so weight is not available to separate it from the value --
--     colour is.
--   * VALUE  -- the name itself ("The Vexing Reach"). A lighter shade of the
--     same hue. Lighter than the title, which is what makes the name the
--     thing the eye lands on.
--   * SUBTLE -- the supporting lines (the archetype, the distance to the
--     boundary). Dimmer than both, so the panel has a hierarchy instead of
--     four equally loud lines.
--
-- All three are derived from Config.ui.color.accent rather than hard-coded,
-- so they follow the theme if it is ever re-tinted.
local function shade (color, mul, add)
  return Color(
    math.min(1.0, color.r * mul + add),
    math.min(1.0, color.g * mul + add),
    math.min(1.0, color.b * mul + add),
    color.a)
end

local ACCENT = Config.ui.color.accent
-- The accent is a saturated crimson (1.00, 0.00, 0.30), so scaling it
-- straight down gives a muddy dark red rather than a strong one. The title
-- is pulled back only in the RED channel, keeping the hue, and given a floor
-- so it stays saturated rather than turning grey.
local TITLE_COLOR = Color(
  math.min(1.0, ACCENT.r * 0.62),
  math.min(1.0, ACCENT.g * 0.30),
  math.min(1.0, ACCENT.b * 0.42), ACCENT.a)
-- The value: a pale tint of the accent -- the same hue, lifted towards
-- white, so it reads as "the accent, but softer".
local VALUE_COLOR = shade(ACCENT, 0.45, 0.55)
-- The supporting lines: present, but clearly behind the names.
local SUBTLE_COLOR = shade(ACCENT, 0.30, 0.34)

-- The lines, in order. The key is the field of the info table the HUD fills
-- in; the prefix is the text shown BEFORE the value, so the readout reads
-- "Sector: The Vexing Reach" rather than a bare name -- which matters when
-- the panel sits over a starfield and the reader has no context for a
-- two-word proper noun.
--
-- The prefixes are CAPITALISED because they are TITLES, not values: the value
-- ("The Vexing Reach") is a proper noun and keeps its own capitalisation,
-- and a lowercase prefix next to a capitalised value reads as one run-on
-- phrase. The value is drawn in a lighter shade than the title so the two
-- are distinguishable at a glance without needing bold (the bitmap font has
-- no bold face -- the theme's title font is the bold one, and swapping fonts
-- per line would break the panel's single-width layout).
local LINES = {
  { key = 'sectorLabel',    prefix = 'Sector:' },
  { key = 'regionLabel',    prefix = 'Region:' },
  { key = 'archetypeLabel', prefix = '', subtle = true },
  { key = 'bearingLabel',   prefix = '', subtle = true },
  { key = 'gateLabel',      prefix = '', subtle = true },
  { key = 'laneLabel',      prefix = '', subtle = true },
}

function SectorPanel.Create ()
  local self = setmetatable({
    -- infoFn: a FUNCTION returning the current info table, or nil.
    --
    -- A function rather than a plain field, because the panel's LABELS poll
    -- their text during the panel's own update, and the HUD's update (which
    -- computes the info) can land either side of that in the UI tree's
    -- update/draw passes. A function is read at the moment the text is
    -- generated, so the ordering cannot make the panel a frame stale -- and
    -- the very first frame cannot leave it empty.
    infoFn = nil,
    labels = {},
    children = List(),
  }, SectorPanel)

  -- The panel: a thin, mostly-transparent plate, sized to its content.
  --
  -- MARGIN: the plate is inset from the screen corner, so it does not sit
  -- flush against the edge. The HUD's own rect already carries a little
  -- padding, but the panel was landing hard against the corner, and a plate
  -- that touches two screen edges reads as a rendering glitch rather than as
  -- an instrument.
  --
  -- ASYMMETRIC PADDING: the left is 12 and the right is 30. The right needs
  -- more because the panel's width is measured from the text's INK bounds
  -- (Font_GetSize returns the ink extent, not the advance width), so the last
  -- glyph's trailing bearing would otherwise sit flush against the border --
  -- and because the labels are left-aligned, every line but the longest
  -- leaves that gap empty. A symmetric 10 looked cramped on the right.
  self:setStretch(0.0, 0.0)
  self:setAlign(0.0, 0.0)
  self:setPadX(12, 30)
  self:setPadY(10, 12)
  -- The inset from the corner the HUD's rect gives it. The HUD carries a
  -- pad of its own (8), so the plate ends up 18 from the screen edge -- which
  -- is the "about 10 pixels of my own padding" the panel was asked for.
  self.marginX = 10
  self.marginY = 10

  for _, line in ipairs(LINES) do
    -- Each line is TWO labels: a title ("Sector") and a value ("The Vexing
    -- Reach"). They are separate labels rather than one string so they can be
    -- drawn in DIFFERENT COLOURS -- the title in the theme's title colour and
    -- the value in a lighter shade of it -- which is what distinguishes them
    -- at a glance. The bitmap font has no bold face, so weight is not
    -- available; colour is.
    local title = Label('')
    title:setAlign(0.0, 0.0)
    -- The TITLE is drawn in the theme's accent colour and the VALUE in a
    -- lighter, warmer shade of it. The bitmap font has no bold face, so
    -- weight is not available to separate them -- colour is.
    --
    -- The two shades are derived from the accent rather than hard-coded, so
    -- they follow the theme if it is ever re-tinted.
    title:setFontColor(TITLE_COLOR)
    title:setPollFn(function ()
      local info = self.infoFn and self.infoFn()
      if not info then return '' end
      local v = info[line.key]
      if v == nil or v == '' then return '' end
      if line.prefix == '' then return '' end
      return line.prefix
    end)

    local value = Label('')
    value:setAlign(0.0, 0.0)
    value:setFontColor(line.subtle and SUBTLE_COLOR or VALUE_COLOR)
    value:setPollFn(function ()
      local info = self.infoFn and self.infoFn()
      if not info then return '' end
      local v = info[line.key]
      if v == nil or v == '' then return '' end
      return v
    end)

    self.labels[line.key] = { title = title, value = value }
    self:add(title)
    self:add(value)
  end
  return self
end

function SectorPanel:onLayoutSizeChildren ()
  -- The labels are positioned in onLayoutPosChildren, so the container's own
  -- child-sizing pass would measure them at their stale positions. Size the
  -- panel from the label metrics directly instead -- the labels are all
  -- left-aligned in a vertical stack, so the panel is as wide as its widest
  -- line and as tall as the stack.
  --
  -- The width is the text's ADVANCE width, not its ink width. Font_GetSize
  -- returns the INK extent (upper.x - lower.x), which for a string ending in
  -- a narrow glyph is narrower than the space the glyph actually occupies --
  -- so measuring the ink would make the panel a few pixels too narrow and
  -- press the last character against the border. `label.desiredSX` is the
  -- label's own layout width, which accounts for that.
  local w, h = 0, 0
  for _, line in ipairs(LINES) do
    local pair = self.labels[line.key]
    if pair.value.bound.z > 0 then
      local titleW = pair.title.bound.z
      -- The title and the value are separated by a space's worth of gap.
      local gap = (titleW > 0) and 10 or 0
      w = math.max(w, titleW + gap + pair.value.desiredSX)
      h = h + pair.value.bound.w + 4
    end
  end
  self.desiredSX = self.padSumX + w
  self.desiredSY = self.padSumY + h
end

-- The panel is INSET from the corner its parent gives it. The HUD's rect
-- already carries a little padding, but the plate was landing hard against
-- the screen edge, and a panel touching two screen edges reads as a
-- rendering glitch rather than as an instrument.
function SectorPanel:onLayoutPos (px, py, psx, psy)
  Widget.onLayoutPos(self, px, py, psx, psy)
  self.x = self.x + (self.marginX or 0)
  self.y = self.y + (self.marginY or 0)
end

function SectorPanel:onLayoutPosChildren ()
  -- Stack the lines vertically, each a title then its value.
  --
  -- This runs AFTER Container:onLayoutPosChildren would have positioned the
  -- children, so the labels end up exactly where this puts them.
  --
  -- The labels' drawText places the text at
  --   label.x + label.padMinX + alignX * (label.sx - ...) - bound.x
  -- and bound.x is the ink's left bearing, so the text can start a pixel or
  -- two LEFT of label.x. Compensating here keeps every line flush at the
  -- panel's left padding.
  local ox, oy = self:getPosGlobal()
  local y = oy + self.padMinY
  for _, line in ipairs(LINES) do
    local pair = self.labels[line.key]
    if pair.value.bound.z > 0 then
      local tx = ox + self.padMinX
      if pair.title.bound.z > 0 then
        pair.title:setPos(tx - pair.title.bound.x, y)
        pair.title.clamp = false
        tx = tx + pair.title.desiredSX + 10
      end
      pair.value:setPos(tx - pair.value.bound.x, y)
      pair.value.clamp = false
      y = y + pair.value.bound.w + 4
    end
  end
end

function SectorPanel:onDraw (focus, active)
  local x, y, sx, sy = self:getRectGlobal()
  -- A dark plate: additive text over a bright nebula was unreadable (the same
  -- lesson as the atmosphere warning).
  DrawEx.Panel(x, y, sx, sy, Color(0.02, 0.03, 0.06, 0.72), 0.5)
  DrawEx.RectOutline(x, y, sx, sy, Color(0.35, 0.55, 0.75, 0.55))
  Container.onDraw(self, focus, active)
end

return SectorPanel
