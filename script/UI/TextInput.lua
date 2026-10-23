--[[ TextInput -- a one-line text field.

  WHY IT READS KEYS ITSELF
  ========================
  The engine's input API is `Input.GetPressed(button)` and
  `Input.GetValue(button)` -- there are no CHARACTER events. So a text
  field has to map the keys it wants to their characters itself, which is
  fine for the small alphabets a game needs and hopeless for general text
  entry. This one takes HEX, because a world seed is a 64-bit number and a
  seed you can type is a seed you can share.

  It is focusable, so it takes the keyboard the way any other widget does:
  the canvas routes the keys to the focused widget's `inputFocused`.

  USAGE
  =====
      local field = TextInput.Create(16)
      field.onSubmit = function (text) ... end
      panel:add(field)
]]

local Widget = require('UI.Widget')
local DrawEx = require('UI.DrawEx')

local TextInput = {}
TextInput.__index = TextInput
setmetatable(TextInput, Widget)

TextInput.name      = 'Text Input'
TextInput.focusable = true

-- The characters it accepts: 0-9 and A-F, so a 64-bit seed fits in
-- sixteen of them.
local CHARS = {}
do
  for i = 0, 9 do
    CHARS[#CHARS + 1] = { tostring(i), Button.Keyboard['N' .. i] }
  end
  for i = 0, 5 do
    local c = string.char(65 + i)
    CHARS[#CHARS + 1] = { c, Button.Keyboard[c] }
  end
end

function TextInput.Create (maxLength, initial)
  local self = setmetatable({
    text      = initial or '',
    maxLength = maxLength or 16,
    caretOn   = true,
    caretT    = 0,
  }, TextInput)
  self:setStretch(0, 0)
  self.desiredSX = 320
  self.desiredSY = 34
  return self
end

function TextInput:setText (text)
  self.text = text or ''
  return self
end

function TextInput:getText ()
  return self.text
end

function TextInput:onUpdate (state)
  -- The caret blinks.
  self.caretT = self.caretT + (state.dt or 0)
  if self.caretT >= 0.5 then
    self.caretT = 0
    self.caretOn = not self.caretOn
  end
end

function TextInput:inputFocused (state)
  -- NOTE : Override `inputFocused`, NOT `onInputFocused`: the canvas
  -- dispatches `inputFocused` (which Widget routes on to `onInput` — and the
  -- raw per-frame path calls `onInput` on every widget, focused or not). A
  -- text field must take keys ONLY while focused and any onInput override
  -- would leak keystrokes into it while you fly the ship.
  for _, c in ipairs(CHARS) do
    if Input.GetPressed(c[2]) then
      if #self.text < self.maxLength then
        self.text = self.text .. c[1]
      end
      return
    end
  end

  if Input.GetPressed(Button.Keyboard.Backspace) then
    self.text = self.text:sub(1, math.max(0, #self.text - 1))
    return
  end

  if Input.GetPressed(Button.Keyboard.Return) then
    if self.onSubmit then self.onSubmit(self.text) end
    return
  end
end

function TextInput:onDraw (focus, active)
  local x, y, sx, sy = self:getRectGlobal()
  local font = Config.ui.font.normal

  local bg = focus == self and Color(0.10, 0.16, 0.24, 0.95)
                         or Color(0.05, 0.07, 0.11, 0.85)
  DrawEx.Panel(x, y, sx, sy, bg, 0.5)
  DrawEx.RectOutline(x, y, sx, sy,
    focus == self and Color(0.45, 0.80, 1.0, 0.9) or Color(0.30, 0.50, 0.70, 0.45))

  -- The draw y is the framework's centering formula (`Widget:drawText`,
  -- `y + (sy + bound.y) * 0.5 - bound.y`); the early `(sy - bound.y)`
  -- variant hung the text below the plate by one glyph ascent.
  local textCol = Color(0.88, 0.93, 0.98, 1.0)
  local bound = font:getSize(self.text)
  font:draw(self.text, x + 10, y + (sy + bound.y) * 0.5 - bound.y,
    textCol.r, textCol.g, textCol.b, textCol.a)

  -- The caret.
  if focus == self and self.caretOn then
    DrawEx.Rect(x + 12 + bound.z, y + 6, 2, sy - 12, Color(0.55, 0.85, 1.0, 0.9))
  end
end

return TextInput
