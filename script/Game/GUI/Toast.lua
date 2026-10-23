--[[ Toast -- transient game messages, drawn over the game's own UI pass.

  THE SHAPE is the old game's quicksave/quickload notification (the
  user's mock): a dark plate with a BLUE ACCENT BAR down its left edge,
  a caps headline (GAME SAVED / GAME LOADED), then label:value rows --
  labels near-white, values in the save-blue -- and an optional yellow
  NOTE line. Exo2Bold headline, NovaMono rows.

  They stack from the top-right, slide in from that edge, hold ~4 s,
  fade out.

  THE CLOCK RULE: toasts age ONLY while the game is live. A toast queued
  from a menu action (a LOAD row, a menu SAVE) would otherwise expire
  unseen behind the menu; LTheory passes dt = 0 while any screen is
  open, so the toast is still there, full alpha, the moment the world
  comes back. Toast.Clear runs wherever the WORLD is replaced (new
  game, loaded game), so a stale toast never describes the wrong
  universe.
]]

local DrawEx = require('UI.DrawEx')

local Toast = {}

local MAX_TOASTS = 3
local list = {}

-- The palette: the menu's focus blue for the bar and values, the popups'
-- muted blue-grey for labels, the mock's yellow for notes.
local ACCENT   = {0.30, 0.70, 1.00}
local TITLE_C  = {0.92, 0.96, 1.00}
local LABEL_C  = {0.88, 0.93, 0.98}
local VALUE_C  = {0.55, 0.85, 1.00}
local NOTE_C   = {1.00, 0.82, 0.35}

local PLATE_W  = 470
local PAD_X    = 18
local BAR_W    = 4
local TITLE_H  = 28
local ROW_H    = 21
local ROW_GAP  = 8
local GAP      = 10
local MARGIN   = 26
local FADE_IN  = 0.22
local FADE_OUT = 0.60

-- A toast: `title`, then a ROW LIST where each row is either
--   { label = 'Credits', value = '10000' }   -- white label, blue value
--   { note  = '...' }                        -- full-width yellow line
function Toast.Show (title, rows, ttl)
  list[#list + 1] = { title = title, rows = rows or {}, t = 0, ttl = ttl or 4.0 }
  if #list > MAX_TOASTS then table.remove(list, 1) end
end

function Toast.Update (dt)
  for i = #list, 1, -1 do
    local t = list[i]
    t.t = t.t + dt
    if t.t >= t.ttl then table.remove(list, i) end
  end
end

function Toast.Clear ()
  list = {}
end

function Toast.Draw (x, y, sx, sy)
  for i = 1, #list do
    local t = list[i]
    local alphaIn  = math.min(1.0, t.t / FADE_IN)
    local alphaOut = math.min(1.0, (t.ttl - t.t) / FADE_OUT)
    local alpha = alphaIn * alphaOut
    if alpha > 0 then
      -- Slide the plate in from the right edge as it fades in.
      local slide = (1.0 - alphaIn) * 36
      local h = TITLE_H + 10 + #t.rows * (ROW_H + ROW_GAP) + 10
      local px = x + sx - PLATE_W - MARGIN + slide
      local py = y + MARGIN + (i - 1) * (h + GAP)
      DrawEx.Panel(px, py, PLATE_W, h,
        Color(0.02, 0.04, 0.08, 0.92 * alpha), 0.5)
      DrawEx.RectOutline(px, py, PLATE_W, h,
        Color(ACCENT[1], ACCENT[2], ACCENT[3], 0.40 * alpha))
      -- The ACCENT BAR: the mock's vertical blue line on the left edge.
      DrawEx.Rect(px + 6, py + 8, BAR_W, h - 16,
        Color(ACCENT[1], ACCENT[2], ACCENT[3], 0.85 * alpha))
      DrawEx.TextAdditive('Exo2Bold', t.title, 19,
        px + PAD_X + BAR_W, py + 10, PLATE_W - PAD_X * 2, TITLE_H,
        TITLE_C[1], TITLE_C[2], TITLE_C[3], alpha, 0.0, 0.0)
      -- The rows: 'Label:' in near-white, the value after it in the
      -- save-blue -- the mock's two-color line, positioned by measuring
      -- the label.
      local rowFont = Cache.Font('NovaMono', 14)
      for r = 1, #t.rows do
        local row = t.rows[r]
        local ry = py + 10 + TITLE_H + (r - 1) * (ROW_H + ROW_GAP)
        if row.note then
          DrawEx.TextAdditive('NovaMono', row.note, 14,
            px + PAD_X + BAR_W, ry, PLATE_W - PAD_X * 2 - BAR_W, ROW_H,
            NOTE_C[1], NOTE_C[2], NOTE_C[3], alpha, 0.0, 0.0)
        else
          local label = (row.label or '') .. ': '
          DrawEx.TextAdditive('NovaMono', label, 14,
            px + PAD_X + BAR_W, ry, PLATE_W - PAD_X * 2 - BAR_W, ROW_H,
            LABEL_C[1], LABEL_C[2], LABEL_C[3], alpha, 0.0, 0.0)
          local bound = rowFont and rowFont:getSize(label)
          local valueX = px + PAD_X + BAR_W + (bound and bound.z or 90) + 10
          DrawEx.TextAdditive('NovaMono', tostring(row.value or ''), 14,
            valueX, ry, PLATE_W - (valueX - px) - PAD_X, ROW_H,
            VALUE_C[1], VALUE_C[2], VALUE_C[3], alpha, 0.0, 0.0)
        end
      end
    end
  end
end

return Toast
