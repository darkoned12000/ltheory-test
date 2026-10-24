--[[ Table -- a reusable data table: outlined frame, sticky column
  headers, wheel-scrollable rows, and cells that take plain text, styled
  text, an image texture, or any widget (the trade buttons).

  WHY THIS EXISTS: the market's BUY/SELL tabs need it, and the user
  called it critical infrastructure -- every future buy/sell situation
  (ship outfits, hangar storage, market boards) uses the same table, so
  it is built ONCE, generically, here.

  THE LAYOUT DISCIPLINE (house rules): the frame is a one-column grid
  whose rows are the header band and the scroll view; the header stays
  put while the data rows scroll under it. Column widths are FIXED per
  column, so every row's cells land on the same x.

  THE DISPATCH DISCIPLINE: an instance's `onDraw` is the framework's
  virtual (draw -> onDraw -> onDrawChildren), so outline/header
  decorations painted there sit UNDER the content -- never over it.
]]

local Grid = require('UI.Grid')
local ScrollView = require('UI.ScrollView')
local Label = require('UI.Label')
local Image = require('UI.Image')
local DrawEx = require('UI.DrawEx')

local Table = {}

-- The palette, from the menu's own family. The header band reads as a
-- DIFFERENT shade on purpose (the user's ask): darker and more opaque
-- than the rows, with the accent line under it.
local OUTLINE = Color(0.45, 0.80, 1.0, 0.35)
local HEAD_BG = Color(0.05, 0.08, 0.15, 0.95)
local HEAD_TX = Color(0.74, 0.82, 0.94, 1.0)
local LINE_C  = Color(0.45, 0.80, 1.0, 0.14)
local WHITE   = Color(0.88, 0.93, 0.98, 1.0)

-- `cols`: an array of { title = 'PRICE', width = 100 }.
-- `opts`: { height = 320 } -- the visible height of the scrolled rows.
function Table.Create (cols, opts)
  local frame = Grid():setCols(1) -- [header; scrolled rows]
  frame:setStretch(0, 0)

  -- The sticky header: OUTSIDE the scroll, so it never moves.
  local header = Grid():setCols(#cols)
  header:setPadCellX(8)
  for _, col in ipairs(cols) do
    local l = Label():setText(col.title or '')
    l:setFontColor(HEAD_TX)
    if col.width then l:setWidth(col.width) end
    header:add(l)
  end
  -- The header's own COLUMN lines, from the laid-out cells' real rects.
  header.onDraw = function (_, focus, active)
    local x, y, sx, sy = header:getRectGlobal()
    for i = 1, #header.children - 1 do
      local c = header.children[i]
      local cx, cy, csx, csy = c:getRectGlobal()
      DrawEx.Rect(cx + csx + 4, y + 2, 1, sy - 4, LINE_C)
    end
  end

  local rows = Grid():setCols(1)
  rows:setStretch(0, 0)
  local scroll = ScrollView():setScrollable(false, true)
  scroll:setMinSize(0, opts.height or 320)
  scroll:setStretch(0, 0)
  scroll:add(rows)

  -- The outline + the header band's underline (drawn under the content).
  -- The underline runs the FULL frame width: the header row can be
  -- narrower than the widest data row (button clusters are wider than
  -- their header cell), and a short line reads as a bug.
  frame.onDraw = function (_, focus, active)
    local x, y, sx, sy = frame:getRectGlobal()
    DrawEx.RectOutline(x, y, sx, sy, OUTLINE)
    local hx, hy, hsx, hsy = header:getRectGlobal()
    if hsx > 2 and hsy > 2 then
      DrawEx.Panel(hx + 1, hy + 1, hsx - 2, hsy - 2, HEAD_BG, 0.25)
    end
    DrawEx.Rect(x, hy + hsy, sx, 1, OUTLINE)
  end

  -- AddRow: cells matched column-by-column. A cell is a string or
  -- number (plain text), { text =, color = } (styled text),
  -- { image = tex } (a small item icon), or any widget (button grids).
  -- Each row draws a separator under it AND the vertical column lines
  -- between its cells, from the cells' real rects.
  frame.AddRow = function (_, cells)
    local row = Grid():setCols(#cols)
    row:setPadCellX(8)
    row.onDraw = function (_, focus, active)
      local x, y, sx, sy = row:getRectGlobal()
      DrawEx.Rect(x, y + sy, sx, 1, LINE_C)
      for i = 1, #row.children - 1 do
        local c = row.children[i]
        local cx, cy, csx, csy = c:getRectGlobal()
        DrawEx.Rect(cx + csx + 4, y + 2, 1, sy - 4, LINE_C)
      end
    end
    for i = 1, #cols do
      local c = cells[i]
      -- EVERY CELL RESPECTS ITS COLUMN'S WIDTH: a text cell that sizes
      -- to its own content ("26") breaks the alignment with the header
      -- column above it ("PRICE", 110px) -- the squeezed, unprofessional
      -- look the user called out. Widgets (buttons) size themselves;
      -- images too.
      local colWidth = cols[i] and cols[i].width or nil
      if c == nil then
        -- An empty cell keeps the column alive.
      elseif type(c) == 'string' or type(c) == 'number' then
        local l = Label():setText(tostring(c)):setFontColor(WHITE)
        if colWidth then l:setWidth(colWidth) end
        row:add(l)
      elseif type(c) == 'table' and c.image then
        row:add(Image.Create(c.image))
      elseif type(c) == 'table' and c.text then
        local l = Label():setText(c.text)
        l:setFontColor(c.color or WHITE)
        l:setWidth(c.width or colWidth)
        row:add(l)
      else
        row:add(c)
      end
    end
    rows:add(row)
    return row
  end

  frame:add(header)
  frame:add(scroll)
  return frame
end

return Table
