-- PerfProbe -- A/B frame-time measurement harness for the 4K asteroid-field scene.
--
-- Run with: PHX_FIXED_SIZE=3840,2160 PHX_PERF=120 ./run.sh PerfProbe
--
-- It reproduces the reported scene (streaming asteroid field at the live panel
-- density, nebula, sun shadows, full post chain, debug panel open) at 4K, then
-- prints per-configuration frame statistics so each suspect can be costed
-- independently rather than guessed at.
--
-- PERF_VARIANT selects one variable to change from that baseline.
-- Audio is muted. This app exists to be measured, not played.

Config.window.fullscreen = false
Config.window.width = 3840
Config.window.height = 2160
Config.render.vsync = false
Config.gpu.resolutionScale = '100%'
Config.audio.musicVolume = 0
for _, sfx in pairs(Config.audio.sfx) do sfx.volume = 0 end

local Entities = requireAll('Game.Entities')
local DebugControl = require('Game.Controls.DebugControl')
local Metric = require('ffi.Metric')
local Profiler = require('ffi.Profiler')

local Probe = Application()
local VARIANT = os.getenv('PERF_VARIANT') or 'baseline'

local function setSetting (key, value)
  if Settings.exists(key) then Settings.set(key, value) end
end

-- The reported scene's starting state, taken from the debug-panel dump of the
-- 48 fps session. The field settings there are LIVE panel values (perChunk
-- 2.496, loadRadius 10.02) and are denser than Config.Local's shipped
-- defaults -- about 10,500 rocks instead of ~5,800. Reproducing them is the
-- whole point: the baseline has to be the scene that was actually slow.
--
-- NOTE: this must run AFTER the Renderer exists. The Renderer's constructor
-- re-seeds every panel value from Config.gpu, so applying these earlier is
-- silently undone -- which is how an early version of this probe measured the
-- shipped field instead of the reported one.
function Probe.applySceneSettings ()
  -- The engine's own profiler prints a per-scope breakdown on exit. Enable it so
  -- the run reports where the frame actually goes, rather than inferring it.
  if os.getenv('PERF_PROFILER') then
    Profiler.Enable()
  end
  setSetting('gen.asteroidField.enable', true)
  setSetting('gen.asteroidField.perChunk', 2.496)
  setSetting('gen.asteroidField.loadRadius', 10.02)
  setSetting('gen.asteroidField.fadeStart', 8.488)
  setSetting('nebula.enable', true)
  setSetting('nebula.quality', 2)          -- Low
  setSetting('nebula.radius', 18740)
  setSetting('nebula.density', 1.806)
  setSetting('nebula.coverage', 1.6)
  setSetting('postfx.radialblur.enable', true)
  setSetting('postfx.radialblur.strength', 0.22)
  setSetting('postfx.radialblur.scanlines', 0.1643)
  setSetting('postfx.sharpen.enable', true)
  setSetting('postfx.bloom.enable', true)
  setSetting('render.sun.shadows', true)
  setSetting('render.sun.shadowSize', 2)  -- 512
  setSetting('render.sun.shadowRange', 5983)
  setSetting('render.shadow.period', 1.953)
  setSetting('ssao.enable', false)
  setSetting('render.taa.enable', false)
  setSetting('postfx.godrays.enable', false)
  setSetting('lightning.enable', false)

  -- Film grain is seeded from TIME, not the frame index, so two runs of the
  -- same scene never produce byte-identical images. Disable it for capture
  -- A/B comparisons (PHX_NOGRAIN=1) -- otherwise the grain alone is a ~0.2%
  -- pixel difference that swamps the thing being measured.
  if os.getenv('PHX_NOGRAIN') then
    setSetting('postfx.grain.enable', false)
  end

  -- One variable at a time, relative to the baseline above.
  if VARIANT == 'no-radialblur' then
    setSetting('postfx.radialblur.enable', false)
  elseif VARIANT == 'no-sharpen' then
    setSetting('postfx.sharpen.enable', false)
  elseif VARIANT == 'no-bloom' then
    setSetting('postfx.bloom.enable', false)
  elseif VARIANT == 'no-nebula' then
    setSetting('nebula.enable', false)
  elseif VARIANT == 'no-field' then
    setSetting('gen.asteroidField.enable', false)
  elseif VARIANT == 'no-sunshadow' then
    setSetting('render.sun.shadows', false)
  elseif VARIANT == 'no-post' then
    setSetting('postfx.radialblur.enable', false)
    setSetting('postfx.sharpen.enable', false)
    setSetting('postfx.bloom.enable', false)
  elseif VARIANT == 'field-only' then
    setSetting('nebula.enable', false)
    setSetting('postfx.radialblur.enable', false)
    setSetting('postfx.sharpen.enable', false)
    setSetting('postfx.bloom.enable', false)
    setSetting('render.sun.shadows', false)
  elseif VARIANT == 'biomes-off' then
    -- W7c A/B: 0 reproduces the pre-W7c look exactly.
    setSetting('render.planet.biomes', 0)
  elseif VARIANT == 'nocull' then
    -- Disable the CPU cull (both the frustum and the fade band, since the
    -- fade-band cull lives behind the same 'cullable' flag) so a captured
    -- frame can be compared against the culled one.
    --
    -- CAUTION: a capture A/B needs PHX_NOGRAIN=1 (grain is seeded from the
    -- wall clock, so two runs of the SAME scene differ by ~0.2% of pixels --
    -- the same order as the thing being measured) and PHX_FIXED_DT (the
    -- volumetric medium's time source) and PHX_FIXED_VIEW=hold (the chase
    -- camera drifts). With those pinned, the run-to-run noise floor was
    -- measured at 0.195% of pixels differing by >30, so a difference at that
    -- scale is NOT evidence of a cull bug.
    local Material = require('Game.Material')
    Material.Rock().cullable = false
  elseif VARIANT == 'lightning-on' then
    setSetting('lightning.enable', true)
  elseif VARIANT == 'no-panel' then
    -- The debug panel draws G-buffer previews every frame; that is a DEBUG cost,
    -- not a game cost.
  elseif VARIANT == 'small-shadow-range' then
    -- Diagnostic: if the sun-shadow cost is the DRAW of nearby rocks, shrinking
    -- the range (fewer rocks in range) will cut it. If the cost is the
    -- TRAVERSAL of all 10,643 entities to find them, it will not move.
    setSetting('render.sun.shadowRange', 1000)
  elseif VARIANT == 'no-dust' then
    Config.gen.nDustClouds = 0
    Config.gen.nDustFlecks = 0
  elseif VARIANT == 'no-planet' then
    -- The planet's shader is heavy (fbm terrain + scattering + cloud shell) and
    -- at 4K it can cover much of the frame.
  elseif VARIANT == 'no-batched' then
  elseif VARIANT == 'batched' then
    -- Enable the engine's draw batcher (grouping consecutive same-material
    -- draws and filling matrices on worker threads).
    Config.render.multithread = true
  elseif VARIANT == 'sparse-field' then
    setSetting('gen.asteroidField.perChunk', 0.8)
    setSetting('gen.asteroidField.loadRadius', 12)
  elseif VARIANT == 'half-res' then
    setSetting('render.resolutionScale', 3)  -- 67%
  end
end

function Probe:onInit ()
  self.seed = 15423934050514487609ULL
  self.system = Entities.System(self.seed)
  self.system:addChild(Entities.GPUParticles())
  self.player = Entities.Player()
  local ship = self.system:spawnShip()
  ship:setPos(Config.gen.origin)
  ship:setFriction(0)
  ship:setSleepThreshold(0, 0)
  self.system:addChild(ship)
  self.player:setControlling(ship)

  -- The rest of the real scene. The planet is a heavy shader (fbm terrain +
  -- scattering + cloud shell + storms) and at 4K it can cover a large part of
  -- the frame, so it is a prime suspect for the reported cost.
  if VARIANT ~= 'no-planet' then
    self.system:spawnStation()
    local planet = self.system:spawnPlanet()
    local controlling = self.player:getControlling()
    local center = planet:getPos()
    local sp = controlling:getPos()
    local dx, dy, dz = sp.x - center.x, sp.y - center.y, sp.z - center.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    local standoff = (Config.render.planet.standoff or 1.75) * planet:getScale()
    if dist < standoff then
      local s = dist > 1e-3 and standoff / dist or 1
      controlling:setPos(Vec3f(center.x + dx * s, center.y + dy * s, center.z + dz * s))
    end
  end

  self.gameView = GUI.GameView(self.player)
  self.gameView.ltheory = self
  self.canvas = UI.Canvas()
  self.canvas:add(self.gameView:add(Controls.MasterControl(self.gameView, self.player)))

  -- The Renderer constructor re-seeds every panel value from Config.gpu, so the
  -- scene settings have to be applied AFTER it exists or they are silently
  -- overwritten.
  Probe.applySceneSettings()

  DebugControl.ltheory = self
  self.debugWindow = GUI.DebugWindow(self)
  self.gameView.debugWindow = self.debugWindow
  -- The debug panel was OPEN in the reported session, and it draws live graphs
  -- and polls a dozen values every frame. Keep that in the baseline unless a
  -- variant turns it off, so the measurement matches what was actually run.
  self.gameView:add(self.debugWindow:setStretch(0, 1),
                    VARIANT ~= 'no-panel')

  printf('[probe] variant=%s  res=%dx%d', VARIANT, self.resX, self.resY)
end

function Probe:onInput ()
  self.canvas:input()
end

function Probe:onUpdate (dt)
  -- Phase timing. The debug panel's "submit" number is CPU time to RECORD the
  -- frame, and it cannot show GPU cost -- so split the frame explicitly:
  --   update  = physics + entity update (CPU, includes Bullet)
  --   render  = recording the draw calls (CPU) -- this is where a 10k-draw-call
  --              field shows up
  --   total   = what the user actually feels
  local t0 = TimeStamp.Get()
  self.system:update(dt)
  local t1 = TimeStamp.Get()
  self.system:streamAsteroidField(self.player:getControlling())
  local t2 = TimeStamp.Get()
  self.canvas:update(dt)
  local t3 = TimeStamp.Get()

  self.accUpdate = (self.accUpdate or 0) + TimeStamp.GetElapsedMs(t0)
  self.accStream = (self.accStream or 0) + TimeStamp.GetElapsedMs(t1)
  self.accFrames = (self.accFrames or 0) + 1

  -- Quit cleanly after the requested time so the engine's profiler gets to
  -- print its per-scope breakdown on exit. A killed process cannot.
  if os.getenv('PERF_PROFILER') and (self.t or 0) > 15 then
    self:quit()
    return
  end

  if (self.t or 0) > 3 and not self.reported then
    self.reported = true
    local af = self.system.asteroidField
    local chunks, rocks = 0, 0
    if af then chunks, rocks = af:getStats() end
    printf('[probe] res=%dx%d entities=%d fieldChunks=%d fieldRocks=%d',
           self.resX, self.resY, #(self.system.children or {}), chunks, rocks)
  end

  -- Reset the accumulators once the world has settled: the boot frame includes
  -- generating ~10,600 rocks and a ~1.7 s spike, which would swamp every
  -- average and make the phase split meaningless.
  if (self.t or 0) > 3 then
    if not self.warm then
      self.warm = true
      -- Reset EVERY accumulator, including accDraw. Leaving accDraw to keep the
      -- boot spike while dividing it by the post-warm frame count inflated the
      -- draw number to more than the whole frame time.
      self.accUpdate, self.accStream, self.accFrames, self.accDraw = 0, 0, 0, 0
    elseif not self.phased and (self.t or 0) > 6 then
      local Frustum = require('Game.Frustum')
      local culled, kept = Frustum.cullStats()
      printf('[probe] frustum cull: culled=%d kept=%d', culled, kept)
      -- CULL-MARGIN MEASUREMENT. The CPU cull keeps an entity whose bounding
      -- SPHERE (collision radius x 1.15) touches the frustum, so the cull is
      -- only safe if the DRAWN mesh fits inside that sphere. The drawn mesh is
      -- one of eight LODs of the shape the collision sphere was built from, and
      -- a coarse LOD of a bumpy shape can have a LARGER bounding radius than the
      -- base mesh. Measure the worst archetype's ratio and compare it against
      -- the margin the cull applies; a ratio above the margin means the cull
      -- can drop a rock whose geometry is still on screen (a pop).
      --
      -- The mirror of this check lives in tools/validate_frustum.lua, which
      -- pins the margin constant against the number measured here.
      do
        local Entities = requireAll('Game.Entities')
        local worstRatio, worstArch = 0, nil
        for ai = 1, 32 do
          -- getMesh(seed) picks archetype (seed % 32) + 1, so seed = ai - 1
          -- resolves to exactly archetype ai.
          local a = Entities.Asteroid(ai - 1, 1.0, { static = true })
          local body = a.body
          local collRadius = body and body:getBoundingRadius() or 0
          local lod = a.mesh
          if collRadius > 0 and lod then
            -- The LOD chain is dMin=0, dMax=1, then x(lac*sqrt(2)) = x2.121
            -- per step, for 8 entries. Sample each entry's midpoint so the
            -- selected LOD is exactly the one the renderer would use.
            local maxRadius = 0
            local dMin, dMax = 0, 1
            for _ = 1, 8 do
              local m = lod:get((dMin + dMax) * 0.5)
              if m then
                local r = m:getRadius()
                if r > maxRadius then maxRadius = r end
              end
              dMin = dMax
              dMax = dMax * 1.5 * math.sqrt(2.0)
            end
            local ratio = maxRadius / collRadius
            if ratio > worstRatio then worstRatio, worstArch = ratio, ai end
          end
        end
        printf('[probe] max LOD radius / collision radius: worst=%.4f (archetype %s) -- margin is 1.15',
               worstRatio, tostring(worstArch))
      end
      printf('[probe] shadow period setting=%.3f -> effective=%d frames',
             Settings.get('render.shadow.period') or 1,
             math.max(1, math.floor((Settings.get('render.shadow.period') or 1) + 0.5)))
    -- Verify the economy registry still sees the station (it used to find it by
    -- scanning every child; it must still find it by registration).
    local Registry = require('Game.EconomyRegistry')
    local econ = Registry.entitiesFor(self.system)
    local kinds = {}
    for _, e in ipairs(econ) do
      local k = e:hasFactory() and 'factory' or e:hasMarket() and 'market'
          or e:hasTrader() and 'trader' or e:hasFlows() and 'flows' or 'other'
      kinds[k] = (kinds[k] or 0) + 1
    end
    local parts = {}
    for k, v in pairs(kinds) do parts[#parts+1] = k..'='..v end
    table.sort(parts)
    printf('[probe] economy registry: %d entities [%s]', #econ, table.concat(parts, ' '))
    -- Verify the registry's add / remove / RE-ADD cycle. The re-add is the
      -- interesting one: an entity that gains its component BEFORE it is
      -- parented is registered by the AddedToParent hook, so if that hook is
      -- lost the entity is unregistered on removal and never comes back.
      do
        local Registry = require('Game.EconomyRegistry')
        local before = #Registry.entitiesFor(self.system)
        local st = Entities.Station(self.system.rng:get64())
        self.system:addChild(st)
        local afterAdd = #Registry.entitiesFor(self.system)
        self.system:removeChild(st)
        local afterRemove = #Registry.entitiesFor(self.system)
        self.system:addChild(st)
        local afterReAdd = #Registry.entitiesFor(self.system)
        printf('[probe] registry cycle: before=%d add=%d remove=%d readd=%d %s',
               before, afterAdd, afterRemove, afterReAdd,
               (afterAdd == before + 1 and afterRemove == before
                and afterReAdd == before + 1) and 'OK' or 'BROKEN')
        self.system:removeChild(st)
        -- The OTHER order: parent FIRST, component added later. The old
        -- registry only installed its AddedToParent hook on the deferred
        -- path, so an entity registered this way was unregistered on removal
        -- and never came back.
        -- A BARE entity, so the component is genuinely added AFTER
        -- parenting (a Station gains its market in its constructor, which is
        -- the other order and always worked).
        local Entity = require('Game.Entity')
        local st2 = Entity()
        self.system:addChild(st2)
        local b2 = #Registry.entitiesFor(self.system)
        st2:addMarket()
        local a2 = #Registry.entitiesFor(self.system)
        self.system:removeChild(st2)
        local r2 = #Registry.entitiesFor(self.system)
        self.system:addChild(st2)
        local rd2 = #Registry.entitiesFor(self.system)
        printf('[probe] registry parent-first: base=%d add=%d remove=%d readd=%d %s',
               b2, a2, r2, rd2,
               (a2 == b2 + 1 and r2 == b2 and rd2 == b2 + 1) and 'OK' or 'BROKEN')
        self.system:removeChild(st2)
      end
      Frustum.resetCullStats()
      self.phased = true
      local n = math.max(1, self.accFrames or 1)
      printf('[probe] per-frame CPU: update=%.2f ms (physics+entities)  stream=%.2f ms  drawRecord=%.2f ms',
             (self.accUpdate or 0) / n, (self.accStream or 0) / n,
             (self.accDraw or 0) / n)
      printf('[probe] engine metrics: drawCalls=%d trisDrawn=%d vertsDrawn=%d',
             Metric.Get(Metric.DrawCalls), Metric.Get(Metric.TrisDrawn),
             Metric.Get(Metric.VertsDrawn))
    end
  end
  self.t = (self.t or 0) + dt
end

function Probe:onExit ()
  -- The engine only prints its profiler table when the app's own toggle is on,
  -- so a probe that enabled the profiler directly has to disable it here.
  if os.getenv('PERF_PROFILER') then
    Profiler.Disable()
  end
end

function Probe:onDraw ()
  local t0 = TimeStamp.Get()
  self.canvas:draw(self.resX, self.resY)
  self.accDraw = (self.accDraw or 0) + TimeStamp.GetElapsedMs(t0)
end

return Probe
