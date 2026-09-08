local DebugWindow = {}
DebugWindow.__index = DebugWindow
setmetatable(DebugWindow, UI.Window)

local MemPool    = require('ffi.MemPool')   -- binds libphx.MemPool_GetSize
local Container = require('UI.Container')

DebugWindow.name = 'Debug Window'

function DebugWindow:onEnable ()
  -- Panel is interactive via the OS cursor: show it so widgets can be hovered
  -- and clicked while the panel is open.
  Input.SetMouseVisible(true)
end

function DebugWindow:onDisable ()
  -- Restore hidden cursor for normal play (the game reticle is the aim cursor).
  Input.SetMouseVisible(false)
end

function DebugWindow:input (state)
  -- The panel is an overlay on the game: only route keyboard/nav/wheel into it
  -- while the OS cursor is actually over it. With the cursor in the game view
  -- the panel must not steal W/S/A/D (flight keys), space (fire/select) or the
  -- scroll wheel (sliders/nav focus) from the ship.
  if not self:containsPoint(state.mousePosX, state.mousePosY) then return end
  Container.input(self, state)
end

function DebugWindow:onLayoutSize ()
  UI.Window.onLayoutSize(self)
  -- Keep the panel proportional to the window so it reads the same on any
  -- monitor and leaves room for the larger scaled fonts: ~34% of the width,
  -- clamped to stay usable on narrow and ultra-wide displays.
  local w = self.ltheory and self.ltheory.resX or 1920
  local width = Math.Clamp(Math.Round(0.34 * w), 460, 820)
  self.desiredSX = max(self.desiredSX, width)
end

function DebugWindow:onDraw (focus, active)
  self.timer:reset()
  UI.Window.onDraw(self, focus, active)
  self.drawTime = self.timer:getElapsed()
end

local lastAlloc = 0
local emaAlloc = 0
local emaFrameTime = 0
local frameHist = {}   -- recent frame deltas for the FPS 1% low readout
local fps1LowMs = 1
local sessionMinDt = nil

local function getAllocationRate (dt)
  local alloc = GC.GetMemory()
  local freq = alloc - lastAlloc
  -- Only update the EMA if the GC is inactive (freq < 0 -> GC is running)
  if freq >= 0 then emaAlloc = Math.EMA(emaAlloc, freq, dt, 1.0) end
  lastAlloc = alloc
  return emaAlloc
end

function DebugWindow:createProfilingText ()
  return UI.NavGroup()
    :add(UI.Collapsible('Profiling')
      :add(UI.Grid():setCols(1):setPad(2, 12, 2, 2)
        :add(UI.Button('Dump Settings', function () DebugWindow.DumpSettings() end))
        :add(UI.Grid():setPadCellX(8)
          :add(UI.Label('Frame Time'))
          :add(UI.Label():setMinWidth(60):setFormat('%.2f ms')
            :setPollFn(function () return 1000 * self.ltheory.dt end))
          :add(UI.Label('Frame Time EMA1'))
          :add(UI.Label():setMinWidth(60):setFormat('%.2f ms')
            :setPollFn(function ()
              emaFrameTime = Math.EMA(emaFrameTime, self.ltheory.dt, self.ltheory.dt, 1.0)
              return 1000.0 * emaFrameTime end))
          :add(UI.Label('FPS'))
          :add(UI.Label():setMinWidth(60):setFormat('%.0f')
            :setPollFn(function ()
              -- Rolling average over the same 120-frame window as the 1% low
              -- readout below (not the instantaneous EMA), so the 1% low can
              -- never appear higher than the average FPS. Read-only here; the
              -- 1% low poll owns appending to frameHist.
              local sum = 0
              for i = 1, #frameHist do sum = sum + frameHist[i] end
              local n = math.max(1, #frameHist)
              return n / sum end))
          :add(UI.Label('Lua Memory'))
          :add(UI.Label():setMinWidth(70):setFormat('%.2f kb')
            :setPollFn(GC.GetMemory))
          :add(UI.Label('Lua Allocation Rate'))
          :add(UI.Label():setMinWidth(70):setFormat('%.2f kb/s')
            :setPollFn(function () return getAllocationRate(self.ltheory.dt) end))
          :add(UI.Label('Lua GC Passes'))
          :add(UI.Label():setPollFn(GC.GetPasses))
          :add(UI.Label('Lua GC Frequency'))
          :add(UI.Label():setFormat('%.2f Hz')
            :setPollFn(GC.GetFrequency))
          :add(UI.Label('Total Rigidbodies'))
          :add(UI.Label():setPollFn(function ()
            local total = 0
            for i = 1, Type.GetCount() do
              local type = Type.GetByID(i)
              if type.pool and type:hasField('body') then
                total = total + MemPool.GetSize(type.pool)
              end
            end
            return total
          end))
          :add(UI.Label('Total Pooled Objects'))
          :add(UI.Label():setPollFn(function ()
            local total = 0
            for i = 1, Type.GetCount() do
              local type = Type.GetByID(i)
              if type.pool then total = total + MemPool.GetSize(type.pool) end
            end
            return total
          end))
          :add(UI.Label('Entities'))
          :add(UI.Label():setPollFn(function ()
            local sys = self.ltheory and self.ltheory.system
            if not sys then return 0 end
            local n = 0
            for _ in sys:iterChildren() do n = n + 1 end
            return n
          end))
          :add(UI.Label('Cached Textures'))
          :add(UI.Label():setPollFn(function () return Cache.texCount or 0 end))
          :add(UI.Label('FPS (1% Low, window)'))
          :add(UI.Label():setMinWidth(60):setFormat('%.0f')
            :setPollFn(function ()
              local dt = self.ltheory.dt
              table.insert(frameHist, dt)
              if #frameHist > 120 then table.remove(frameHist, 1) end
              local n = math.max(1, math.floor(0.01 * #frameHist))
              local s = {}
              for i = 1, #frameHist do s[i] = frameHist[i] end
              table.sort(s)
              local worst = 0
              for i = #s - n + 1, #s do worst = worst + s[i] end
              fps1LowMs = 1000 * worst / n
              return 1.0 / (fps1LowMs * 0.001) end))
          :add(UI.Label('FPS (Min, session)'))
          :add(UI.Label():setMinWidth(60):setFormat('%.0f')
            :setPollFn(function ()
              local dt = self.ltheory.dt
              if not sessionMinDt or dt > sessionMinDt then sessionMinDt = dt end
              return 1.0 / sessionMinDt end))
          :add(UI.Label('Render Submit'))
          :add(UI.Label():setMinWidth(60):setFormat('%.2f ms')
            :setPollFn(function ()
              local gv = self.ltheory and self.ltheory.gameView
              local rt = gv and gv.renderTimes
              return rt and rt.submit or 0 end))
          :add(UI.Label('Render PostFX'))
          :add(UI.Label():setMinWidth(60):setFormat('%.2f ms')
            :setPollFn(function ()
              local gv = self.ltheory and self.ltheory.gameView
              local rt = gv and gv.renderTimes
              return rt and rt.postfx or 0 end))
          :add(UI.Label('Render Present'))
          :add(UI.Label():setMinWidth(60):setFormat('%.2f ms')
            :setPollFn(function ()
              local gv = self.ltheory and self.ltheory.gameView
              local rt = gv and gv.renderTimes
              return rt and rt.present or 0 end))
          :add(UI.Label('Render Total'))
          :add(UI.Label():setMinWidth(60):setFormat('%.2f ms')
            :setPollFn(function ()
              local gv = self.ltheory and self.ltheory.gameView
              local rt = gv and gv.renderTimes
              if not rt then return 0 end
              return (rt.submit or 0) + (rt.postfx or 0) + (rt.present or 0) end))
        )
      )
    )
end

function DebugWindow:createProfilingGraphs ()
  return UI.NavGroup()
    :add(UI.Collapsible('Profiling Graphs')
      :add(UI.Grid():setCols(1):setPad(2, 12, 2, 2)
        :add(UI.Label('Frame Time (s)'))
        :add(UI.Graph()
          :setMode(UI.Graph.Mode.Sweep)
          :setPollFn(function () return self.ltheory.dt * 1000 end)
          :addRuler(1000 /  60,  '100%', Vec3f(1.0, 0.2, 0.05))
          :addRuler(1000 / 120, '50%', Vec3f(1.0, 0.5, 0.10), true)
          :addRuler(1000 / 240, '25%', Vec3f(0.5, 1.0, 0.20), true)
        )
        :add(UI.Label('Lua Memory Allocated (Kb)'))
        :add(UI.Graph()
          :setMode(UI.Graph.Mode.Scroll)
          :setPollFn(GC.GetMemory)
          :setMaxHeight(64)
        )
      )
    )
end

function DebugWindow:createAudioSection ()
  return UI.NavGroup()
    :add(UI.Collapsible('Audio')
      :add(UI.Grid():setPad(2, 12, 2, 2):setPadCellX(8)
        :add(UI.Label('Loaded Sounds'))
        :add(UI.Label():setPollFn(Audio.GetLoadedCount))
        :add(UI.Label('Total Sounds'))
        :add(UI.Label():setPollFn(Audio.GetTotalCount))
        :add(UI.Label('Playing Sounds'))
        :add(UI.Label():setPollFn(Audio.GetPlayingCount))
      )
    )
end

function DebugWindow:createUISection ()
  local canvas = self.ltheory.canvas
  local state  = self.ltheory.canvas.state
  local uiDebugGrid = UI.Grid()

  return UI.NavGroup()
    :add(UI.Collapsible('UI')
      :add(UI.Grid():setCols(1):setPad(2, 12, 2, 2)
        :add(UI.Button('Toggle Grid Layout', function (button, state)
          if uiDebugGrid.fixedRows then uiDebugGrid:setCols(2) else uiDebugGrid:setRows(2) end end))
        :add(uiDebugGrid:setPadCellX(8)
          --:add(UI.Label('Input Time'))
          --:add(UI.Label():setFormat('%.3f ms')
          --  :setPollFn(function () return 1000 * canvas.inputTime end))
          :add(UI.Label('Update Time'))
          :add(UI.Label():setFormat('%.3f ms')
            :setPollFn(function () return 1000 * canvas.updateTime end))
          :add(UI.Label('Layout Time'))
          :add(UI.Label():setFormat('%.3f ms')
            :setPollFn(function () return 1000 * canvas.layoutTime end))
          :add(UI.Label('Draw Time'))
          :add(UI.Label():setFormat('%.3f ms')
            :setPollFn(function () return 1000 * self.drawTime end))
          --:add(UI.Label('Total Time'))
          --:add(UI.Label():setFormat('%.3f ms')
          --  :setPollFn(function () return 1000 * (canvas.inputTime + canvas.updateTime + canvas.layoutTime + self.drawTime) end))
          -- TODO : Fix this
          --:add(UI.Label('Input Events'))
          --:add(UI.Label():setPollFn(function () return self.ltheory.eventCount end))
          :add(UI.Label('Focus'))
          :add(UI.Label():setMinWidth(160):setPollFn(function ()
            return state.focus and state.focus.name or 'nil' end))
          :add(UI.Label('Active'))
          :add(UI.Label():setMinWidth(160):setPollFn(function ()
            return state.active and state.active.name or 'nil' end))
          :add(UI.Label('Scroll Focus'))
          :add(UI.Label():setMinWidth(160):setPollFn(function ()
            return state.scrollFocus and state.scrollFocus.name or 'nil' end))
          :add(UI.Label('Scroll Active'))
          :add(UI.Label():setMinWidth(160):setPollFn(function ()
            return state.scrollActive and state.scrollActive.name or 'nil' end))
          :add(UI.Label('Nav Focus'))
          :add(UI.Label():setMinWidth(160):setPollFn(function ()
            return state.navFocus and state.navFocus.name or 'nil' end))
          :add(UI.Label('Panel Focus'))
          :add(UI.Label():setMinWidth(160):setPollFn(function ()
            return state.panelFocus and state.panelFocus.name or 'nil' end))
          :add(UI.Label('Show Layout'))
          :add(UI.Checkbox(
            function () return canvas.drawDebug end,
            function (enabled) canvas.drawDebug = enabled end))
          :add(UI.Label('Show Focus'))
          :add(UI.Checkbox(
            function () return canvas.drawFocus end,
            function (enabled) canvas.drawFocus = enabled end))
          :add(UI.Label('Mouse Position'))
          :add(UI.Label():setPollFn(function () return (Vec2i(state.mousePosX, state.mousePosY)) end))
          --:add(UI.Label('Active Device'))
          --:add(UI.Label():setPollFn(function () local d = ffi.new('Device') Input.GetActiveDevice(d) return d end))
          :add(UI.Label('Active Device Type'))
          :add(UI.Label():setPollFn(Input.GetActiveDeviceType))
          :add(UI.Label('Active Device ID'))
          :add(UI.Label():setPollFn(Input.GetActiveDeviceID))
        )
      )
    )
end

function DebugWindow:createSettingsSections ()
  local vars = Settings.getAll()
  for i = 1, #vars do
    local var = vars[i]
    local keys = var.key:split('%.')
    local section = self:getSection(keys[1])
    if var.type == 'float' then
      section
        :add(UI.Grid():setCols(3)
          :setPadCellX(8)
          :add(UI.Label(var.name))
          :add(UI.Slider(var.getter, var.setter, var.min, var.max))
          :add(UI.Label()
            :setMinWidth(52):setAlign(1, 0.5):setFormat('%.3g')
            :setPollFn(var.getter)))
    elseif var.type == 'bool' then
      section
        :add(UI.Grid():setCols(2)
          :setPadCellX(8)
          :add(UI.Label(var.name))
          :add(UI.Checkbox(var.getter, var.setter)))
    elseif var.type == 'enum' then
      section
        :add(UI.Grid():setCols(2)
          :setPadCellX(8)
          :add(UI.Label(var.name))
          :add(UI.OptionSlider(var.getter, var.setter, var.elems, var.value)))
    end
  end
end

function DebugWindow:getSection (name)
  local section = self.sections[name]
  if section then return section end
  -- Settings section: one full-width row per setting. Each setting is added as
  -- a single nested row-grid child (see createSettingsSections), so the outer
  -- grid must be single-column to stop two settings sharing a row.
  section = UI.Grid():setCols(1):setPadCellX(8):setPad(2, 12, 2, 2)
  self.contents
    :add(UI.NavGroup()
      :add(UI.Collapsible(name)
        :add(UI.Grid():setCols(1)
          :add(section)
        )
      )
    )
  self.sections[name] = section
  section.childMap = {}
  return section
end

-- TODO JP : Temporary hack to avoid Debug wrapper
local instance

function DebugWindow.SetValue (section, name, value)
  local self = instance
  local s = self:getSection(section)
  local w = s.childMap[name]
  if not w then
    w = UI.Label():setMinWidth(60)
    local row = UI.Grid():setCols(2):setPadCellX(8)
    row:add(UI.Label(name))
    row:add(w)
    s:add(row)
    s.childMap[name] = w
  end

  w:setText(value)
end

-- Dump every live debug setting (plus a little runtime state) to the console
-- and log/settings_dump.txt, so the exact tuning state can be pasted to an
-- assistant when troubleshooting. Triggered by the "Dump Settings" button in
-- the Profiling section.
function DebugWindow.DumpSettings ()
  local self = instance
  local lt = self and self.ltheory

  local lines = {}
  table.insert(lines, '==== Debug Panel Snapshot ====')
  local stamp = (os and os.date) and os.date('%Y-%m-%d %H:%M:%S') or tostring(Time.GetRaw())
  table.insert(lines, 'time:    ' .. stamp)
  if lt then
    local dt = lt.dt or 0
    table.insert(lines, string.format('window:  %dx%d', lt.resX or 0, lt.resY or 0))

    do -- Runtime / profiling readouts (mirrors the Profiling section)
      local rt    = lt.gameView and lt.gameView.renderTimes or {}
      local sys   = lt.system
      local objs, rigs = 0, 0
      for i = 1, Type.GetCount() do
        local type = Type.GetByID(i)
        if type.pool then
          objs = objs + MemPool.GetSize(type.pool)
          if type:hasField('body') then rigs = rigs + MemPool.GetSize(type.pool) end
        end
      end
      local ents = 0
      if sys then for _ in sys:iterChildren() do ents = ents + 1 end end

      local sum = 0
      for i = 1, #frameHist do sum = sum + frameHist[i] end
      local avgMs  = #frameHist > 0 and (1000 * sum / #frameHist) or (1000 * dt)
      local fpsAvg = avgMs > 0 and (1000 / avgMs) or 0

      table.insert(lines, string.format('frame:   %.2f ms  (avg %.1f fps, 1%% low %.2f ms)',
        avgMs, fpsAvg, fps1LowMs))
      table.insert(lines, string.format('render:  submit %.2f | postfx %.2f | present %.2f ms',
        rt.submit or 0, rt.postfx or 0, rt.present or 0))
      table.insert(lines, string.format('pools:   %d objects / %d rigidbodies | entities %d | textures %d',
        objs, rigs, ents, Cache.texCount or 0))
      table.insert(lines, string.format('lua:     %.2f kb | gc %.2f kb/s | passes %d | freq %.2f Hz',
        GC.GetMemory() / 1024, emaAlloc, GC.GetPasses(), GC.GetFrequency()))
    end
  end
  table.insert(lines, '')
  table.insert(lines, '-- settings --')
  for _, v in ipairs(Settings.getAll()) do
    local val = v.getter()
    if v.type == 'enum' and v.elems then
      val = v.elems[math.floor(val or 1)] or val
    elseif type(val) == 'number' then
      val = string.format('%.4g', val)
    end
    table.insert(lines, string.format('%-26s %s', v.key, tostring(val)))
  end

  local text = table.concat(lines, '\n')
  print(text)
  local f = io.open('log/settings_dump.txt', 'w')
  if f then
    f:write(text, '\n')
    f:close()
    print('Snapshot saved to log/settings_dump.txt')
  end
end

function DebugWindow.Create (ltheory)
  local self
  self = UI.Window('Debug')
  self = setmetatable(self, DebugWindow)

  self.ltheory  = ltheory
  self.timer    = Timer.Create()
  self.drawTime = 0
  self.sections = {}

  self.contents = UI.Grid()
    :setCols(1)
    :setStretchY(0)
    :add(self:createProfilingText())
    :add(self:createProfilingGraphs())
    :add(self:createAudioSection())
    :add(self:createUISection())

  self:createSettingsSections()

  if Config.debug.windowSection then
    for i = 1, #self.contents.children do
      local child = self.contents.children[i]
      child.expanded = (child.title == Config.debug.windowSection)
    end
  end

  self.draggable = false
  self
    :setStretchY(1)
    :add(UI.ScrollView()
      :setPadUniform(2)
      :setScrollable(false, true)
      :add(self.contents))

  instance = self
  return self
end

return DebugWindow
