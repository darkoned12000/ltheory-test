# Planets Work — rotation, moons, clouds (`planets-work`)

Forward-looking plan (not a completed-work archive). Grounded in the current
code, not the research note (which was written before the map/nebula work and
has some stale claims).

## Findings (verified against the tree, 2026-09-20)

- `script/Game/Entities/Planet.lua` — surface cube (`gen/planet`, 2048 RGBA16F,
  R=height/G=color/B=clouds), 4 palette colors, `oceanLevel`, `atmoScale = 1.1`,
  an IcoSphere(5) surface mesh + an inverted atmo mesh. Registers `Event.Render`.
- **The mesh transform IS the Bullet body.** `Entity:getPos/getRot/getToWorld
  Matrix` all read `self.body` (`script/Game/Components/RigidBody.lua`). So
  rotating a planet means rotating its body (`setRot`), and the physics step
  must not fight it (planets have zero velocity and no gravity → it won't).
- **The surface is sampled in LOCAL space**: `res/shader/vertex/wvp.glsl` sets
  `pos = wp.xyz` (world) but `vertPos = vertex_position` (model), and
  `material/planet.glsl` does `texture(surface, vertPos)`. So rotating the mesh
  rotates the sampled pattern — a spin is visible. Normals use `mWorldIT`, so
  lighting follows.
- `res/shader/include/scattering2.glsl` has the cloud path behind
  `#define CLOUDS_ENABLED 0`. **`cloudCube` and `cloudNoise` are declared but
  NEVER bound from Lua**, and `Planet.cloudLevel` is unused. So "enable clouds"
  is *not* a toggle: it needs a `cloudCube` (there is `gen/clouds_cube.glsl`) and
  a 3D `cloudNoise`, plus making the define runtime-switchable.
- `System:spawnPlanet()` is the entry point (`Config.gen.nPlanets`,
  `Config.gen.scalePlanet`, `Config.gen.planetViewDist`). A second path exists in
  `script/Gen/System/SystemBasic.lua`.
- There are **no Moon or Ring entities** and no planet rotation today.

## Phasing

**Phase A — rotation (this turn).** Config-gated, deterministic per planet.
**Phase B — moons.** A `Moon` entity orbiting a planet, tidally locked.
**Phase C — clouds.** Bind `cloudCube`/`cloudNoise`, make the cloud path runtime
switchable, animate wind. (Biggest of the three; needs a Tex3D source.)

---

## Phase A — Planet rotation **[DONE 2026-09-20]**

Result: `Config.render.planet.{spin,spinSpeed}`; `Planet` derives a tilted axis +
speed from the seed (drawn *after* the appearance params, so today's planets are
unchanged for a seed) and `Planet:update` writes `setRot(FromAxisAngle(axis,
angle))`. Measured headless: angle accrues monotonically, not clobbered by the
physics step. `spin = false` restores static planets. User-confirmed visible.

Design (as built):
- `Planet` derives a spin **axis** and **speed** from the seed, appended AFTER
  the existing RNG draws so today's planet *appearance* is unchanged for a seed.
- Axis is a tilted unit vector (`(-0.35..0.35, 1, -0.35..0.35)` normalized);
  speed `~0.01..0.05 rad/s` with a random sign (slow enough to read as a planet,
  not a top).
- `Planet:update(state)` accumulates `spinAngle` and writes
  `self:setRot(Quat.FromAxisAngle(axis, spinAngle))` (base rotation is identity
  at spawn, so this is a clean axial spin about a fixed world-up-ish axis).
- Gate: `Config.render.planet.spin` (bool). Off → no update cost, planet static
  (exactly today's behavior).

Config (`script/Config.App.lua`, `Config.render.planet.*`):
- `spin = true`
- `spinSpeed = function (rng) return rng:getUniformRange(0.01, 0.05) end`

Verification: no shader edits (validator unaffected); headless boot;
`Configure → test` green; measure the rotation over frames in a probe.

## Phase B — Moons **[DONE 2026-09-20]**

Result: `Planet(seed, opts)` now takes `{detail, cubeRes, mass, atmoScale,
parent, orbitRadius}`. A moon is a low-detail Planet whose `Planet:update`
orbits `opts.parent` (kinematic body, so the physics step never fights the
scripted placement) and tidally locks via `Quat.FromLookUp(-offset, up)`.
`System:spawnPlanet` spawns `Config.gen.nMoons(rng)` (**0–3**) per planet.
Tuning lives in `Config.render.planet.moon`: `orbitSpeed` (slowed to
`0.004–0.018 rad/s` — a full orbit takes **minutes**, was seconds),
`scale`/`orbit`/`inclination`/`roll` all as functions of `rng`, so:
- size `0.04–0.28 x parent radius` (bigger planets ⇒ bigger moons),
- orbit distance `3–9 x parent radius`, each with a random inclination + roll
  so sibling orbits don't line up (circular — radius preserved exactly),
- direction (sign) and phase are random per moon.

Moons are **barren**: no atmosphere mesh/atmosphere pass, `oceanLevel = 0`, and a
low-saturation palette whose hue family (rock `0.08` / ice `0.58` / rust `0.02`)
is picked per seed, so they don't look like tiny copies of their planet.

Measured headless: 2 moons at size `0.14/0.10`, orbit `6.0/8.8`, speed
`-0.0087/+0.0101 rad/s` (opposite directions), `dist/orbitRadius ≈ 1.000`, no
Lua errors (confirms `FromLookUp`).

Design (as built):

- `script/Game/Entities/Moon.lua`: a Planet-like entity at `scale = planet.r *
  0.06..0.22`, IcoSphere(3.5) surface, lower-res cube (512), thin/no atmo.
- Orbit: `System:spawnPlanet` optionally spawns `Config.gen.nMoons` (0..2) moons
  per planet; each stores `{parent, radius, phase, angularSpeed, tilt}` and, in
  `Moon:update`, sets `pos = parent.pos + orbitDir(phase) * radius`.
- **Tidal lock**: rotation always faces the planet (compute from the orbit dir).
- Physics: `setKinematic(true)` (script-driven position; still collides) so the
  physics step never fights the orbital placement.
- Verification: headless boot + a probe asserting orbit radius stays constant.

## Follow-up pass (2026-09-20, after play-test)

- **Moons looked like recoloured planets.** The material derives appearance from the height field (`material/planet.glsl` maps `map.x` -> palette), and moons ran the *same* `gen/planet.glsl`. Added `res/shader/fragment/gen/moon.glsl`: a ridged multifractal + cellular **craters** (deliberately a different structure from the planet's smooth sine-bandpass terrain), used when `barren`. Gotcha hit: an unused uniform is optimized out and *setting a missing uniform aborts the engine* — so `coef` is now genuinely used (steers crater strength).
- **Moon tuning** (all in `Config.render.planet.moon`): slowed orbits to `0.004–0.018 rad/s`; count `0–3`; size `0.04–0.28 x parent`; orbit `3–9 x parent` with per-moon inclination + roll (circular — radius preserved exactly); direction/phase random. Moons are barren (no atmosphere, `oceanLevel 0`, low-saturation rock/ice/rust palette).
- **Moons were invisible on the map (F10).** They *were* seeded, but as their own nodes ~240k–710k out (off-screen edge arrows). Reparented them to their planet (`planet:addChildren()` + share the system physics world + `planet:addChild(moon)`), so the sector level hides them and drilling the planet reveals them — same pattern as zone members.
- **Drilled level framed nothing.** The fit excluded `r >= 5000` (planet-scale), which also excluded moons (they are >= 5000 too), leaving an empty fit. Now the fit takes ALL nodes and relies on the existing robust p90 trim.
- **The drill parent now stays visible.** `GraphProvider.children(ctx, non-root)` includes `ctx` itself as a `context` node, so a drilled planet shows the planet at the centre with its moons orbiting it. The node gets an outer ring (reads as "here").
- **Selection followed the camera.** A clicked node that MOVES (orbiting moon, flying ship) drifted out of view; `NodeGraph:onUpdate` now re-centres the camera on the followed node each frame (exact assignment — an ease would fight `applyScroll`'s screen pin).
- **Names.** Planets get a `genName(rng)`; moons get `<planet> I/II/...`. Deterministic from the world seed (same seed -> same names), not test-only.
- **Moons still looked like planets (colour).** Two causes, one of which the generator change didn't touch: (a) the *surface* material applies `atmosphereDefault` to every body, and barren moons still had `atmoScale = 1.03`, so they got the same thin blue atmospheric tint as their planet; (b) the palette was too light. Fix: `material/planet.glsl` gains `uniform float hasAtmo` and skips the scattering entirely for airless bodies (`Planet:render` sets it; moons `atmoScale = 1.0`), and the moon palette is now dark (`L 0.05–0.22`) with a low but visible hue tint (`S 0.05–0.24`) so rock/ice/rust still read. Measured: planet `atmo=true` ~`(0.37,0.46,0.42)`; moons `atmo=false, ocean=0` ~`(0.05–0.22)`.

  Note: `hasAtmo` is a plain uniform set on every draw (not `#autovar`), so it can't hit the optimized-out-uniform abort; the atmosphere *material* is unaffected (it only runs for bodies that have an atmosphere mesh).

## Planet types & biomes **[DONE 2026-09-21]**

A planet's **type** is now the spine that everything else hangs off. `Config.render.planet.types` is a weighted table; `Planet` picks one from the seed (`pickType`), and the type drives:

- **generator** (`gen = 'gen/planet'` or `'gen/moon'`),
- **palette** — a 4-stop biome ramp (`typeColor(rng, t, f)`, `f` 0=low .. 1=peak; peaks are lighter/less saturated so they read as snow/ice caps),
- **ocean** waterline range,
- **atmosphere** scale (`0` = airless: no atmosphere mesh, `hasAtmo=false`),
- **`weather`** = cloud chance (stored now, wired in Phase C),
- relief knobs (`freqBase`/`powerBase`/`powerVar`) for the generator.

Types shipped: `terrestrial`, `ocean`, `desert`, `ice`, `barren` (uses `gen/moon`), `lava`. Moons are a fixed `moon` type (barren, `gen/moon`, rock/ice/rust hue families) and skip the planet table. Gas giants are deferred — they need a banded generator and a no-solid-surface path, not just a palette.

`material/planet.glsl` now uses **all four** palette colours (it previously used only `color1`/`color2`, so `color3`/`color4` were dead data): a `smoothstep` ramp low→mid→high→peak.

Verified: test seed rolls `ocean` (`c1≈(.08,.16,.20) → c4≈(.25,.29,.35)`) with two barren moons; 137/0 shaders, 84/84 node checks, clean boot.

`forceType` (Config.Local) pins every planet's type for auditioning (nil = weighted pick).

### Mountains **[DONE 2026-09-21]**

`gen/planet.glsl` gains `genRidge` (a ridged multifractal: `1-|2*cellNoise-1|`, weighted octaves, `f *= 2.07`) blended into `genHeight` by `uniform float mountain`:

```
base + mountain * ridge * (1 - base)     // mountain = 0 -> base exactly
```

That form lifts ridges toward the top of the range but can never exceed it, so raising the amplitude adds relief instead of clipping flat peaks (the previous blend could overshoot 1.0).

Per-type amplitude (Config `types[].mountain`): desert `0.90`, lava `1.00`, terrestrial `0.80`, ice `0.60`, ocean `0.45`; barren uses `gen/moon` (no `mountain`). Raised 2026-09-21 at the user's request ("a little higher for all planet types") after the first pass read well. The ridges show from orbit through the material's existing machinery — the height -> 4-stop colour ramp plus **horizon self-shadowing** (`visibility()`, which samples the height toward the star and darkens the lee side) — so no vertex displacement is needed. `mountain` is passed only for `gen/planet` (setting a uniform a shader lacks aborts the engine — see the optimized-out-uniform trap).

Console report on system spawn (user request): `[system] planet <name>  type=<type>  moons=<n>  radius=<r>`.

Verification note: the test seed rolls `ocean`, where mountains are deliberately subtle — use `Config.render.planet.forceType = 'desert'` (or `terrestrial`) to audition ranges. Verify 137/0 shaders, clean boot.

Next: **clouds** (seeded cloud cube + `cloudNoise` Tex3D + runtime switch, gated by each type's `weather`).

## Type-realism fixes (2026-09-21) — "lava planet looks like water"

Screenshot: a `lava` world rendered as a pale blue/white ball with faint pink terrain. Two causes, both because the surface ignored the type:

- **`oceanLevel` was a dead uniform.** `material/planet.glsl` declared it, and `Planet:render` set it, but the body used a hardcoded threshold `max(0, h2 - 0.8)`. So every planet grew oceans regardless of its type's `ocean` range — lava/desert included. Fixed: `waterline = 1 - clamp(oceanLevel,0,1)`, so `0` = no water, `1` = all water (and the uniform is now actually used, removing a latent optimized-out-uniform risk).
- **The atmosphere was fixed Earth-blue.** `scattering2.glsl` uses `const vec3 kRayleigh = 2*vec3(5.5,13.0,22.4)` for every planet, so any body with an atmosphere got a blue sky — a lava world looked icy. Fixed: new `uniform vec3 atmoTint` scales the Rayleigh term, set per type (`Planet.atmoTint`, set in both the surface and atmosphere render branches).

Per-type tints (Config `types[].atmoTint`): terrestrial `(1.0,1.0,1.0)`, ocean `(0.9,1.0,1.1)`, ice `(0.9,0.98,1.12)`, desert `(1.4,0.95,0.55)`, lava `(1.6,0.60,0.32)` (warm ash). Lava now reads as a dark volcanic world with a warm haze rather than an ocean.

Note: `atmoTint` must be set on EVERY draw (uniforms default to 0 → no atmosphere, and setting a missing uniform aborts). Both branches do.

Verify 137/0 shaders, 84/84 node checks, clean boot with `forceType='lava'`.

Open follow-up: lava has no *emission* — it reads as dark rock, not glowing molten. That needs an emissive term (like the `Material_Ice`/NoShade path) to sell molten surfaces.

**Water tuning (2026-09-21) — "terrestrial looks like an ocean planet".** With `waterline = 1 - oceanLevel`, a type's `ocean` value *is* effectively its water fraction, so the original `terrestrial = {0.15,0.70}` gave up to 70% water and read as an ocean world (the pre-types look was a hardcoded `0.8` ⇒ ~20% water, land-dominant). Retuned: `terrestrial {0.05,0.30}` (land-dominant, lakes/seas), `ocean {0.62,0.92}`, `ice {0.15,0.55}`, `desert`/`lava` ~0. The `ocean` type is the only one that should read as mostly water.

## Moon size + mountain strength (2026-09-21)

- **"One moon seemed really big."** `moon.scale` ran `0.04–0.28 x parent`, so a moon could be a third the planet's size. Tightened to `0.03–0.14 x parent`.
- **Mountains a bit more pronounced.** `types[].mountain` raised (desert `1.00`, terrestrial `0.95`, ice `0.70`, ocean `0.50`, lava `1.00`) and the palette `light` ranges widened slightly for relief contrast. `genRidge` sharpened: `n*n -> n*n*n` and 6 octaves. Note the blend `base + mountain*ridge*(1-base)` already saturates at `1`, so `mountain` is at its useful ceiling — further "pronouncement" would need deeper *valleys* (`base - k*ridge` for low ground) or a normal-perturbation term in the material, not a bigger amplitude.

## Nebula limb speckle (2026-09-21) — FIXED (verify over time)

Play-test: a dense stochastic speckle (nebula-coloured) along a planet's limb at close range; disappears when the volumetric nebula is disabled. It only shows against a **bright** background ("only this type of background") because the composite is `scene * T + inscatter`, so grain in transmittance `T` is only visible where the scene is bright (a planet limb).

Mechanism (two parts):
1. `filter/volume.glsl` jitters the half-res ray start with blue noise (intentional: turns concentric bands into fine grain), so `T` carries fine grain.
2. `filter/volblur.glsl` composites via a depth-aware 3x3 gather — but at a **depth boundary** the weights collapse (`wsum < 1e-4`) and it fell back to a **nearest** half-res `texelFetch`, showing the raw grain, magnified, exactly at the limb.

First pass (halve jitter + bilinear fallback) was **not enough** — reproduced again in a blown-out frame (`hdr avg 14.98`): a dense dither band exactly along the boundary of the bright region, confirming the `scene*T` mechanism. Second pass:
- jitter `+/-0.25 -> +/-0.1` step;
- **more steps**: `nebula.steps` High `24 -> 32` (loop bound `24 -> 48` in `volume.glsl`/`medium.glsl`/`volblur.glsl`). The fine medium noise (`valueNoise` at `0.002` = ~500-unit features) was under-sampled by ~583-unit steps, so the jitter was decorrelating aliasing into visible grain; finer steps resolve it instead.
- boundary fallback stayed the bilinear tap.

**Real root cause found (2026-09-21, via nebula-on/off A/B + zoom):** the speckle is a fine **stipple/mottle over the whole lit medium**, not a boundary ring — i.e. the noise *field* itself is bad. `mediumDensity` does `p += volFlow * volTime`, and `volTime = Time.GetRaw() * 0.001` is **absolute**, ~**1.79e6 s**. That translates the noise sample coordinate to ~**3-6e7**; `valueNoise(p * 0.002)` then evaluates the hash `fract(sin(x) * 4137.31315)` at x ~ **6e4**, far past float precision, so the hash degenerates into a stipple (also why it only shows where the medium is dense and lit against a bright background — it's always present, just not always visible).

Fixes:
- **Bounded drift** in `mediumDensity`: wrapped phase + sway (`mod(volTime,300)`), so the sample coordinate stays small instead of growing without bound. (`volFlow * volTime` is a genuine unbounded translation, so it could not be kept as-is.)
- **`nebula.jitter` live knob** (`Config.gpu.nebulaJitter`, default `0.05`, panel "Ray Jitter"): the ray-start dither amount in steps. **Set it to 0** — if the speckle vanishes, it was the jitter-derived grain and 0 (with slow banding instead) is the trade you prefer; if it persists, the density sampling itself is under-resolved (~437-unit steps vs ~500-unit fine noise) and the lever is more steps (High `32 -> 48`) or a lower-frequency `mediumDensity`.
- High steps rose `24 -> 32` earlier (loop bound 48).

## "Light shining through the planet" (2026-09-21) — FIXED

Repro (seed `14112139399293175324`, pinned via `Config.gen.seedGlobal`): a small bright dot on a planet's disc, present when `nebula.quality` != Off and `nebula.density > 0`, gone at density 0. **Not** lightning (disabling it changes nothing).

Diagnosis from the A/B frames: the dot sits at the **same screen position** whether `nebula.g = +0.4` (HDR `max 21.2`) or `-0.499` (`max 1.93`) — so it is `g`-independent. The only `g`-independent term in the in-scatter is `texture(irMap, rd).xyz`. `irMap` is the nebula's **irradiance**, and the nebula env cube is built around the star, so `irMap(rd)` is brightest **toward the star**. The march adds that ambient per step, so a planet with the star behind it gets a hot spot at the star's screen position, on the disc. (The `g` dependence of the HDR `max` is the separate HG forward lobe — real, but not this dot.)

`nebula.debug = Lighting` confirmed it: the in-scatter view is full of **small bright dots**, which are `texture(irMap, rd)` sampled at **LOD 0**. The IR cube is mipmapped (`TexCube_GenIRMap` -> `GenMipmap`), but LOD 0 still carries bright point features (stars); since `rd` is per-pixel constant, each bright feature maps to a **dot on screen**, which then lands on the planet.

Fix: sample the IR cube at a **blurred mip** for the volume's ambient (`textureLod(irMap, rd, 6.0)`) so the point features average into a smooth ambient, plus keep the per-sample `light` bound (`min(light, vec3(3.0))`). Verify with `nebula.debug = Lighting` on the pinned seed — the dots should be gone and only the smooth lit medium should remain.

## Crash: ship spawned inside a huge planet (2026-09-21) — FIXED

`LTheory.lua:147 attempt to call method 'update' (a nil value)`, seed `5524659694511835430`, planet radius **343812**. Reproduced headlessly.

Chain: `spawnPlanet` can roll a radius (from `1e5 * erlang(2)`) larger than `Config.gen.planetViewDist` (250000). The spawn-clear only pushed the ship to `planetViewDist`, so the ship spawned **inside** the planet -> Bullet `Overflow in AABB, object removed from simulation` -> ship destroyed/detached -> `Player:getRoot()` returned a detached entity (or nil) -> `root:update` nil -> crash.

Fixes:
- Clear the ship by at least the planet **surface**: `clear = max(planetViewDist, planet:getScale() * 1.35)` (plus a zero-distance guard).
- `LTheory:onUpdate` guards the root: `local root = self.player and self.player:getRoot(); if root and root.update then root:update(dt) end` — a bad spawn can no longer kill the process.
- `System:spawnMoon` orbit floor `>= planet radius * 1.5`, so moons never spawn inside a huge planet (the `orbitMax = 220000` cap was below a 343812 radius).

Still logs one Bullet `Overflow in AABB` for that extreme planet — a **scale** artifact (a 343812-radius planet engulfs the ~10000-scale system, so nearby objects overlap its AABB), not a crash. Taming it means capping planet scale or pushing planets outside `kSystemScale`; not done (user wants large planets).

## Crash: screenshot with nebula disabled (2026-09-21) — FIXED

SIGSEGV in `Renderer.lua:936` (`godrays`) -> `Shader.SetTex2D('texAnchors', self.texAnchors)` with a **nil** texture (`Tex2D_GetHandle(NULL)`).

Root cause: the **master** nebula toggle disables the volume call in `GameView`, so `Renderer:volume()` never runs — but `Renderer:godrays` still reads `nebula.quality` (still `High`) and derives `volCount = #med.anchors` (>0, `self.volumes` is built inside the nebula block but persists after disabling), so it bound `self.texAnchors`, which only `volume()` creates. **F12 was the trigger**: it sets `render.superSample = 2`, changing the supersample -> renderer reset -> `Renderer:free()` nils the lazily-created textures. Both conditions (nebula off *and* a reset) were needed, which is why the scene ran fine until F12.

Guarded all **three** `texAnchors` bind sites; the godrays path additionally forces `volCount = 0` when `self.texAnchors` is nil, so it degrades to background-field-only shafts instead of crashing.

**Toggle audit (all texture binds in `Renderer.lua`):** `buffer0/1/2`, `uiBuffer`, `zBuffer*`, `meterTex` are recreated every frame in `start`/`startUI`; `volView`/`texLightning`/`godView` are created in their own pass immediately before use; `med.envMap`/`irMap` are gated by the caller; `med.noise` is created on demand by `getAoNoise()` and bound guarded in godrays. **`texAnchors` was the only cross-feature nil** (created by `volume`, consumed by `godrays`) — now safe. Caveat: the F12 supersample-reset is not reproducible headlessly, so this is verified by crash log + audit.

## Impact craters (2026-09-21)

`gen/planet.glsl` gains `genCraters` (cell field -> bowl + raised rim, `uniform float crater`), added to `genHeight`. Like `mountain`, `crater` is only passed for `gen/planet` (missing-uniform abort). Because `gen/moon` already does craters, barren bodies keep theirs; planets get weather-worn, subtler ones.

First pass didn't read as craters: my profile made the centre only `-0.1` (a shallow dip, so it looked like blobs), and desert's strong ridge (`mountain=1.0`) drowned it. Corrected: `bowl = smoothstep(0,0.35,d)` / `rim = 1-smoothstep(0.35,0.5,d)` giving `rim*0.35 - (1-bowl)*0.9` — a **deep central basin + raised rim** (properly concave). Also: bigger cells (`f = freq*1.15`), stronger per-type amounts (desert `0.90`, ice `0.55`, terrestrial `0.45`, lava `0.30`, ocean `0.08`), eased the desert ridge (`1.0 -> 0.70`) so basins aren't masked, and widened palette `light` ranges for more tonal contrast.

## Atmosphere halo + map scale (2026-09-21)

Two play-test reports:

- **Background/stars visible "through" the planet.** Cause: the atmosphere mesh was drawn at a **hardcoded `1.5x`** the planet (`material/planet.glsl`, planet render) while the scattering density shell is `rAtmo = scale * atmoScale` (~`1.03–1.15x`). Between those radii the medium is essentially empty (alpha ≈ 0), so the starfield/background showed through a wide ring around every planet. Fixed: the mesh scale now uses `self.atmoScale`, so mesh and density shell coincide.
- **Map: a planet you're hugging looks "furthest away".** The map places a node at the body's CENTRE, so a ship 130k above the surface of a 120k-radius planet is 250k from the node — reading as far. Fixed by drawing a body's **true radius** as a faint ring (`n.r * zoom`, capped 600px) in `NodeGraph`, so "close to the surface" reads as close to the body's edge. (Existing `drawnRadius` stays clamped 6–40px for click targets.)
- If the stars were visible on the *solid* surface (not the halo) there may still be a deeper depth issue in the additive star pass — worth re-checking after this fix.

## Lighting / scale fixes (2026-09-20, after play-test #2)

Play-test surfaced: the ship reads as a pure-black silhouette against the nebula, and the moon "disappears and reappears" as you fly.

- **Ship is a metal.** `Ship.lua` uses `Material.Metal()`; in `light/dir.glsl` a metal gets **only** `cookTorrance` specular (no diffuse), and `light/global.glsl` gives it env-reflection (`irMap`) + a small `fill`. From the night side (chase cam behind a hull facing away from the star) that is a black silhouette — physically consistent, not a bug. Fix chosen: lift the metal fill (`fill * 0.6 -> 1.0`) and `sunAmbientFill 0.3 -> 0.42`, so a hull never sits at pure black. If we want the hull to read like the asteroids, the real lever is the material (Metal -> Diffuse/Ice), left as a decision.
- **Moon disappearance.** Moons orbited at `3-9 x planet radius`, and `spawnPlanet` uses `scale = 1e5 * erlang(2)` (it **ignores `Config.gen.scalePlanet`**), so radii are ~79k and orbits reached **240k-710k** — right against the **1e6 far plane**, while also occulting behind the (79k-radius) planet. Fix: orbit multiplier `1.6-3.2 x` plus an absolute `orbitMax = 220000` cap (applied in `spawnMoon`), so moons stay well inside the far plane. Measured: orbits now `172k/188k` (`2.2x/2.4x`).

  Root cause worth a separate look: `spawnPlanet` ignoring `scalePlanet` makes planets ~50x the intended `Config.gen.scalePlanet` (2000/5e3) — the whole system scale is inflated, which is why orbits were in the hundreds of thousands to begin with. Not changed here (it would resize every world).

## Phase C — Clouds (sketch, needs care)

1. Generate `cloudCube` from `gen/clouds_cube.glsl` (per planet seed) and bind it
   in `Planet:render` (and the atmosphere material if it consumes it).
2. Source `cloudNoise` (sampler3D): build a 3D noise volume (RenderTarget
   `PushTex3D` over a `gen/` shader) — this is the main new plumbing.
3. Make `CLOUDS_ENABLED` runtime-switchable: replace the `#if` with a
   `uniform int cloudsEnabled` early-out so the (already-written) 32-step cloud
   march only runs when asked. Avoids a second shader variant and keeps the
   validator's output set unchanged.
4. Animate: offset the noise sample by `time * windDir * windSpeed`.
5. Verification: `./configure.py test` (the validator compiles the changed
   include), headless boot with clouds on, and a frame dump.

## Open items / follow-ups (consolidated, 2026-09-21)

Everything below is **not done** — collected here so it's findable in one place.

**Features**
- **Clouds (Phase C)** — the last remaining pillar. Needs: a **seeded** cloud cube (`gen/clouds_cube.glsl` exists but hardcodes `seed = 1337.0`, so every planet would share one pattern), a 3D `cloudNoise` source (the missing plumbing — a `Tex3D` built once), making `CLOUDS_ENABLED` runtime-switchable in `scattering2.glsl`, wind animation, and gating per type via `weather`.
- **Gas giants** — deferred from the type pass: needs a banded generator and a no-solid-surface render path, not just a palette entry.
- **Lava emission** — currently reads as dark rock, not glowing molten. Needs an emissive term (the `Material_Ice`/NoShade path is the precedent).
- **Relief shading (normal perturbation)** — craters/mountains read from *albedo* (height -> colour ramp) + `visibility()` self-shadow; a height-gradient normal perturbation would make rims catch light and basins go dark. Also the "deeper valleys" variant (`base - k*ridge` for low ground). Biggest remaining "looks 3D" lever.

**Scale / universe-gen**
- **`spawnPlanet` ignores `Config.gen.scalePlanet`** — it hardcodes `scale = 1e5 * erlang(2)`, ~50x the configured value, so planets are huge vs `kSystemScale = 10000` and **engulf the system** (the residual Bullet `Overflow in AABB`). Taming it means capping planet scale or placing planets outside `kSystemScale`; not done because the user wants large planets. At minimum, wire `scalePlanet` in as the *base* so size is tunable.

**Nebula**
- **Green speckle: the `nebula.jitter` test is still pending.** Set it to 0 on a frame where the speckle shows. Vanishes -> jitter grain (accept 0 + slow banding). Persists -> the density sampling is under-resolved and the lever is more steps (High `32 -> 48`) or a lower-frequency `mediumDensity`.

**Moon polish**
- Orbits are **not equatorial** — `inclination`/`roll` are per-moon and independent of the planet's spin axis (intentional variety; easy to couple later).
- **No minimum absolute moon size** — `parent radius * 0.03..0.14` only, so a tiny planet gets pebble-moons. One-line clamp if wanted.

**Look decisions**
- **Ship hull is `Material.Metal`** — specular-only, so it silhouettes; switching to `Diffuse`/`Ice` is the lever if we want it lit like the asteroids.

**Fragility notes (engine-level, not planets)**
- **`Renderer:free` nils lazily-created textures** (`volView`/`texAnchors`/`texLightning`/`godView`). Any pass that binds one without recreating it in-pass can crash (that was the F12 bug). The toggle audit found `texAnchors` was the only cross-feature case, but the pattern is live.
- **The medium noise hash is `fract(sin(x)*c)`**, which loses precision past ~1e4 — the green-speckle root cause. The drift is bounded now, but any future sampler that grows a coordinate without bound hits the same stipple.
- **`volTime` is absolute** (`Time.GetRaw()*0.001`, ~1.79e6 s), not session-relative — a precision trap for anything else that uses it.

## Non-goals (this pass)

- Rings, gas-giant shaders, biomes, atmosphere-entry/landing physics (see
  `ltheory-planet-research.md` — separate, larger efforts).
