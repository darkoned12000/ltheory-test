local Bindings  = require('UI.Bindings')
local Container = require('UI.Container')
local DrawEx    = require('UI.DrawEx')
local State     = require('UI.State')

local Canvas = {}
Canvas.__index = Canvas
setmetatable(Canvas, Container)

Canvas.isCanvas = true
Canvas.name     = 'Canvas'

-- THE CUSTOM CURSOR
-- =================
-- `showCursor` turns on a draw-over-everything pointer in place of the
-- system cursor, for apps that want to own their menu feel. It is the old
-- game's `Icon Pointer`: two fading strokes out of a tip, 0 -> (1,2) and
-- 0 -> (2,1) in triangle-normalized space. The system cursor stays hidden
-- the whole session (the app hides it once at boot); this one draws only
-- when there is something to POINT AT -- a modal screen, or a hovered
-- widget -- so a happily flying ship still has no cursor at all.

-- The pointer tip's leg length and its fade resolution.
local cursorLeg = 22
local cursorSegs = 6
local cursorColor = Color(0.55, 0.82, 1.0, 1)

function Canvas:drawCursor (s)
  if not self.showCursor                then return end
  if not (s.modalFocus or s.focus or s.active) then return end
  local mx, my = s.mousePosX, s.mousePosY

  -- Two legs out of the tip, each in fading segments: bright at the tip,
  -- gone by the end. Leg 0->(1,2), leg 0->(2,1), scaled by `cursorLeg`.
  for i = 0, cursorSegs do
    local t0, t1 = i / cursorSegs, (i + 1) / cursorSegs
    local a = (1.0 - t1) * 0.95 + 0.05
    local c = Color(cursorColor.r, cursorColor.g, cursorColor.b, a)
    -- Leg 0->(2,1): the shallow, nearly-horizontal stroke.
    DrawEx.Line(mx + cursorLeg * 2 * t0, my + cursorLeg * t0,
                mx + cursorLeg * 2 * t1, my + cursorLeg * t1, c)
    -- Leg 0->(1,2): the steep, nearly-vertical stroke.
    DrawEx.Line(mx + cursorLeg * t0, my + cursorLeg * 2 * t0,
                mx + cursorLeg * t1, my + cursorLeg * 2 * t1, c)
  end
  -- The tip, filled, so the pointer has an unambiguous head.
  DrawEx.Point(mx + 1, my + 1, 2, cursorColor)
end


function Canvas:findMouseFocus ()
  local s = self.state
  local foci = {}

  if s.modalFocus then
    s.modalFocus:findMouseFocus(s.mousePosX, s.mousePosY, foci)

  elseif s.scrollActive then
    return

  else
    self:onFindMouseFocusChildren(s.mousePosX, s.mousePosY, foci)
  end

  if foci.focus then
    s:setPanelFocus (foci.panelFocus)
    s:setScrollFocus(foci.scrollFocus)
    s:setNavFocus   (foci.navFocus)
    s:setFocus      (foci.focus)
  else
    -- Cursor over nothing focusable (e.g. the game view): drop UI focus so the
    -- panel's widgets stop consuming keyboard input (sliders/WASD, collapsibles)
    -- while you're actually flying the ship.
    s:setFocus(nil)
  end
end

function Canvas:input ()
  Profiler.Begin('Canvas.Input')
  local s = self.state

  Profiler.Begin('Canvas.Focus')
  -- Mouse Focus
  local md = Input.GetMouseDelta()
  local mouseMoved = md.x ~= 0 or md.y ~= 0

  if mouseMoved then
    s.scrollActive = nil
    self:findMouseFocus()
  end

  -- TODO : Remove this once Control:delta() works properly
  local select = Bindings.Select:get()
  local cancel = Bindings.Cancel:get()

  -- Modal Focus
  if s.modalFocus then
    if cancel > 0 then
      s.modalFocus:cancel()
    end

    if select > 0 then
      if not s.focus and not s.modalFocus:containsPoint(s.mousePosX, s.mousePosY) then
        s.modalFocus:cancel()
      end
    end
  end
  Profiler.End()

  Profiler.Begin('Canvas.Drag')
  -- Activate, Begin Drag. Only a real mouse press may start a drag. Space is
  -- both the UI 'select' action AND the ship's mouse-look modifier, so a
  -- keyboard-select must never grab a widget under the cursor: while the
  -- player steers with Space+mouse, the cursor position would otherwise yank a
  -- hovered slider (e.g. to its max).
  local mouseSelect = Input.GetValue(Button.Mouse.Left) > 0
  if s.focus then
    if select > 0 and mouseSelect then
      s.active = s.focus
      if s.active.draggable then s.active:dragBegin(s) end
    end
  end

  -- Drag, End Drag, Deactivate
  if s.active then
    if mouseMoved then
      if s.active.draggable then s.active:drag(s) end
    end

    if select < 0 then
      if s.active.draggable  then s.active:dragEnd(s) end
      -- Always fire click on the press-target on release. The old check
      -- (s.active == s.focus) required the pointer to land on the exact same
      -- widget; any layout shift or scroll between press and release left focus
      -- nil and silently swallowed the click — the main cause of "cannot
      -- interact with debug panel controls".
      s.active:click(s)
      s.active = nil
    end
  end
  Profiler.End()

  Profiler.Begin('Canvas.InputFocused')
  local focus = s:getDeepestFocus()
  while focus and focus ~= self do
    if not focus.removed then focus:inputFocused(s) end
    focus = focus.parent
  end
  Profiler.End()

  Profiler.Begin('Canvas.InputChildren')
  for i = 1, #self.children do
    local child = self.children[i]
    if not child.removed then child:input(s) end
  end
  Profiler.End()

  Profiler.End()
end

function Canvas:update (dt)
  Profiler.Begin('Canvas.Update')
  local s = self.state
  local mp = Input.GetMousePosition()
  s.dt = dt
  s.mousePosX = mp.x
  s.mousePosY = mp.y

  self.timer:reset()
  for i = 1, #self.children do
    local child = self.children[i]
    if not child.removed then child:update(s, dt) end
  end

  do -- Deferred add/remove
    Profiler.Begin('Canvas.DeferredAddRemove')
    for i = 1, #self.removeQueue do
      local op = self.removeQueue[i]
      op.parent:removeImmediate(op.child)
    end
    self.removeQueue:clear()

    for i = 1, #self.addQueue do
      local op = self.addQueue[i]
      op.parent:addImmediate(op.child)
    end
    self.addQueue:clear()
    Profiler.End()
  end

  self.updateTime = self.timer:getElapsed()
  Profiler.End()
end

function Canvas:draw (sx, sy)
  Profiler.Begin('Canvas.Draw')
  local s = self.state

  do -- Layout
    Profiler.Begin('Canvas.Layout')
    self.timer:reset()
    for i = 1, #self.children do self.children[i]:layoutSize() end
    for i = 1, #self.children do self.children[i]:layoutPos(0, 0, 0, 0, sx, sy) end
    self.layoutTime = self.timer:getElapsed()
    Profiler.End()
  end

  s:refreshFocus()

  do -- Debug
    if self.printFocus then
      print('focus      ', s.focus       and s.focus.name)
      print('active     ', s.active      and s.active.name)
      print('scrollFocus', s.scrollFocus and s.scrollFocus.name)
      print('navFocus   ', s.navFocus    and s.navFocus.name)
      print('panelFocus ', s.panelFocus  and s.panelFocus.name)
      print('modalFocus ', s.modalFocus  and s.modalFocus.name)
      print()
    end
  end

  do -- Draw
    self.timer:reset()
    if self.enabled > 0 then
      BlendMode.Push(BlendMode.Alpha)
      Draw.PushAlpha(self.enabled)
      DrawEx.PushAlpha(self.enabled)
      for i = 1, #self.children do self.children[i]:draw(s.focus, s.active) end
      self:drawCursor(s)
      DrawEx.PopAlpha()
      Draw.PopAlpha()
      BlendMode.Pop()
    end
  end

  do -- Debugging
    BlendMode.Push(BlendMode.Alpha)
    if self.drawDebug then
      -- Don't use wireframe! (it's not pixel-perfect)
      Config.ui.color.debugRect:set()
      self:onDrawDebugChildren(s.focus, s.active)
    end

    if self.drawFocus then
      if s.focus then
        Draw.Color(1.0, 0.0, 0.0, 0.1)
        Draw.Rect(s.focus:getRectGlobal())
      end
    end
    BlendMode.Pop()
    self.drawTime = self.timer:getElapsed()
  end

  Draw.Color(1.0, 1.0, 1.0, 1.0)
  Profiler.End()
end

function Canvas:queueAdd (parent, child)
  local op = { parent = parent, child = child }
  self.addQueue:append(op)
end

function Canvas:queueRemove (parent, child)
  local op = { parent = parent, child = child }
  self.removeQueue:append(op)
end

function Canvas.Create ()
  local self = setmetatable({
    state          = nil,
    addQueue       = List(),
    removeQueue    = List(),

    -- The custom pointer; apps turn it on and never show the system cursor.
    showCursor     = false,

    -- Debug
    drawFocus   = false,
    drawDebug   = false,
    printFocus  = false,
    updateTime  = 0,
    layoutTime  = 0,
    drawTime    = 0,
    timer       = Timer.Create(),

    children    = List(),
  }, Canvas)

  self.state = State.Create(self)
  self:setEState(Container.EState.Enabled)
  return self
end

return Canvas
