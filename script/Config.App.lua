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

-- Seeds known to look good (paste into Config.gen.seedGlobal to
-- reproduce one):
  --   14589938814258111262ULL
  --   15297218883250103974ULL
  --   1842258441393851360ULL
  --   1305797465843153519ULL
  --   5421862249219039751ULL
  --   638780708004697442ULL

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

  -- Chunk-streamed endless asteroid field (AsteroidField.lua).
  --
  -- Each chunk is generated from Seed.rng('asteroidField', <chunk coords>), so
  -- it is a pure function of the world seed and the cell: loading one chunk
  -- cannot perturb another, flying away and back gives the identical field, and
  -- the shared generation stream is never consumed. See the module header for
  -- why the old fixed-cluster field could not be streamed.
  --
  -- Visible rock count is roughly (loaded chunks) x perChunk, but the number
  -- that actually matters is DENSITY inside the view radius, so tune perChunk
  -- against loadRadius by eye rather than trusting the product.
  --
  -- Radii are multiples of chunkSize resolved to world units.
  --
  -- They have to reach past visual range, because the camera has no distance
  -- cutoff at all (zFar = 1e6, Util/Camera.lua:13). Measured: at a 7500-unit
  -- boundary the seam was plainly visible -- raising the radius from 3 to 6
  -- chunks changed 10380 pixels, so the 7500..15000 band was on screen and
  -- rocks popped in.
  --
  --   chunkSize    world units per chunk edge
  --   perChunk     rocks generated per chunk
  --   fadeStart    distance where fragments are fully visible. From there to
  --               the conservative fade end, a screen-space dither discard
  --               dissolves the rock; this does not scale or animate geometry.
  --   loadRadius   chunk-centre distance at which chunks enter the world. The
  --               shader fade ends BEFORE this by half a cell diagonal plus
  --               the largest rock radius, so a newly loaded rock cannot pop
  --               in partway through the curtain.
  --   unloadRadius distance at which chunks are dropped. It must be larger than
  --               loadRadius to provide hysteresis and prevent boundary churn.
  --   radius       the field is bounded to this distance from the system origin;
  --               0 = truly unbounded. Measured: at 60000 you exit the field
  --               after ~40k units of travel and the rocks simply stop (0 rocks,
  --               verified), which reads as the trick failing rather than as
  --               leaving a system. 400000 is ~13x the system extent (planets
  --               sit at 1e4..3e4), so in practice you never reach it and the
  --               field behaves as endless -- while remaining a real bound, so
  --               the generator can never be talked into allocating anywhere.
  --               Lower it to restore a hard, visible edge.
  --   minScale/maxScale  rock size range (Asteroid health scales with it)
  --   clumpChance  fraction of rocks placed beside an existing rock rather
  --               than scattered -- what makes it read as a field, not gravel
  --   clumpRadius  clump spread as a fraction of chunkSize
  --   planetMargin clearance outside a planet's collision radius; without it
  --               rocks spawn inside planets (W8's bug class)
  --   static       rocks are immovable (mass 0). Cheapest, and they still ram.
  asteroidField = {
    enable      = false,   -- opt-in until play-tested
    chunkSize   = 2500,
    -- Distance fade is in world units (multiples of chunkSize). Chunk centres
    -- load at loadRadius; because rocks stay inside their cell, the conservative
    -- fade end is loadRadius - half a cell diagonal - maximum rock radius. With
    -- the values below the band is about 21875..27263 units: farther away than
    -- before, and ~32% narrower so the dissolve completes more quickly.
    --
    -- This is deliberately a lower-density, longer-reach field: loading radius
    -- grows cubically, so fractional perChunk density keeps the number of Bullet
    -- bodies near the current order of magnitude while extending the horizon.
    -- Space should read vast, not like a dense fog wall. Tune Reach, Density,
    -- and Fade Start in Debug > Asteroid Field.
    perChunk    = 0.8,
    fadeStart   = 8.75,    -- fully solid inside 21875
    loadRadius  = 12,      -- fade finishes around 27263; chunks load to 30000
    unloadRadius = 14,     -- dropped beyond 35000 (hysteresis)
    -- THE BUDGET: the hard ceiling on loaded chunks, evicted farthest-first
    -- when a long flight's path tube would grow past it. Radius hysteresis
    -- cannot bound cost by itself (a 60k-unit flight loads a ~30k-radius tube
    -- along the whole path: measured 8151 -> 16887 rocks in one session with
    -- the FPS dying). 4600 covers the boot sphere at this load radius with
    -- headroom, so the cap only ever trims what is already behind you.
    maxChunks   = 4600,
    radius      = 400000,
    -- Rock size is in world units on the entity scale; the mesh radius is about
    -- 0.54 x scale. Base sizes are 12..300, with rare landmarks up to 900. At
    -- distance d, a rock's projected size scales as radius/d; the far fade band
    -- therefore favors the largest tier, while small rocks naturally read as
    -- distant specks and dissolve earlier.
    minScale    = 12,
    maxScale    = 300,
    -- Rare large tier: this fraction of rocks gets a 2..4x multiplier on top of
    -- its exponential base size. Play-tested feedback asked for landmarks --
    -- rocks 2-4x the biggest ones otherwise present, but scarce enough that you
    -- see a FEW as you fly rather than a crowd. Raising maxScale instead would
    -- make every rock bigger, which is not the same thing at all.
    -- At ~6500 loaded rocks, 0.05 => ~325 landmarks in the entire loaded field;
    -- only a small fraction are in the camera view at once.
    largeChance = 0.05,
    -- Ceiling for the large tier ONLY, and deliberately above maxScale. The tier
    -- used to clamp back to maxScale, which made it dead code: the base draw
    -- already clamped (see sizeSoftCap), so 38.5% of bases sat at exactly 300
    -- and every landmark draw was multiplied straight back down to 300. A
    -- landmark has to be able to exceed the biggest ordinary rock.
    largeMaxScale = 900,
    -- Soft bound on the exponential size draw, u = E / (E + sizeSoftCap).
    -- The draw is unbounded, so clamping it piles a huge spike on one value --
    -- measured 38.5% of the whole field at exactly maxScale, which made both
    -- size knobs inert. This maps [0,inf) into [0,1) with no saturation.
    -- Raising it pushes the mass lower in the range (smaller, rarer big rocks);
    -- 0.7 keeps the median rock at ~7px across at the far edge of the field.
    sizeSoftCap = 0.7,
    clumpChance = 0.65,
    clumpRadius = 0.18,
    planetMargin = 1500,
    static      = true,
  },
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
  -- Ship stand-off from a planet is planetStandoff x the planet's own radius, and
  -- is applied UNCONDITIONALLY at spawn (see LTheory.lua). It used to be
  -- conditional (`if dist < clear`), which meant the stand-off usually did not
  -- apply at all and the planet's apparent size varied 11.6-54 deg purely by
  -- seed draw. Because the ship's apparent size is set by the chase camera and
  -- not by its distance to the planet, this is the ONLY knob that changes how big
  -- the planet reads next to the ship.
  --
  -- Disc angular diameter = 2*asin(1/planetStandoff), independent of the planet's
  -- size: 2.2 -> 54 deg, 1.75 -> 70 deg, 1.5 -> 84 deg. Below ~1.45 it exceeds
  -- the 80 deg FOV and the disc runs off every edge.
  --
  -- Because it is scale-invariant, raising `scalePlanet` does NOT make the planet
  -- look bigger -- radius and stand-off rise together. Only this value does.
  -- Below radius ~2860 the planetViewDist floor wins and small bodies stay small
  -- (radius 588 -> 13.5 deg), deliberately.
  planetViewDist = 5000,
  planetStandoff = 1.75,      -- x planet radius; ~70 deg disc at 80 deg FOV

  -- Planet size (System:spawnPlanet). `scalePlanet` is the HONOURED base:
  -- radius = scalePlanet * Erlang(2), so the mean radius is ~2x this.
  --
  -- W8 (2026-10-16): the live spawn path ignored `scalePlanet` entirely and used
  -- `planetScaleBase = 1e5` below, giving a mean radius of ~200k against
  -- kSystemScale = 10000 -- every planet was ~20x the system it sat in and could
  -- engulf the belt and stations. `scalePlanet` was read only by the legacy
  -- Gen/System/SystemBasic generator, so a player's `Config.gen.scalePlanet` had
  -- no effect on the world they actually played in. It is now the live base;
  -- `planetScaleBase` remains only as a fallback if that is set instead.
  --
  -- Engagement is now structurally impossible rather than merely unlikely: the
  -- placement distance is DERIVED from the radius (`planetClearance` below), so
  -- no value of `scalePlanet` can produce an engulfing planet.
  scalePlanet     = 6000,    -- mean radius ~12k; the belt lives within 10k
  planetClearance = 2.5,     -- planet CENTRE is at least this x its radius, so
                              --     its surface clears the system's own extent
  -- Fallback base, used only if `scalePlanet` is nil. It was the live base
  -- before W8 and is 20x larger; changing it does nothing unless scalePlanet is
  -- unset.
  planetScaleBase = 1e5,
  -- Planets are static bodies, so Bullet's oversized-AABB limit (~289k radius)
  -- no longer bounds them; this cap is about the 1e6 far plane at the ship's
  -- 1.35x stand-off.
  planetRadiusMax = 400000,
  playerShipSize = 4,
}

Config.audio = {
  -- Name of the ambient music track res/sound/<name>.{mp3,ogg,wav}, and its
  -- volume (2D, unattenuated). Override in Config.Local.lua, e.g.:
  --   Config.audio.music       = 'duelofthefates'
  --   Config.audio.musicVolume = 0.2
  music       = 'system/ambiance/089',
  musicVolume = 0.35,
  -- One master gain for every gameplay SFX (blaster, explosion, engine,
  -- thunder). It multiplies each effect's own `Config.audio.sfx.<name>.
  -- volume` at the moment the sound plays, so the slider on the SETTINGS
  -- screen applies live without rebuilding anything. Default: full.
  sfxVolume   = 1.0,

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
  -- The boost's energy cost per second. Scaled with the boost's strength
  -- (it now doubles the thrust rather than tripling it), so the boost's
  -- efficiency per unit of energy is unchanged.
  boostCost = 6.7,
  rateOfFire = 10,
  autoTarget             = false,
  pulseDamage            = 40,
  pulseSize              = 64,
  pulseSpeed             = 6e2,
  pulseRange             = 1000,
  pulseSpread            = 0.01,

  -- Collision damage. damage = (relSpeed - rammingMinSpeed) * rammingDamageScale,
  -- applied to BOTH bodies (System:handleRamming).
  --
  -- WAS HARDCODE: min 25, scale 2, against 100 ship HP -- which made anything
  -- above 75 u/s instantly fatal. That was survivable when a world held ~30
  -- decorative rocks. With a streamed field putting ~1000 DESTRUCTIBLE rocks
  -- around the ship, "above 75 u/s is death" turns routine flight into a
  -- minefield, so both numbers are knobs now and both are deliberately gentle.
  --
  -- To make collision harmless entirely (scenery you pass through), set
  -- rammingDamageScale = 0. To restore the old lethal curve, 2.0.
  -- Both of these are relative to the SHIP'S TOP SPEED (500 u/s, see
  -- Ship:getTopSpeed), because a collision's damage is the impact speed:
  -- the old numbers (25 and 0.35) were tuned for a 100 u/s ship, and a
  -- 500 u/s ship hitting a rock at 500 would take 166 damage against 100 HP
  -- -- instant death, and "routine flight" in a sector with a rock field
  -- would be lethal.
  rammingMinSpeed     = 125.0, -- below this, no damage at all (a quarter of the top speed)
  rammingDamageScale  = 0.07,  -- 100 HP ship survives a ~1550 u/s hit (3x the top speed)

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

  dockRange              = 500,

  -- THE AI POPULATION (the economy's participants): NPC capital ships
  -- whose Think action picks jobs by payout -- mining the belts into
  -- the stations' standing bids, riding the trade flows. 0 = none
  -- (default until the jobs path is play-tested); raise for traffic.
  aiShips                = 6,

  -- The SECTOR's extent, in world units. A sector is a volume of space with
  -- its own name and its own regions; this is how big it is.
  --
  -- It has to comfortably contain the playable volume: the asteroid field
  -- streams to loadRadius * chunkSize around the ship (12 * 2500 = 30,000 at
  -- the shipped defaults), so 60,000 gives the field room to sit inside a
  -- region rather than always being at the sector's edge.
  --
  -- A region is a named place INSIDE the sector, and there are one to six of
  -- them per sector (determined by the sector's seed). This number is the
  -- sector's size, not a region's.
  sectorRadius           = 60000,
}

Config.render = {
  fullscreen = false,
  vsync      = false, -- the dump's value: vsync on double-buffers a 4K frame
                      --     by a whole frame, which is very visible at 60 Hz.
  -- CPU-side draw batching/submit. OFF by default so the running app is unchanged;
  -- override in Config.Local.lua to opt in.
  multithread      = false,
  workers          = 0,  -- worker threads for batch build (0 = auto via core count, clamped 1..8)

  -- Planet axial spin (planets-work Phase A). Angle accrued in the planet's
  -- update; deterministic per seed. spin = false restores fully static planets.
  planet = {
    spin      = true,
    spinSpeed = function (rng) return rng:getUniformRange(0.01, 0.05) end,  -- rad/s
    -- Multiplier on the per-planet rate above, NOT a new distribution: the seed
    -- still picks 0.01-0.05 rad/s and this scales the result, so worlds keep
    -- their individual personalities. Read live, so it applies to planets already
    -- spinning. Default 0.6 = a 40% reduction in rotation.
    --
    -- NOTE: cloud wind is defined as a FRACTION of rotation (cloudWind, default
    -- 0.04), so it slows down with the planet. That is deliberate -- the deck
    -- keeps drifting at the same rate RELATIVE to the ground, which is what
    -- makes a fast and a slow planet feel alike. To hold the old absolute drift
    -- while the rotation is slower, raise cloudWind to 0.04 / 0.6 = 0.067.
    planetSpinRate = 0.6,

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
      { name = 'terrestrial', weight = 32, gen = 'gen/planet', ocean = { 0.05, 0.30 }, atmo = 1.10, weather = 0.60, mountain = 0.85, atmoTint = { 1.00, 1.00, 1.00 }, ring = 0.30, ringIce = 0.85,
        hue = { 0.18, 0.46 }, sat = { 0.12, 0.34 }, light = { 0.11, 0.40 }, crater = 0.45, relief = 10.0, valley = 0.35, crack = 0.25 },
      { name = 'ocean',       weight = 14, gen = 'gen/planet', ocean = { 0.62, 0.92 }, atmo = 1.15, weather = 0.70, mountain = 0.45, atmoTint = { 0.90, 1.00, 1.10 }, ring = 0.22, ringIce = 0.80,
        hue = { 0.50, 0.62 }, sat = { 0.18, 0.40 }, light = { 0.14, 0.30 }, crater = 0.08, relief = 4.0, valley = 0.25, crack = 0.15 },
      { name = 'desert',      weight = 14, gen = 'gen/planet', ocean = { 0.00, 0.03 }, atmo = 1.03, weather = 0.08, mountain = 0.70, atmoTint = { 1.40, 0.95, 0.55 },
        hue = { 0.04, 0.12 }, sat = { 0.20, 0.45 }, light = { 0.10, 0.44 }, crater = 0.90, relief = 14.0, valley = 0.50, crack = 0.45 },
      { name = 'ice',         weight = 14, gen = 'gen/planet', ocean = { 0.15, 0.55 }, atmo = 1.05, weather = 0.40, mountain = 0.70, atmoTint = { 0.90, 0.98, 1.12 }, ring = 0.28, ringIce = 0.30,
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
      -- Floor as a FRACTION of the parent radius, not an absolute 800. W8 made
      -- planets much smaller (scalePlanet 6e3 -> radius ~1e3-9e3), and an
      -- absolute 800 floor then gave a radius-1008 planet moons of radius 800 --
      -- 0.79x its own planet. 3% keeps the "no pebble-moons" intent at any
      -- parent size, and for large parents it subsumes the old 800 outright
      -- (3% of a 2e5 planet is 6000).
      minRadiusFrac = 0.03,
      orbit       = function (rng) return rng:getUniformRange(1.6, 3.2) end,      -- x parent radius
      orbitMax    = 220000,   -- absolute cap (world units): keeps moons clear of the
                              -- 1e6 far plane, so they can't clip out as you fly
      inclination = function (rng) return rng:getUniformRange(-0.35, 0.35) end,   -- rad off the equator
    },
  },
}

-- Window setup at launch (consumed by Application:run). ``width``/``height`` set
-- the initial window size (Hyprland's tiler can override once it maps the window)
-- and ``fullscreen`` covers the whole output if true. Override in Config.Local.lua.
--
-- There is NO ``quitKey`` any more. It was Escape, and Escape is how the
-- player toggles the menu -- an accidental quit in the middle of a chase
-- because someone wanted pause is not an acceptable trade for a missing
-- title-bar button. Quitting is the menu's EXIT entry. If a specific window
-- manager still wants a quit key, set ``Config.window.quitKey = >>Button.<key>``
-- in Config.Local.lua -- Application:run reads it if it is set.
Config.window = {
  width      = 1024,  -- default = 1600
  height     = 768,   -- default = 900
  fullscreen = false,
  quitKey    = nil,
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
  exposureEV         = 0.03791,      --   exposure stops (-4..4)
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
  -- Colour grading (post-tonemap, in linear space). The panel's
  -- 'Post FX > Saturation / Contrast / Temp / Tint' read these live.
  colorSat      = 1.078,   --   saturation multiplier (0..3)
  colorContrast = 1.034,   --   contrast multiplier (0..3)
  colorTemp     = 0.07901, --   warm/cool bias, -1..1
  colorTint     = 0.06725, --   magenta/green bias, -1..1

  vignette           = true,   -- cinematic darkened corners
  vignetteStrength   = 0.5,    --   (0..1)
  vignetteHardness   = 20,     --   falloff toward center (2..32)
  grain              = false,  -- animated film grain, final pass
  grainStrength      = 1,      --   (0..4)
  aberration         = false,  -- chromatic aberration (lens fringe)
  aberrationStrength = 1,      --   (0..1)
  aberrationDispersion = 0.0002, -- UV offset at the frame edge (0..0.01); was hardcoded
  fxaa               = false,  -- cheap full-res post-AA (an alternative to
                          --     the capture-only 2x supersample)
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
  -- with a fixed-camera harness before changing them; see docs/ltheory-planets.md 11.0
  -- W5 for why frame-timing drift makes the naive sweep untrustworthy.
  nebulaDensity  = 2.495,        --   medium master gain (0..4)
  nebulaAmbient  = 1.002,        --   irMap ambient scale in the inscatter (0 = sun-term only)
  nebulaPalette  = 0.5067,        --   medium albedo mix (1 = palette, 0 = flat tint)
  nebulaJitter   = 0.3056,        --   blue-noise ray-start jitter in step units (no extra march work)
  nebulaBackground = 0.1019,      --   everywhere-field presence (0..1.5, anchors unaffected)
  nebulaCoverage = 1.009,          --   bank size/density multiplier (0.25..2.5)
  nebulaRadius   = 22010.0,      --   max march distance, world units
  nebulaG        = 0.07659,        --   Henyey-Greenstein phase (phase 1.5 tune-up)
  nebulaStarGlow  = 0.5585,      --   Central Star baked into the envMap cube at
                          --     generation time. Was hardcoded 8.0/4.0 (a 12x peak
                          --     that clipped to solid white over a broad patch of
                          --     sky). Changing it needs a relaunch; the cube is
                          --     generated once and also feeds irMap, so it moves
                          --     ambient lighting too.
                          --     NEBULA1 ONLY. The Nebula2 generator builds its
                          --     emission from per-blob colour/density plus
                          --     extinction passes and has no such uniform --
                          --     setting one ABORTS via Shader_GetVariable (see
                          --     docs/ltheory-planets.md 12), which crashed boot for
                          --     any seed taking that path until 2026-10-15.
  nebulaTint     = 0.0,       --   inscatter tint mix (0..1)
  nebulaTintR    = 1.0,          --     1 = warm (1, .6, .2)
  nebulaTintG    = 1.0,
  nebulaTintB    = 1.0,

  -- God-rays (postfx.godrays.*, fog-nebula Phase 3). Independent low-res shaft
  -- pass from starDir: its own on/off + strength, forward-scatter lobe + A/B
  -- debug view. Off = renderer never invoked.
  -- Temporal anti-aliasing is the interactive AA path. The only remaining SSAA
  -- use is the Screenshot key's one-shot 2x raster capture; it is hidden from
  -- the settings panel and disables TAA for that frame.
  taaEnabled  = false,   -- off until play-tested
  taaBlend    = 0.9,     -- history weight; lower = less ghosting on movers

  -- Panel-seeded form of the asteroid-field knobs. These seed the debug panel
  -- (Renderer.lua's SETTINGS), and the panel is what actually drives the live
  -- field settings. Remaining shape (chunkSize, unloadRadius, sizes, clumping,
  -- planetMargin) stays in Config.gen.asteroidField.
  asteroidFieldEnabled    = true,
  asteroidFieldPerChunk   = 2.004,
  asteroidFieldLoadRadius = 10.04,
  asteroidFieldFadeStart  = 8.53,

  godraysEnabled  = true,
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
  sunIntensity    = 1.245,     --   direct/ambient brightness (0..6)
  -- The star DRAWN in the skybox at starDir (separate from the lighting above).
  -- `sunStarHalo` is the one that matters for realism: at the old 120 it spread
  -- the glow over ~20 degrees of sky, so a star sitting just beyond a planet's
  -- limb read as a light source ON the planet. Higher = tighter.
  sunStarTight    = 14830.0, --   disc exponent (higher = smaller disc)
  sunStarDisc     = 49.98,    --   disc brightness (HDR, rolled off by the tonemap)
  sunStarHalo     = 505.5,   --   halo exponent (higher = tighter halo)
  sunStarGlow     = 0.5558,  --   halo brightness
  sunAmbientFill  = 0.5135,--   hemisphere fill so shadows aren't pure black; lifted
                           --   from 0.12 so GTAO (ambient-only) has visible contrast
                           --   (ao_on==ao_off composite measured 2026-09-10)
  sunWarmth       = 0.7568,--   1 = warm orange (matching starColor), 0 = white
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
  planetBiomes      = 0.5019,     -- biome blend strength (W7c). 0 = the pre-W7c look
                          -- exactly (one elevation ramp, one character per planet);
                          -- 1 = the full blend, where a planet's climate is decided
                          -- by latitude + altitude (temperature) and by the
                          -- generator's biome field (moisture). The weights are
                          -- NORMALISED, so biomes cross-fade and never switch --
                          -- there is no threshold to pop as the camera moves.
  planetCloudsEnabled = true, -- master switch for every planet's cloud deck. Use
                           -- THIS to turn clouds off, not Coverage=0: per-planet
                          -- cloudLevel is a bias that can be negative, so 0 gain
                          -- still leaves clouds on ~1/3 of desert worlds.
  planetClouds   = 1.3,    -- cloud-deck gain (0..3.0). NOT a 0..1 fraction: it
                          -- positions the coverage window smoothstep(0.70-0.20c,
                          -- 0.95-0.20c), so it stays meaningful above 1. Per-planet coverage is
                          -- type.weather x this x a per-planet bias; airless bodies
                          -- carry weather = 0 and never pay for it.
  planetCloudHeight = 0.0303, -- cloud SHELL altitude as a fraction of planet radius.
                          -- 0 = the old deck projected onto the ground (no
                          -- parallax -- the clouds are welded to the terrain);
                          -- >0 puts the deck on a sphere above it, so the camera
                          -- moves relative to the clouds and you get parallax.
                          -- A real cloud deck is ~0.16% of a planet's radius up;
                          -- the default is higher because a physically-scaled
                          -- shell is too thin to read at any sane camera distance.
  planetCloudShadow = 0.5698, -- how much the deck dims the sun term on the ground
                          --     beneath it (0..1). One extra cube fetch on an
                          --     already-bound texture, no new pass. 0 = off.
  planetSpinRate    = 0.2081,  -- multiplier on the per-planet rotation rate
                          --     (0 = frozen; 1 = the seed's own rate)
  planetRingsEnabled = true, -- master switch for rings. Checked at spawn AND at
                          --     draw time, so it hides an existing ring live --
                          -- every other ring knob is construction-time and
                          --     cannot affect the world already on screen.
  planetRingVariation = 0.5745, -- 0 = every ringed world gets the same canonical
                          --     ring (good for A/B-ing a look change across
                          --     seeds), 1 = full spread.
  planetRingChance  = 0.9124,   -- GLOBAL multiplier on each type's per-type `ring`
                          --     weight, so ring frequency is tunable without
                          --     touching the type table. Per-type chances are
                          --     ~0.2-0.3, so at 0.45 roughly one world in six
                          --     ends up ringed -- a treat, not the norm. 0 forces
                          --     every type off and is a clean A/B.
  planetRingOpacity = 2.0,    -- ring optical depth scale
  planetRingBright  = 1.0,    -- overall ring brightness multiplier
  planetRingEnv     = 1.306,    -- how strongly a ring picks up the skybox / nebula
                          --     irradiance. Light scattered toward the eye comes
                          --     from the star's direction, so a backlit ring
                          --     takes the colour of whatever nebula bank is
                          --     behind it. 0 = star light only.

  planetStorms      = 0.8715,     -- storminess multiplier on the type's `weather` prior
                          --     (ocean .70 / terr .60 / ice .40 / lava .15 /
                          --     desert .08 / barren+moon 0). Storms read as
                          --     DARKER convective cells, per ISS photography.
  planetStormFlash  = 1.351,     -- intra-cloud lightning. OFF by default: it fires
                          --     unprompted the moment a clouded world loads, which
                          --     reads as a rendering glitch rather than weather.
                          --     Raise it (or drag the panel's " - Flashes"
                          --     slider) to audition. Cells fire independently
                          --     (hashed per cell per time window), so the planet
                          --     twinkles rather than strobing in unison.
                          --     NOTE: keep this, the SETTINGS `default` in
                          --     Renderer.lua, and the `or` fallback in
                          --     Planet:render in agreement -- Config.gpu is what
                          --     actually seeds the panel at launch, so changing
                          --     only one of the three leaves the world flashing.
  planetCloudWind   = 0.1007, -- cloud advection as a FRACTION OF THE PLANET'S SPIN,
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
  fovY          = 79.95,       -- camera vertical FOV (deg)
  filtering     = 'Bilinear', -- Bilinear | Trilinear | Aniso (texture filter quality)
  resolutionScale = '100%', -- render 3D below window size, upscale on present
                            -- (100%|85%|75%|67%|50%; big perf lever at 4K)

  -- Interactive anti-aliasing is TAA. Screenshot-key SSAA is capture-only and
  -- is not a Config.gpu setting; Application briefly requests 2x then restores
  -- the render scale. TAA is disabled only for that capture frame.
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
