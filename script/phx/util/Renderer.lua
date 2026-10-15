local Cache = require('phx.util.Cache')
local CaptureHarness = require('phx.util.CaptureHarness')

-- TODO JP : Refactor all of this monolithic nonsense into RenderPass objects.

--------------------------------------------------------------------------------
-- Settings registration + GPU config seeding
--------------------------------------------------------------------------------
-- Each row below is the single source of truth for one Settings.add*() entry.
-- It replaces three things that used to live separately (and could drift out
-- of sync with each other): the Settings.add* call itself, the flat seed(...)
-- call that pulled a matching value out of Config.gpu, and -- for enums -- a
-- hand-written {label = index} lookup table used only to translate a GPU
-- config string into the right Settings.addEnum index.
--
-- Reordering an enum's displayed options (e.g. changing the AO quality list
-- from {Off,Half,Quarter} to something else) now automatically updates the
-- index used for GPU seeding, because the index is derived from the SAME
-- `options` array passed to Settings.addEnum, not a separate copy.
--
-- Fields:
--   kind    : 'bool' | 'float' | 'enum'
--   key     : Settings key, e.g. 'postfx.bloom.enable'
--   label   : display label passed straight to Settings.add*
--   default : default value (enum default is an option INDEX, as before)
--   gpu     : Config.gpu field name this is seeded from (nil = not GPU-seedable)
--   min/max : bounds, 'float' only
--   options : option label array, 'enum' only
--   optKey  : OPTIONAL function(rawGpuValue) -> option label string. Use this
--             when the raw Config.gpu value isn't already spelled exactly like
--             one of `options` (numbers vs. string labels, alternate spellings
--             like "Anisotropic" vs. "Aniso", etc). Defaults to identity.
--------------------------------------------------------------------------------

local function idKey (v) return v end
local function strKey (v) return v ~= nil and tostring(v) or nil end

local SETTINGS = {
  -- Post FX -------------------------------------------------------------------
  { kind = 'bool',  key = 'postfx.aberration.enable',   label = 'Aberration',   default = false, gpu = 'aberration' },
  { kind = 'float', key = 'postfx.aberration.strength', label = ' - Strength',  default = 1, min = 0, max = 1, gpu = 'aberrationStrength' },
  -- UV offset at the frame edge. Was hardcoded 0.0002 behind an in-shader fallback;
  -- exposed because with `aspect` now supplied the pass actually works, and this
  -- is how hard the lens fringe reads.
  { kind = 'float', key = 'postfx.aberration.dispersion', label = ' - Dispersion', default = 0.0002, min = 0, max = 0.01, gpu = 'aberrationDispersion' },

  { kind = 'bool',  key = 'postfx.bloom.enable',        label = 'Bloom',        default = true,  gpu = 'bloom' },
  { kind = 'float', key = 'postfx.bloom.radius',        label = ' - Radius',    default = 20, min = 4, max = 64, gpu = 'bloomRadius' },
  { kind = 'float', key = 'postfx.bloom.intensity',     label = ' - Intensity', default = 1, min = 0, max = 4, gpu = 'bloomIntensity' },
  { kind = 'float', key = 'postfx.bloom.threshold',     label = ' - Threshold', default = 1, min = 0, max = 8, gpu = 'bloomThreshold' },

  { kind = 'bool',  key = 'postfx.sharpen.enable',      label = 'Sharpen',      default = true, gpu = 'sharpen' },
  -- Cheap post-AA alternative to supersampling (wired to the existing
  -- filter/fxaa shader). At 4K, SS 2x/4x cost ~4x/16x the pixels; FXAA is one
  -- full-res pass.
  { kind = 'bool',  key = 'postfx.fxaa.enable',         label = 'FXAA',         default = false, gpu = 'fxaa' },
  { kind = 'float', key = 'postfx.sharpen.strength',    label = ' - Strength',  default = 1, min = 0, max = 3, gpu = 'sharpenStrength' },
  { kind = 'float', key = 'postfx.sharpen.radius',      label = ' - Radius',    default = 2, min = 1, max = 6, gpu = 'sharpenRadius' },

  { kind = 'bool',  key = 'postfx.radialblur.enable',    label = 'RadialBlur',   default = false, gpu = 'radialblur' },
  { kind = 'float', key = 'postfx.radialblur.strength',  label = ' - Strength',  default = 1, min = 0, max = 1, gpu = 'radialblurStrength' },
  { kind = 'float', key = 'postfx.radialblur.scanlines', label = ' - Scanlines', default = 1, min = 0, max = 1, gpu = 'radialblurScanlines' },

  { kind = 'bool',  key = 'postfx.tonemap.enable',    label = 'Tonemap',       default = true, gpu = 'tonemap' },
  { kind = 'enum',  key = 'postfx.tonemap.operator',  label = ' - Operator',   default = 2,
    options = { 'AgX', 'ACES', 'Filmic', 'Khronos' }, gpu = 'tonemapOperator' },
  { kind = 'float', key = 'postfx.exposure.ev',       label = ' - Exposure EV', default = 0, min = -4, max = 4, gpu = 'exposureEV' },

  -- Color Grading Micro-Knobs (Roadmap #14)
  { kind = 'float', key = 'postfx.color.sat',       label = ' - Saturation',  default = 1.0, min = 0, max = 3, gpu = 'colorSat' },
  { kind = 'float', key = 'postfx.color.contrast',  label = ' - Contrast',    default = 1.0, min = 0, max = 3, gpu = 'colorContrast' },
  { kind = 'float', key = 'postfx.color.temp',      label = ' - Temp (W/C)',  default = 0.0, min = -1, max = 1, gpu = 'colorTemp' },
  { kind = 'float', key = 'postfx.color.tint',      label = ' - Tint (M/G)',  default = 0.0, min = -1, max = 1, gpu = 'colorTint' },

  -- REMOVED: auto-exposure (postfx.autoexposure.*, Renderer:autoExposureEV).
  -- It never worked, for two independent reasons, both of which had to be true
  -- for it to look merely "off" rather than broken:
  --  1. Time units. Time_GetRaw() returns time(0) -- Unix EPOCH SECONDS
  --     (libphx/src/PhxTime.cpp:29) -- but autoExposureEV computed
  --     dt = (now - self.autoTime) / 1000, treating seconds as milliseconds.
  --     Every delta was therefore 1000x too small, so the 0.5 s adaptation
  --     constant was really ~500 s and the smoother could never converge. The
  --     dt > 0.25 clamp below it never fired either, for the same reason.
  --  2. Its input. The meter it keys on gates its readback on
  --     `now - meterLast >= 100`, i.e. 100 *seconds*, so `lit` was refreshed
  --     once per 100 s -- measured: exactly one readback in 5200 frames.
  -- So auto-exposure was keying off a value that never moved, through a filter
  -- 1000x too slow to follow anything. Fixing it was not the interesting part:
  -- even working, it is wrong for this game. Exposure is a deliberate
  -- art-direction choice here (the HDR/tonemap item set it by hand), and this
  -- game spans a lit planet surface and empty space, so a keyed 0.18 mid-grey
  -- with a -6..+2 EV range would pump the entire screen by several stops every
  -- time the player crossed that boundary. Absolute brightness is information
  -- in a space game; auto-exposure throws it away. Kept: postfx.exposure.ev,
  -- a plain manual offset.
  --
  -- The meter (filter/exposure) SURVIVES, because it is how the HDR exposure
  -- work was actually calibrated -- but it is now opt-in on its own, because it
  -- renders 4096 random texelFetches into a 1x1 target every frame and was
  -- running unconditionally for a debug-panel readout. Measured cost of the pass
  -- alone: ~0.75-1.05 ms/frame across runs, i.e. 20-28% of the whole frame, with
  -- nothing consuming it. Default frame time went 3.30 -> ~2.5 ms when it was
  -- gated off.
  { kind = 'bool',  key = 'postfx.exposure.meter', label = 'Exposure Meter', default = false, gpu = 'exposureMeter' },

  { kind = 'bool',  key = 'postfx.vignette.enable',   label = 'Vignette',    default = true, gpu = 'vignette' },
  { kind = 'float', key = 'postfx.vignette.strength', label = ' - Strength', default = 0.5, min = 0, max = 1, gpu = 'vignetteStrength' },
  { kind = 'float', key = 'postfx.vignette.hardness', label = ' - Hardness', default = 20.0, min = 2, max = 32, gpu = 'vignetteHardness' },

  { kind = 'bool',  key = 'postfx.grain.enable',   label = 'Film Grain', default = false, gpu = 'grain' },
  { kind = 'float', key = 'postfx.grain.strength', label = ' - Amount',  default = 1, min = 0, max = 4, gpu = 'grainStrength' },

  { kind = 'bool',  key = 'nebula.enable',  label = 'Nebula Volume', default = true, gpu = 'nebulaEnabled' },
  { kind = 'enum',  key = 'nebula.quality', label = ' - Quality',    default = 2,
    options = { 'Off', 'Low', 'Medium', 'High' }, gpu = 'nebulaQuality' },
  { kind = 'enum',  key = 'nebula.debug',   label = ' - Debug View', default = 1,
    options = { 'Off', 'Density', 'Transmittance', 'Lighting', 'Steps', 'Anchors' }, gpu = 'nebulaDebug' },
  { kind = 'float', key = 'nebula.density', label = ' - Density',    default = 1.5, min = 0, max = 4, gpu = 'nebulaDensity' },
  { kind = 'float', key = 'nebula.jitter',  label = ' - Ray Jitter', default = 0.05, min = 0, max = 1, gpu = 'nebulaJitter' },
  { kind = 'float', key = 'nebula.ambient', label = ' - Ambient',    default = 1.0, min = 0, max = 3, gpu = 'nebulaAmbient' },
  { kind = 'float', key = 'nebula.palette', label = ' - Palette',     default = 1.0, min = 0, max = 1, gpu = 'nebulaPalette' },
  { kind = 'float', key = 'nebula.background', label = ' - Background', default = 0.2, min = 0, max = 1.5, gpu = 'nebulaBackground' },
  { kind = 'float', key = 'nebula.coverage', label = ' - Coverage',  default = 2, min = 0.25, max = 2.5, gpu = 'nebulaCoverage' },
  { kind = 'float', key = 'nebula.radius',  label = ' - Radius',     default = 14000, min = 500, max = 40000, gpu = 'nebulaRadius' },
  { kind = 'float', key = 'nebula.g',       label = ' - Phase g',    default = 0.4, min = -1, max = 1, gpu = 'nebulaG' },
  -- Baked into the sky CUBE at generation time (gen/nebula.glsl 'Central Star'),
  -- so a change needs a relaunch to re-bake. Was a hardcoded 8.0/4.0 = 12x peak
  -- that clipped to white across a broad patch of sky.
  { kind = 'float', key = 'nebula.starGlow', label = ' - Baked Star Glow', default = 0.35, min = 0, max = 3, gpu = 'nebulaStarGlow' },
  { kind = 'float', key = 'nebula.tint',    label = ' - Glow Tint',  default = 0.0, min = 0, max = 1, gpu = 'nebulaTint' },
  { kind = 'float', key = 'nebula.tintR',   label = '   Color R',    default = 1.0, min = 0, max = 1, gpu = 'nebulaTintR' },
  { kind = 'float', key = 'nebula.tintG',   label = '   Color G',    default = 1.0, min = 0, max = 1, gpu = 'nebulaTintG' },
  { kind = 'float', key = 'nebula.tintB',   label = '   Color B',    default = 1.0, min = 0, max = 1, gpu = 'nebulaTintB' },

  -- God-rays (fog-nebula Phase 3, independent A/B product) ---------------
  { kind = 'bool',  key = 'postfx.godrays.enable',   label = 'God Rays',      default = false, gpu = 'godraysEnabled' },
  { kind = 'float', key = 'postfx.godrays.strength', label = ' - Strength',   default = 1, min = 0, max = 32, gpu = 'godraysStrength' },
  { kind = 'float', key = 'postfx.godrays.g',        label = ' - Anisotropy', default = 0.7, min = 0, max = 0.98, gpu = 'godraysG' },
  { kind = 'float', key = 'postfx.godrays.ceiling',   label = ' - Soft Ceiling', default = 2.0, min = 0, max = 12, gpu = 'godraysCeiling' },
  { kind = 'enum',  key = 'postfx.godrays.debug',    label = ' - Debug View', default = 1,
    options = { 'Off', 'Shaft' }, gpu = 'godraysDebug' },

  -- Lightning storm flash (fog-nebula Phase 4, local volumetric point-light) ----
  { kind = 'bool',  key = 'lightning.enable',        label = 'Lightning',    default = false, gpu = 'lightningEnable' },
  { kind = 'enum',  key = 'lightning.quality',       label = ' - Quality',   default = 2,
    options = { 'Low', 'High' }, gpu = 'lightningQuality' },
  { kind = 'float', key = 'lightning.energy',        label = ' - Energy',    default = 22, min = 0, max = 40, gpu = 'lightningEnergy' },
  { kind = 'float', key = 'lightning.radius',        label = ' - Radius',    default = 6000, min = 100, max = 12000, gpu = 'lightningRadius' },
  { kind = 'float', key = 'lightning.rate',          label = ' - Storm Rate', default = 2, min = 0.25, max = 3, gpu = 'lightningRate' },
  { kind = 'enum',  key = 'lightning.debug',         label = ' - Debug View', default = 1,
    options = { 'Off', 'Region', 'Energy' }, gpu = 'lightningDebug' },

  -- Core render -----------------------------------------------------------
  { kind = 'float', key = 'render.fovY',        label = 'FOV',           default = 75, min = 50, max = 100, gpu = 'fovY' },
  { kind = 'enum',  key = 'render.superSample', label = 'SuperSampling', default = 1,
    options = { 'Off', '2x', '4x' }, gpu = 'superSample' },
  { kind = 'enum',  key = 'render.resolutionScale', label = 'Render Scale', default = 1,
    options = { '100%', '85%', '75%', '67%', '50%' }, gpu = 'resolutionScale', optKey = strKey },
  { kind = 'bool',  key = 'render.wireframe',   label = 'Wireframe',             default = false },
  { kind = 'bool',  key = 'render.cullface',    label = 'Backface Culling',      default = true },
  { kind = 'bool',  key = 'render.showBuffers', label = 'Show Deferred Buffers', default = false },
  { kind = 'enum',  key = 'render.textureFilter', label = 'Texture Filter', default = 1,
    options = { 'Bilinear', 'Trilinear', 'Trilinear + Aniso' }, gpu = 'filtering',
    optKey = function (v)
      if v == 'Aniso' or v == 'Anisotropic' then return 'Trilinear + Aniso' end
      return v
    end },
  { kind = 'float', key = 'render.shadow.radius', label = 'Shadow Radius (PCF)', default = 2, min = 0, max = 8 },
  { kind = 'float', key = 'render.shadow.bias',   label = 'Shadow Bias',         default = 0.001, min = -0.01, max = 0.1 },
  { kind = 'float', key = 'render.shadow.scale',  label = 'Shadow Dist Scale',   default = 0.0005, min = 0, max = 0.01 },

  { kind = 'bool',  key = 'render.sun.enable',    label = 'Sun Light',       default = true, gpu = 'sunLight' },
  { kind = 'float', key = 'render.sun.intensity', label = ' - Intensity',    default = 1, min = 0, max = 6, gpu = 'sunIntensity' },
  { kind = 'float', key = 'render.sun.fill',      label = ' - Ambient Fill', default = 0.4564, min = 0, max = 1, gpu = 'sunAmbientFill' },
  { kind = 'float', key = 'render.sun.warmth',    label = ' - Warmth',       default = 0.7476, min = 0, max = 1, gpu = 'sunWarmth' },
  { kind = 'bool',  key = 'render.sun.marker',    label = ' - Direction Marker', default = false, gpu = 'sunMarker' },
  { kind = 'float', key = 'render.sun.starTight', label = ' - Star Disc',   default = 20000, min = 500, max = 60000, gpu = 'sunStarTight' },
  { kind = 'float', key = 'render.sun.starDisc',  label = ' - Star Bright', default = 30,    min = 0,   max = 120,   gpu = 'sunStarDisc' },
  { kind = 'float', key = 'render.sun.starHalo',  label = ' - Star Halo',   default = 900,   min = 60,  max = 6000,  gpu = 'sunStarHalo' },
  { kind = 'float', key = 'render.sun.starGlow',  label = ' - Halo Glow',   default = 0.35,  min = 0,   max = 2,     gpu = 'sunStarGlow' },
  { kind = 'bool',  key = 'render.sun.shadows',   label = ' - Shadows',      default = true, gpu = 'sunShadows' },
  { kind = 'float', key = 'render.sun.shadowRange', label = ' - Shadow Range', default = 8000, min = 500, max = 20000, gpu = 'sunShadowRange' },
  { kind = 'enum',  key = 'render.sun.shadowSize',  label = ' - Shadow Res',   default = 3,
    options = { '256', '512', '1024', '2048' }, gpu = 'sunShadowSize', optKey = strKey },
  { kind = 'float', key = 'render.shadow.maxLights', label = ' - Shadow Lights', default = 2, min = 0, max = 8 },
  { kind = 'float', key = 'render.shadow.period',    label = ' - Shadow Update', default = 2, min = 1, max = 4 },

  { kind = 'bool',  key = 'render.vsync', label = 'VSync', default = true },

  { kind = 'float', key = 'lighting.ambientEnv', label = 'Environment Light',   default = 1.35, min = 0, max = 3, gpu = 'ambientEnv' },
  { kind = 'float', key = 'lighting.specular',   label = 'Dielectric Specular', default = 0.35, min = 0, max = 1, gpu = 'dielectricSpec' },

  -- Planet self-lighting (planets are Material_NoShade; see material/planet.glsl).
  { kind = 'float', key = 'render.planet.relief',    label = 'Planet Relief',      default = 1.0,   min = 0, max = 3, gpu = 'planetRelief' },
  { kind = 'float', key = 'render.planet.sunScale',   label = 'Planet Sun Scale',   default = 1.0,   min = 0, max = 4, gpu = 'planetSunScale' },
  { kind = 'float', key = 'render.planet.envAmbient', label = 'Planet Nebula Fill', default = 1.75,  min = 0, max = 10, gpu = 'planetEnvAmbient' },
  { kind = 'float', key = 'render.planet.atmoGlow',   label = 'Planet Atmosphere',  default = 0.756, min = 0, max = 3,  gpu = 'planetAtmoGlow' },
  { kind = 'bool',  key = 'render.planet.cloudsEnabled', label = 'Planet Clouds', default = true, gpu = 'planetCloudsEnabled' },
  -- Multiplier on the type's prior, NOT a 0..1 fraction: it positions the
  -- coverage window, so it is meaningful above 1 (resolved coverage is clamped
  -- separately at 1.5 -- see Planet:cloudCoverage for why not at 1.0).
  { kind = 'float', key = 'render.planet.clouds',     label = ' - Coverage',         default = 1.25,  min = 0, max = 3.0, gpu = 'planetClouds' },
  -- Cloud shell altitude as a fraction of the planet radius. 0 = the old
  -- ground-projected deck (clouds welded to the terrain, no parallax). The
  -- default is ~12x a physically-scaled cloud deck because a real 0.16% shell
  -- gives an offset too small to read at any sane camera distance.
  { kind = 'float', key = 'render.planet.cloudHeight', label = ' - Shell Altitude', default = 0.02, min = 0, max = 0.12, gpu = 'planetCloudHeight' },
  -- How much the deck dims the sun term on the ground beneath it. One extra
  -- cube fetch on an already-bound texture; no new pass.
  { kind = 'float', key = 'render.planet.cloudShadow', label = ' - Shadow',        default = 0.55, min = 0, max = 1, gpu = 'planetCloudShadow' },
  -- Advection speed as a FRACTION OF THE PLANET'S OWN SPIN, not an absolute
  -- rate. Real cloud drift is ~6% of Earth's rotation; the default is in that
  -- band. Because it is relative, the deck feels the same on a 2-minute planet
  -- and a 10-minute one, and creeps slowly BACKWARDS against the spin the way
  -- it does on Earth.
  { kind = 'float', key = 'render.planet.cloudWind', label = ' - Wind', default = 0.04, min = 0, max = 0.2, gpu = 'planetCloudWind' },
  { kind = 'float', key = 'render.planet.terminator', label = 'Planet Terminator',  default = 0.35, min = 0, max = 1,   gpu = 'planetTerminator' },

  -- SSAO / GTAO -------------------------------------------------------------
  { kind = 'bool',  key = 'ssao.enable',      label = 'Ambient Occlusion', default = false, gpu = 'aoEnabled' },
  { kind = 'enum',  key = 'ssao.quality',     label = ' - Resolution',     default = 2,
    options = { 'Off', 'Half', 'Quarter' }, gpu = 'aoQuality' },
  { kind = 'float', key = 'ssao.radius',      label = ' - Radius',         default = 500, min = 0.1, max = 4000, gpu = 'aoRadius' },
  { kind = 'float', key = 'ssao.intensity',   label = ' - Intensity',      default = 1.5, min = 0, max = 3, gpu = 'aoIntensity' },
  { kind = 'float', key = 'ssao.fillOcclude', label = ' - Fill Occlude',   default = 1, min = 0, max = 1, gpu = 'fillOcclude' },
  { kind = 'enum',  key = 'ssao.directions',  label = ' - Directions',     default = 2,
    options = { '2', '4', '6', '8' }, gpu = 'aoDirections', optKey = strKey },
  { kind = 'enum',  key = 'ssao.steps',       label = ' - Steps',          default = 2,
    options = { '2', '3', '4', '6' }, gpu = 'aoSteps', optKey = strKey },
  { kind = 'float', key = 'ssao.thickness',   label = ' - Thickness',      default = 0.25, min = 0, max = 1, gpu = 'aoThickness' },
  { kind = 'enum',  key = 'ssao.blur',        label = ' - Denoise',        default = 2,
    options = { '0', '1', '2' }, gpu = 'aoBlur', optKey = strKey },
  { kind = 'bool',  key = 'ssao.show',        label = ' - Show',           default = false },
}

-- Nebula march budget, indexed by the `nebula.quality` enum INDEX (1..4), i.e.
-- { 'Off', 'Low', 'Medium', 'High' }. Index 1 is unused-but-present so the table
-- lines up with the option list instead of needing a `- 1` that silently shifts
-- every entry and drops the last one off the end.
--
-- This WAS a real inversion, and it is exactly the shape of bug that hides for
-- years because both broken paths still produce a plausible image. The tables
-- used to be {10,20,48} and {12,24,40} read as `steps[q-1] or <default>`, so:
--     Low(2)=20   Medium(3)=48   High(4)=nil -> default 20   (volume)
--     Low(2)=24   Medium(3)=40   High(4)=nil -> default  8   (god-rays)
-- 'High' therefore rendered FEWER steps than 'Low' (8 vs 24 for the shafts) --
-- the reported "low and medium show more nebula than high". 'Off' is 0 and the
-- volume pass skips; god-rays deliberately clamp Off up to Low, because they are
-- gated on `nebula.enable` rather than on quality.
local VOL_STEPS = { [1] =  0, [2] = 10, [3] = 20, [4] = 48 }
local VOL_EVALS = { [1] =  0, [2] =  2, [3] =  2, [4] =  3 }
local GOD_STEPS = { [1] =  0, [2] = 12, [3] = 24, [4] = 40 }
local GOD_EVALS = { [1] =  0, [2] =  2, [3] =  2, [4] =  3 }

-- Guard the invariant that cost us this: a quality enum whose option count does
-- not match its march table re-creates the silent off-the-end fallback. Checked
-- at registration so a future 5th option fails loudly at boot, not as a picture
-- that merely looks a bit thin.
do
  for _, s in ipairs(SETTINGS) do
    if s.key == 'nebula.quality' then
      local n = #s.options
      for _, t in ipairs({ { 'VOL_STEPS', VOL_STEPS }, { 'VOL_EVALS', VOL_EVALS },
                           { 'GOD_STEPS', GOD_STEPS }, { 'GOD_EVALS', GOD_EVALS } }) do
        for i = 1, n do
          if t[2][i] == nil then
            error(string.format('Renderer: nebula.quality has %d options but %s has no entry for index %d',
                  n, t[1], i))
          end
        end
      end
    end
  end
end

for _, s in ipairs(SETTINGS) do
  if s.kind == 'bool' then
    Settings.addBool(s.key, s.label, s.default)
  elseif s.kind == 'float' then
    Settings.addFloat(s.key, s.label, s.default, s.min, s.max)
  elseif s.kind == 'enum' then
    Settings.addEnum(s.key, s.label, s.default, s.options)
    s.optionIndex = {}
    for i, name in ipairs(s.options) do s.optionIndex[name] = i end
  end
end

local function seedFromGpu (gpu)
  for _, s in ipairs(SETTINGS) do
    if s.gpu and Settings.exists(s.key) then
      local raw = gpu[s.gpu]
      if raw ~= nil then
        if s.kind == 'enum' then
          local optKey = s.optKey or idKey
          local idx = s.optionIndex[optKey(raw)]
          if idx then Settings.set(s.key, idx) end
        else
          Settings.set(s.key, raw)
        end
      end
    end
  end
end

--------------------------------------------------------------------------------

local Renderer = class(function (self)
  self.ds = 4

  seedFromGpu((Config and Config.gpu) or {})

  if Settings.exists('render.vsync') and Config and Config.render and Config.render.vsync ~= nil then
    Settings.set('render.vsync', Config.render.vsync)
  end

  self.exposure   = { avg = 0, max = 0, over = 0, lit = 0 }
  self.meterLast  = 0
  self.frameSeed  = 0
end)

local colorFormat = TexFormat.RGBA16F
local depthFormat = TexFormat.Depth32F

local function createBuffer (sx, sy, format)
  local self = Tex2D.Create(sx, sy, format)
  self:setMagFilter(TexFilter.Linear)
  self:setMinFilter(TexFilter.Linear)
  self:setWrapMode(TexWrapMode.Clamp)
  self:push()
  Draw.Clear(0, 0, 0, 0)
  self:pop()
  self:genMipmap()
  return self
end

--------------------------------------------------------------------------------
function Renderer:applyFilter (frag, onSetVars)
  local shader = Cache.Shader('ui', 'filter/' .. frag)
  if not shader then return end
  self.buffer1:pushLevel(self.level)
  shader:start()
    Shader.SetTex2D('src', self.buffer0)
    if onSetVars then onSetVars() end
    Draw.Color(1, 1, 1, 1)
    Draw.Rect(0, 0, self.sx, self.sy)
  shader:stop()
  self.buffer1:pop()
  self:swap()
end

function Renderer:fxaa ()
  Draw.Color(1, 1, 1, 1)
  self:applyFilter('fxaa', function ()
    Shader.SetFloat2('viewportSize', self.sx, self.sy)
  end)
end

function Renderer:aberration (strength)
  Draw.Color(1, 1, 1, 1)
  self:applyFilter('aberration', function ()
    Shader.SetFloat('strength', strength)
  end)
end

function Renderer:tonemap ()
  self:applyFilter('tonemap', function ()
    Shader.SetInt('texOp', Settings.get('postfx.tonemap.operator') or 1)
    -- Manual exposure offset only. Auto-exposure was removed: it keyed off a
    -- value refreshed once per 100 s through a filter 1000x too slow to converge.
    local ev = Settings.get('postfx.exposure.ev') or 0
    Shader.SetFloat('exposure', 2.0 ^ ev)

    -- Color Grading Micro-Knobs (Roadmap #14)
    Shader.SetFloat('colorSat',      Settings.get('postfx.color.sat') or 1.0)
    Shader.SetFloat('colorContrast', Settings.get('postfx.color.contrast') or 1.0)
    Shader.SetFloat('colorTemp',     Settings.get('postfx.color.temp') or 0.0)
    Shader.SetFloat('colorTint',     Settings.get('postfx.color.tint') or 0.0)
  end)
end

function Renderer:vignette ()
  local strength = Settings.get('postfx.vignette.strength') or 0.5
  local hardness = Settings.get('postfx.vignette.hardness') or 8.0
  self:applyFilter('vignette', function ()
    Shader.SetFloat('strength', strength)
    Shader.SetFloat('hardness', hardness)
  end)
end

function Renderer:grain (strength)
  self:applyFilter('grain', function ()
    Shader.SetFloat('strength', strength)
    Shader.SetFloat('time', (tonumber(Time.GetRaw()) or 0) * 0.001)
    Shader.SetFloat2('size', self.sx, self.sy)
  end)
end

function Renderer:colorGrade (curve1, curve2)
  self:applyFilter('colorgrade', function ()
    Shader.SetTex1D('curve1', curve1)
    Shader.SetTex1D('curve2', curve2)
  end)
end

function Renderer:blur (dst, src, dx, dy, radius)
  local shader = Cache.Shader('ui', 'filter/blur')
  if not shader then return end
  local size = src:getSize()
  dst:push()
  shader:start()
    Shader.SetFloat('variance', 0.2 * radius)
    Shader.SetFloat2('dir', dx, dy)
    Shader.SetFloat2('size', size.x, size.y)
    Shader.SetInt('radius', radius)
    Shader.SetTex2D('src', src)
    Draw.Color(1, 1, 1, 1)
    Draw.Rect(0, 0, size.x, size.y)
  shader:stop()
  dst:pop()
end

function Renderer:sharpen (radius, sigma, strength)
  Draw.Color(1, 1, 1, 1)

  do -- Blur
    local shader = Cache.Shader('ui', 'filter/blur2d')
    if shader then
      self.buffer2:pushLevel(self.level)
      shader:start()
        Shader.SetInt('radius', radius)
        Shader.SetFloat('sigma', sigma)
        Shader.SetFloat2('size', self.sx, self.sy)
        Shader.SetTex2D('src', self.buffer0)
        Draw.Rect(0, 0, self.sx, self.sy)
      shader:stop()
      self.buffer2:pop()
    end
  end

  do -- High pass blend
    local shader = Cache.Shader('ui', 'filter/sharpen')
    if shader then
      self.buffer1:pushLevel(self.level)
      shader:start()
        Shader.SetFloat('strength', strength)
        Shader.SetTex2D('src', self.buffer0)
        Shader.SetTex2D('srcBlur', self.buffer2)
        Draw.Rect(0, 0, self.sx, self.sy)
      shader:stop()
      self.buffer1:pop()
    end
  end

  self:swap()
end

function Renderer:bloom (radius)
  Draw.Color(1, 1, 1, 1)
  local A = self.dsBuffer0
  local B = self.dsBuffer1
  local threshold = Settings.get('postfx.bloom.threshold') or 1.0
  local intensity = Settings.get('postfx.bloom.intensity') or 1.0
  local knee = threshold * 0.5

  local baseW = self.resX / self.ds
  local baseH = self.resY / self.ds

  local mips = 1
  while mips < 12 and math.floor(baseW / (2 ^ mips)) >= 2 and math.floor(baseH / (2 ^ mips)) >= 2 do
    mips = mips + 1
  end
  local levels = math.max(2, math.min(mips, 4 + math.floor(radius / 8)))

  do -- Prefilter
    local shader = Cache.Shader('ui', 'filter/bloompre')
    if shader then
      A:pushLevel(0)
      shader:start()
        Shader.SetFloat('bloomThreshold', threshold)
        Shader.SetFloat('bloomKnee', knee)
        Shader.SetTex2D('src', self.buffer0)
        Draw.Rect(0, 0, baseW, baseH)
      shader:stop()
      A:pop()
    end
  end

  do -- Downsample
    local shader = Cache.Shader('ui', 'filter/bloomdown')
    for i = 1, levels - 1 do
      if shader then
        local w = math.floor(baseW / (2 ^ (i - 1)))
        local h = math.floor(baseH / (2 ^ (i - 1)))
        A:setMipRange(i - 1, i - 1)
        A:setMinFilter(TexFilter.Linear)
        A:pushLevel(i)
        shader:start()
          Shader.SetFloat2('srcSize', w, h)
          Shader.SetTex2D('src', A)
          Draw.Rect(0, 0, math.floor(baseW / (2 ^ i)), math.floor(baseH / (2 ^ i)))
        shader:stop()
        A:pop()
      end
    end
  end

  do -- Seed accumulation
    local shader = Cache.Shader('ui', 'filter/identity')
    if shader then
      local w = math.floor(baseW / (2 ^ (levels - 1)))
      local h = math.floor(baseH / (2 ^ (levels - 1)))
      A:setMipRange(levels - 1, levels - 1)
      A:setMinFilter(TexFilter.Linear)
      B:pushLevel(levels - 1)
      shader:start()
        Shader.SetTex2D('src', A)
        Draw.Rect(0, 0, w, h)
      shader:stop()
      B:pop()
    end
  end

  do -- Progressive upsample
    local shader = Cache.Shader('ui', 'filter/bloomup')
    for i = levels - 2, 0, -1 do
      if shader then
        local w = math.floor(baseW / (2 ^ i))
        local h = math.floor(baseH / (2 ^ i))
        A:setMipRange(i, i)
        A:setMinFilter(TexFilter.Linear)
        B:setMipRange(i + 1, i + 1)
        B:setMinFilter(TexFilter.Linear)
        B:pushLevel(i)
        shader:start()
          Shader.SetFloat('scatter', 0.7)
          Shader.SetTex2D('src', A)
          Shader.SetTex2D('srcLow', B)
          Draw.Rect(0, 0, w, h)
        shader:stop()
        B:pop()
      end
    end
  end

  do -- Composite bloom
    local shader = Cache.Shader('ui', 'filter/bloomcomposite')
    if shader then
      B:setMipRange(0, 0)
      B:setMinFilter(TexFilter.Linear)
      self.buffer1:pushLevel(self.level)
      shader:start()
        Shader.SetFloat('intensity', intensity)
        Shader.SetTex2D('src', self.buffer0)
        Shader.SetTex2D('srcBlur', B)
        Draw.Rect(0, 0, self.sx, self.sy)
      shader:stop()
      self.buffer1:pop()
      self:swap()
    end
  end

  A:setMipRange(0, 0)
  B:setMipRange(0, 0)
  A:setMinFilter(TexFilter.Linear)
  B:setMinFilter(TexFilter.Linear)
end

function Renderer:free ()
  if self.buffer0 then
    self.buffer0:free()
    self.buffer1:free()
    self.buffer2:free()
    self.uiBuffer:free()
    self.dsBuffer0:free()
    self.dsBuffer1:free()
    self.zBuffer:free()
    self.zBufferL:free()
    self.meterTex:free()
  end

  if self.volView then
    self.volView:free()
    self.volView = nil
  end
  if self.texAnchors then
    self.texAnchors:free()
    self.texAnchors = nil
  end
  if self.anchorBytes then
    self.anchorBytes:free()
    self.anchorBytes = nil
  end
  if self.volView then
    self.volView:free()
    self.volView = nil
  end
  if self.godView then
    self.godView:free()
    self.godView = nil
  end
  if self.texLightning then
    self.texLightning:free()
    self.texLightning = nil
  end
  if self.lightningBytes then
    self.lightningBytes:free()
    self.lightningBytes = nil
  end
  self.lightningStamp = nil
end

function Renderer:present (x, y, sx, sy, useMips)
  Draw.Color(1, 1, 1, 1)
  RenderState.PushAllDefaults()
  local shader = Cache.Shader('ui', 'filter/identity')
  if not shader then
    RenderState.PopAll()
    return
  end
  shader:start()
    Shader.SetTex2D('src', self.buffer0)
    self.buffer0:draw(x, y + sy, sx, -sy)
  shader:stop()
  RenderState.PopAll()
end

function Renderer:presentAll (x, y, sx, sy)
  Draw.Color(1, 1, 1, 1)
  RenderState.PushAllDefaults()
  local shader = Cache.Shader('ui', 'filter/identity')
  if not shader then
    RenderState.PopAll()
    return
  end
  shader:start()
    self.buffer0:draw(x, y + sy / 2, sx / 2, -sy / 2)
    self.buffer1:draw(x + sx / 2, y + sy / 2, sx / 2, -sy / 2)
    self.buffer2:draw(x, y + sy, sx / 2, -sy / 2)
    self.zBufferL:draw(x + sx / 2, y + sy, sx / 2, -sy / 2)
  shader:stop()
  RenderState.PopAll()
end

function Renderer:start (resX, resY, ss)
  local ss = ss or 1
  local sx, sy = ss * resX, ss * resY
  if self.sx ~= sx or self.sy ~= sy or self.ss ~= ss then
    self.sx = sx
    self.sy = sy
    self.ss = ss
    self.resX = resX
    self.resY = resY

    if self.buffer0 then self:free() end

    self.buffer0 = createBuffer(sx, sy, colorFormat)
    self.buffer1 = createBuffer(sx, sy, colorFormat)
    self.buffer2 = createBuffer(sx, sy, colorFormat)
    self.uiBuffer = createBuffer(sx, sy, colorFormat)
    self.zBuffer = createBuffer(sx, sy, depthFormat)
    self.zBufferL = createBuffer(sx, sy, TexFormat.R32F)

    self.dsBuffer0 = createBuffer(resX / self.ds, resY / self.ds, colorFormat)
    self.dsBuffer1 = createBuffer(resX / self.ds, resY / self.ds, colorFormat)

    self.meterTex = createBuffer(1, 1, colorFormat)
  end

  self.buffer0:setMipRange(0, 0)
  self.buffer1:setMipRange(0, 0)
  self.buffer2:setMipRange(0, 0)
  self.buffer0:setMinFilter(TexFilter.Linear)
  self.buffer1:setMinFilter(TexFilter.Linear)
  self.buffer2:setMinFilter(TexFilter.Linear)
  self.level = 0

  RenderTarget.Push(sx, sy)
  RenderTarget.BindTex2D(self.buffer0)
  RenderTarget.BindTex2D(self.buffer1)
  RenderTarget.BindTex2D(self.zBufferL)
  RenderTarget.BindTex2D(self.zBuffer)

  Draw.Clear(0, 0, 0, 0)
  Draw.ClearDepth(1)
  Draw.Color(1, 1, 1, 1)
  BlendMode.Push(BlendMode.Disabled)
  CullFace.Push(Settings.get('render.cullface') and CullFace.Back or CullFace.None)
  RenderState.PushDepthTest(true)
end

function Renderer:startAlpha (mode)
  RenderTarget.Push(self.sx, self.sy)
  RenderTarget.BindTex2D(self.buffer0)
  RenderTarget.BindTex2D(self.zBuffer)

  BlendMode.Push(mode)
  CullFace.Push(CullFace.None)
  RenderState.PushDepthTest(true)
  RenderState.PushDepthWritable(false)
end

function Renderer:startPostEffects ()
end

function Renderer:startUI (tex)
  self.uiTex = tex or self.buffer1
  RenderTarget.Push(self.sx, self.sy)
  RenderTarget.BindTex2D(self.uiTex)
  RenderTarget.BindTex2D(self.zBuffer)
  Draw.Clear(0, 0, 0, 0)
  BlendMode.Push(BlendMode.Alpha)
  CullFace.Push(CullFace.None)
  RenderState.PushDepthTest(false)
  RenderState.PushDepthWritable(false)
end

function Renderer:endUI ()
  if not self.uiTex then return end
  self.uiTex:pop()
  BlendMode.Pop()
  CullFace.Pop()
  RenderState.PopDepthTest()
  RenderState.PopDepthWritable()
end

function Renderer:compositeUI (post)
  if not self.uiTex then return end
  local shader = Cache.Shader('ui', post and 'filter/ui_overlay' or 'ui/composite')
  BlendMode.PushDisabled()
  self.buffer2:push()
  if shader then
    shader:start()
      Shader.SetTex2D('srcBottom', self.buffer0)
      Shader.SetTex2D('srcTop', self.uiTex)
      Draw.Color(1, 1, 1, 1)
      Draw.Rect(0, 0, self.sx, self.sy)
    shader:stop()
  end
  self.buffer2:pop()
  self.buffer2, self.buffer0 = self.buffer0, self.buffer2
  BlendMode.Pop()
end

function Renderer:stopUI ()
  self:endUI()
  self:compositeUI()
end

function Renderer:stop ()
  BlendMode.Pop()
  CullFace.Pop()
  RenderState.PopDepthTest()
  RenderTarget.Pop()
end

function Renderer:stopAlpha ()
  BlendMode.Pop()
  CullFace.Pop()
  RenderState.PopDepthTest()
  RenderState.PopDepthWritable()
  RenderTarget.Pop()
end

function Renderer:swap ()
  self.buffer0, self.buffer1 = self.buffer1, self.buffer0
end

local meterLog = os.getenv('PHX_METER') ~= nil
-- 1 Hz readback, in the SECONDS Time_GetRaw() returns -- and 1 Hz is the ceiling
-- that clock allows, not a tuning choice. See the note at the readback.
local meterIntervalSec = 1

function Renderer:meter ()
  -- Only run when something actually consumes the numbers. The pass is not free:
  -- 4096 random texelFetches plus a 1 Hz synchronous readback that stalls the
  -- pipeline, and with auto-exposure off (the shipped default) the only consumer
  -- was the debug panel. Gating here rather than at the call site means any future
  -- caller is safe too.
  if not Settings.get('postfx.exposure.meter') then return end
  local shader = Cache.Shader('ui', 'filter/exposure')
  if not (shader and self.meterTex) then return end

  self.frameSeed = (self.frameSeed + 1) % 4096
  do
    self.meterTex:pushLevel(0)
    shader:start()
      Shader.SetFloat2('size', self.sx, self.sy)
      Shader.SetFloat('timeSeed', self.frameSeed + 1)
      Shader.SetTex2D('src', self.buffer0)
      Draw.Color(1, 1, 1, 1)
      Draw.Rect(0, 0, 1, 1)
    shader:stop()
    self.meterTex:pop()
  end

  -- Readback rate. Time_GetRaw() returns time(0) -- Unix EPOCH SECONDS
  -- (libphx/src/PhxTime.cpp:29) -- so this gate is in SECONDS, not the 100 ms the
  -- original constant was written as. On a seconds clock `>= 100` meant once per
  -- 100 SECONDS: measured exactly one readback across 5200 frames, so the debug
  -- panel's `hdr:` line showed a single boot-time sample forever.
  --
  -- Do not try to make this faster than 1 Hz. time(0) has 1-second granularity,
  -- so `now` only changes once a second and no threshold can beat that (measured:
  -- a 0.1 s gate yields ~0.9 Hz, not 10 Hz). 1 Hz is the right rate for this
  -- consumer anyway -- it is a human reading four numbers in a panel, and a
  -- 10 Hz synchronous readback would add 10 pipeline stalls per second to buy
  -- digits nobody can see. If a genuinely faster meter is ever wanted it needs a
  -- real clock (Time_GetRawMs / a monotonic ms source), not a smaller constant.
  local now = Time.GetRaw()
  if now - self.meterLast >= meterIntervalSec then
    self.meterLast = now
    local b = self.meterTex:getDataBytes(PixelFormat.RGBA, DataFormat.Float):managed()
    self.exposure.avg  = b:readF32()
    self.exposure.max  = b:readF32()
    self.exposure.over = b:readF32()
    self.exposure.lit  = b:readF32()
    -- PHX_METER=1: log the meter's own readings, so its behaviour can be checked
    -- without a human reading the debug panel.
    if meterLog then
      io.stderr:write(string.format(
        '[METER] avg=%.4f lit=%.4f max=%.4f over=%.4f\n',
        self.exposure.avg, self.exposure.lit, self.exposure.max,
        self.exposure.over))
    end
  end
end

-- REMOVED: Renderer:autoExposureEV(). See the REMOVED note in the SETTINGS table
-- above for why (two unit bugs meant it could never converge, and a working
-- version would be wrong for this game anyway). Time_GetRaw() is SECONDS, so any
-- timing here must convert explicitly.

function Renderer:volume (med)
  local q = Settings.get('nebula.quality') or 1
  if q <= 1 then return end
  local stepF = VOL_STEPS[q] or VOL_STEPS[2]
  local evalF = VOL_EVALS[q] or VOL_EVALS[2]

  local shaderH = Cache.Shader('worldray', 'filter/volume')
  local shaderF = Cache.Shader('worldray', 'filter/volblur')
  if not (shaderH and shaderF) then return end

  local volW = math.max(1, math.floor(self.sx / 2))
  local volH = math.max(1, math.floor(self.sy / 2))
  local volMip = 1.0

  if not self.volView or self.volView:getSize().x ~= volW then
    if self.volView then self.volView:free() end
    self.volView = Tex2D.Create(volW, volH, TexFormat.RGBA16F)
    self.volView:setMagFilter(TexFilter.Linear)
    self.volView:setMinFilter(TexFilter.Linear)
    self.volView:setWrapMode(TexWrapMode.Clamp)
    self.volView:push()
    Draw.Clear(0, 0, 0, 0)
    self.volView:pop()
  end

  local anchors = med.anchors
  local volCount = anchors and #anchors or 0
  if volCount > 0 then
    if not self.texAnchors then
      self.texAnchors = Tex2D.Create(4, 16, TexFormat.RGBA32F)
      self.texAnchors:setMagFilter(TexFilter.Linear)
      self.texAnchors:setMinFilter(TexFilter.Linear)
      self.texAnchors:setWrapMode(TexWrapMode.Clamp)
    end
    if not self.anchorBytes then
      self.anchorBytes = Bytes.Create(64 * 16)
    end

    local bytes = self.anchorBytes
    local p = ffi.cast('float*', bytes:getData())
    -- Packing contract with include/medium.glsl:
    --   col0 = (pos.xyz, extX)            -> c.xyz / c.w
    --   col1 = (density, scale, warp, extY)
    --   col2 = (coreColor.rgb, extZ)      -> the per-anchor core albedo + z extent
    --   col3 = (rimColor.rgb, -)          -> the per-anchor rim albedo
    -- The record in NebulaVolumes.build is {px,py,pz, extX,extY,extZ, density,
    -- scale, warp, core.rgb, rim.rgb} (1..15, plus a named d2). This offset was
    -- stale by the three extent fields at one point: `scale` landed in the
    -- density slot and the colour was read from (scale, warp, core.r), so the
    -- noise was sampled at p*extZ (~1e9, where the sin hash is pure garbage) ->
    -- the per-pixel "green speckle". The extents and the rim colour were dropped
    -- entirely: every plume was a sphere of extX with one flat colour, though
    -- NebulaVolumes authors all three extents and a second tone per plume.
    for i = 1, volCount do
      local a = anchors[i]
      local o = (i - 1) * 16
      p[o + 0], p[o + 1], p[o + 2], p[o + 3]  = a[1], a[2], a[3], a[4]
      p[o + 4], p[o + 5], p[o + 6], p[o + 7]  = a[7], a[8], a[9], a[5]
      p[o + 8], p[o + 9], p[o + 10], p[o + 11] = a[10], a[11], a[12], a[6]
      p[o + 12], p[o + 13], p[o + 14], p[o + 15] = a[13], a[14], a[15], 0
    end
    self.texAnchors:setDataBytes(bytes, PixelFormat.RGBA, DataFormat.Float)
  end

  -- Lightning storm flash sources (bounded ≤6 rows, re-upload only on change).
  -- Off = never uploaded and count forced to 0, so the shader loop is zero-cost.
  local flashes = med.lightning
  local lCount = 0
  if flashes and #flashes > 0 and Settings.get('lightning.enable') then
    lCount = math.min(#flashes, 6)
    if not self.texLightning then
      self.texLightning = Tex2D.Create(3, 6, TexFormat.RGBA32F)
      self.texLightning:setMagFilter(TexFilter.Linear)
      self.texLightning:setMinFilter(TexFilter.Linear)
      self.texLightning:setWrapMode(TexWrapMode.Clamp)
    end
    if not self.lightningBytes then
      self.lightningBytes = Bytes.Create(48 * 6)
    end
    if (med.lightningStamp or 0) ~= (self.lightningStamp or -1) then
      local bytes = self.lightningBytes
      local p = ffi.cast('float*', bytes:getData())
      for i = 1, lCount do
        local f = flashes[i]
        local o = (i - 1) * 12
        p[o + 0], p[o + 1], p[o + 2], p[o + 3] = f.pos.x, f.pos.y, f.pos.z, f.radius
        p[o + 4], p[o + 5], p[o + 6], p[o + 7] = f.color.x, f.color.y, f.color.z, f.energy
        p[o + 8], p[o + 9], p[o + 10], p[o + 11] = f.spawnTime, f.duration, f.attack, 0
      end
      self.texLightning:setDataBytes(bytes, PixelFormat.RGBA, DataFormat.Float)
      self.lightningStamp = med.lightningStamp or 0
    end
  end

  local dens = Settings.get('nebula.density') or 1
  local sigT = dens * 0.00005
  local sigS = dens * 0.0000375
  local volDist   = Settings.get('nebula.radius') or 12000
  local volAniso  = Settings.get('nebula.g') or 0
  local tintAmt   = Settings.get('nebula.tint') or 0.35
  local tintR, tintG, tintB = Settings.get('nebula.tintR') or 1,
                              Settings.get('nebula.tintG') or 0.6,
                              Settings.get('nebula.tintB') or 0.2
  local fx, fy, fz, fsp = 0.4, 0.2, 0.8, 40
  local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
  local volTime = CaptureHarness.volTime()
  local volGather = 8.0 / (800.0 * 800.0)

  Profiler.Begin('Render.Volume')

  do -- Pass A
    RenderTarget.Push(volW, volH)
    RenderTarget.BindTex2D(self.volView)
    RenderState.PushDepthTest(false)
    shaderH:start()
      Shader.SetTex2D('texDepth', self.zBufferL)
      Shader.SetTexCube('envMap', med.envMap)
      Shader.SetTexCube('irMap',  med.irMap)
      Shader.SetTex2D('texNoise', med.noise)
      Shader.SetFloat3('starDir',  med.starDir.x, med.starDir.y, med.starDir.z)
      Shader.SetFloat3('sunColor', med.sunColor.x, med.sunColor.y, med.sunColor.z)
      Shader.SetFloat('volMip',    volMip)
      Shader.SetFloat('volDensity', dens)
      Shader.SetFloat('volBackground', Settings.get('nebula.background') or 1)
      Shader.SetFloat('volSigmaT',  sigT)
      Shader.SetFloat('volSigmaS',  sigS)
      Shader.SetFloat('volSteps',   stepF)
      Shader.SetFloat('volDist',    volDist)
      Shader.SetFloat('volEvals',   evalF)
      Shader.SetFloat('volJitter',  Settings.get('nebula.jitter') or 0.05)
      Shader.SetFloat('volAmbient', Settings.get('nebula.ambient') or 1.0)
      Shader.SetFloat('volPalette', Settings.get('nebula.palette') or 1.0)
      Shader.SetFloat3('volFlow', 40 * fx / fl, 40 * fy / fl, 40 * fz / fl)
      Shader.SetFloat('volTime',    volTime)
      Shader.SetFloat('volCount',   volCount)
      if volCount > 0 and self.texAnchors then Shader.SetTex2D('texAnchors', self.texAnchors)
      end
      Shader.SetFloat('volAniso',   volAniso)
      Shader.SetFloat3('volTint', tintR, tintG, tintB)
      Shader.SetFloat('volTintAmt', tintAmt)
      Shader.SetInt('lightningCount', lCount)
      if lCount > 0 then Shader.SetTex2D('texLightning', self.texLightning) end
      Draw.Color(1, 1, 1, 1)
      Draw.Rect(-1, -1, 2, 2)
    shaderH:stop()
    RenderState.PopDepthTest()
    RenderTarget.Pop()
  end

  do -- Pass B
    self.buffer1:pushLevel(self.level)
    RenderState.PushDepthTest(false)
    shaderF:start()
      Shader.SetInt('volMode', (Settings.get('nebula.debug') or 1) - 1)
      Shader.SetTex2D('texVol',   self.volView)
      Shader.SetTex2D('texScene', self.buffer0)
      Shader.SetTex2D('texDepth', self.zBufferL)
      Shader.SetFloat('volMip',    volMip)
      Shader.SetFloat('volGather', volGather)
      Shader.SetFloat('volDensity', dens)
      Shader.SetFloat('volSigmaT',  sigT)
      Shader.SetFloat('volSigmaS',  sigS)
      Shader.SetFloat('volSteps',   stepF)
      Shader.SetFloat('volDist',    volDist)
      Shader.SetFloat('volEvals',   evalF)
      Shader.SetFloat('volCount',   volCount)
      if volCount > 0 and self.texAnchors then Shader.SetTex2D('texAnchors', self.texAnchors) end
      Shader.SetFloat3('volFlow', 40 * fx / fl, 40 * fy / fl, 40 * fz / fl)
      Shader.SetFloat('volTime',    volTime)
      Shader.SetFloat3('volTint', tintR, tintG, tintB)
      Draw.Color(1, 1, 1, 1)
      Draw.Rect(-1, -1, 2, 2)
    shaderF:stop()
    RenderState.PopDepthTest()
    self.buffer1:pop()
    self:swap()
  end

  Profiler.End()
end

function Renderer:godrays (med)
  if not (Settings.get('postfx.godrays.enable') or (Settings.get('postfx.godrays.debug') or 0) > 0) then return end
  local shaderH = Cache.Shader('worldray', 'filter/godrays')
  local shaderF = Cache.Shader('ui', 'filter/godblur')
  if not (shaderH and shaderF) then return end

  local gW = math.max(1, math.floor(self.sx / 4))
  local gH = math.max(1, math.floor(self.sy / 4))
  if not self.godView or self.godView:getSize().x ~= gW then
    if self.godView then self.godView:free() end
    self.godView = Tex2D.Create(gW, gH, TexFormat.RGBA16F)
    self.godView:setMagFilter(TexFilter.Linear)
    self.godView:setMinFilter(TexFilter.Linear)
    self.godView:setWrapMode(TexWrapMode.Clamp)
  end

  local dens = Settings.get('nebula.density') or 1
  local sigT = dens * 0.00005
  local sigS = dens * 0.0000375
  local volDist = Settings.get('nebula.radius') or 12000
  local q = Settings.get('nebula.quality') or 1
  -- Shafts are gated on `nebula.enable`, not on quality, so 'Off' still marches:
  -- clamp it up to Low rather than dropping to a 0-step march.
  if q <= 1 then q = 2 end
  local stepF = GOD_STEPS[q] or GOD_STEPS[2]
  local evalF = GOD_EVALS[q] or GOD_EVALS[2]
  local fx, fy, fz, fsp = 0.4, 0.2, 0.8, 40
  local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
  local volTime = CaptureHarness.volTime()
  local tintAmt = Settings.get('nebula.tint') or 0.0
  local tintR, tintG, tintB = Settings.get('nebula.tintR') or 1,
                              Settings.get('nebula.tintG') or 1,
                              Settings.get('nebula.tintB') or 1
local volCount = med.anchors and #med.anchors or 0
  -- Nebula Off => Renderer:volume() early-returns and never creates texAnchors.
  -- Must not bind a nil texture (and the shader must skip the anchor loop).
  if not self.texAnchors then volCount = 0 end
  local godA = Settings.get('postfx.godrays.g') or 0.92
  local strength = Settings.get('postfx.godrays.strength') or 1
  local godMode = (Settings.get('postfx.godrays.debug') or 1) - 1

  Profiler.Begin('Render.GodRays')

  do -- Pass A: quarter-res shaft march
    RenderTarget.Push(gW, gH)
    RenderTarget.BindTex2D(self.godView)
    RenderState.PushDepthTest(false)
    shaderH:start()
      Shader.SetTex2D('texDepth', self.zBufferL)
      Shader.SetFloat3('starDir',  med.starDir.x, med.starDir.y, med.starDir.z)
      Shader.SetFloat3('sunColor', med.sunColor.x, med.sunColor.y, med.sunColor.z)
      Shader.SetFloat('volSigmaT',  sigT)
      Shader.SetFloat('volSigmaS',  sigS)
      Shader.SetFloat('volSteps',   stepF)
      Shader.SetFloat('volDist',    volDist)
      Shader.SetFloat('volEvals',   evalF)
      Shader.SetFloat3('volFlow', 40 * fx / fl, 40 * fy / fl, 40 * fz / fl)
      Shader.SetFloat('volTime',    volTime)
      Shader.SetFloat('volCount',   volCount)
      if volCount > 0 and self.texAnchors then Shader.SetTex2D('texAnchors', self.texAnchors) end
      Shader.SetFloat3('volTint', tintR, tintG, tintB)
      Shader.SetFloat('volTintAmt', tintAmt)
      Shader.SetFloat('godA', godA)
      Shader.SetFloat('volDensity', dens)
      Shader.SetFloat('volBackground', Settings.get('nebula.background') or 1)
      Shader.SetFloat('volMip',     1.0)
      Draw.Color(1, 1, 1, 1)
      Draw.Rect(-1, -1, 2, 2)
    shaderH:stop()
    RenderState.PopDepthTest()
    RenderTarget.Pop()
  end

  do -- Pass B: radial integrate + composite
    self.buffer1:pushLevel(self.level)
    RenderState.PushDepthTest(false)
    shaderF:start()
      Shader.SetInt('godMode', godMode)
      Shader.SetTex2D('texVol',   self.godView)
      Shader.SetTex2D('texScene', self.buffer0)
      if med.noise then Shader.SetTex2D('texNoise', med.noise) end
      Shader.SetFloat2('sunUV', med.sunUv.x, med.sunUv.y)
      Shader.SetFloat('godStrength', strength * (med.sunFade or 1.0))
      Shader.SetFloat('godCeiling', Settings.get('postfx.godrays.ceiling') or 2.0)
      Draw.Color(1, 1, 1, 1)
      Draw.Rect(0, 0, self.sx, self.sy)
    shaderF:stop()
    RenderState.PopDepthTest()
    self.buffer1:pop()
    self:swap()
  end

  Profiler.End()
end

-- REMOVED: Renderer:fog (filter/fogw, postfx.fog.*). See ltheory-planets.md §11.5.
-- The pass modelled aerial perspective as an UNBOUNDED exponential atmosphere:
-- it hazed any pixel by 1-exp(-density*dist) regardless of whether there was
-- actually any medium along that ray. In this world the medium is a bounded union
-- of <=16 ellipsoids around the viewer (res/shader/include/medium.glsl), and the
-- march stops at their exit -- outside them rho = 0, i.e. vacuum. A planet 137k
-- away therefore has ~120k of NOTHING in front of it, yet the pass still applied
-- ~0.50 of haze to it. Measured: the planet's disc lost 45% of its local contrast
-- (sd 18.15 -> 10.03, p95/p05 3.77 -> 1.51) and went milky. The volumetric pass
-- already does the scattering correctly, over the medium that actually exists.
-- If a real atmosphere is ever wanted, it belongs in the medium (a planet-bound
-- ellipsoid anchor), not as a depth-only post blend.

local filterModes = {
  [1] = { min = TexFilter.Linear,          mag = TexFilter.Linear, aniso = 0,  mip = false },
  [2] = { min = TexFilter.LinearMipLinear, mag = TexFilter.Linear, aniso = 0,  mip = true },
  [3] = { min = TexFilter.LinearMipLinear, mag = TexFilter.Linear, aniso = 16, mip = true },
}

function Renderer:setTextureFilter (mode)
  Cache.filterMode = filterModes[mode] or filterModes[3]
  if Cache.applyFilterMode then Cache.applyFilterMode() end
  if Material and Material.applyFilterMode then Material.applyFilterMode() end
end

return Renderer
