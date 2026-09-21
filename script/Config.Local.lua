-- Config.Local.lua -- LOCAL overrides (tracked; keep machine-local values here).
-- Loaded after Config.App.lua (see Main.lua:14) and seeds the debug-panel
-- Settings at boot; the panel stays live-editable.

-- Pre-existing local setup (kept).
Config.debug.instantJobs = true
Config.debug.jobSpeed = 10000

Config.debug.window = true
Config.debug.metrics = true
Config.ui.showTrackers = false

Config.render.vsync = false

Config.window.fullscreen = true

-- Manually set the universe seed (do not delete)
-- Config.gen.seedGlobal = 14112139399293175324ULL


-- Config.gen.nBeltSize = function (rng) return 10000 end
Config.gen.scalePlanet = 5e3
-- Config.gen.nNPCs = 10
Config.gen.nFields = 1
Config.gen.nPlanets = 0
Config.gen.nTurrets = 1
Config.gen.nThrusters = 2
Config.gen.nStations = 2
-- Config.gen.nDustClouds = 0
-- Config.gen.nDustFlecks = 2048

if false then
  Config.jit.loom = true
  Config.jit.profile = false
  Config.jit.verbose = false
end

-- Storm-chaser preset (fog-nebula testing). Window size is a no-op under
-- fullscreen; set fullscreen = false above for windowed FPS checks.
-- Windowed fallback:
-- Config.window.width  = 1920
-- Config.window.height = 1080

-- Thick storm banks.
Config.gpu.nebulaEnabled  = true
Config.gpu.nebulaQuality  = 'High'    -- 24 march steps (needs a real GPU)
Config.gpu.nebulaDensity  = 2.2       -- medium gain (panel: 0..4)
Config.gpu.nebulaBackground = 0.4     -- everywhere-field presence (kills sky wash, keeps banks)
Config.gpu.nebulaCoverage = 2.0       -- bank size + core density (panel: 0.25..2.5, Freelancer-thick)
Config.gpu.nebulaRadius   = 14000     -- march + storm-host sight range
Config.gpu.nebulaG        = 0.4       -- forward-scatter rims on sun-side banks (panel: -1..1)

-- Lightning, ready on boot: the only toggle left is lightning.enable.
Config.gpu.lightningEnable  = true
Config.gpu.lightningQuality = 'High'  -- up to 6 concurrent volume flashes
Config.gpu.lightningEnergy  = 22
Config.gpu.lightningRadius  = 6000
Config.gpu.lightningRate    = 2
Config.gpu.lightningDebug   = 'Off'   -- 'Energy' to hunt strikes, 'Off' to watch

-- Flashes bloom past threshold 1.0; keep both as-is.
Config.gpu.bloom          = true
Config.gpu.bloomThreshold = 1.0
Config.gpu.bloomIntensity = 1.0
