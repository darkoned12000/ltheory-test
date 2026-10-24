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

-- The palette, from the menu's own family.
local OUTLINE = Color(0.45, 0.80, 1.0, 0.30)
local HEAD_BG = Color(0.10, 0.14, 0.24, 0.90)
local HEAD_TX = Color(0.74, 0.82, 0.94, 1.0)
local LINE_C  = Color(0.45, 0.80, 1.0, 0.12)
local WHITE   = Color(0.88, 0.93, 0.98, 1.0)

-- `cols`: an array of { title = 'PRICE', width = 100 }.
-- `opts`: { height = 320 } -- the visible height of the scrolled rows.
function Table.Create (cols, opts)
  local frame = Grid():setCols(1) -- [header; scrolled rows]
  frame:setStretch(0, 0)

  -- The sticky header: OUTSIDE the scroll, so it never moves.
  local header = Grid():setCols(#cols)
  header:setPadCellX(4)
  for _, col in ipairs(cols) do
    local l = Label():setText(col.title or '')
    l:setFontColor(HEAD_TX)
    if col.width then l:setWidth(col.width) end
    header:add(l)
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
  -- Each row draws a faint separator under it.
  frame.AddRow = function (_, cells)
    local row = Grid():setCols(#cols)
    row:setPadCellX(4)
    row.onDraw = function (_, focus, active)
      local x, y, sx, sy = row:getRectGlobal()
      DrawEx.Rect(x, y + sy, sx, 1, LINE_C)
    end
    for i = 1, #cols do
      local c = cells[i]
      if c == nil then
        -- An empty cell keeps the column alive.
      elseif type(c) == 'string' or type(c) == 'number' then
        row:add(Label():setText(tostring(c)):setFontColor(WHITE))
      elseif type(c) == 'table' and c.image then
        row:add(Image.Create(c.image))
      elseif type(c) == 'table' and c.text then
        local l = Label():setText(c.text)
        l:setFontColor(c.color or WHITE)
        if c.width then l:setWidth(c.width) end
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
