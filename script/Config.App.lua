Config.app = 'LTheory'

Config.debug = {
  metrics         = true,
  window          = false, -- Debug window visible at launch? No: always opened via F9.
  windowSection   = nil,  -- Set to the name of a debug window section to
                          -- collapse all others by default
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
  seedGlobal = nil, -- Set to force deterministic global RNG
  seedSystem = nil, -- Set to force deterministic system generation

  origin     = Vec3f(0, 0, 0), -- Set far from zero to test engine precision
  nFields    = 20,
  nFieldSize = function (rng) return 200 * (rng:getExp() + 1.0) end,
  nStations  = 0,
  nNPCs      = 0,
  nNPCsNew   = 0,
  nPlanets   = 1,
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
  bloomRadius        = 48,     --   blur spread (4..64)
  bloomIntensity     = 1,      --   contribution (0..4)
  bloomThreshold     = 1,      --   soft-knee floor (0..8)
  sharpen            = true,   -- unsharp high-pass sharpen
  tonemap            = true,   -- HDR -> display (AgX) + sRGB; false = raw clamp
  tonemapOperator    = 'AgX',  --   AgX | ACES | Filmic | Khronos
  exposureEV         = 0,      --   exposure stops (-4..4)
  vignette           = true,   -- cinematic darkened corners
  vignetteStrength   = 0.25,   --   (0..1)
  vignetteHardness   = 20,     --   falloff toward center (2..32)
  grain              = false,  -- animated film grain, final pass
  grainStrength      = 1,      --   (0..4)
  aberration         = false,  -- chromatic aberration (lens fringe)
  aberrationStrength = 1,      --   (0..1)
  radialblur         = false,  -- radial motion blur / scanlines
  radialblurStrength = 1,      --   (0..1)
  radialblurScanlines = 1,     --   (0..1)

  -- Texture / edge quality.
  filtering     = 'Aniso', -- Bilinear | Trilinear | Aniso (texture filter quality)
  superSample   = '2x',    -- Off | 2x | 4x (SSAA: renders the frame over-res)

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

Config.ui.font = {
  normal     = Cache.Font('Share', 14),
  normalSize = 14,
  title      = Cache.Font('Exo2Bold', 10),
  titleSize  = 10,
}
