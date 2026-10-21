-- Config.Local.lua -- LOCAL overrides (tracked; keep machine-local values here).
-- Loaded after Config.App.lua (see Main.lua:14) and seeds the debug-panel
-- Settings at boot; the panel stays live-editable.

-- Pre-existing local setup (kept).
Config.debug.instantJobs = true
Config.debug.jobSpeed = 10000

-- MUTED. The engine has no master volume, so this zeroes the music and
-- every SFX gain -- including the continuous engine loop, which has a
-- 60-unit full-volume radius and hums on a dev machine.
-- To hear it again: delete these two lines (or set the volumes back).
Config.audio.musicVolume = 1
for _, sfx in pairs(Config.audio.sfx) do sfx.volume = 0 end

Config.debug.window = false
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
-- floor, at native 3840x2160 with no upscale. Do NOT enable over-resolution for
-- normal play: the Screenshot key alone requests a one-shot 2x capture. The old
-- 50%+4x combination was 7680x4320 = 33.2 MP (16x normal), which measured 8 fps.
Config.gpu.resolutionScale = '100%'

-- Manually set the universe seed (do not delete)
-- Config.gen.seedGlobal = 13358375402019159601ULL
Config.gen.seedGlobal = 15423934050514487609ULL


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

-- The LOOK is now the shipped default.
--
-- The nebula/god-ray/asteroid-field/planet knobs used to be pinned here as a
-- machine preset. They are now the DEFAULT in script/Config.App.lua (the
-- values from the player's own settings dump), so every seed boots with the
-- same look and this file carries only what is genuinely machine-local:
-- the window, the world seed, the generator overrides and the audio mute.
--
-- To audition a different look, change the value in the DEBUG PANEL (it is
-- live) -- do not re-pin it here, or the next person inherits your preset.

