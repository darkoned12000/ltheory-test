Config.app = 'LTheory'

Config.debug = {
  metrics         = true,
  window          = false, -- Debug window visible at launch? No: always opened via F9.
  windowSection   = nil,  -- Open ONE debug-window section at launch (the rest stay
                          -- collapsed). Name it by the setting key's first
                          -- segment, or by its display label:
                          --   genship ('Ship Generator') | nebula | lightning |
                          --   godrays | postfx | lighting | render | ssao | exposure
                          -- e.g. Config.debug.windowSection = 'genship'
  timeAccelFactor = 10,
  damageLog       = false, -- Print [DAMAGE] lines to console for every hit
}

Config.debug.physics = {
  drawWireframes         = false,
  drawBoundingBoxesLocal = false,
  drawBoundingBoxesworld = false,
}

local goodSeeds = {
  14589938814258111262ULL,
  15297218883250103974ULL,
  1842258441393851360ULL,
  1305797465843153519ULL,
  5421862249219039751ULL,
  638780708004697442ULL,
}

Config.gen = {
  debug      = false, -- Enable verbose mesh-generation diagnostics (bad normals, etc.)
  seedGlobal = nil, -- Set to force deterministic global RNG (honoured by LTheory + PhysicsTest; paste a boot-log "Seed: N" line, N as <n>ULL)
  seedSystem = nil, -- Set to force deterministic system generation

  origin     = Vec3f(0, 0, 0), -- Set far from zero to test engine precision
  nFields    = 20,
  nFieldSize = function (rng) return 200 * (rng:getExp() + 1.0) end,
  nStations  = 0,
  nNPCs      = 0,
  nNPCsNew   = 0,
  nPlanets   = 1,
  -- Moons per planet (planets-work Phase B).
  nMoons     = function (rng) return rng:getInt(0, 3) end,
  nBeltSize  = function (rng) return 0 end, -- Asteroids per planetary belt
  nThrusters = 1,
  nTurrets   = 2,

  nDustFlecks = 1024,
  nDustClouds = 1024,
  nStars      = function (rng) return 30000 * (1.0 + 0.5 * rng:getExp()) end,

  shipRes     = 8,
  nebulaRes   = 1024,

  -- Minimum distance to keep the player's ship from a planet center at spawn:
  -- keeps you just clear of the surface (and out of its "huge in your face" zone)
  -- so there's room to see and fly around it. Tune freely; default ~1.25x radius.
  planetViewDist = 250000,

  -- Planet-work planet size (System:spawnPlanet). `scalePlanet` just below is the
  -- legacy SystemBasic scale and is unrelated. Planets are static bodies, so
  -- Bullet's oversized-AABB limit (~289k radius) no longer bounds them; this cap
  -- is about the 1e6 far plane and system coherence.
  planetScaleBase = 1e5,     -- radius = planetScaleBase * Erlang(2); mean ~200k
  planetRadiusMax = 400000,  -- hard cap (far side inside 1e6 at 1.35x stand-off)

  scalePlanet = 2000,
  playerShipSize = 4,
}

Config.audio = {
  -- Name of the ambient music track res/sound/<name>.{mp3,ogg,wav}, and its
  -- volume (2D, unattenuated). Override in Config.Local.lua, e.g.:
  --   Config.audio.music       = 'duelofthefates'
  --   Config.audio.musicVolume = 0.2
  music       = 'system/ambiance/089',
  musicVolume = 0.35,

  -- Gameplay sound effects, keyed by logical effect name. Each entry:
  --   sound   = asset name under res/sound/ (extension auto-probed)
  --   volume  = linear gain multiplier (1.0 = file's native loudness,
  --             0.0 = silent, >1 boosts but may clip)
  --   minDist = 3D full-volume radius in world units (no attenuation inside
  --             this range; beyond it the engine's global rolloff applies)
  -- Add new effects here as weapons/systems are added (afterburner, shieldHit,
  -- hullHit, uiClick, ...). Override anything in Config.Local.lua to test
  -- different assets/volumes without touching gameplay code.
  sfx = {
    blaster   = { sound = 'blaster',     volume = 2.2, minDist = 40  },
    explosion = { sound = 'explosion',   volume = 1.0, minDist = 200 },
    engine    = { sound = 'engine_loop', volume = 1.0, minDist = 60  },
    thunder   = { sound = 'thunder',     volume = 3.5, minDist = 4000 },
  },
}

Config.game = {
  boostCost = 10,
  rateOfFire = 10,
  autoTarget             = false,
  pulseDamage            = 40,
  pulseSize              = 64,
  pulseSpeed             = 6e2,
  pulseRange             = 1000,
  pulseSpread            = 0.01,

  shipBuildTime          = 10,
  shipEnergy             = 100,
  shipEnergyRecharge     = 10,
  shipHealth             = 100,
  shipHealthRegen        = 2,
  stationScale           = 20,

  playerDamageResistance = 1.0,

  enemies                = 0,
  friendlies             = 0,
  squadSizeEnemy         = 8,
  squadSizeFriendly      = 8,
  spawnDistance          = 2000,
  friendlySpawnCount     = 10,
  timeScaleShipEditor    = 0.0,
  invertPitch            = false,

  aiUsesBoost            = true,
  aiFire                 = function (dt, rng) return rng:getExp() ^ 2 < dt end,

  dockRange              = 50,
}

Config.render = {
  fullscreen = false,
  vsync      = true,
  -- CPU-side draw batching/submit. OFF by default so the running app is unchanged;
  -- override in Config.Local.lua to opt in.
  multithread      = false,
  workers          = 0,  -- worker threads for batch build (0 = auto via core count, clamped 1..8)

  -- Planet axial spin (planets-work Phase A). Angle accrued in the planet's
  -- update; deterministic per seed. spin = false restores fully static planets.
  planet = {
    spin      = true,
    spinSpeed = function (rng) return rng:getUniformRange(0.01, 0.05) end,  -- rad/s

    -- Atmosphere exclusion bubble. A planet only collides as a smooth sphere at
    -- `scale`, so a ship pressing in "meshes" with the shaded surface. This
    -- pushes a ship back out at `scale * max(atmoScale, atmoBubbleMin)` and
    -- removes its inward velocity, so you bounce off the atmosphere instead of
    -- grinding the planet. Sets `ship.atmoWarning` for the HUD banner.
    atmoBubble    = true,
    atmoBubbleMin = 1.02,  -- minimum shell factor (airless bodies have atmoScale 1)
    atmoBubbleMsg = 'ATMOSPHERE - PULL UP',

    -- Surface TYPES (planets). Picked per seed by weight; each drives the
    -- generator, palette, ocean level and atmosphere, so a planet's "biome" IS
    -- its type. `weather` is the cloud chance (Phase C, not wired yet).
    --   ocean = waterline range | atmo = atmosphere scale (0 = none/airless)
    --   hue/sat/light = palette ranges (light ramps toward peaks)
    -- forceType = 'terrestrial' pins every planet's type for auditioning
    -- (override in Config.Local.lua); nil = weighted per-seed pick.
    forceType = nil, -- default is nil
    types = {
      -- `aurora` = has a global magnetic dynamo AND enough air to emit. That is
      -- two requirements, and it is why this is a per-type flag rather than
      -- "any world with an atmosphere": Venus has a thick atmosphere and NO
      -- intrinsic field (no aurora), Titan has air and no dynamo (no aurora).
      -- Only the Earth-like types get one. Absent elsewhere == 0.
      { name = 'terrestrial', weight = 32, gen = 'gen/planet', ocean = { 0.05, 0.30 }, atmo = 1.10, weather = 0.60, mountain = 0.85, atmoTint = { 1.00, 1.00, 1.00 }, aurora = 1.0,
        hue = { 0.18, 0.46 }, sat = { 0.12, 0.34 }, light = { 0.11, 0.40 }, crater = 0.45, relief = 10.0, valley = 0.35, crack = 0.25 },
      { name = 'ocean',       weight = 14, gen = 'gen/planet', ocean = { 0.62, 0.92 }, atmo = 1.15, weather = 0.70, mountain = 0.45, atmoTint = { 0.90, 1.00, 1.10 }, aurora = 1.0,
        hue = { 0.50, 0.62 }, sat = { 0.18, 0.40 }, light = { 0.14, 0.30 }, crater = 0.08, relief = 4.0, valley = 0.25, crack = 0.15 },
      { name = 'desert',      weight = 14, gen = 'gen/planet', ocean = { 0.00, 0.03 }, atmo = 1.03, weather = 0.08, mountain = 0.70, atmoTint = { 1.40, 0.95, 0.55 },
        hue = { 0.04, 0.12 }, sat = { 0.20, 0.45 }, light = { 0.10, 0.44 }, crater = 0.90, relief = 14.0, valley = 0.50, crack = 0.45 },
      { name = 'ice',         weight = 14, gen = 'gen/planet', ocean = { 0.15, 0.55 }, atmo = 1.05, weather = 0.40, mountain = 0.70, atmoTint = { 0.90, 0.98, 1.12 },
        hue = { 0.55, 0.66 }, sat = { 0.05, 0.18 }, light = { 0.22, 0.55 }, crater = 0.55, relief = 7.0, valley = 0.30, crack = 0.35 },
      { name = 'barren',      weight = 18, gen = 'gen/moon',   ocean = { 0.00, 0.00 }, atmo = 0.0,  weather = 0.00,
        hue = { 0.05, 0.10 }, sat = { 0.02, 0.16 }, light = { 0.06, 0.22 },
        freqBase = 6, powerBase = 1.0, powerVar = 1.0 },
      { name = 'lava',        weight =  8, gen = 'gen/planet', ocean = { 0.00, 0.00 }, atmo = 1.04, weather = 0.15, mountain = 1.00, atmoTint = { 1.60, 0.60, 0.32 },
        hue = { 0.00, 0.04 }, sat = { 0.25, 0.55 }, light = { 0.05, 0.14 }, crater = 0.30, relief = 14.0, valley = 0.45, crack = 0.40,
        emissive = { 1.00, 0.28, 0.05 }, emissiveAmt = 1.3 },
    },

    -- Moons (Phase B). Sizes/radii are multiples of the PARENT radius, so big
    -- planets get big, distant moons. Speeds are slow: a full orbit takes
    -- minutes, not seconds. Orbits lie in the planet's EQUATORIAL plane, so
    -- they match the planet's spin axis (`inclination` tilts off it).
    moon = {
      orbitSpeed  = function (rng) return rng:getUniformRange(0.004, 0.018) end,  -- rad/s
      scale       = function (rng) return rng:getUniformRange(0.03, 0.14) end,    -- x parent radius
      minRadius   = 800,      -- absolute floor so a small planet gets no pebble-moons
      orbit       = function (rng) return rng:getUniformRange(1.6, 3.2) end,      -- x parent radius
      orbitMax    = 220000,   -- absolute cap (world units): keeps moons clear of the
                              -- 1e6 far plane, so they can't clip out as you fly
      inclination = function (rng) return rng:getUniformRange(-0.35, 0.35) end,   -- rad off the equator
    },
  },
}

-- Window setup at launch (consumed by Application:run). ``width``/``height`` set
-- the initial window size (Hyprland's tiler can override once it maps the window),
-- ``fullscreen`` covers the whole output if true, and ``quitKey`` is a physical
-- key (see Button.Keyboard.*) that quits the app cleanly on Hyprland, where the
-- XWayland window has no title-bar close button. Override in Config.Local.lua.
Config.window = {
  width      = 1024,  -- default = 1600
  height     = 768,   -- default = 900
  fullscreen = false,
  quitKey    = Button.Keyboard.Escape,
}

-- GPU portability & picture: same binary scales from integrated GPU to RTX.
-- This block is the source of truth for every graphics/post-processing option;
-- Renderer seeds runtime Settings from it at startup (see Renderer.lua), and
-- the debug window edits the same Settings live. A future in-game Settings
-- screen will present exactly this set. Override anything here, or outright, in
-- Config.Local.lua. A key left as nil (omit the line) keeps the built-in value.
Config.gpu = {
  -- Low-end caps (VRAM / GPU load).
  maxParticles     = 131072, -- GPU particle pool capacity (VRAM-bound)
  computeShadows   = false,  -- shadow-map lighting; no backend yet, kept for parity

  -- Post chain. Each switch enables one pass; its optional tunables follow it
  -- and are only applied when present (nil = keep the default).
  bloom              = true,   -- Karis exponentially-weighted bloom
  bloomRadius        = 20,     --   blur spread (4..64)
  bloomIntensity     = 1,      --   contribution (0..4)
  bloomThreshold     = 1,      --   soft-knee floor (0..8)
  sharpen            = true,   -- unsharp high-pass sharpen
  sharpenStrength    = 1,      --   unsharp amount (0..3)
  sharpenRadius      = 2,      --   blur radius for the high-pass mask (1..6)
  tonemap            = true,   -- HDR -> display (ACES) + sRGB; false = raw clamp
  tonemapOperator    = 'ACES', --   AgX | ACES | Filmic | Khronos
  exposureEV         = 0,      --   exposure stops (-4..4)
  exposureMeter      = false,  --   run the HDR exposure meter (filter/exposure) and
                          --     feed the debug panel's `hdr:` line. It costs
                          --     ~0.75-1.05 ms/frame (20-28% of a 3.7 ms
                          --     frame) for a 4096-sample 1x1 pass plus a 1 Hz
                          --     synchronous GPU readback, so it is OFF by
                          --     default: switch it on only while tuning exposure
                          --     by hand. Default frame time went 3.30 -> ~2.5 ms
                          --     when this was gated off.
  -- REMOVED: autoExposure / autoExposureKey / autoExposureMinEV /
  -- autoExposureMaxEV / autoExposureSpeed. Auto-exposure never worked: the
  -- adaptation used Time_GetRaw() (which returns time(0), i.e. epoch SECONDS) as
  -- if it were milliseconds, making the 0.5 s constant ~500 s, and the meter it
  -- keyed on refreshed only once per 100 s for the same reason -- so it was
  -- smoothing a constant. Beyond that it is the wrong tool here: this game spans
  -- a lit planet surface and empty space, and absolute brightness is information
  -- the player is meant to read. Use `exposureEV` by hand.
  vignette           = true,   -- cinematic darkened corners
  vignetteStrength   = 0.5,    --   (0..1)
  vignetteHardness   = 20,     --   falloff toward center (2..32)
  grain              = false,  -- animated film grain, final pass
  grainStrength      = 1,      --   (0..4)
  aberration         = false,  -- chromatic aberration (lens fringe)
  aberrationStrength = 1,      --   (0..1)
  aberrationDispersion = 0.0002, -- UV offset at the frame edge (0..0.01); was hardcoded
  radialblur         = false,  -- radial motion blur / scanlines
  radialblurStrength = 1,      --   (0..1)
  radialblurScanlines = 1,     --   (0..1)

  -- REMOVED: the Distance haze block (fogEnable/fogDensity/fogTint/fogMaxHaze/
  -- fogR/G/B, i.e. filter/fogw). It hazed by depth alone, modelling an unbounded
  -- exponential atmosphere, so it applied ~0.50 of haze to a planet 137k away
  -- across ~120k of vacuum and halved the planet's local contrast. The medium in
  -- this world is a bounded union of ellipsoids (see res/shader/include/medium.glsl)
  -- and the volumetric pass already scatters it correctly. A real atmosphere, if
  -- ever wanted, belongs in the medium as a planet-bound anchor.

  -- Volumetric nebula/dust (nebula.*, fog-nebula Phase 1). World-space banks,
  -- correct transmittance (star occlusion), single-scatter inscatter (HG phase
  -- + irMap ambient), depth-aware reconstruction. Off = renderer never invoked.
  nebulaEnabled  = true,
  nebulaQuality  = 'Low',      -- Off | Low | Medium | High. Volume march steps
                          -- 10/20/48 and god-ray steps 12/24/40 respectively;
                          -- 'Off' skips the volume pass (shafts clamp to Low).
  nebulaDebug    = 'Off',            -- Off | Density | Transmittance | Lighting | Steps | Anchors
  -- NOTE (W5, 2026-10-12): these shipped defaults were NOT re-tuned -- the
  -- calibration in script/Config.Local.lua was measured at nebulaQuality 'High',
  -- and these run 'Low', where the march (and so the veil) differs. Re-tune
  -- with a fixed-camera harness before changing them; see ltheory-planets.md 11.0
  -- W5 for why frame-timing drift makes the naive sweep untrustworthy.
  nebulaDensity  = 1.5,        --   medium master gain (0..4)
  nebulaAmbient  = 1.0,        --   irMap ambient scale in the inscatter (0 = sun-term only)
  nebulaPalette  = 1.0,        --   medium albedo mix (1 = palette, 0 = flat tint)
  nebulaJitter   = 0.05,       --   ray-start dither in steps (0 = none; speckle knob)
  nebulaBackground = 0.2,      --   everywhere-field presence (0..1.5, anchors unaffected)
  nebulaCoverage = 2,          --   bank size/density multiplier (0.25..2.5)
  nebulaRadius   = 14000,      --   max march distance, world units
  nebulaG        = 0.4,        --   Henyey-Greenstein phase (phase 1.5 tune-up)
  nebulaStarGlow  = 0.35,      --   Central Star baked into the envMap cube at
                          --     generation time. Was hardcoded 8.0/4.0 (a 12x peak
                          --     that clipped to solid white over a broad patch of
                          --     sky). Changing it needs a relaunch; the cube is
                          --     generated once and also feeds irMap, so it moves
                          --     ambient lighting too.
                          --     NEBULA1 ONLY. The Nebula2 generator builds its
                          --     emission from per-blob colour/density plus
                          --     extinction passes and has no such uniform --
                          --     setting one ABORTS via Shader_GetVariable (see
                          --     ltheory-planets.md 12), which crashed boot for
                          --     any seed taking that path until 2026-10-15.
  nebulaTint     = 0.0,       --   inscatter tint mix (0..1)
  nebulaTintR    = 1.0,          --     1 = warm (1, .6, .2)
  nebulaTintG    = 1.0,
  nebulaTintB    = 1.0,

  -- God-rays (postfx.godrays.*, fog-nebula Phase 3). Independent low-res shaft
  -- pass from starDir: its own on/off + strength, forward-scatter lobe + A/B
  -- debug view. Off = renderer never invoked.
  godraysEnabled  = false,
  godraysStrength = 1,          -- shaft gain. 1.0 = the pass IS the single-scatter
                          -- integral, i.e. no amplification: 14k units of thin gas
                          -- really do scatter only a little. Raising this is a
                          -- STYLISTIC choice that makes the medium brighter than
                          -- the light it is reflecting -- it was 8, which with g=0.92
                          -- added ~190x the sun's own radiance dead ahead and read
                          -- as a light source sitting on the planet's limb.
  godraysG        = 0.7,        --   shaft HG phase g. The forward peak is
                          --   (1-g^2)/(4*pi*(1+g^2-2g)^1.5): 23.9 at g=0.92 (300x
                          --   isotropic), 1.5 at g=0.7. Tight values are what made the
                          --   shafts read as a source rather than as scattering.
  godraysCeiling  = 2.0,        --   soft ceiling on the added shaft. The shafts used to
                          --   be added linearly at strength 8, so looking toward
                          --   the star through the medium clipped to a flat white
                          --   disc that read as a light source ON the planet. 0 =
                          --   linear (old behaviour).
  godraysDebug    = 'Off',      --   Off | Shaft

  -- Lightning storm flash (lightning.*, fog-nebula Phase 4). Local volumetric
  -- point-light flash inside the volume march; storm schedule + bolt ribbon
  -- is LightningStorm.lua. Off = controller no-op, shader loop stays zero-cost.
  lightningEnable  = false,     -- master switch
  lightningQuality = 'High',    -- Low (2 concurrent) | High (4)
  lightningEnergy  = 22,        -- nominal flash energy at nucleus (attenuated by 1/(d²+1))
  lightningRadius  = 6000,      -- per-event radius cutoff, world units
  lightningRate    = 2,         -- storm rate multiplier (bolt count × rate, intervals ÷ rate)
  lightningDebug   = 'Off',     -- Off | Region | Energy

  -- Sun: the warm directional light + ambient fill that makes asteroid fields /
  -- dust lanes read as "lit by the system's star" (System.starDir). Matches the
  -- hardcoded starColor (1, 0.5, 0.1) used by planet atmospheric scattering.
  sunLight        = true,  -- directional + dust backlight contribution
  sunIntensity    = 1,     --   direct/ambient brightness (0..6)
  -- The star DRAWN in the skybox at starDir (separate from the lighting above).
  -- `sunStarHalo` is the one that matters for realism: at the old 120 it spread
  -- the glow over ~20 degrees of sky, so a star sitting just beyond a planet's
  -- limb read as a light source ON the planet. Higher = tighter.
  sunStarTight    = 20000, --   disc exponent (higher = smaller disc)
  sunStarDisc     = 30,    --   disc brightness (HDR, rolled off by the tonemap)
  sunStarHalo     = 900,   --   halo exponent (higher = tighter halo)
  sunStarGlow     = 0.35,  --   halo brightness
  sunAmbientFill  = 0.4564,--   hemisphere fill so shadows aren't pure black; lifted
                           --   from 0.12 so GTAO (ambient-only) has visible contrast
                           --   (ao_on==ao_off composite measured 2026-09-10)
  sunWarmth       = 0.7476,--   1 = warm orange (matching starColor), 0 = white
  sunMarker       = false, --   draw a crosshair where starDir projects (analysis aid)
  sunShadows      = true,  -- directional shadow map from the sun
  sunShadowRange  = 8000,  --   half-size of the ortho shadow box (world units)
  sunShadowSize   = '1024',--   shadow map resolution (256/512/1024/2048)
  shadowMaxLights = 2,     -- max point lights that cast shadows (nearest to camera)
  shadowPeriod    = 2,     -- update shadow maps every N frames (1 = every frame)

  -- PBR finishing: dielectric specular intensity (0..1) and IBL intensity
  -- (scales the irMap/envMap ambient in light/global).
  dielectricSpec = 0.35,
  ambientEnv     = 1.35,  -- IBL scale; lifted 1->1.35 so ambient-only AO reads
  planetSunScale   = 1.0,   -- planets' sun-term brightness (Material_NoShade; 0 = nebula only)
  planetAtmoGlow   = 0.756, -- planets' atmospheric-scattering brightness (0..3)
  planetEnvAmbient = 1.75,  -- planets' nebula-skybox fill; separate from `ambientEnv`,
                          -- which is the deferred-material IBL the ship/asteroids use
  planetTerminator = 0.35, -- day/night falloff: 0 = cosine law (physical, dims
                          -- toward the limb), 1 = the old flat wrap, which kept 37%
                          -- brightness AT the limb and read as a glow on the edge.
  planetCloudsEnabled = true, -- master switch for every planet's cloud deck. Use
                          -- THIS to turn clouds off, not Coverage=0: per-planet
                          -- cloudLevel is a bias that can be negative, so 0 gain
                          -- still leaves clouds on ~1/3 of desert worlds.
  planetClouds   = 1.25,    -- cloud-deck gain (0..3.0). NOT a 0..1 fraction: it
                          -- positions the coverage window smoothstep(0.70-0.20c,
                          -- 0.95-0.20c), so it stays meaningful above 1. Per-planet coverage is
                          -- type.weather x this x a per-planet bias; airless bodies
                          -- carry weather = 0 and never pay for it.
  planetCloudHeight = 0.02, -- cloud SHELL altitude as a fraction of planet radius.
                          -- 0 = the old deck projected onto the ground (no
                          -- parallax -- the clouds are welded to the terrain);
                          -- >0 puts the deck on a sphere above it, so the camera
                          -- moves relative to the clouds and you get parallax.
                          -- A real cloud deck is ~0.16% of a planet's radius up;
                          -- the default is higher because a physically-scaled
                          -- shell is too thin to read at any sane camera distance.
  planetCloudShadow = 0.55, -- how much the deck dims the sun term on the ground
                          --     beneath it (0..1). One extra cube fetch on an
                          --     already-bound texture, no new pass. 0 = off.
  planetStorms      = 1.0,     -- storminess multiplier on the type's `weather` prior
                          --     (ocean .70 / terr .60 / ice .40 / lava .15 /
                          --     desert .08 / barren+moon 0). Storms read as
                          --     DARKER convective cells, per ISS photography.
  planetStormFlash  = 1.0,     -- intra-cloud lightning. Cells fire independently
                          --     (hashed per cell per time window), so the planet
                          --     twinkles rather than strobing in unison.
  planetAurora      = 1.0,     -- auroral emission. TYPE-GATED: only worlds whose
                          --     type sets `aurora` (needs a magnetic dynamo AND
                          --     an atmosphere) emit at all -- terrestrial and
                          --     ocean. Raising this will NOT light a desert,
                          --     an ice world, a lava world, a barren rock or a
                          --     moon.
  planetAuroraHeight = 0.03,   -- lower (green) shell altitude as a fraction of
                          --     radius; Earth's green band is 100-300 km on a
                          --     6371 km radius. The red band above is derived
                          --     in the shader at 2.2x this altitude.
  planetCloudWind   = 0.04, -- cloud advection as a FRACTION OF THE PLANET'S SPIN,
                          --     not an absolute rate. Real drift is ~6% of Earth's
                          --     rotation; relative keeps the feel identical on a
                          --     2-minute planet and a 10-minute one, and the deck
                          --     creeps backwards against the spin as on Earth.

  -- GTAO screen-space ambient occlusion (see ssao-gtao-implementation.md).
  -- Opt-in: kept OFF by default until a mid-tier GPU measurement proves the
  -- cost; the debug-panel 'ssao' section enables it live.
  aoEnabled     = false, -- master switch
  aoQuality     = 'Half',-- Off | Half | Quarter AO resolution
  aoRadius      = 500,   -- world-space occlusion radius (0.1..4000)
  aoIntensity   = 1.5,   -- AO power curve / strength (0..3); user-approved default (Phase C close 2026-09-10)
  fillOcclude   = 1,     -- 1 = occlude the sun hemisphere fill like the IBL (Phase-C look);
                         -- 0 = "correct" ambient-only (fill stays warm in shadow) — §9.2 storytelling knob
  aoDirections  = 4,     -- GTAO slices (2/4/6/8)
  aoSteps       = 3,     -- taps per slice (2/3/4/6)
  aoThickness   = 0.25,  -- silhouette bias (0..1) — keeps rims lit, not black
  aoBlur        = 1,     -- bilateral denoise passes (0/1/2)

  -- Texture / edge quality.
  fovY          = 75,       -- camera vertical FOV (deg)
  filtering     = 'Bilinear', -- Bilinear | Trilinear | Aniso (texture filter quality)
  superSample   = 'Off',    -- Off | 2x | 4x (SSAA: renders the frame over-res)
  resolutionScale = '100%', -- render 3D below window size, upscale on present
                            -- (100%|85%|75%|67%|50%; big perf lever at 4K)

  -- Future: antiAlias = 'TAA' — temporal AA (planned, not yet wired).
}

Config.ui = {
  showTrackers     = true,
  defaultControl   = 'Ship',
  controlBarHeight = 48
}

Config.ui.color = {
  accent            = Color(1.00, 0.00, 0.30, 1.0),
  focused           = Color(1.00, 0.00, 0.30, 1.0),
  active            = Color(0.70, 0.00, 0.21, 1.0),
  background        = Color(0.15, 0.15, 0.15, 1.0),
  border            = Color(0.12, 0.12, 0.12, 1.0),
  fill              = Color(0.60, 0.60, 0.60, 1.0),
  textNormal        = Color(0.75, 0.75, 0.75, 1.0),
  textNormalFocused = Color(0.00, 0.00, 0.00, 1.0),
  textTitle         = Color(0.60, 0.60, 0.60, 1.0),
  debugRect         = Color(0.50, 1.00, 0.50, 0.05),
  selection         = Color(1.00, 0.50, 0.10, 1.0),
  control           = Color(0.20, 0.60, 1.00, 0.3),
  controlFocused    = Color(0.20, 1.00, 0.20, 0.4),
  controlActive     = Color(0.14, 0.70, 0.14, 0.4),
}

-- Baseline UI fonts (pixel sizes at a 900px-tall window). LTheory:onInit
-- scales these to the actual window height so the debug panel (and any other
-- UI) reads the same on any monitor/resolution.
Config.ui.font = {
  normal     = Cache.Font('Share', 22),
  normalSize = 22,
  title      = Cache.Font('Exo2Bold', 16),
  titleSize  = 16,
}
