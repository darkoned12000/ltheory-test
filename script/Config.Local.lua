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

-- `Config.window.width/height` (1024x768) are IGNORED in fullscreen: SDL hands
-- back the monitor's resolution and Application adopts it, so this was rendering
-- at 3840x2160 = 8.29 MP, not 0.79 MP. The boot log's `Resolution:` line reports
-- the *request*, not reality -- the debug panel's `window:` field is the live
-- size. Measured there (panel on, harness-pinned):
--     3840x2160, nebula Low : 5.77 ms / 173 fps
--     3840x2160, nebula High: 9.34 ms / 107 fps
-- The nebula alone is ~48% of the frame at High and its cost scales with pixels
-- (+0.55 ms at 0.79 MP, +4.4 ms at 8.29 MP).
--
-- resolutionScale is the only working lever at 4K: it renders below window size
-- and upscales on present.
--
-- 2026-10-17: 50% -> 100%. The blockiness on the planet was this line, and it
-- was not buying anything. Measured on this machine (RX 7900 XTX, seeded world,
-- held camera, PHX_PERF):
--     1.86 MP -> 1.72 ms (583 fps)     7.4 MP -> 5.40 ms (185 fps)
--     29.7 MP -> 22.9 ms (44 fps, after the medium.glsl anchor hoist)
-- So 4K/100% (~8.3 MP) lands near 6 ms / ~165 fps -- still ~2.7x the 60 fps
-- floor, at native 3840x2160 with no upscale. Do NOT re-add 4x superSample:
-- ss multiplies the WHOLE internal buffer, so 50%+4x was 7680x4320 = 33.2 MP
-- (16x normal), which measured 8 fps for you.
Config.gpu.resolutionScale = '100%'

-- Manually set the universe seed (do not delete)
-- Config.gen.seedGlobal = 13358375402019159601ULL


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
-- W5 calibration (2026-10-12; sweep + method in ltheory-planets.md 11.0).
-- Measured on a fixed seed + fixed dump frame, High quality, 960x600, as
-- sky-crop mean luminance / structure (p90/p50) / whole-frame blown fraction:
--   2.2 / 0.10 / 2.0 / rays off  ->  21.5 / 2.81 / 0.000%  (the old preset)
--   2.2 / 0.10 / 2.0 / rays 8    ->  40.7 / 3.20 / 0.001%
--   3.0 / 0.10 / 2.0 / rays 8    ->  51.3 / 3.09 / 0.154%
--   3.0 / 0.10 / 1.6 / rays 8    ->  47.5 / 3.54 / 0.121%  <- chosen
--   3.0 / 0.10 / 1.4 / rays 14   ->  47.8 / 4.27 / 0.376%
-- The rays are the dominant brightness lever (~2x on their own), 14 starts
-- blooming ~0.4% of the frame while 8 stays under 0.13%, and LOWER coverage
-- raises structure -- banks stop merging into a veil. Hence density up,
-- coverage down. W3's ellipsoid plumes cost ~15% of sky brightness here, not
-- the ~30% the doc predicted.
Config.gpu.nebulaEnabled  = true
Config.gpu.nebulaQuality  = 'Low'     -- was 'High'. High costs ~4.4 ms/frame at 4K (48% of
                              -- the frame) and the extra steps buy little: see
                              -- ltheory-planets.md 11.11, where Low/Medium read
                              -- identically (52.7 vs 53.0 sky) and High's only real
                              -- difference is a density mask that makes it DIMMER.
Config.gpu.nebulaDensity  = 3.0       -- medium gain (panel: 0..4)
-- Everywhere-field presence. `density` scales sigma_t AS WELL AS the medium
-- density, so the sky veil is quadratic in it:
--   OD = 5e-5 * density^2 * background * radius
-- at density 3.0 / radius 14k: background 0.4 -> OD 2.5 (the sky is only 8%
-- transmissive = the "wash over everything"); 0.10 -> OD ~0.63 (~53%
-- transmissive), so the anchor-span banks read against a mostly clear sky.
Config.gpu.nebulaBackground = 0.10    -- everywhere-field presence (banks are anchor-driven)
Config.gpu.nebulaCoverage = 1.6       -- bank size + core density (panel: 0.25..2.5)
Config.gpu.nebulaRadius   = 14000     -- march + storm-host sight range
Config.gpu.nebulaG        = 0.4       -- forward-scatter rims on sun-side banks (panel: -1..1)

-- God-rays were OFF in this preset, so at this density the shafts had in fact
-- never been seen. On, but at the PHYSICAL gain: strength 1.0 means the pass is
-- just the single-scatter integral -- the medium reflects, it does not amplify.
-- It was 8 here, which with g=0.92 added ~190x the sun's own radiance dead
-- ahead, so the nebula looked brighter than the star and read as a light source
-- sitting on the planet's limb. Raise strength only for a stylistic effect.
Config.gpu.godraysEnabled  = true
Config.gpu.godraysStrength = 1
Config.gpu.godraysG        = 0.7

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

-- Endless asteroid field (chunk-streamed). See ltheory-planets.md 11.18.
-- The panel also drives these live: Debug > Asteroid Field (on/off, density, reach).
Config.gpu.asteroidFieldEnabled    = true
Config.gpu.asteroidFieldPerChunk   = 8
Config.gpu.asteroidFieldLoadRadius = 4
