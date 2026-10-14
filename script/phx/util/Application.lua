local Bindings = require('phx.util.ApplicationBindings')

-- Gamepad mapping DB is version-stamped in its filename; hoisted here so a
-- future bump doesn't require hunting through run() for a bare string.
local GAMEPAD_DB = 'gamecontrollerdb_205.txt'

local Application = class(function (self) end)

-- Virtual ---------------------------------------------------------------------

function Application:getDefaultSize ()
  return Config.window.width, Config.window.height
end

function Application:getTitle ()
  return 'Phoenix Engine Application'
end

function Application:getWindowMode ()
  if Config.window.fullscreen then
    return Bit.Or32(WindowMode.Fullscreen, WindowMode.Resizable)
  end
  return Bit.Or32(WindowMode.Shown, WindowMode.Resizable)
end

function Application:onInit         ()       end
function Application:onDraw         ()       end
function Application:onResize       (sx, sy) end
function Application:onUpdate       (dt)     end
function Application:onExit         ()       end
function Application:onInput        ()       end

function Application:quit ()
  self.exit = true
end

-- Internal helpers --------------------------------------------------------

-- Wraps the SetValue('gcmem', ...) + Begin/End pattern that used to be
-- hand-copied at the top of every frame-loop phase. Guarantees a matching
-- Profiler.End() even if a new phase is added later without remembering the
-- boilerplate -- the alternative (each call site doing it by hand) is exactly
-- how a stray missing End() sneaks in.
function Application:profiled (label, fn)
  Profiler.SetValue('gcmem', GC.GetMemory())
  Profiler.Begin(label)
  fn()
  Profiler.End()
end

-- Bottom-of-screen perf readout (Config.debug.metrics). Pure extraction from
-- the old inline block -- same text, same layout, same colors.
function Application:drawMetrics (font, profiling)
  local s = string.format(
    '%.2f ms / %.0f fps / %.2f MB / %.1f K tris / %d draws / %d imms / %d swaps',
    1000.0 * self.dt,
    1.0 / self.dt,
    GC.GetMemory() / 1000.0,
    Metric.Get(Metric.TrisDrawn) / 1000,
    Metric.Get(Metric.DrawCalls),
    Metric.Get(Metric.Immediate),
    Metric.Get(Metric.FBOSwap))

  BlendMode.Push(BlendMode.Alpha)
  Draw.Color(0.1, 0.1, 0.1, 0.5)
  Draw.Rect(0, self.resY - 20, self.resX, self.resY)
  font:draw(s, 10, self.resY - 5, 1, 1, 1, 1)

  if profiling then
    font:draw('>> PROFILER ACTIVE <<', self.resX - 128, self.resY - 5, 1, 0, 0.15, 1)
  end
  BlendMode.Pop()
end

-- Shader-compile-failure banner (item 4: make a broken pass visible, not a
-- silent black screen). Pure extraction from the old inline block.
--
-- NOTE: the second and third font:draw calls below pass ONE MORE numeric
-- argument than every other font:draw call in this file (5 vs. 4). If
-- font:draw's signature is (text, x, y, r, g, b, a) -- which the 4-arg calls
-- are consistent with -- these two lines are shifted by one: the intended
-- color/alpha land in the wrong slots and the trailing value is silently
-- dropped. Left exactly as originally written since I can't confirm the
-- signature from this file alone; worth a visual check next time this
-- overlay is on screen (orange filename line looking washed-out/pink would
-- confirm it), then drop the leading `1,` on both lines below.
function Application:drawShaderErrorOverlay (font)
  local e = Cache.lastError
  if not e then return end
  font:draw('SHADER FAILED TO COMPILE', 10, self.resY - 5, 1, 1, 1, 1)
  font:draw(e.key, 10, self.resY - 23, 1, 0.85, 0.7, 0.55, 1)
  font:draw('fix the .glsl or reload (F5)', 10, self.resY - 41, 1, 0.6, 0.6, 0.6, 1)
end

-- Application Template --------------------------------------------------------

function Application:run ()
  self.resX, self.resY = self:getDefaultSize()
  self.window = Window.Create(
    self:getTitle(),
    self.resX,
    self.resY,
    self:getWindowMode())

  self.exit = false
  self.window:setVsync(Config.render.vsync)

  if Config.jit.profile and Config.jit.profileInit then Jit.StartProfile() end

  Preload.Run()

  Input.LoadGamepadDatabase(GAMEPAD_DB)
  self:onInit()
  self:onResize(self.resX, self.resY)

  local font = Font.Load('NovaMono', 10)
  self.lastUpdate = TimeStamp.GetFuture(-1.0 / 60.0)

  if Config.jit.dumpasm then Jit.StartDump() end
  if Config.jit.profile and not Config.jit.profileInit then Jit.StartProfile() end
  if Config.jit.verbose then Jit.StartVerbose() end

  local profiling = false
  local toggleProfiler = false
  -- PHX_PERF=<frames>: unattended frame-time statistics (see the block at the
  -- bottom of the loop). Declared out here, NOT beside `timeScale`: everything
  -- inside the loop body is re-initialised every frame, which silently makes an
  -- accumulator a constant 1 so any `n % interval` test never fires.
  local perfInterval = tonumber(os.getenv('PHX_PERF') or '') or nil
  local perfN, perfEma, perfSamples = 0, 0, {}
  local printSettings = os.getenv('PHX_SETTINGS') ~= nil

  while not self.exit do
    if toggleProfiler then
      toggleProfiler = false
      profiling = not profiling
      if profiling then Profiler.Enable() else Profiler.Disable() end
    end

    Profiler.SetValue('gcmem', GC.GetMemory())
    Profiler.Begin('Frame')
    Engine.Update()

    self:profiled('App.onResize', function ()
      local size = self.window:getSize()
      if size.x ~= self.resX or size.y ~= self.resY then
        self.resX = size.x
        self.resY = size.y
        self:onResize(self.resX, self.resY)
      end
    end)

    local timeScale = 1.0
    local doScreenshot = false

    self:profiled('App.onInput', function ()
      -- TODO : Remove this once bindings are fixed
      if Input.GetKeyboardCtrl() and Input.GetPressed(Button.Keyboard.W) then self:quit() end
      if Input.GetPressed(Bindings.Exit) then self:quit() end
      -- Clean quit key for WM environments whose XWayland window has no
      -- title-bar close button (e.g. Hyprland tiling). Default Escape.
      if Config.window.quitKey
        and Input.GetPressed(Config.window.quitKey) then self:quit() end

      if Input.GetPressed(Bindings.ProfilerToggle) then
        toggleProfiler = true
      end

      if Input.GetPressed(Bindings.Screenshot) then
        doScreenshot = true
        if Settings.exists('render.superSample') then
          self.prevSS = Settings.get('render.superSample')
          Settings.set('render.superSample', 2)
        end
      end

      if Input.GetPressed(Bindings.ToggleFullscreen) then
        self.window:toggleFullscreen()
      end

      if Input.GetPressed(Bindings.Reload) then
        Profiler.Begin('Engine.Reload')
        Cache.Clear()
        SendEvent('Engine.Reload')
        Preload.Run()
        Profiler.End()
      end

      if Input.GetDown(Bindings.TimeAccel) then
        timeScale = Config.debug.timeAccelFactor
      end

      if Input.GetPressed(Bindings.ToggleWireframe) then
        Settings.set('render.wireframe', not Settings.get('render.wireframe'))
      end

      self:onInput()
    end)

    self:profiled('App.onUpdate', function ()
      local now = TimeStamp.Get()
      self.dt = TimeStamp.GetDifference(self.lastUpdate, now)
      self.lastUpdate = now
      self:onUpdate(timeScale * self.dt)
    end)

    -- PHX_PERF=<frames> : frame-time statistics on stdout, every <frames> frames.
    -- The debug panel shows the same numbers, but only while a human is watching
    -- (and its text is unreadable in a PHX_DEBUG_DUMP capture), whereas this is
    -- what an unattended perf run needs: ema/min/p95/max over a window, so a
    -- single spike cannot masquerade as a result. See ltheory-planets.md 11.0 W6.
    perfN = perfN + 1
    -- PHX_SETTINGS=1 : print the live value of the settings that drive a look,
    -- once the Renderer has seeded them. A/B runs that write Config.gpu.* and
    -- then assume the toggle took are worthless without this: two "disable"
    -- variants during the star-glare investigation came out byte-identical to
    -- baseline, and it was never clear whether the pass contributed nothing or
    -- the override never arrived.
    if printSettings and perfN >= 5 then
      printSettings = false
      local keys = {
        'render.sun.intensity', 'render.sun.enable',
        'render.planet.sunScale', 'render.planet.envAmbient',
        'render.planet.atmoGlow', 'render.planet.clouds',
        'nebula.enable', 'postfx.godrays.enable', 'postfx.bloom.enable',
        'postfx.exposure.meter', 'postfx.tonemap.enable',
      }
      for _, k in ipairs(keys) do
        if Settings.exists(k) then
          printf('[SETTING] %-26s = %s', k, tostring(Settings.get(k)))
        end
      end
    end

    if perfInterval then
      perfSamples[#perfSamples + 1] = self.dt
      if perfN % perfInterval == 0 then
        table.sort(perfSamples)
        local mean = 0
        for i = 1, #perfSamples do mean = mean + perfSamples[i] end
        mean = mean / #perfSamples
        local p95 = perfSamples[math.max(1, math.floor(#perfSamples * 0.95))]
        io.stderr:write(string.format(
          '[PERF] n=%d mean=%.2f ema=%.2f min=%.2f p95=%.2f max=%.2f fps=%.0f\n',
          perfN, 1000 * mean, 1000 * perfEma, 1000 * perfSamples[1],
          1000 * p95, 1000 * perfSamples[#perfSamples], 1000 / (1000 * mean)))
        perfEma = mean
        perfSamples = {}
      end
    end

    self:profiled('App.onDraw', function ()
      self.window:beginDraw()
      self:onDraw()
    end)

    if doScreenshot then
      ScreenCap()
      if self.prevSS then
        Settings.set('render.superSample', self.prevSS)
        self.prevSS = nil
      end
    end

    if os.getenv('PHX_AUTOSHOT') then
      self.autoShotN = (self.autoShotN or 0) + 1
      if self.autoShotN == tonumber(os.getenv('PHX_AUTOSHOT')) then ScreenCap() end
    end

    if Config.debug.metrics then
      self:drawMetrics(font, profiling)
    end

    self:drawShaderErrorOverlay(font)

    self:profiled('App.SwapBuffers', function ()
      self.window:endDraw()
    end)

    Profiler.End()
    Profiler.LoopMarker()
  end

  if profiling then Profiler.Disable() end

  if Config.jit.dumpasm then Jit.StopDump() end
  if Config.jit.profile then Jit.StopProfile() end
  if Config.jit.verbose then Jit.StopVerbose() end

  do -- Exit
    self:onExit()
    self.window:free()
  end
end

return Application
