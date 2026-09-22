# Planets — Master Doc (generation, rendering, moons, types, open work)

**This is the single master doc** for planet work. It merges the former
`ltheory-planet-research.md` (whose "not supported" claims are now stale — moons,
rotation, visible mountains/craters, valleys and cracks all exist) and the
running `planets-work` log. Branch: `planets-work`.

**Where we are:** rotation, tidally-locked orbiting moons, weighted surface
**types** (biomes), mountains / craters / valleys / cracks, per-type atmosphere
and tint, emissive lava, skybox night-ambient, planet↔map integration, names,
and an engine-driven sun/nebula lighting pass are all in.

**Focus now (in order):**
1. **Green speckle** — a volumetric-nebula grain artifact (NOT a planet bug).
2. **FPS** — find headroom and cut the expensive paths.

**Deferred:** clouds, gas giants (both expected to be FPS-expensive — defer
until the perf budget is understood). Rings / biomes / atmosphere-entry are
further out; see §11.

---

## 1. File map

| File | Role |
|------|------|
| `script/Game/Entities/Planet.lua` | The entity. Also used for **moons** via `opts.parent`. Surface cube + palette + render + spin/orbit update. |
| `res/shader/fragment/gen/planet.glsl` | Surface generation (height/color/clouds cube). `mountain`/`crater`/`valley`/`crack`. |
| `res/shader/fragment/gen/moon.glsl` | Barren-body generation (ridged + craters). Used when `gen='gen/moon'`. |
| `res/shader/fragment/material/planet.glsl` | Surface material: height→colour ramp, relief normal, atmosphere, waterline, emissive, skybox ambient. |
| `res/shader/fragment/material/atmosphere.glsl` | Forward atmosphere shell (self-lit scattering). |
| `res/shader/include/scattering2.glsl` | Rayleigh+Mie scattering; `atmoTint`; the (disabled) `CLOUDS_ENABLED` path. |
| `script/Game/Entities/System.lua` | `spawnPlanet` / `spawnMoon`; the console report. |
| `script/Game/GUI/GameView.lua` | Sun/dir + global lighting; the volumetric nebula + god-rays call sites; the composite. |
| `script/UI/GraphProvider.lua`, `script/UI/NodeGraph.lua` | F10 map integration (moons under their planet; true-radius rings). |

---

## 2. Generation (`gen/planet.glsl`)

A single 64-bit seed drives everything. The generator renders a **RGBA16F cube
map**: `R = height`, `G = color` (unused by the material), `B = clouds`
(unused), `A = 0`. Base args: `seed`, `freq` (~4–8), `power` (~1.5–2), `coef`
(4 random weights). It is sampled in **local** space (`vertPos =
vertex_position` in `vertex/wvp.glsl`), which is why rotating the body spins the
visible terrain.

Per-type sculpting uniforms, each added to `genHeight`:

```
ridge  = genRidge(p)    // 1-|2*cellNoise-1|, weighted octaves, f *= 2.07 — sharp crests
craters= genCraters(p)  // cell field -> bowl + raised rim (concave)
cracks = genCracks(p)   // narrow deep grooves along smooth-noise contours

h = base + mountain * ridge * (1 - base)      // lifts crests, never overshoots 1
h = h    - valley  * (1 - ridge) * base       // carves broad LOW ground
h = h    - crack   * cracks                    // narrow rifts
```

- `mountain` lifts **crests**; `valley` lowers **broad basins** (the two are
  complementary — see the note in §3 about `mountain` being at its ceiling);
  `crack` is the narrow-groove pass.
- `gen/moon.glsl` is a *different structure* (ridged + heavy craters), so barren
  bodies don't read as recoloured planets.
- **Trap:** only `gen/planet` declares `mountain`/`crater`/`valley`/`crack`;
  `Planet.lua` passes them *only* for that generator (setting a uniform a shader
  lacks aborts the engine — see §12).

## 3. Surface material (`material/planet.glsl`)

- **4-stop biome ramp** (all four palette colours are used):
  `colour = smoothstep mix` low→mid→high→peak, peaks lighter/less saturated.
- **Relief shading:** the normal is perturbed from the **height gradient** of a
  *smooth* (3-octave) height over a **wide** `eps` — deliberately low-frequency.
  A high-frequency gradient (6 octaves / tiny `eps`) aliased into **shimmer** at
  1×; only supersampling hid it. Keep it smooth.
- **Atmosphere:** `hasAtmo` (0 for airless) skips scattering entirely; `atmoTint`
  scales the Rayleigh term per type.
- **Waterline:** `waterline = 1 - oceanLevel` (oceanLevel ≈ the water fraction).
- **Emissive (lava):** `colour += emissive * emissiveAmt * mask` where mask is
  high on **low** terrain. Note the albedo is clamped ≤1, so it's a bright
  colour, **not** an HDR bloom.
- **Skybox night-ambient:** `colour = surface*light + surface*amb` where
  `amb = linear(textureLod(irMap, N, 5.0)) * envAmbient`. So a bright nebula
  softly lights the night side ("no true dark side in a bright medium"); an
  empty sky leaves it ~1%. `render.planet.envAmbient` (default 1.75) is the knob.
- `setMaterial(Material_NoShade)` — the surface is **self-lit** (it computes its
  own sun term from `starDir`), and the deferred passes treat it as such.

## 4. Types & biomes (`Config.render.planet.types`)

Weighted table; `Planet` picks one per seed (`pickType`). `forceType` in
`Config.Local.lua` pins it for auditioning. A type drives: **generator**,
**palette** (`hue`/`sat`/`light`), **ocean**, **atmosphere** (`atmo` scale,
`atmoTint`), **`weather`** (cloud chance — reserved for Phase C), and the
generator/material amplitudes (`mountain`/`crater`/`valley`/`crack`, `relief`,
`emissive`/`emissiveAmt`).

Types shipped: `terrestrial`, `ocean`, `desert`, `ice`, `barren` (`gen/moon`),
`lava`. Moons are a fixed `moon` type (barren, `gen/moon`, rock/ice/rust hues).
**Gas giants are deferred** (§11) — they need a banded generator + a
no-solid-surface path, not a palette entry.

## 5. Atmosphere

- The mesh is the inverted icosphere scaled by `atmoScale`; the **mesh scale now
  matches `rAtmo = scale * atmoScale`** (a hardcoded `1.5×` used to leave a wide
  empty halo for the background to show through).
- `scattering2.glsl`: Rayleigh (`kRayleigh`) + Mie. `atmoTint` scales Rayleigh
  per type (desert warm, lava ash, ice cool, terrestrial/ocean blue).
- The atmosphere material is a **forward, self-lit** pass — it writes straight to
  `fragColor`, not the G-buffer (so it is not double-lit by the deferred passes).
- `render.planet.atmoGlow` tunes the atmosphere strength.

## 6. Moons

- `Planet(seed, opts)` with `opts.parent` = a moon: **kinematic** body (the
  physics step never fights the scripted placement), **tidal-locked**
  (`Quat.FromLookUp(-offset, up)`), **equatorial orbit** (basis perpendicular to
  the parent's `spinAxis`, small `inclination` off it; radius preserved exactly).
- `System:spawnPlanet` spawns `Config.gen.nMoons(rng)` (**0–3**) per planet.
- `Config.render.planet.moon`: `orbitSpeed` `0.004–0.018 rad/s` (minutes per
  orbit), `scale` `0.03–0.14 × parent`, `minRadius = 800` (no pebble-moons),
  `orbit` `1.6–3.2 × parent` with an `orbitMax = 220000` cap (far-plane safety)
  and a floor `≥ 1.5 × parent radius` (never inside a huge planet).
- Moons are **barren**: no atmosphere, `oceanLevel 0`, dark low-saturation
  palette (rock/ice/rust hue family).
- **Map:** moons are parented to the planet (share the system physics world), so
  the sector level hides them and **drilling the planet reveals them**; the drill
  level keeps the planet as its centre node.

## 7. Rotation, names, report

- **Rotation:** `Planet:update` writes `setRot(FromAxisAngle(spinAxis, angle))`
  using a seed-derived tilted axis + `Config.render.planet.spinSpeed`. The
  physics step doesn't clobber it (zero angular velocity). `spin = false` →
  static.
- **Names:** planets get `genName(rng)`; moons `<planet> I/II/…` (deterministic
  per seed).
- **Console:** `spawnPlanet` prints
  `[system] planet <name>  type=<type>  moons=<n>  radius=<r>`.

## 8. Lighting (scene ↔ planet)

- **Sun (engine-driven):** `render.sun.enable` gates **both** the directional pass
  and the hemisphere `fill` (`sunColor`/`sunFill` → 0 when off). It **also**
  feeds the volumetric nebula's inscatter (`sunColor` in `volume.glsl`), so
  turning it off flattens the scene *and* dims the nebula glow.
- **`starDir`** (the star's direction) is always pushed; the planet surface
  self-lights from it, so the surface **terminator is independent of the sun
  toggle** — only its *brightness floor* moves (the fill).
- **Planet knobs:** `render.planet.{sunScale, envAmbient, atmoGlow}`.

## 9. Map (F10) integration

Planets are drillable context nodes (the planet stays at the centre; moons
populate the level). Large bodies draw a **true-radius ring** so "hugging the
surface" reads as close (node centres are a radius apart). Selection **follows**
the moving node. (See the node-UI doc for the map's own design.)

## 10. Tunables & tools

- **Config:** `Config.render.planet.*` (spin, `types`, `moon`, per-type params),
  `Config.gen.{nMoons, planetViewDist}`.
- **Debug panel:** `render.planet.{sunScale, envAmbient, atmoGlow}`;
  `nebula.{quality, density, jitter, background, coverage, radius, g, tint,
  debug}`; `render.sun.*`; `render.shadow.{maxLights, period}`;
  `render.resolutionScale`; `lighting.{ambientEnv, specular}`.
- **Seed pinning:** `Config.gen.seedGlobal = <n>ULL` (the `ULL` matters — a plain
  number is a double and rounds the low bits). Use the boot-log `Seed:` value.
  This is how to reproduce a specific world without hunting.
- **Verify:** `./configure.py test` (GLSL validator at 4.6 core + all suites;
  `tools/validate_nodegraph.lua`). Headless boot: `PHX_DEBUG_DUMP=<frame>` with
  `unset WAYLAND_DISPLAY; SDL_VIDEODRIVER=x11`.
- **Auditioning:** `Config.render.planet.forceType = 'desert'` (etc.).

## 11. Open work

### 11.1 Green speckle — PRIORITY 1

A fine **stipple/mottle** in the volumetric nebula, visible only where the scene
behind it is **smooth and bright** (a planet disc / limb) — against the busy sky
it's invisible. Composited as `scene * T + inscatter`, so it's grain in the
transmittance `T`.

**What it is NOT** (ruled out by experiment):
- **Not the ray-start jitter.** `nebula.jitter = 0` does not remove it; the
  jitter *masks* aliasing as grain, it doesn't cause it.
- **Not march step count.** High `48 → 96` (loop bounds raised to match) did
  **not** change it, and cost a lot of FPS — reverted. So it is **not**
  fixed-step sampling of the density.
- **Not feature size.** Coarsening the finest octaves (background `0.002 →
  0.0008`, anchors `0.0015 → 0.0008`), widening the density `smoothstep`
  thresholds, and switching `valueNoise → smoothNoise` (C1) did not remove it.

**Where that leaves us** — the grain is likely generated *upstream* of the
march, or is spatial rather than sampling:
1. **Half-res `volView` + upsample** (leading candidate). The volume is
   rendered at half res; the composite (`filter/volblur.glsl`) does a depth-aware
   3×3 gather but **falls back to a half-res tap at a depth boundary**, so the
   half-res grain shows magnified — worst against a planet disc. A **smooth+sharp
   surface** is exactly the case that reveals it.
2. **A fixed density feature** (not sampling): if true, no step/jitter change
   touches it.

**Next decisive test (1 click):** on one fixed frame with a planet filling the
view, toggle `render.superSample` **Off vs 2×**.
- Grain **~halves** with 2× → it scales with sample count → **temporal
  accumulation** (jitter + reprojected history blend) is the proper fix.
- Grain **unchanged** → it's a fixed pattern (the half-res upsample) → **filter
  the volume** in `volblur` (a small spatial blur on `T`/inscatter), not more
  samples.

**Repro seeds:** `14112139399293175324`, `5742763467356266433`,
`11396275097720600019`, `12368961037346951482`.

### 11.2 FPS — PRIORITY 2

Frame is ~7–12 ms at 4K (occasionally ~17 in the full-res Density debug view).
Known costs / levers:
- **Volumetric nebula** — scales with `nebula.quality` steps (Low/Med/High =
  10/20/48) and with `radius`; the debug Density view is full-res and expensive.
  The medium's anchor loop is bounded at 16 anchors; the volume is half-res.
- **Supersampling** (`render.superSample`) is the surface-AA lever and the
  biggest single cost (you saw <30 fps at 2×/4K) — `render.resolutionScale` is
  the counter-knob (render below window, upscale on present).
- **Shadows** — `render.shadow.{maxLights, period}` amortize point-light shadow
  updates; `render.sun.shadowSize` selects the sun-map resolution.
- **Sharpen** amplifies aliasing/shimmer (keep the surface gradient smooth, §3).
- Ideas worth profiling: cull/step-scale by view, drop the volume to quarter-res
  when the camera is inside a planet's atmosphere bubble, gate per-type work.

### 11.3 Deferred features

- **Clouds (Phase C).** The research doc called this "a one-line toggle" — it is
  not. Needs: a **seeded** `cloudCube` (`gen/clouds_cube.glsl` hardcodes
  `seed = 1337.0`, so all planets would share one pattern), a 3D `cloudNoise`
  source (the missing plumbing — a `Tex3D` built once), making
  `CLOUDS_ENABLED` runtime-switchable, wind animation, and per-type `weather`
  gating. **Expected FPS cost — the reason it's deferred.**
- **Gas giants.** Need a banded generator and a no-solid-surface render path
  (thick atmosphere dominant), not just a palette entry. **Expected FPS cost.**
- **Planetary rings.** No ring entity today. A particle/anulus system is
  plausible (the engine has `GPUParticles`); it's a new entity + a ring shader.
- **True biomes.** The height→4-colour ramp is the current "biome". Discrete
  biomes need a biome channel in the generation cube + a per-biome material
  lookup (and likely vertex displacement for real terrain relief).
- **Atmosphere entry / landing.** No atmosphere-entry physics, no landable
  surface today. A design: `exp(-altitude/scaleHeight)` density field → ship
  drag/lift coupling → landing-zone detection (see the old research recipes,
  folded here).

### 11.4 Scale / universe-gen

- **`spawnPlanet` uses `scale = 1e5 * erlang(2)`** and does not wire
  `Config.gen.scalePlanet` as the base. Planets are therefore huge relative to
  `kSystemScale = 10000` and can **engulf the system** (the residual Bullet
  `Overflow in AABB`, non-fatal). Latest work caps/⌈tunes⌉ radius — keep that in
  mind. Taming it fully means capping scale or placing planets outside
  `kSystemScale`.

### 11.5 Look decisions

- **Ship hull is `Material.Metal`** (specular-only → silhouettes). `Diffuse`/`Ice`
  is the lever if we want it lit like the asteroids.
- **Lava emission** currently tops out at the albedo clamp — let the emissive
  exceed 1 if we want bloom on molten surfaces.

## 12. Traps (engine-level — cost us time; know them)

- **An unused uniform is optimized out, and setting a missing uniform
  ABORTS the process** (`Shader_GetVariable`). Hence `mountain`/`crater`/
  `valley`/`crack` are passed only to `gen/planet`, and `coef`/`atmoTint`/
  `hasAtmo` are kept genuinely used. **Never** declare a uniform "for symmetry".
- **The medium noise hash is `fract(sin(x) * c)`** — it loses float precision
  past ~1e4 and degenerates into a stipple. `mediumDensity`'s drift used to be
  `volFlow * volTime` with **absolute** `volTime` (~1.79e6 s) → sample coords
  ~6e7 → the original stipple. Now bounded (`mod(volTime,300)` + a sway). Any
  future sampler that grows a coordinate without bound hits this.
- **`Renderer:free` nils lazily-created textures** (`volView`/`texAnchors`/
  `texLightning`/`godView`). Any pass binding one without recreating it in-pass
  can crash — that was the **F12** bug (god-rays bound `texAnchors`, created only
  by `volume()`, after a supersample change triggered a reset). All such binds
  are now guarded, but the pattern is live.
- **Moving a per-primitive program change into a batched run breaks the batch**
  (the flat immediate batch flushes on program change — see the node-ui doc).

## 13. Verification workflow

1. Edit.
2. `./configure.py test` → 137/0 shaders + suite + node checks.
3. Headless boot with a dump; grep for `FATAL` / `attempt to` / `Shader_Get`.
4. For behaviour, env-gated probes (always reverted before commit).
5. For look/perf, the debug panel + `Config.gen.seedGlobal` to pin the world.

## 14. Non-goals (this pass)

Rings, gas-giant rendering, true biomes, atmosphere entry/landing — see §11.3;
each is a separate, larger effort.
