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
1. **Green speckle** — ✅ root cause found + fixed (misaligned anchor upload).
2. **Deterministic lighting** — ✅ done 2026-10-12 (seeded, prefiltered irMap).
3. **Reproducible world streams** — ✅ done 2026-10-12 (`Game.Seed`).
4. **Nebula medium actually using its own data** — ✅ done 2026-10-12 (W3).
5. **W4 look fixes** — ✅ done 2026-10-12 (marker clamped; the other two needed
   no code — see §11.0).
6. **W5 density + god-rays re-tune** — ✅ done 2026-10-12 (density 2.2→3.0,
   coverage 2.0→1.6, god-rays on at 8; measured, table in §11.0). W6 FPS next.
7. **W7 deferred planet features** — W7a clouds landed; W7b rings, W7c biomes,
   W7d gas giants, W7e atmosphere entry, ordered in §11.3. W6's *scaling* half
   (rock/NPC load) folded into the `procedural-space-environment.md` work.

**Deferred:** clouds, gas giants (both expected to be FPS-expensive — defer
until the perf budget is understood). Rings / biomes / atmosphere-entry are
further out; see §11.

**Status: planet work is parked, not finished.** W1–W3 are in; the rest of the
ordered dependency list is in **§11.0** — pick it up there.

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
| `script/Game/Seed.lua` | One source of truth for "which world is this?" — `setWorld` / `rng(name, salt)`. Every clock-seeded stream goes through it (W2). |
| `script/Game/Entities/Nebula.lua` | Skybox `envMap` + the irradiance cube (`genIRMap(samples, seed)`) + starfield; owns the visible star. |
| `libphx/src/TexCube_GenIRMap.cpp`, `libphx/include/TexCube.h` | The irradiance convolution: Hammersley sample set, per-level cone-matched `srcLod`, **seeded** (§11.0 W1). |
| `res/shader/fragment/compute/irmap.glsl` | The per-texel convolution loop (cap average over `sampleBuffer` at `srcLod`). |
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

### 10.1 CaptureHarness — reproducible look/perf captures

`script/phx/util/CaptureHarness.lua`. Env-gated, off unless asked for, and
**required for any pixel or frame-time A/B** (§11.8 item A1).

| variable | effect |
|---|---|
| `PHX_FIXED_DT=0.0166667` | Pin the frame delta. Changing a nebula setting changes frame time → changes the `dt` history → changes Bullet's settling → changes where everything is by the dump frame. This is W5's trap, and it is why two "equivalent" runs showed the sun visible in one and eclipsed in the other. |
| `PHX_FIXED_VIEW=hold` | Freeze the camera pose from frame 2 and hold it. Fly to a framing you like, then replay it exactly. |
| `PHX_FIXED_VIEW=log` | Same, and print the frozen pose in a form you can paste back as an explicit spec. |
| `PHX_FIXED_VIEW=x,y,z,lx,ly,lz[,ux,uy,uz]` | Freeze to an explicit pose (position, look direction, optional up). |
| `PHX_FIXED_SIZE=1280,720` | Force the window size **and drop `WindowMode.Resizable`**, so the compositor cannot resize it mid-capture. |
| `PHX_REPORT_SIZE=1` | Print the live render size periodically. |

Implementation notes worth keeping:
- The freeze goes in `GameView:draw` immediately **before `Camera:beginDraw`**,
  i.e. after every camera controller has run. `Camera:refreshMatrices` resolves
  `pos = posOffset + posT` / `rot = rotOffset * rotT`, so writing
  `posOffset`/`rotOffset` discards the chase camera's contribution for the frame.
- Pose is captured on **frame 2, not frame 1**: `cam.pos`/`cam.rot` are only
  resolved inside `beginDraw`, so on frame 1 they are still the constructor's
  `Identity` — which would silently freeze the camera at the origin.
- Orientation uses the engine's own `Quat:getForward()` / `getUp()` rather than
  matrix columns. `CoordTest` asserts the quaternion axes and the matrix lookup
  columns agree, and `Quat.FromLookUp(look, up)` is the exact inverse, so the
  round-trip is lossless and the sign convention never has to be guessed.

**Verified** (pinned seed, dump at frame 150):

| | render | sha256 |
|---|---|---|
| harness ON, same config, run 1 | 1280×720 | `3c3cdb06b9e8` |
| harness ON, same config, run 2 | 1280×720 | `3c3cdb06b9e8` |
| harness ON, density 3.0 → 1.5 | 1280×720 | `ecf1ad8be44e` |
| harness **OFF**, same config, run 1 | 1885×969 | `0953696b1229` |
| harness **OFF**, same config, run 2 | 1885×969 | `0156c9acfe46` |

i.e. **bit-identical frames** with the harness on, it still detects a real setting
change, and without it the same config produces **different** frames — which is
why every earlier A/B in this doc needed re-checking.

### 10.2 `tools/cmp_capture.py` — the gate

Compares two dumps and **refuses** the comparison unless the frames are actually
comparable, by reading the `[DUMP] frame=… render=WxH camera=(x,y,z)
harness=… dt=…` header each capture now prints. Rejects on mismatched render
size, dump frame, dt pinning, harness state or camera pose (to 1 unit), and warns
if a supposed A/B came out byte-identical — the signature of an override that
never applied (§11.3's `PHX_SETTINGS` lesson).

Exit: `0` compared, `1` invalid, `2` identical-frames.

```
python3 tools/cmp_capture.py shot_a.png shot_b.png [a.log] [b.log]
```

## 11. Open work

### 11.0 Wrap-up plan — the dependency order (START HERE)

Planet work is **parked**, not finished. This is the ordered list of what is left,
with the dependency that makes the order *the* order. The rule behind it: **you
cannot A/B anything until the lighting is reproducible** (W1), and **you cannot
tune a look against a frame that will change shape under you** (W3–W5 before W6).

| # | Item | Depends on | Effort | State |
|---|------|-----------|--------|-------|
| W1 | Deterministic + prefiltered `irMap` | — | done | ✅ 2026-10-12 |
| W2 | Remaining `RNG_FromTime` (particles, dust, NPC AI) | — | S | ✅ 2026-10-12 |
| W3 | Nebula medium: consume the rim colour + ellipsoid extents it already computes | W1 | M | ✅ 2026-10-12 |
| W4 | Small look fixes (star in haze, marker rim clamp, integer-hash medium) | W1 | S | ✅ 2026-10-12 |
| W5 | Re-tune density ⇒ god-rays gain together | W3, W4 | S | ✅ 2026-10-12 |
| W6 | FPS: profile on the *final* W5 settings | W5 | M | open |
| W7 | Deferred features (clouds, gas giants, rings, biomes, atmosphere entry) | W6 | L | §11.3 — split below |
| W8 | Planet scale vs `kSystemScale` (planets can engulf the system) | — | M | §11.4 |
| S1 | Speckle watch — verify on seeds beyond the repro | W1 | S | open |

Two **pending decisions** (not tasks — someone has to pick a side): §11.5's
`Material.Metal` ship hull and the albedo-clamped lava emission.

**W1 — deterministic, prefiltered irradiance cube. ✅ DONE 2026-10-12.**
The last known nondeterminism in the *renderer*. `TexCube_GenIRMap` took its
sample set from `RNG_FromTime()`, so the irradiance cube — every ambient term in
the scene — was different on every boot. Two runs of "the same" world were not
comparable, which silently invalidated several measurements during the speckle
hunt.
- **Now:** `TexCube_GenIRMap(self, samples, seed)` — a world-derived seed, a
  Hammersley (stratified + radical-inverse) sample set instead of iid taps, and a
  **cone-matched source LOD** per mip so the wide-cap levels are prefiltered
  instead of 256 sharp taps. Every level still convolves from the original
  source, so noise does not accumulate down the chain.
- **Verified:** two boots at the same `Config.gen.seedGlobal` produce
  **byte-identical** `irMap` faces (sha256 per face). Deviation from a
  16384-sample converged reference, mean |Δ| in 8-bit units:

  | level | 1 | 2 | 3 | 4 | 5 |
  |-------|---|---|---|---|---|
  | old (iid + LOD 0) | 0.147 | 0.616 | 0.838 | 0.921 | 1.602 |
  | **new** | **0.030** | **0.068** | **0.090** | **0.082** | **0.063** |

  i.e. ~10–25× quieter, and now **below the 8-bit quantisation of its own
  reference** at every level.
- **Side effects to expect:** the coarse mips are now genuinely blurred, so
  `render.planet.envAmbient` (1.75) and `nebula.ambient` (1.0) may want a small
  nudge — a darker, smoother night side and a slightly less grainy nebula wash.
  Re-check them before touching anything else (that is W5's job).
- **Follow-ups deliberately NOT taken:** the estimator is still a **uniform-weight
  spherical-cap average**, not a cosine-weighted irradiance integral (that would
  change the energy by ~π and invalidate every ambient tuning above), and the
  level-0 chain is still a plain mip chain. Both are documented, not bugs.

**W2 — the rest of `RNG_FromTime`. ✅ DONE 2026-10-12.** Only ever affected
**full-frame pixel equality**, not lighting: `GPUParticles.explode`, `Dust`,
`Thruster`, `Turret`, the legacy `Explosion`, the NPC actions and `LTheory.lua`
all seeded from the clock.
- **Now:** one new module, `script/Game/Seed.lua`, is the single source of
  truth. `LTheory:generate()` resolves the world seed *first* and calls
  `Seed.setWorld(seed)`, so everything created afterwards — and by entities
  later — derives from the printed boot-log `Seed:`. Streams are **named**
  (`Seed.rng('dust')`, `Seed.rng('turret.fire', self.id)`), never positional, so
  adding a generator can't reshuffle the existing ones. Per-entity streams are
  salted with the entity id / a spawn ordinal instead of sharing one
  process-wide sequence — the NPC actions previously all drew from a *single*
  shared clock-seeded stream, so one NPC's re-target jitter advanced another's.
  With no seed known (unpinned boot) `Seed.rng` still returns `RNG_FromTime()`,
  i.e. exactly the old behaviour.
- **Verified:** a temporary `PHX_DEBUG_W2=1` probe inside `Seed.rng` (logging
  name/salt/first-3-draws, reverted afterwards) run twice with
  `seedGlobal` pinned → **all 1614 stream creations identical** across the two
  boots, every stream distinct from every other. Note the AI paths only appear
  if NPCs are spawned — `LTheory.lua`'s `spawnAI` loop is hardcoded `for i = 1,
  0`, so `Config.gen.nNPCs` is dead config and AI actions are unreachable in
  normal play. Enabling it for the test is what produced an audible constant hum
  on the dev machine (two idling NPC engines inside `sfx.engine`'s 60-unit
  full-volume radius), so mute audio before any headless verification boot.
- **Still time-seeded, deliberately:** the world-seed draw itself
  (`RNG.FromTime():get64()` when `seedGlobal` is unset — that *is* the "new
  world each boot" feature), and the test apps under `script/App/`
  (`TestImGui`, `TestHmGui`, `GenTex2D`, …).
- **Not claimed:** physics is Bullet's own integrator, so two runs still differ
  in the last digits once real collisions happen. Reproducible *world
  generation and streams*, not a bit-exact simulation.

**W3 — the nebula medium ignores two things it already computes. ✅ DONE
2026-10-12.** `NebulaVolumes.build` emits a **rim colour** (`rr,rg,rb`) and
**non-uniform ellipsoid extents** (`extX/extY/extZ`), and the file header
advertises "dual-tone gradients and non-uniform ellipsoid stretching" — but
`medium.glsl` read neither (the falloff was spherical, on `extX` only). The
*upload* bug of §11.1 was exactly this class of error: CPU writes a field, GPU
never asks for it, nobody notices.
- **Now:** `texAnchors` is 4 texels wide instead of 3 — `col1.w = extY`,
  `col2.w = extZ`, `col3 = rim.rgb` — and the medium uses them. The envelope,
  the ray-AABB early-out (`cloudSection`) and the albedo all read the same
  per-axis extents, and the albedo is a **dual-tone gradient**: core colour
  through the body, the authored rim colour (`hsl(s, 0.65, 0.35)` — deliberately
  darker than the core's `hsl(s, 0.80, 0.60)`) on the outer shell.
- **The rim is keyed on RADIUS, not on the envelope.** First attempt mixed on
  `env` — which *is* the density — and the rim tone swallowed most of the
  plume's volume (volume goes as r³, so everything past 0.65R is 72% of it) and
  dimmed the whole field by roughly half. Keyed on `dist` instead, the second
  tone rides on density that is already falling, so the body keeps its
  brightness. Worth remembering: on a volumetric, "the edge" is most of the
  volume unless you key it on radius.
- **Expected brightness change (for W5):** an ellipsoid of the authored extents
  has ~**30% less volume** than the old sphere of `extX` (mean extY multiplier
  0.7, extZ 1.0, extX 1.0). Measured in W5: the net cost was only **~15%** of sky
  brightness (25.3 → 21.5 at identical settings) and structure *improved*
  (2.58 → 2.81), because the rim is keyed on radius and the body keeps its core
  colour. The analytic argument above over-counts — trust the measurement.
- **Verified:** `nebula.debug = Anchors` (the view that draws anchor geometry
  directly) shows stretched ellipsoids, and the beauty pass reads as structured
  banks instead of a uniform magenta veil over the whole frame.
- **Also fixed en route — the `Anchors` debug view was broken, pre-existing.**
  `cloudSection` folded the anchors together with min/max the *wrong* way round,
  computing an **intersection** of up to 16 slabs spread over a 12k lattice —
  empty almost everywhere. Callers got `sec.y < sec.x`, computed a **negative**
  step, and marched *backwards* out of the section: hard diagonal seams and
  screen-filling white slabs. It now returns the union bound (earliest entry →
  latest exit, clamped to `tCap`), the view bails on an empty interval, and it
  displays **mean density along the section** instead of raw optical depth
  (raw OD scales with span × steps and saturated to solid white). Side effect:
  that view went from 12.6 ms to 7.5 ms, since it no longer walks off the end.

**W4 — three small look fixes. ✅ DONE 2026-10-12 — two of the three needed no
code, and one of those turned out not to exist.** Recording that honestly, because
the next person would otherwise re-investigate all three.
- **The star in the distance-haze pass: already correct, no change needed.**
  The worry was that `filter/fogw.glsl` samples `envMap` along the view ray while
  the star is drawn in `skybox.glsl`, so the star would dim with the cube. It
  does not: `fogw.glsl` gates `fogF` to **0** for anything at or past 950k linear
  depth, and the skybox writes ~1e6 (`farPlane * vertPos`), so `mix(c, bg, 0) = c`
  and the star passes through untouched. Only *real geometry* hazes, which is the
  point of the gate. What can dim a star is the volumetric nebula in front of it
  — correct behaviour, and not this pass.
- **The parked integer-hash medium variant: it does not exist.** That item was
  wrong in this doc before this pass. There has never been an integer-hash variant
  of the medium in `res/shader` (`git log -S` over the tree finds nothing, and
  there is no such branch in `medium.glsl`). What actually protects the medium
  from `fract(sin(x)*c)` losing precision is (a) the **bounded drift** —
  `mod(volTime, 300)` plus a sway, so sample coordinates never grow without limit
  — and (b) the anchor-layout fix, which removed the `p * extZ ≈ 1e9` coordinates
  that were the real source. If the drift ever has to grow again, the models to
  copy are the CPU-side `NebulaVolumes.hash32` or the GLSL uint hash in
  `filter/exposure.glsl` — not a half-finished variant to re-tune.
- **The sun marker rim clamp: implemented.** An off-screen marker was simply
  clipped away, which made it useless exactly when you wanted it ("turn toward
  the light") — and the star is off screen for most headings. It now places the
  crosshair where the bearing to the star exits the view rect, inset 24 px:
  clamping each axis independently would pin it to a corner and lose the bearing
  as soon as *both* axes exceeded the rect, so the exit point is computed by
  scaling the centre→star vector by `min(halfW/|dx|, halfH/|dy|)`. Off-screen it
  draws smaller (r 8 vs 14) and dimmer (0.7×) with a tick on the outward side, so
  it reads as a bearing hint rather than an assertion that the star is there.
  `render.sun.marker` still defaults **off**.
  - Verified: the clamp math exactly (7 synthetic positions — every clamped point
    lands on the inset rect and is collinear with the bearing to ~1e-14; on-screen
    positions pass through untouched), plus live captures with the marker on:
    on the star when in view, and pinned at the left rim when forced off screen.

**W5 — density and god-rays, tuned together. ✅ DONE 2026-10-12.** `nebula.density`
feeds both the volume and `Renderer:godrays`, and the veil is **quadratic** in it
(`OD = 5e-5 · density² · background · radius`), so it had to move after W1 and W3.
- **Method:** one muted boot per candidate, fixed `seedGlobal`, fixed dump frame,
  lightning off (frame-timed → run-to-run noise) and the debug window off (it
  covers the left third of the frame, which is where the sky crop is). Metrics
  are display-referred on the dumped final frame: a **sky crop** (top-left, the
  only reliably sky region in this composition), reported as mean luminance,
  **structure** (p90/p50 — a flat veil pulls p90 down toward p50) and the
  **whole-frame blown fraction** (>250/255, the bloom proxy).
- **Result** (High quality, 960×600; density / background / coverage / rays):

  | d / bg / cov / rays | sky mean | sky struct | frame blown |
  |---|---|---|---|
  | 2.2 / 0.10 / 2.0 / pre-W3 baseline | 25.3 | 2.58 | 0.000% |
  | 2.2 / 0.10 / 2.0 / **off** (old preset) | 21.5 | 2.81 | 0.000% |
  | 2.2 / 0.10 / 2.0 / 8 | 40.7 | 3.20 | 0.001% |
  | 3.0 / 0.10 / 2.0 / 8 | 51.3 | 3.09 | 0.154% |
  | 3.0 / 0.10 / 2.0 / 14 | 63.7 | 2.98 | 0.473% |
  | 4.0 / 0.08 / 2.0 / 14 | 73.0 | 2.77 | 0.667% |
  | 3.0 / 0.06 / 2.0 / 14 | 57.3 | 2.88 | 0.271% |
  | 3.0 / 0.10 / 1.4 / 14 | 47.8 | 4.27 | 0.376% |
  | **3.0 / 0.10 / 1.6 / 8** (chosen) | **47.5** | **3.54** | **0.121%** |
  | 2.6 / 0.10 / 1.6 / 10 | 45.9 | 3.59 | 0.113% |

  Three things came out of it:
  1. **The rays are the dominant lever** — turning them on at unchanged density
     nearly doubled the sky (21.5 → 40.7). They had been **off** in the machine
     preset the whole time, so the "default strength 8" had never been seen at
     this density.
  2. **14 starts blooming** (~0.4–0.7% of the frame at/over threshold); 8 holds
     under 0.13% for the same density and coverage.
  3. **Lower coverage raises structure** (2.0 → 3.09, 1.6 → 3.54, 1.4 → 4.27) —
     smaller banks stop merging into a veil. Hence the retune is *density up,
     coverage down*, which is the opposite of "add everything".
- **Corrections this pass produced:**
  - **W3 cost ~15% of sky brightness, not the ~30% its own entry predicted**
    (25.3 → 21.5 at identical settings). The rim-keyed-on-radius decision is why:
    the volumetric argument over-counted, because the body keeps its core colour.
  - Structure *improved* across W3 (2.58 → 2.81), so W3 traded a little
    brightness for more contrast — not a straight loss.
- **Cost:** flat. 3.02–3.19 ms across every variant at this window size, so these
  settings are effectively free; the real perf question is W6 at 4K.
- **Applied to:** `script/Config.Local.lua` (the machine preset — density 3.0,
  background 0.10, coverage 1.6, god-rays **on** at 8), with the table in the
  comment above the block so the numbers travel with the values.
- **Deliberately NOT changed:** the **shipped** `Config.App` defaults
  (1.5 / 0.2 / 2.0 at `nebulaQuality = 'Low'`). The calibration above is measured
  at High, and Low marches differently, so shipping those numbers unvalidated
  would be a guess. There is now a comment at the config saying so.
- **The harness has a trap worth knowing (it invalidated two of my captures).**
  Changing any medium setting changes frame time → changes the `dt` history →
  changes Bullet's settling → **changes the camera attitude by the dump frame**.
  With the sun near the planet's limb, that swamps the effect being measured: two
  "equivalent" runs showed the sun fully visible in one and eclipsed in the other,
  and a Low-quality run came out 2× brighter purely because the ship had drifted.
  Comparisons are only valid *within* a family of identical frame cost (the table
  above is one family — all High, same framing, checked). A trustworthy harness
  needs a **fixed camera** (static/spectator, or dumping before physics runs);
  that is a small piece of work and belongs with W6's measurement pass.
- **Not verified:** taste. These are defensible numbers, not the final look —
  play-testing it against the panel is the point.

**W6 — FPS.** Keep it **after** W5: the frame cost depends on the final density
and god-ray settings, so profiling before them means profiling the wrong frame.
Existing levers and their costs are in §11.2.

**S1 — speckle watch.** The green-speckle fix (§11.1) was verified on the repro
seed only. If the grain reappears elsewhere it is a *different* cause — capture
the boot-log `Seed:` value and the repro frame and start from §11.1's forensics
method (it is a good one), not from the old conclusion.

**Two caveats for anyone play-testing this state:**
- The star is **occluded whenever the sun is behind a planet** — correct, but it
  means the crosshair can sit on a bright limb with no visible disc.
- `render.sun.marker` **defaults off**.

---

### 11.1 Green speckle — RESOLVED (see 11.0 W1 for the follow-on)

#### ✅ RESOLVED 2026-09-22 — root cause: misaligned anchor upload

`Renderer:volume` packed `texAnchors` with a **record layout that was stale by
three fields**: `extX/extY/extZ` were added to `NebulaVolumes.build`'s record
(upstream commit `b552ab4`) and the upload was never updated. So `medium.glsl`
actually read:

| shader wants | got |
|---|---|
| `d.x` = density | **extY** (~thousands) |
| `d.y` = noise scale | **extZ** (~thousands) |
| `d.z` = warp | density |
| albedo | `(scale, warp, core.r)` |

Two consequences: the noise was evaluated at `p * extZ` ≈ 1e9, where
`fract(sin(x)*c)` is pure garbage — the per-pixel chromatic stipple the author
had already written a warning about ("finer scales aliased into speckle") — and
the medium came out effectively opaque (density ~1e3), which is why the nebula
read as a flat green wash.

**How it was pinned:** pixel forensics showed the noise was *chromatic*
(σ≈2/255 in R/B, flat in G) and not luminance; `nebula.palette = 0` (which
bypasses the albedo) removed it, while step count / jitter / density coarsening
/ the composite denoise never could — because it was never in the density.

**Fix:** `Renderer.lua` now writes `col1 = (density, scale, warp)`,
`col2 = (core.rgb, -)`. Validator 137/0, clean boot; the nebula now renders as
structured plumes rather than a wash, and **the speckle is gone** on the repro.

**Follow-ups found while fixing — two half-wired features:**
- **Palette coupling is not wired.** `NebulaVolumes.build` accepts `sectorHue`
  to centre plume hues on the skybox, but GameView calls it without one, so
  plumes take `0.02 + hash*0.95` = the whole colour wheel → clashing red/green
  plumes against a differently-hued sky. ✅ **Fixed** in `95405ab` — the sector
  seed now drives `Palette.hue`, and both generators publish it
  (`script/Gen/Nebula/Palette.lua`).
- **Rim colour + ellipsoid extents are computed but never consumed** (`rr,rg,rb`
  unused; the falloff is spherical on `extX` only), despite the
  "dual-tone / non-uniform stretching" header. ✅ **Fixed** — see §11.0 W3.

**Superseded investigation** (kept for the record):

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

**Ruled out (2026-09-22):** the **half-res `volView` + upsample**. Upgrading the
composite gather to a **5×5 Gaussian-weighted, depth-aware, *bilinear*** gather
(was 3×3 nearest) did not remove it — a per-half-res-texel grain would have
averaged away. Pixel forensics confirms the feature size is ~3–7 screen px
(300 px crop @4×), *coarser* than one half-res texel.

**Gating verified with instrumentation (2026-09-22):** `nebula.enable = false`
(the "Nebula Volume" toggle) **or** `nebula.quality = Off` ⇒ `Renderer:volume` is
**never called** (`[NEB] GameView gate enable=false quality=1`, no
`Renderer:volume called`). `nebula.density` has exactly two consumers
(`Renderer:volume`, `Renderer:godrays`) — both raymarches, both gated. So a
`density = 0` that removes the speckle **proves the volume was running**: the
speckle *is* the volumetric **inscatter**, not the skybox/ambient.

**Deduction — it cannot be the march.** The grain survives both step count and
jitter, so it is not sampling of the density. In `filter/volume.glsl` the only
per-pixel quantities **independent of the march** are those forming the per-step
`light`:

```
light = (sunColor * hgPhase(dot(rd, starDir)) + textureLod(irMap, rd, 6.0))
        * albedo * tintFilter
```

Every step scales this same `light`, so a per-pixel wobble in it reads as a
speckle regardless of step count — immune to jitter/coarsening/steps, exactly as
observed.

**Prime suspect — the irradiance cube is a noisy, nondeterministic MC estimate.**
`libphx/src/TexCube_GenIRMap.cpp` + `fragment/compute/irmap.glsl`:
- `RNG_FromTime()` → the sample set (hence `irMap`) was **different every boot**;
  the lighting was not reproducible and the pattern "moved" between runs.
  ✅ fixed (§11.0 W1 — seeded, and verified byte-identical across boots).
- `float w = 1.0;` → GGX-distributed samples averaged with **uniform weight**
  (no PDF weighting) → a cone-average, not a proper convolution. ⏳ **deliberately
  left as-is** (see W1: changing it rescales all ambient by ~π).
- every sample was `textureLod(src, L, 0.0)` → **always LOD 0**, so the coarse
  mips (cone ≈ whole hemisphere) were 256 LOD-0 samples of a point-lit env → high
  variance. ✅ fixed (cone-matched `srcLod`).

**Pixel measurement of a live repro (2026-09-22, `screenshot/2026-09-22 02.png`):**
- the bright green wash is **smooth in luminance**: high-pass σ ≈ 0.3–0.6 %
  (≈1 LSB) — there is no brightness grain;
- the residual is **chromatic**: σ ≈ 2/255 in R and B with G flat (a hue/sat
  wobble), and it scales with wash brightness; dark regions don't show it.

⇒ Not density/transmittance grain but the **colour of the medium's illumination**.
Two *coloured*, march-independent inputs to `light` match: `albedo = mc.yzw`
(the per-sample palette) and `ambient = textureLod(irMap, rd, 6.0)`. Both are
immune to steps/jitter/coarsening/composite-denoise — exactly the observed
behaviour. Knobs added for the A/B: **`nebula.ambient`** (irMap scale) and
**`nebula.palette`** (albedo mix, 1 = palette, 0 = flat tint).

**Decisive A/B (1 click, knob added 2026-09-22):** `nebula.ambient` (panel
" - Ambient", `volume.glsl` `volAmbient`) scales **only** the `irMap` term in the
inscatter.
- Speckle **gone at 0** → confirmed MC-irradiance noise → fix 11.1a.
- Speckle **remains** → it is the sun/phase term → suspect `worldDir`/`hgPhase`.

**Outcome:** the irMap term was *a* contributor (it is now seeded, prefiltered
and ~10–25× quieter — §11.0 W1), but the visible speckle was the anchor-layout
bug at the top of this section. Both knobs (`nebula.ambient`, `nebula.palette`)
are still in the panel and are still the fastest way to bisect the inscatter.

**11.1a — refactor. ✅ Part 1 done 2026-10-12 (→ §11.0 W1); the rest is open.**
The nebula has **three** representations with no shared source of truth: the
`envMap` cube + `irMap` (skybox + all ambient), `NebulaVolumes.lua` CPU anchors
(rebuilt per cell, pop at boundaries), and `medium.glsl`'s own sin-hash field on
the GPU. Tuning one does not move the others and the "off" switches are
ambiguous.
- (1) ✅ deterministic low-discrepancy (Hammersley) MC + LOD-matched sampling for
  `irMap`, seeded from the sector (`TexCube_GenIRMap(self, samples, seed)`).
  Proper **PDF weighting** was deliberately left out — see W1's side-effects note.
- (2) ⏳ one integer hash shared CPU/GPU, replacing `fract(sin(x)*c)` — the
  variant exists but is parked with stale thresholds (→ W4).
- (3) ⏳ derive skybox + anchors + medium from one seed field.
- (4) ⏳ band-limit the medium to the march step.

**Superseded investigation** (kept for the record — all of these hypotheses were
measured and **disproved**, so don't re-run them):

**The "next decisive test" below was never needed** — the anchor-layout bug was
found first (see the top of §11.1) and it explained every observation. Kept only
because the two-pass volblur + 5×5 gather changes it proposes are still the right
ideas *if* a grain ever reappears. **Superseded**, not disproved.

**Where that leaves us** — the grain was generated *upstream* of the march:
1. ~~Half-res `volView` + upsample.~~ Not the cause — the composite gather was
   upgraded to 5×5 Gaussian/depth-aware/bilinear and the grain stayed, which a
   per-half-res-texel grain could not survive.
2. ~~A fixed density feature.~~ Not the cause — coarsening octaves, widening
   `smoothstep`s and `valueNoise → smoothNoise` all failed to move it.
3. ✅ **The actual cause:** `medium.glsl` reading a misaligned anchor record, so
   the noise was evaluated at `p * extZ ≈ 1e9` where `fract(sin(x)*c)` is garbage.

**Next decisive test (1 click)** — *only if grain returns, per §11.0 S1:* on one
fixed frame with a planet filling the view, toggle `render.superSample` **Off vs
2×**.
- Grain **~halves** with 2× → it scales with sample count → **temporal
  accumulation** (jitter + reprojected history blend) is the proper fix.
- Grain **unchanged** → it's a fixed pattern (the half-res upsample) → **filter
  the volume** in `volblur` (a small spatial blur on `T`/inscatter), not more
  samples.

**Repro seeds:** `14112139399293175324`, `5742763467356266433`,
`11396275097720600019`, `12368961037346951482`. Only the first was re-verified
after the fix; the rest are untested (→ §11.0 S1).

### 11.2 FPS — see §11.0 W6 (do it *after* the density/god-ray re-tune)

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

### 11.3 Deferred features (§11.0 W7, split into ordered pieces)

**Gate: W6 has a measured budget** (3.7 ms/frame at 1024x768, ~13 ms of headroom to
60fps; the volumetric pass is 30% of the frame, everything else is noise), so the
gate is satisfied — with the standing caveat that the budget was measured on an
*empty* system, so re-measure before shipping the load W6 never got to.

W7 is five unrelated features, so it is ordered rather than listed:

| # | Piece | Depends on | Effort | State |
|---|-------|-----------|--------|-------|
| W7a | Planet clouds | — | S | ✅ **CLOSED 2026-10-15** — plumbing, ship, shell + parallax, clouds toggle, resolved-coverage/spin/pos logging, **cloud shadows**, **spin-relative wind**, coverage retune. Look signed off by the player. Left: rain/storms (see §11.12 — judged invisible from orbit). |
| W7b | Planetary rings | — | M | open |
| W7c | True biomes | W7a | M | open |
| W7d | Gas giants | W7c | L | open |
| W7e | Atmosphere entry / landing | — | L | open |

**Two corrections to the old descriptions, both found by reading the tree:**

- **Clouds were never the expensive job this section claimed.** It described
  Phase C as needing a seeded `cloudCube`, a new `Tex3D` noise source, a
  runtime-switchable `CLOUDS_ENABLED`, and an "expected FPS cost". But
  `gen/planet.glsl` has baked a **seeded, per-planet cloud field into the surface
  cube's BLUE channel since the generator was first written** (`genClouds`), and
  the material simply never read it. Consuming it is one extra cube fetch and a
  composite — no new texture, no new cube, no regeneration, and it measures at
  **~0.05–0.1 ms** (W7a below). The old plan was describing `gen/clouds_cube.glsl`
  (still in the tree, still hardcoding `seed = 1337.0`), a path the generator
  route makes unnecessary.
- **`genColor` is dead weight.** A 12-iteration fractal evaluated per texel into
  the GREEN channel, read by nothing — the material builds its palette from height
  alone. Same class of bug as W3's dropped fields. W7c consumes it; until then
  every planet cube pays for it.

**W7a — planet clouds. ✅ plumbing + shipped 2026-10-12; the LOOK is not tuned.**
- The material now reads the cube's blue channel and composites a cloud deck,
  gated by `type.weather` (which has been in `Config.render.planet.types` since
  the type table was written, carrying 0.60 terrestrial / 0.08 desert / 0.00
  barren …) times the new `render.planet.clouds` knob times a per-planet
  `cloudLevel` bias -- **all three, not the slider alone.** Because `cloudLevel`
  is a bias that can go negative, Coverage = 0 does **not** switch clouds off:
  `0 * weather + cloudLevel` stays positive for ~34% of desert worlds and ~14%
  of lava worlds. There is now an explicit `render.planet.cloudsEnabled` master
  toggle for that, and it is the only reliable off switch. Getting this wrong
  quietly broke an isolation test of the shell below (Coverage 0 left clouds
  rendering, so the A/B compared nothing) — so two terrestrial worlds don't get identical weather, and
  airless bodies cost nothing. Moons return early in `update`, so the advection
  clock is advanced before that branch.
- **Wind costs nothing:** the field is a fractal of the *local* direction, so the
  deck drifts by sliding the lookup point along the local tangents — no animation
  texture, no regeneration. It has to be built from `vertPos` and a local basis,
  not the world tangents `T`/`B` the relief code uses, or the drift would smear
  with the planet's spin.
- **Shipped look is provisional and deliberately conservative** (coverage window
  high in the field's range, 1.25× albedo). First attempt at 1.6× with a window
  centred on 0.5 blanketed the planet into a bleached shell — `genClouds` returns
  `0.5 + 0.5*sin(...)`, so anything centred near 0.5 covers most of the sphere.
- **Not done / needs a real test bed:** ~~the seed available at boot puts a huge
  planet directly in front of the sun, where the atmosphere shell plus
  auto-exposure already wash the surface to a pale ball *without* clouds. Judge
  the deck on a planet seen with the sun behind the *camera*, or from further
  out.~~ **Partly resolved 2026-10-15:** auto-exposure no longer exists (§11.6),
  so that wash attribution is stale and the deck has since been seen on several
  seeds at `resolutionScale 50%` and read as good — **the look is signed off**.
  The framing caveat stands for anyone re-judging it: prefer a planet with the
  sun behind the *camera*, or seen from further out.
- **Three extras**: clouds casting shadow on the surface, rain/storms, and --
  until 2026-10-15 -- the shell. **The shell now exists** (below), which was the
  prerequisite for the other two: shadowing and rain both need a layer with
  vertical separation to exist at all.

**The cloud shell (2026-10-15).** v1 sampled the cloud field at the **surface**
direction, so the deck was welded to the terrain: move the camera and the clouds
moved with the ground underneath them, which reads as painted-on rather than as
weather. The deck now sits on a shell at `rPlanet * (1 + cloudHeight)`:

- `material/planet.glsl` intersects the view ray with that sphere and samples the
  cube at the **shell hit's** local direction. The cube is authored in local space
  so terrain spins with the body, which means a world-space hit has to be brought
  back into that frame -- so `Planet.lua` passes the body's local axes in world
  space (`planetAxisX/Y/Z`, from `Quat:getAxisX/Y/Z`) and the shader inverts them.
  Deliberately **not** the `mWorldIT` autovar: no fragment shader has ever
  declared it, and an autovar that is never uploaded is silently IDENTITY -- which
  would present as "parallax doesn't work" rather than as an error.
- **Grazing-angle fade.** Near the limb the shell offset grows without bound and
  smears the whole deck into radial streaks, so the parallax blends back to the
  ground direction via `smoothstep(0.02, 0.30, |dot(view, normal)|)`. The same
  reason relief mapping needs a step budget at silhouettes.
- `cloudHeight = 0` degenerates to v1's lookup **exactly**, so the knob is a clean
  A/B against the old behaviour and existing worlds are unchanged if it is left at
  0. Default **0.02** (2% of radius, ~2000 units at R=101527). A real cloud deck is
  ~0.16% of radius up; the default is an order of magnitude above that because a
  physically-scaled shell is too thin to read at any sane camera distance. Knob:
  `render.planet.cloudHeight`, 0-0.12.
- **Verified numerically**, not by eye -- `tools/verify_cloud_shell.py`, same
  precedent as W4's clamp check. It is checked against properties that hold for
  *any* correct ray-sphere solve rather than a hand-derived closed form (an
  earlier version of that file used a closed form, the formula was wrong, and it
  looked like a shader bug):
  - the returned point lies on the shell (worst residual 2.2e-10 units over 4000
    random poses). This is what catches a sign error in the ray setup, and it
    caught one: `origin - eye` instead of `eye - origin` put the sample on the far
    side of the body;
  - `t` is the nearest positive root, and the sample never lands on the far side;
  - `height = 0` reproduces v1 exactly; a head-on view has zero parallax;
  - parallax rises monotonically with view angle (0.04 deg at 5 deg elevation to
    0.87 deg at 60 deg);
  - a genuinely grazing view fades to zero offset;
  - thin-shell limit: `offset/height -> tan(incidence)` (0.3144 vs 0.3151).
- **Verified visually** under the harness: `h=0 -> 0.02` moves 0.84% of pixels,
  `0.02 -> 0.06` moves 1.07%, and with clouds on the changed pixels are confined
  to **x 480-959** -- the disc and its edge, with **zero** change in the sky.
- Open: single layer only. There is no thickness, so no self-shadowing inside the
  deck and no soft edges through depth. A multi-sample march along the shell is
  the natural v2, and is what cloud shadows and rain will build on.

**Cloud shadows (2026-10-15).** The deck drawn on the surface also blocks the sun,
so the sun term is dimmed by whatever the deck covers *along the direction to the
star*. Same shell, same baked field, same wind drift -- a second ray-sphere solve
along the sun instead of along the view ray. One extra cube fetch on a texture
that is already bound; no new pass, no render target.

- `starDir` is world space and `vertPos` is local, so the sun direction is
  converted with the same `worldToLocalDir` the shell uses. Getting this wrong
  would make the shadow cast by a sun fixed to the planet's own frame, and it
  would never sweep as the body rotates.
- The solve is the simple closed form, because in local space the planet centre
  *is* the origin: `t = -b + sqrt(b^2 - R^2 + rShell^2)`, `b = vertPos . sunDir`.
- Fades out over `smoothstep(0.06, 0.32, NL)`: as the sun nears the horizon the
  ray grazes the shell and the hit point runs to infinity, sampling arbitrarily.
- **Cost: free.** Measured at 1280x720: shadow off 1.00 ms / 1000 fps, on
  0.79 ms / 1259 fps -- i.e. within noise (it came out *faster*, which is noise).
- **Verified numerically** by 5 more checks in `tools/verify_cloud_shell.py`: the
  hit point lies on the shell (worst residual 2.9e-11 units over 4000 random sun
  directions), sun-overhead hits at exactly `R*(1+h)`, the point is never behind
  the surface, the fade reaches 0 at the horizon, and `cloudShadow = 0` is an
  exact no-op.
- **It was invisible at the old default settings, and that was a coverage problem,
  not a shadow problem.** shadow 0 and shadow 1 produced *byte-identical* frames at
  `clouds = 0.44`. Cause: `cov = smoothstep(0.70 - 0.20*clouds, 0.95 -
  0.20*clouds, cd)` over a field that averages 0.5, so the window `[0.612, 0.862]`
  put only **14%** of the field above the *upper* edge (fully covered); there was
  almost nothing to cast from. Fixed below by raising coverage.

**Cloud coverage raised (2026-10-15).** `render.planet.clouds` 1.0 -> **1.25**,
range `0..1.5` -> `0..3.0`. The deck and its shadows are now visible, but the
value was chosen from a rendered ladder rather than arithmetic -- see the
overshoot note below, because the first attempt at 2.0 was wrong.

| type | weather | resolved @1.0 | resolved @2.0 | any / full coverage |
|---|---|---|---|---|
| ocean | 0.70 | 0.70 | 1.40 | 58% / 33% |
| terrestrial | 0.60 | 0.60 | 1.18 | 54% / 29% |
| ice | 0.40 | 0.44 | 0.84 | 46% / 21% |
| lava | 0.15 | 0.15 | 0.30 | 36% / 11% |
| desert | 0.08 | 0.08 | 0.16 | 33% / 8% |
| barren / moon | 0.00 | 0.00 | 0.00 | 0% (gated on `hasAtmo`) |

- **The knob is not a 0..1 fraction and cannot be treated as one.** It is a
  multiplier that *positions the coverage window*, so it stays meaningful above
  1; `Config.App` now says so, because the old `(0..1.5)` range comment was the
  thing that hid this.
- **The clamp in `cloudCoverage()` moved 1.0 -> 1.5, and it had to.** Raising only
  the knob saturates: at knob 2 both ocean and terrestrial resolved to exactly
  1.00, flattening them into each other AND discarding the per-planet
  `cloudLevel` bias, because the bias is added *before* the clamp and then thrown
  away. At 1.5 the ordering and the seed variation both survive -- two live
  terrestrials resolve to 1.18 and 1.05.
- **`mix(color, cloudLit, cov * clouds)` is now `clamp(..., 0, 1)`.** With
  `clouds` above 1 the factor reaches 1.5, and `mix` with `t > 1` *extrapolates*
  past `cloudLit` -- the deck would render brighter than the cloud colour itself.
  Safe by accident before (resolved was clamped to 1); a latent trap now that it
  is not.
- **Side effect of that clamp, worth knowing before judging edge softness:** the
  factor reaches 1.0 at `cov = 1/clouds`, not at `cov = 1.0`. At a terrestrial
  default (resolved 1.20) the coverage ramp therefore saturates at
  **cov = 0.833** -- the top 17% of the ramp is flat. That is *correct* (opaque
  cloud must render opaque) and it leaves a real soft edge (verified as checks
  N/O/O2/P), but if the deck ever reads as having hard-edged clouds, this
  compression is the reason, not the noise field.
- Barren worlds and moons stay at 0.00 regardless of bias, so raising the knob
  cannot resurrect the moon bug found above.

**The coverage ladder (and why 2.0 was wrong).** Derived coverage fractions are
not a substitute for looking at the planet. Same seed, same explicit pose, each
rung re-run with `PHX_SETTINGS=1` so the applied value is self-certifying
(`render.planet.clouds` confirmed as 1 / 1.25 / 1.5 / 2):

| knob | resolved (terrestrial) | mean delta vs 1.25 | look |
|---|---|---|---|
| 1.00 (old default) | 0.58 | 2.755 | continents and ocean read clearly, light cloud on top |
| **1.25 (shipped)** | **0.73** | -- | **deck clearly present, surface still legible** |
| 1.50 | 0.88 | 2.707 | heavy; continents only break through in patches |
| 2.00 | 1.18 | 5.602 | near-total whiteout; surface detail lost |

1.0 and 1.5 landing almost equidistant from 1.25 (2.755 / 2.707, with 1.25 their
midpoint) is a useful sanity check that the knob is behaving linearly where it
should be.

The trap: at 2.0 the measured "fraction of frame decked" only moves 10.7% ->
15.2%, so a numeric check would have called it a modest success. The planet goes
white anyway, because what actually changes is the **opacity of the deck where it
exists**, not how much of the disc it covers. **Judge this knob by eye; the
coverage arithmetic will not tell you when you have gone too far.**

At 1.25 a terrestrial resolves to 0.73, below 1.0, so the new mix clamp does not
bite at the default -- it is a guard for the top of the range, not a shaping
parameter.

**Determinism is good; my first ladder was not.** Two runs of an identical
config are **byte-identical** across separate boots (`det1` vs `det2`, and
default-config runs all identical), so the harness itself is sound and
`PHX_SETTINGS=1` does not perturb rendering. But the original ladder batch was
run *without* `PHX_SETTINGS`, and its 1.25 rung does **not** reproduce against the
certified capture (mean 0.160/255, 0.33% of samples, max 190) while every
certified pair matches exactly. Rule 6's `PHX_SETTINGS=1` is not ceremony: an
unverified override is exactly how a ladder ends up measuring values you cannot
name. The ladder above was re-run with it.

**Deck/shadow desync on non-zero wind -- FIXED (found in play, 2026-10-15).**
Moving the Wind slider showed a second, counter-rotating circle inside the disc:
the clouds visibly swung away from their own shadows. Cause: the two sampling
paths applied `cloudDrift` to vectors of completely different magnitude.

- Deck: `normalize(cloudL + cloudDrift)` where `cloudL` is a UNIT direction, so
  the drift has full effect.
- Shadow: `normalize(vertPos + Ll*t + cloudDrift)` where `vertPos + Ll*t` is the
  shell hit point with magnitude ~`rPlanet` (~1e5), so the drift is swamped.

Measured on the reported configuration (rPlanet 95976, shell altitude 0.0533, 10
minutes of drift at the default wind): the shadow sample moved **4.1e-6 rad**
where the deck moved 0.415 rad -- a factor of **95,818**. Fixed by normalising
the shell point to a unit direction *before* adding the drift, so both paths are
now structurally identical:

```glsl
vec3 sp = normalize(normalize(vertPos + Ll * t) + cloudDrift);   // was: normalize(vertPos + Ll*t + cloudDrift)
```

- **This is exactly the class of bug a "does the feature work" check cannot
  catch, and a numeric shadow check could not have caught it either** -- the
  shadow *was* enabled and *was* darkening the sun; it was just sampling the
  wrong place. It was invisible at wind 0 because neither term moved. Only
  dragging the slider exposed it. Pinned as checks Q1-Q3.
- The stale comment that hid this ("the drift offset is ~2e-4 of the lookup, so
  anchoring them to the same basis is what matters") was itself the bug's
  cover: it assumed a tiny drift, which was true when the rate was a fixed
  2e-4 and false once the drift is spin-relative and grows with elapsed time.
  Corrected in place.
- Verified at the reported settings (shell altitude 0.0533, shadow 0.492, wind
  0 vs 0.0343): the wind-on frame no longer shows a second circle.

**Wind decays over a long session -- KNOWN LIMIT (not fixed).** Because the
drift axis is built from the surface normal and not from the sample direction,
it is not perpendicular to it, so the advection has to use
`normalize(dir + D*tangent)`. That rotates by `atan(D)`, not `D`, so the
effective angular rate decays as `rate/(1+D^2)`: ~5% compressed after 24
minutes, **52% after an hour** -- the wind very slowly stops. A constant-rate fix
needs a per-fragment perpendicular axis and a Rodrigues rotation, which changes
how the deck shears and so needs its own look pass. Pinned as check Q4.

**Wind is now tied to the planet's own spin (2026-10-15).** It was a hardcoded
`cloudTime * 2.0e-4`, an **absolute** rate, which was wrong twice over: against a
0.01-0.05 rad/s spin (randomised per planet) that is 1/50th to 1/250th of the
rotation, so the ground swept 1 degree in under two seconds while the clouds needed
87 -- invisible. And because the spin is randomised, the same absolute drift was
5x more visible on a slow world than a fast one. Now `windRate = spinSpeed *
render.planet.cloudWind`, default **0.04**, which is also the physically meaningful
ratio (real cloud drift is ~6% of Earth's rotation). Consequences:

- Constant *feel* on every planet, and the deck creeps **backwards** against the
  spin the way it does on Earth, rather than at an arbitrary absolute rate.
- On the pinned test planet (`spin=0.0173 rad/s`, a 6.0 min rotation) the default
  is 6.9e-4 rad/s = **2.4 deg/min** against a 59.5 deg/min rotation -- a 4%
  counter-drift. That is ~3.5x the old absolute rate on this body, and the old
  rate was 0.69 deg/min on every planet regardless of size or spin.
- Verified by capturing the same static (`spin = false`) planet 150 s of simulated
  time apart at wind 0 / 0.04 / 0.20: the difference grows monotonically
  (2.182 / 3.883 / 5.786 mean abs delta). The wind=0 case is not zero because
  **comparing different frames always includes the nebula's own animation** --
  `simTime` differs between frame 150 and 9150 -- which is worth remembering before
  attributing any inter-frame difference to the thing being tested.
- The `[system] planet` line now also reports `spin=<rad/s> (<minutes>)`, since
  rotation rate is what the wind is derived from and it was otherwise invisible.

**Coverage is logged per world, and that immediately found a bug (2026-10-15).**

`[system] planet` now reports the **resolved** coverage -- the number that
actually decides how cloudy a world looks -- plus both inputs and the surface-cube
seed:

```
[system] planet Netosu    type=ice         moons=2 radius=101527 clouds=0.44 (weather 0.40 + bias +0.04) seed=0.273110
[system] planet LLeccohife type=terrestrial moons=2 radius=95976  clouds=0.58 (weather 0.60 + bias -0.02) seed=0.445641
[system] planet Beterytee  type=barren     moons=0 radius=53752  clouds=0.14 (weather 0.00 + bias +0.14) seed=0.330582
```

because neither panel knob shows it. `Coverage` is only a multiplier on the
type's prior, and `Shell Altitude` is the parallax altitude; the resolved value is
`clamp(weather * Coverage + cloudLevel, 0, 1)` with `cloudLevel ~ U(-0.2, +0.15)`
drawn from the planet's own rng.

**The bug: a barren world resolved to 0.14 and rendered a cloud deck over a body
with no atmosphere.** `weather = 0` for barren types and moons was believed to be
sufficient to switch clouds off -- and the source comment said "airless bodies cost
nothing" -- but `weather = 0` leaves `cloudLevel`, which can be **positive**. So
roughly 43% of barren worlds (bias > 0) and of moons got clouds. The prior was
never decisive; only the *sign* of the bias was assumed.

Fixed by gating `cloudCoverage()` on `hasAtmo`, which also makes the old comment
true. After: barren reads `clouds=0.00`; the atmospheric worlds are byte-identical
(0.44 / 0.58 / 0.45 unchanged).

Worth noting how it was found: the reasoning about the formula was *right* and the
implementation was still wrong, and a single log line settled it. The same question
had taken a capture harness and five seeds to answer approximately, and the harness
measurement was itself confounded (3 of 5 seeds had the planet out of frame).

Also note `seed=` in the log is the **per-planet surface-cube seed**, which seeds
both the terrain and the baked cloud field -- so any world reported by a player is
reproducible from its own log line, without having to work out which world seed
produced it.

**W7b — planetary rings.** The most self-contained piece: a new entity plus a ring
shader, touching neither the generator nor the surface material, so it cannot
break the existing look. Needs: an anulus mesh or GPU particle band (the engine
has `GPUParticles`), a ring shader (ice vs dust, forward-scatter when backlit,
planet shadow on the ring band — the shadow machinery exists), and a per-type
probability. W8 (planet scale) should land first or the ring inner radius has to
be derived from a radius that is currently untamed.

**W7c — true biomes.** Consumes the dead `genColor` channel. The interesting part
is not the lookup but the *continuity*: the design note
(`procedural-space-environment.md` §7) is explicit that a procedural boundary is
a bug — "the player should think *something is changing*, not *I entered a new
zone*". So biomes must blend between neighbouring region colours over large
distances, not switch. The height→4-stop ramp stays as the within-biome detail.

**W7d — gas giants.** Needs a banded generator and a no-solid-surface render path
(thick atmosphere dominant). Explicitly the expensive one, and it should not start
before W6's budget is re-measured with real load.

**W7e — atmosphere entry / landing.** Gameplay, not rendering, and independent of
everything above: an `exp(-altitude/scaleHeight)` density field → ship
drag/lift coupling → landing-zone detection. Sized for after the visuals land.

**Environment lighting directionality (2026-10-12).** *"The skybox produces light
from all degrees"* — correct, and measurable. `irMap` is **not** a plain
irradiance map: it is a *progressive-blur chain* (mip 0 = the raw envMap, each
higher mip a wider-cap average, converging on a hemispherical average). So for a
diffuse lookup a **low** mip is the directional answer and a high mip is
literally "light from everywhere". Measured on the 1024 nebula cube — contrast
between the brightest and darkest directions (p95/p05), plus how much the
darkest 5% of directions is lifted above its true value:

| sample | p05 | median | p95 | p95/p05 |
|---|---|---|---|---|
| irMap mip 2 (256²/face) | 13 | 78 | 118 | **9.1:1** |
| irMap mip 3 (128²) | 15 | 77 | 118 | 7.9:1 |
| irMap mip 5 (32²) — *was the planet's* | 25 | 76 | 121 | 4.8:1 |
| irMap mip 6 (16²) | 30 | 75 | 122 | 4.1:1 |
| irMap mip 8 (4²/face) — *was the diffuse IBL* | — | — | — | ~uniform |

- **Changed:** `light/global.glsl` diffuse IBL **mip 8 → 4** (`kDiffuseIBLLod`),
  and the planet's night-side fill **mip 5 → 3**. Mip 8 is 4×4 per face — a
  hemispherical average, so every lit surface was getting omnidirectional fill.
  The median barely moves (78 → 77), so directionality is bought without a
  brightness compensation; the cost is darker night sides where a surface faces
  empty sky. **Needs an eyeball:** if nights go too black, raise `ambientEnv` /
  `render.planet.envAmbient` rather than putting the LOD back.
- The specular IBL still uses `roughnessToLOD(rough)`, which is correct (rougher
  = blurrier); only the *diffuse* lookups were flattened.
- Also found while chasing the ship's "duplicated" look: `genship.global.surface`
  defaults to **'Extrude'** with `genship.override = true`, so
  `ShipFighter.SurfaceDetail` calls `shape:extrude(0.2)` on the hull **and every
  wing** — that is the stacked-plate look, not a rendering bug. Set Surface
  Detail to 'Smooth Corners' or 'None' to compare. The settings were hard to
  find: the debug panel opens only `Config.debug.windowSection` (nil = *all*
  sections collapsed), and section titles were raw key prefixes, so `genship`
  now displays as "Ship Generator" and `windowSection` accepts key or label.

**The blown white glow at the planet's limb — investigation (2026-10-13).**
Reported as "an unnatural light source sitting on the planet". What was ruled out,
with **verified** settings (see the `PHX_SETTINGS` probe below — an earlier
attempt at this same A/B produced two byte-identical "disabled" variants, so the
toggles were not known to have applied, and one round of conclusions had to be
thrown away):
- **Not the volumetric nebula, god-rays or bloom.** Confirmed independently by
  the player, and by a matched bloom-on/bloom-off pair whose glow falloff is
  identical (253/249/236/200/167/151/133/120 vs 253/249/234/195/154/149/132/119).
- **Not the planet's atmosphere.** `planetAtmoGlow = 0` (verified live) leaves
  the glow unchanged — 136/125 at 320/400 px out vs a 134/124 baseline.
- **Not the planet's shading alone**: `sunScale = 0` reduces the outer halo
  (119/104 vs 134/124) and clouds off reduces it most (106/89) — so the planet's
  sun term *and* the cloud deck contribute, but neither is the whole story.

**What it actually is, in two parts:**

1. **The sky cube has a clipped-white baked star glow.** `gen/nebula.glsl`'s
   "Central Star" adds `8·exp(-√(4096·d)) + 4·exp(-(1024·d)^¼)` where
   `d = 1 - dot(dir, starDir)` — a peak of **12×** the nebula colour, i.e. far
   above 1.0, so it **saturates**. Measured on the generated 1024 cube: the +X
   face runs median 103 / p95 199 / **p99 254**, while every other face sits at
   median 49–78. That is a solid white patch baked into the environment, and
   because it is *baked into the cube at generation time*, **no runtime toggle
   touches it** — which is precisely why disabling the volume, god-rays and
   bloom changed nothing.
2. **The planet's lit limb + cloud deck** adds a broad halo around it, on top of
   the thin atmosphere limb arc.

**Fixed so far:**
- The skybox star's own halo was `pow(ca, 120) * 0.8` — a ~20°-wide lobe, i.e.
  literally "light from all degrees", which is what the player described. Now
  `pow(ca, sunStarHalo)` with `render.sun.starHalo` default **900**, and the disc
  `pow(ca, sunStarTight)` default **20000** at 30 instead of 6000 at 60. Four new
  panel knobs. (Tightening it changed little here, because part 1 dominates.)
- **Terminator:** `exp(-(1-NL)^4)` stays within 6% of full brightness until
  NL ≈ 0.5 and still reads **37% at the geometric limb**, so the day side glowed
  almost to the edge. Now blends toward a true cosine law via
  `render.planet.terminator` (default **0.35**; 0 = pure Lambert/physical,
  1 = the old flat wrap). Outer-halo luma 400 px out: 124 → 78.
- **Cloud deck:** albedo 1.25 → 1.05, and its sun term now follows the same
  terminator so the deck does not keep glowing past the limb.

**Still open:** the generator's baked Central Star amplitude/tightness (part 1).
That changes the sky's character *and* everything `irMap` convolves from it, so
it wants the player's eye before it is touched.

**Harness lessons (both cost real time here):**
- **Verify your overrides applied.** `PHX_SETTINGS=1` now prints the live value
  of the settings that drive a look, once the Renderer has seeded them.
- **Sample the falloff, not the clipped core.** A 253-valued core reads 253 for
  every variant, so a ±40 px grid around the peak compares nothing; the whole
  difference between the variants lived 320–400 px out.
- **Confirm the frame is the same shape.** `Config.window.width/height` is not
  reliably honoured between runs (one batch came out 841×1232 portrait while the
  rest were 1891×969), so pixel comparisons are only valid within a framing.
  Same family of problem as W5's `dt`-drift trap.

**ROOT CAUSE (found 2026-10-13, after the player found it): two passes march the
same medium, and the god-ray composite added it linearly at gain 8.**

```lua
-- GameView.lua, post chain
if Settings.get('nebula.enable') then ... Renderer:volume(...) ... end        -- pass A
if Settings.get('postfx.godrays.enable') ... then Renderer:godrays(...) end   -- pass B
```

- `filter/godrays.glsl` calls **`mediumCloud`**, so pass B marches the *same*
  medium as pass A — but it was gated only on `postfx.godrays.enable`, **not**
  on `nebula.enable`. So "Nebula Volume off" left the shafts marching a medium
  the player had just switched off, and vice versa. **Each toggle removed only
  half the effect**, which is exactly why both appeared to do nothing while
  `nebula.density → 0` (zeroes `mediumDensity()` for *both*) or
  `nebula.radius → 500` (empties both marches) removed it completely. Fixed: pass
  B is now gated on `nebula.enable` as well.
- `filter/godblur.glsl` composited `scene + acc * godStrength` — **linear, with no
  ceiling**, at `godStrength` = `postfx.godrays.strength` (default 8). Looking
  toward the star through 14k units of medium therefore went straight past 1.0
  and clipped to a **flat white disc** hugging the planet's limb. It reads as a
  light source *on* the planet because the star happens to sit at the limb, and
  all of the medium is genuinely *in front of* the planet (radius 101527, camera
  pushed to a 1.35× stand-off ≈ 137k, versus a 14k march) — so it is correctly
  depth-limited haze, just blown out by the gain.
- **Fixed:** a Reinhard knee on the added shaft,
  `shaft / (1 + shaft / godCeiling)`, `postfx.godrays.ceiling` (default **2.0**,
  0 = the old linear behaviour). A no-op well below the ceiling, saturating
  smoothly above it, so **no gain setting can produce a hard white blob** again.
  Verified by capture at the pinned test seed: the planet's disc goes from washed
  out across its left third to readable, with the atmosphere crescent visible
  again and the glow contained to the limb.
- Note this only became reachable because **W5 turned god-rays on for the first
  time**; the W5 sweep could not have caught it, because that sweep never framed
  a planet against the star.

**Lesson (the expensive one):** two passes consuming the same data need ONE
gate. The asymmetry looked like a rendering mystery for a full session because
each individual toggle "did nothing", and two earlier rounds of my own A/B were
wrong before I trusted the player's observation that density controls it.

### 11.4 Scale / universe-gen (= §11.0 W8)
- **`spawnPlanet` uses `scale = 1e5 * erlang(2)`** and does not wire
  `Config.gen.scalePlanet` as the base. Planets are therefore huge relative to
  `kSystemScale = 10000` and can **engulf the system** (the residual Bullet
  `Overflow in AABB`, non-fatal). Latest work caps/⌈tunes⌉ radius — keep that in
  mind. Taming it fully means capping scale or placing planets outside
  `kSystemScale`.
- **Done when:** `Config.gen.scalePlanet` is actually honoured as the base (it
  is currently dead config in `Config.Local.lua`), and no seed produces a planet
  that swallows the belt/station cluster. Independent of W1–W6 — it is a
  gameplay/streaming question, not a lighting one, so it can be picked up in
  parallel.

### 11.5 Look decisions

- **Ship hull is `Material.Metal`** (specular-only → silhouettes). `Diffuse`/`Ice`
  is the lever if we want it lit like the asteroids.
- **Lava emission** currently tops out at the albedo clamp — let the emissive
  exceed 1 if we want bloom on molten surfaces.
- **What ships as the nebula default** (added 2026-10-14, from §11.11). `Config.App`
  ships rays **off** and a ~0.6× veil versus the tuned preset, and the two sit at
  different quality tiers whose step counts differ in measured brightness by ~29%.
  Safe and not broken — but "shipped" currently means "the preset with two things
  turned down" rather than a look validated in its own right. Needs a taste call.

### 11.6 Pulling out dead post passes (Distant Haze + Auto-Exposure)

Asked after the god-ray fix as "is any of this actually earning its place?". Both
candidates turned out to be **wrong or broken**, and one of them was costing a
quarter of the frame while switched off.

**The metering clock is in SECONDS, and has been read as milliseconds twice.**

`Time_GetRaw()` is `return (uint)(time(0) % UINT_MAX);`
(`libphx/src/PhxTime.cpp:29`) — Unix **epoch seconds**, confirmed at runtime
(`raw=1791952044`, and the trace also dumps the type signature showing it is
declared `PHX_API uint Time_GetRaw()`). Two consumers treated it as ms:

| site | assumed | actual | effect |
|---|---|---|---|
| `Renderer:autoExposureEV` | `dt = (now-t)/1000` ⇒ ms | t is *seconds* | every delta **1000×** too small; the 0.5 s adaptation constant was really ~500 s, so it could never converge. The `dt > 0.25` clamp never fired either. |
| `Renderer:meter` readback | `now - last >= 100` ⇒ 100 ms | 100 **seconds** | measured **exactly one** readback in 5200 frames — the panel's `hdr:` line showed one boot-time sample, forever. |

**Auto-exposure: removed.** It was non-functional for the two reasons above —
smoothing a constant, through a filter 1000× too slow to follow anything. Fixing
it was the wrong investment anyway: this game spans a lit planet surface and
empty space, so a keyed 0.18 mid-grey over a −6..+2 EV range pumps the whole
screen by several stops every time the player crosses that boundary. Absolute
brightness is *information* here (it tells you how far you are from a star);
auto-exposure discards it. Kept `postfx.exposure.ev` as a plain manual offset.

I had also suspected the 4096-sample `lit` estimate was too noisy to drive a
smoother. **Measured: it isn't.** After fixing the rate (24 samples), `lit` has
sd 1.48% of mean and a frame-to-frame median change of **0.024 stops** (max 0.059).
So noise was not a reason to remove it — the unit bugs were, and the art
argument is what settles it.

**The meter: kept, but gated — it was 23% of the frame for a debug readout.**

`Renderer:meter()` ran *unconditionally* every frame: 4096 random `texelFetch`es
into a 1×1 target plus a synchronous `getDataBytes`. Nothing consumed it unless
you opened the debug panel, and auto-exposure was off. It is now opt-in on its
own (`postfx.exposure.meter`), gated **inside** the function so any future caller
is safe too. The panel says `meter off` rather than printing values that have
stopped updating.

- default path: **3.30 → ~2.55 ms mean** (p95 3.47 → ~2.8), **~23% of the frame**
- meter on: ~2.55 → ~3.3–3.5 ms, so the pass alone is ~0.75–1.05 ms
- the readback is now 1 Hz, and **1 Hz is the ceiling, not a choice**:
  `time(0)` has 1-second granularity, so `now` only changes once a second and no
  threshold can beat it (a 0.1 s gate measures ~0.9 Hz, not 10 Hz). Which is
  right for this consumer anyway — a human reading four numbers does not want 10
  pipeline stalls a second. A genuinely faster meter needs a real ms clock
  (`Time_GetRawMs`), not a smaller constant.

**Distance Haze: removed — it was not a tuning problem, it was the wrong model.**

`filter/fogw.glsl` computed `fogF = 1 - exp(-fogDensity * dist)` from the linear
depth buffer **alone**, and blended the pixel toward `mix(envMap(dir), fogColor,
tint)`. That models an **unbounded exponential atmosphere**. But this world's
medium is a *bounded union of ≤16 ellipsoids* around the viewer
(`res/shader/include/medium.glsl`): `mediumCloud` returns `rho = 0` outside them
and `mediumBounds` stops the march at their exit. Outside the ellipsoids it is
**vacuum**.

So for the planet in the pinned test scene — radius 101527, camera at a ~137k
stand-off — the pass applied

```
fogF = 1 - exp(-5e-6 x 137000) = 0.496
```

i.e. **half the planet washed into the nebula's own colour across ~120k of
nothing.** Measured on a disc-interior crop:

| | mean luma | sd | p95/p05 |
|---|---|---|---|
| haze off | 53.6 | **18.15** | **3.77** |
| haze on | 74.5 | **10.03** | **1.51** |

**45% of the local contrast gone** — it turned a legible planet into a milky ball.
No setting of `fogDensity` fixes this, because the knob cannot make 120k of vacuum
scatter. The volumetric pass already does the scattering correctly, over the
medium that actually exists. If a real atmosphere is ever wanted it belongs in
the medium as a planet-bound ellipsoid anchor (the mechanism `NebulaVolumes`
already provides), not as a depth-only post blend.

**Also removed: `getFoginess()` + its `fogDensity` uniform** in
`res/shader/include/lighting.glsl`. Its only caller in the tree was a commented
line in `starbg.glsl`, and the only code that ever uploaded a `fogDensity` uniform
was the haze pass just deleted — so it returned ~0 for the whole of history. Its
comment carried hard-won advice about the falloff power; that advice was about a
`depth / farPlane` normalisation which has no physical meaning against a medium
made of ellipsoids tens of thousands of units across, so the note records the
warning rather than the tuning.

**Net for this item:** −2 passes, −1 dead shader function, −1 dead uniform,
−~0.9 ms on the default path, and one debug tool that actually works instead of
one that shows a frozen number.

### 11.7 `nebula.quality` was INVERTED (High rendered *fewer* steps than Low)

Reported by the player: *"why would the 'low' and 'medium' settings basically
display more nebula effects than 'high'?"*

The enum has **four** options; the march tables had **three** entries and were
read with a `- 1`:

```lua
options = { 'Off', 'Low', 'Medium', 'High' }   -- 1, 2, 3, 4
local steps = { 10, 20, 48 }
local stepF = steps[q - 1] or 20        -- q=4 -> steps[3] -> nil -> 20
```

| quality | index | volume steps | god-ray steps | evals |
|---|---|---|---|---|
| Off | 1 | pass skipped | clamped up to Low | – |
| Low | 2 | 20 | 24 | 2 |
| Medium | 3 | 48 | 40 | 3 |
| **High** | 4 | **20** (fallback) | **8** (fallback) | **2** |

So every entry was shifted one slot right and **the last option fell off the end
into the fallback** — and 'High' got the *smallest* god-ray budget of all (8 vs
Low's 24). 'Off' was quietly consuming the 'Low' slot, which is why Low and
Medium looked richer. Both passes were wrong (`Renderer:volume` and
`Renderer:godrays` had their own private copies of the tables, so they could not
even be kept in sync).

Fixed by hoisting four explicit tables indexed *by the enum index*, with index 1
present-but-unused so no `- 1` is needed, plus a **boot-time assertion** that
every table has an entry for every option — a future 5th option now fails loudly
instead of silently landing on a fallback.

Measured after the fix (all four runs at the same 1.83 MP):

| quality | steps (vol/god) | mean | fps | vs Off |
|---|---|---|---|---|
| Off | – | 1.30 ms | 771 | – |
| Low | 10 / 12 | 1.51 ms | 661 | **+0.21 ms** |
| Medium | 20 / 24 | 1.77 ms | 564 | +0.47 ms |
| High | 48 / 40 | 2.37 ms | 422 | +1.07 ms |

Two things worth noting:

- **High did not get slower** (2.40 ms before the fix at 20/8 steps vs 2.37 ms
  after at 48/40). The march is not step-bound here — `mediumBounds` early-outs
  for rays that miss every ellipsoid, so most of the frame never marches. That is
  also why the *broken* High was not cheap: it was paying for the anchors and the
  composite, not the sample loop.
- **The W5 density calibration survives.** ~~`volume.glsl` accumulates the analytic
  form `inscatter += tr * (1 - stepTr) * (sigmaS/sigmaT) * light` with
  `tr *= stepTr`, which telescopes to `1 - T_total` over the march — independent
  of step count.~~ **CORRECTED 2026-10-14 — this is wrong, and §11.11 has the
  measurement.** It telescopes correctly *for a constant per-step `light`*, but
  `step = tCap / volSteps` combined with `exp(-σt·ρ·step)` means a coarse step
  whose midpoint lands in a plume has `stepTr → 0` and absorbs the whole step at
  full `light`. Measured: 10 steps reads **24%** brighter than 48 at identical
  settings, and High additionally loses ~29% to the `volEvals >= 2.5` density
  mask in `medium.glsl`. So a density tuned at one quality tier reads differently
  at another — which is exactly what shipped-vs-preset does.

## 12. Traps (engine-level — cost us time; know them)

- **An enum's option count must match any table indexed by its value.** The
  `- 1` idiom (`steps[q-1]`) silently shifts every entry and sends the *last*
  option off the end into a fallback — so the highest setting quietly rendered as
  the cheapest. `nebula.quality` did this for years; see §11.7. Index by the enum
  value with an explicit entry for every option, and assert it at registration.
- **A uniform the shader declares but Lua never uploads sits at 0 — no error.**
  `filter/aberration.glsl` divided by one (`0.0/0.0` → NaN) and the result was
  blue horizontal scanlines over the whole frame. The inverse also happens: knobs
  whose uniform was never uploaded (`radialblur.scanlines`, `ssao.blur`) read as
  working but did nothing. Audit both directions.
- **`Resolution:` printed at boot is stale.** `LTheory.lua` logs `resX/resY` once
  from `getDefaultSize()`; `Application` then updates them live on every window
  resize. Headless dumps came out 936×969, 1691×1232 and 1891×969 on nominally
  identical runs, so **check the actual PNG dimensions before comparing two
  captures pixel-for-pixel**, and match resolution before comparing frame times.
  Now mechanical: `PHX_FIXED_SIZE` + `PHX_REPORT_SIZE`, and
  `tools/cmp_capture.py` refuses a mismatched pair outright (§10.1, §10.2).
  **Worse than stale, though: in fullscreen `Config.window.width/height` is
  ignored entirely**, because SDL returns the monitor size and the loop adopts it.
  A 1024×768 request rendered at 3840×2160 — 10.5× the pixels — while the boot log
  cheerfully printed `Resolution: 1024x768`. `Application` now prints the real size
  once with the reason; **trust the debug panel's `window:` field, never the
  `Resolution:` line.** See §11.11.
- **Measure at the resolution the player actually uses.** Every headless run here
  is windowed and small; the game runs fullscreen at the monitor's native size.
  That gap was 6× on frame time and it invalidated reading otherwise-sound
  numbers as "too fast to be real". Re-run at the real size before believing any
  frame-time figure (that is what `PHX_FIXED_SIZE` is for).
- **`PHX_FIXED_DT` and `PHX_PERF` measured the same variable until this was
  caught.** `PHX_PERF` samples `self.dt`, so pinning `dt` for determinism made
  every perf sample read back the pinned constant — four nebula variants at
  quality Low/High all reported *exactly* 16.67 ms / 60 fps. Fixed by keeping
  `self.rawDt` (the real delta) and having `PHX_PERF` sample that instead, so a
  fixed-framing capture and a real frame time compose. The signature to watch
  for is a perf line whose `min == p95 == max`: that is a constant, not a
  measurement.
- **A/B evidence needs FOUR things pinned, or it is not evidence.** Frame
  delta, camera pose, window size, and **time**. Pinning three out of four still
  gives you a plausible-looking picture that will not reproduce: the medium read
  the wall clock for its drift, so identical configs differed by ~0.5% of pixels
  in the sky, and a real measurement came back as pure noise. `CaptureHarness`
  does all four; the failure mode without them is an image that looks like a
  result and is actually the chase camera, or the clock.
- **Verify a determinism tool against itself before trusting it.** The harness
  produced bit-identical frames and still had a hole -- a wall-clock time source
  -- that only appeared when two *identical* runs were compared rather than two
  different ones. Same-vs-same first: a determinism tool that has never been asked
  "are you deterministic?" is not a determinism tool.

- **`Time_GetRaw()` is epoch SECONDS, not milliseconds**
  (`libphx/src/PhxTime.cpp:29`, `time(0)`), *and* it has 1-second granularity so
  it cannot time anything faster than 1 Hz no matter what threshold you use. Two
  call sites read it as ms before this was found; see §11.6. If you need real
  timing, add a monotonic ms source — do not divide this one and hope.

- **An unused uniform is optimized out, and setting a missing uniform
  ABORTS the process** (`Shader_GetVariable`) — it is *not* a silent no-op, and
  reading the Lua will not tell you: §11.10 shipped a `setFloat` on a uniform
  `gen/nebula_emit` never declared, which crashed boot for any seed taking the
  Nebula2 path (~1 in 4). Reading code found it; **booting the other path** is
  what proved it. Any `setFloat`/`setTex*` name must exist in *every* shader that
  call site can reach. Hence `mountain`/`crater`/
  `valley`/`crack` are passed only to `gen/planet`, and `coef`/`atmoTint`/
  `hasAtmo` are kept genuinely used. **Never** declare a uniform "for symmetry".
- The **medium noise hash is `fract(sin(x) * c)`** — it loses float precision
  past ~1e4 and degenerates into a stipple. `mediumDensity`'s drift used to be
  `volFlow * volTime` with **absolute** `volTime` (~1.79e6 s) → sample coords
  ~6e7 → the original stipple. Now bounded (`mod(volTime,300)` + a sway). Any
  future sampler that grows a coordinate without bound hits this. There is **no**
  integer-hash variant of the medium to switch on — if the bound ever has to
  grow, copy `NebulaVolumes.hash32` (CPU) or the uint hash in
  `filter/exposure.glsl` (GPU) rather than looking for a dormant branch (W4).
- **`Renderer:free` nils lazily-created textures** (`volView`/`texAnchors`/
  `texLightning`/`godView`). Any pass binding one without recreating it in-pass
  can crash — that was the **F12** bug (god-rays bound `texAnchors`, created only
  by `volume()`, after a supersample change triggered a reset). All such binds
  are now guarded, but the pattern is live.
- **Moving a per-primitive program change into a batched run breaks the batch**
  (the flat immediate batch flushes on program change — see the node-ui doc).
- **A CPU→GPU record field that the shader never reads is invisible.** The green
  speckle (§11.1) was `extX/extY/extZ` added to `NebulaVolumes.build` and never
  uploaded: the medium read a shifted record, evaluated noise at `p * extZ ≈ 1e9`
  and looked like a render bug. When you add a field to a packed buffer, assert
  the *shader* consumes it — and note `NebulaVolumes` still has two such fields
  (§11.0 W3). The same class of waste, in the other direction, is `genColor` and
  `genClouds` in `gen/planet.glsl`: two full per-texel evaluations whose results
  nothing read (W7a consumed one, W7c will consume the other).
- **A local can shadow a uniform of the same name, and GLSL will not warn.**
  `material/planet.glsl` declared `vec3 surface = color;` halfway through `main()`,
  shadowing the `samplerCube surface` uniform — legal, and it silently changed
  every *later* `texture(surface, …)` into a compile error (or, worse, into a
  different overload). The existing height-gradient fetches all sit above that
  line, which is why it went unnoticed. Renamed to `surfCol`.
- **Never seed a render path from the clock.** `TexCube_GenIRMap` did
  (`RNG_FromTime()`), which made every boot's lighting differ and quietly
  invalidated A/B measurements for a week (§11.0 W1). Anything that ends up in a
  uniform, a texture or a matrix takes a **world-derived seed** — and so does
  anything that ends up on screen (W2 added `Game.Seed` for the second class).
- **A module-scope RNG is a global.** Several AI actions and entities shared one
  `local rng = RNG.FromTime()` at file scope, so their draws interleaved in file
  order and one entity's behaviour shifted when an unrelated one changed. Give
  each instance its own stream (`Game.Seed`, salted by entity id).
- **A wide-angle average of a sharp environment is a noisy one.** Sampling a
  cube at LOD 0 no matter how wide the averaging cap is gives a 256-tap estimate
  with visible variance; prefilter the source to the cap (`srcLod`) instead of
  buying more taps.
- **`PHX_FIXED_VIEW=log` freezes the SHIP's pose, which does not necessarily
  frame the planet.** This silently produced a *false negative* on 2026-10-15: an
  A/B of "clouds off" vs "deck on" returned **byte-identical** frames at mean
  delta 0.000, which reads exactly like "the feature does nothing". It was not
  doing nothing — both captures were of empty sky, because the planet sits at a
  random `kSystemScale * (1 + exp)` offset per seed and the ship was nowhere near
  it. The tell was in the log the whole time and I did not look: no `[system]
  planet` line had been printed, because that log only appears once a planet
  exists in view of the spawn. Two lessons: **the `[system] planet` line now also
  prints `pos=(x,y,z)`** so an explicit `PHX_FIXED_VIEW=x,y,z,lx,ly,lz` can be
  aimed at it (2.2x radius away frames a body at about half the frame width);
  and **before believing any "identical frames" result, confirm the subject is
  actually in the shot.** A zero delta is only evidence of absence if something
  was there to be absent.

## 13. Verification workflow

1. Edit.
2. `python3 configure.py test` → 137/0 shaders + suite + node checks.
   (`./configure.py` is not executable in this checkout — prefix with `python3`.)
3. Headless boot with a dump; grep for `FATAL` / `attempt to` / `Shader_Get`.
4. For behaviour, env-gated probes (always reverted before commit).
5. For look/perf, the debug panel + `Config.gen.seedGlobal` to pin the world.
6. **For any look or frame-time A/B, use `CaptureHarness` (§10.1) and compare
   through `tools/cmp_capture.py` (§10.2).** Concretely:
   `PHX_FIXED_DT=0.0166667 PHX_FIXED_VIEW=log PHX_FIXED_SIZE=1280,720
   PHX_REPORT_SIZE=1` on **every** run in the pair, plus `PHX_SETTINGS=1` so you
   can see the override landed. Without all four, the comparison is not evidence.
7. **Determinism check** (do this whenever you touch a generated texture — it is
   cheap and it is the check that catches seeded-from-the-clock bugs):
   pin `Config.gen.seedGlobal`, boot twice with an env-gated
   `TexCube_Save/SaveLevel` dump of the generated cube, and `sha256sum` the two
   sets. Identical ⇒ deterministic. This is how W1 was verified.
8. **Mute audio before any headless boot.** `sfx.engine` is a continuous sound
   with a 60-unit full-volume radius; spawning NPCs on a dev machine produced an
   audible hum from it.

## 14. Non-goals (this pass)

Rings, gas-giant rendering, true biomes, atmosphere entry/landing — see §11.3;
each is a separate, larger effort, and each is gated behind §11.0 W6.

### 11.9 S1 — speckle watch: CLOSED (measured on all four repro seeds, 2026-10-14)

The player has been unable to reproduce the green speckle since W1/W3, so this
was re-run as a measurement rather than left as "no reports". `CaptureHarness`
(§10.1) is what made it cheap: fixed `dt` + pinned camera + fixed size, so each
seed is a clean repeatable capture.

**Method.** §11.1 characterised the bug as **chromatic** high-frequency noise —
σ ≈ 2/255 in R and B with G flat, scaling with the nebula's wash brightness —
against a *brightness* grain that was smooth (high-pass σ ≈ 0.3–0.6%). So the
test is `(σR+σB)/2 ÷ σG`: ≈1 means no channel is elevated, and the bug would sit
far above it. Stars and near-white highlights are excluded (a point source is
chromatically meaningless and would dominate a high-pass statistic). Measured on
both the fixed sky crop and the **whole frame**, the latter because §11.1 notes
the speckle is only visible where the scene behind it is smooth and bright — a
planet disc or limb — and a fixed sky crop would miss a planet that happened not
to be in it.

Whole-frame result (1280×720, dump at frame 150, all `harness=fixed`):

| seed | sky mean | structure | blown | hp σR | σG | σB | chroma/luma |
|---|---|---|---|---|---|---|---|
| test seed (reference, known clean) | 31.3 | 2.07 | 0.000% | 1.10 | 1.00 | 1.01 | 1.05 |
| `14112139399293175324` | 23.5 | 4.85 | 0.014% | 0.76 | 0.74 | 0.74 | 1.01 |
| `5742763467356266433` | 54.0 | 1.78 | 0.000% | 0.85 | 1.10 | 0.86 | 0.77 |
| `11396275097720600019` | 41.9 | 1.78 | 0.000% | 1.09 | 1.07 | 1.35 | 1.14 |
| `12368961037346951482` | 30.4 | 2.28 | 0.027% | 0.87 | 0.77 | 0.93 | 1.17 |

**All four repro seeds are clean** — every chroma/luma ratio sits at ≈1.0
(0.77–1.17, scatter either side of unity with no channel systematically high),
and the high-pass σ on the repro seeds is no larger than on the known-clean
reference. Blown fractions are ≤0.027%, consistent with ordinary bloom on stars
and nebula cores, not the limb-glow bug. **S1 is closed.**

Two honest caveats: this is 5 seeds at one dump frame at 1280×720, not a sweep
over orbit/rotation/distance, so it does not prove the bug can never recur; and
the §11.1 forensics method stays the right thing to use *if* grain reappears.

### 11.10 S1 found a boot-crash regression (mine, fixed)

Running S1 immediately paid for itself: **one of the four repro seeds aborted the
process at boot**, before it could be measured.

```
[system] planet Beterytee  type=barren  moons=0  radius=53752
Shader_GetVariable: Shader <[vs: vertex/ui , fs: fragment/gen/nebula_emit]>
  has no variable <starGlow>
Signal_Handler: Caught Abort
  ./script/Gen/Nebula/Nebula2.lua(30): <null>
```

`Nebula2.lua` set `starGlow` on `gen/nebula_emit`, which does not declare it —
added by commit `8ab0869`. Per §12, `Shader_GetVariable` **aborts the process** on
a missing variable; it is not a silent no-op.

So this was worse than §11.8's "inert" characterisation, and that
characterisation was itself wrong: during the §11.7 audit I wrote that setting a
uniform the program lacks is "harmless per the known trap". It is the opposite,
and §12 already said so. **Any seed that selects the Nebula2 generator crashes at
boot** — roughly 1 in 4 of the recorded repro seeds.

Fixed by removing the set. `nebula.starGlow` is Nebula1-only (`gen/nebula.glsl`'s
"Central Star"); Nebula2 builds emission from per-blob `color`/`density` plus
extinction passes, so giving it the knob needs its own formulation rather than a
copy of Nebula1's. Both `Nebula2.lua` and `Config.App` now say so. Re-ran the
offending seed: boots clean, captures, and is in the S1 table above.

The general lesson, and it is the second time this session: **an audit that only
reads code will call a missing-uniform bug "inert", because reading the Lua shows
nothing wrong.** It takes a boot on a seed that takes the other path.

### 11.11 Validating the shipped defaults at Low — and `nebula.quality` changes the ART

Run under `CaptureHarness` (§10.1) with `PHX_SETTINGS=1` so every override is
provably applied. All four variants produced an **identical camera pose**
(`-43914.7,-16606.9,228326.3`) at 1280×720 — which is the harness earning its
keep, since four different quality/density settings all freezing to the same pose
is exactly the property that was missing before.

#### The step sweep: `quality` is not a quality knob

Everything held at the preset values (density 3.0, background 0.10, coverage 1.6,
god-rays on), varying only quality:

| quality | volume steps | volume evals | sky mean | structure |
|---|---|---|---|---|
| Off | pass skipped | – | 31.1 | 3.17 |
| Low | 10 | 2 | **52.7** | 2.02 |
| Medium | 20 | 2 | **53.0** | 2.04 |
| High | 48 | **3** | **28.3** | 2.29 |
| *High, evals forced to 2* | 48 | 2 | **40.0** | 1.86 |

Two separate effects, and neither is "quality" in the sense the label implies:

1. **`volEvals >= 2.5` multiplies the background density by a second smoothstep.**
   `medium.glsl:43-46`, taken only at High:
   ```glsl
   float d = smoothstep(0.30, 0.72, 0.66 * a + 0.34 * b);
   if (volEvals >= 2.5) {
     float m = smoothNoise(p * 0.0006 + b * 3.0);
     d *= smoothstep(0.25, 0.9, m);   // mean ~0.33 => cuts density ~3x
   }
   ```
   `smoothNoise` averages ~0.5, and `smoothstep(0.25, 0.9, 0.5)` ≈ 0.33, so High
   **dims the everywhere-field by roughly 3×**. Isolated by forcing High's evals
   to 2: sky mean **28.3 → 40.0**. A resolution/budget tier should not change the
   density; this one does. **This is the defect.**
2. **Coarse steps over-absorb thin gas, so Low is genuinely brighter.** 10 → 20
   steps is worth +0.6% (negligible), but 20 → 48 steps is **−24%**. The
   mechanism is `step = tCap / volSteps` with `stepTr = exp(-σt·ρ·step)`: at Low a
   step is 1400 units, so a *single* sample landing in a plume drives `stepTr → 0`
   and that one sample absorbs the whole step and contributes full `light`. Fine
   steps resolve the plume and share the absorption. So the integral is *not*
   step-count independent, which §11.7 got wrong.

**Correction to §11.7:** that section concluded "the marching integral is
step-count independent, so the W5 density calibration survives" and advised
*against* re-running the sweep. **That was wrong** — measured, 10 steps reads
24–29% brighter than 48 at identical settings, and the dominant term was a
density *mask*, not the quadrature. The advice was right in spirit (don't re-run
the old sweep) and wrong in its reason, which is worse, because the reason is what
you would reuse.

#### God-rays at the physical gain are invisible

`def_low` (rays off) and `def_low_rays` (rays on), both `nebula.density = 1.5`,
produced **byte-identical** metrics (37.2 / 2.19 / 1.19 / 1.12 / 1.15), and
`PHX_SETTINGS` confirmed the toggle landed (`false` / `true`). At strength 1.0 —
the physically-correct gain — **the shafts contribute nothing measurable**.

That is the honest consequence of the §11.6 fix: W5 called the rays "the
dominant lever" (21.5 → 40.7), but that was at **strength 8**, ~190× the sun's
radiance. At strength 1 they are correct and invisible. **W5's "rays on at 8"
preset is therefore no longer a calibration** — it was calibrated against a gain
that has since been removed as unphysical, and the density/coverage numbers were
chosen *around* it.

#### You were never rendering at the resolution you configured

The player's own debug-panel snapshot said `window: 3840x2160` while its boot log
said `Resolution: 1024x768`. Both were true and the gap was the whole mystery:
`LTheory.lua` prints `resX/resY` **once at boot, before the window syncs**, and
`Application` then adopts the window's real size every frame. With
`Config.window.fullscreen = true` SDL hands back the **monitor's** resolution, so
`Config.window.width/height` is **silently ignored** — a 1024×768 request on a
4K display renders 3840×2160, which is **8.29 MP instead of 0.79 MP, 10.5× the
pixels**.

That is why `PHX_PERF` reported 0.9–1.4 ms while the player's panel read 5.6 ms:
both were correct, at 1280×720 windowed and 3840×2160 fullscreen respectively.
Re-run at the player's real size, the harness reproduces their number to within
3% (5.77 vs 5.61 ms), which is what confirmed the diagnosis rather than assuming it.

Measured at 3840×2160, debug panel on, harness-pinned:

| quality | nebula ON | nebula OFF | nebula delta | fps on → off |
|---|---|---|---|---|
| Low | 5.77 ms | 4.76 ms | **+1.0 ms** | 173 → 210 |
| High | 9.34 ms | 4.86 ms | **+4.4 ms** | 107 → 206 |

The debug panel is **not** a factor (0.2–0.3 ms). The nebula's cost scales with
pixels — **+0.55 ms at 0.79 MP, +4.4 ms at 8.29 MP** — and is **~48% of the frame
at High**, which is exactly the "lose 50–100 fps" the player had been feeling.

**Applied:** `Config.gpu.resolutionScale = '50%'` (renders 1920×1080, upscales on
present) and `nebulaQuality = 'Low'`. `Application` now prints the real size once
with the reason, so this cannot mislead again:

```
Display:  3840x2160  (fullscreen: Config.window.1024x768 is ignored;
 use render.resolutionScale to lower the internal resolution)
```

Result at 4K window / 1920×1080 internal / Low / panel on:

| | mean | fps |
|---|---|---|
| nebula ON | **1.68 ms** | 594 |
| nebula OFF | 1.56 ms | 641 |
| *(before: 4K native, Low)* | 5.77 ms | 173 |

**3.4× faster**, and the nebula now costs **0.12 ms** instead of 1.0 ms. Note
`resolutionScale` bottoms out at 50% (1920×1080), so **1024×768 is not reachable
in fullscreen** — going windowed at 1024×768 is the only way to get exactly the
configured size.

**Standing caveat:** every frame-time figure in this doc — W5's "3.02–3.19 ms",
§11.7's sweep, §11.11's numbers — was measured at a *headless windowed* size,
never at the player's 4K fullscreen. They are internally comparable but do not
represent what the player actually experiences. Re-measure anything load-bearing
at the real size.

#### What the shipped defaults actually are

`Config.App` ships `godraysEnabled = false` — so the shipped experience has **no
shafts at all**, and per the point above, enabling them at strength 1 would change
almost nothing. Shipped veil proxy (`density² × background × coverage/2 × radius`)
is **0.62×** the tuned preset.

| variant | sky mean | structure | frame blown |
|---|---|---|---|
| shipped defaults @ Low, rays off | 37.2 | 2.19 | 0.000% |
| shipped defaults @ Low, rays on | 37.2 | 2.19 | 0.000% |
| tuned preset @ Low | 52.7 | 2.02 | 0.000% |
| tuned preset @ High | 28.3 | 2.29 | 0.000% |

**Conclusion: the shipped defaults are safe but were never validated and are now
known to be inconsistent with the preset in two ways** — a ~0.6× veil *and* a
different quality tier whose step count moves brightness by ~29%. Nothing is
blown and nothing is wrong-looking, so this is not urgent; but "the shipped
default" is currently "the preset with two things turned down", not a tuned look
in its own right. Deciding what ships is a taste call, and §11.5 now has a third
entry for it.

### 11.12 Rain/storms from orbit — dropped as invisible (2026-10-15)

Asked whether rain would be noticeable from the ship. **It would not**, and the
arithmetic is not close:

- A raindrop is ~2 mm. At the game's closest planet stand-off (1.35x radius on a
  ~1e5-unit body, so ~3.5e4 units, rendered at 4K with `resolutionScale = 50%`)
  one screen pixel covers on the order of **1e2-1e3 units**. A drop is 4-5 orders
  of magnitude below a pixel. It cannot be drawn, and it cannot be *seen* -- not
  as geometry, not as a texture, not as a resolved particle.
- The same holds for any local precipitation: rain, snow, hail. They are
  sub-pixel at every camera distance the game permits, because the camera is
  always outside the atmosphere.

What is actually visible from orbit, and what already exists or is worth doing:

| Effect | Visible from orbit? | Status |
|---|---|---|
| Cloud decks / systems | **yes** — the whole reason W7a exists | ✅ shipped |
| Storm cells (mesoscale) | **yes** — 100s of km, many pixels across | plausible W7a extension |
| Lightning | **yes** — already implemented and firing at boot | ✅ shipped |
| Dust storms (lava/desert) | **yes**, same scale as storm cells | plausible |
| Aurorae | **yes**, and absent | candidate (W7c-adjacent) |
| Rain / snow / hail | **no** — sub-pixel by 4-5 orders of magnitude | dropped |
| Rainbows | from orbit, **no**; only from inside the atmosphere | dropped (W7e scope) |

So "rain/storms" was really "storms" all along. Storms are a *cloud-field*
feature (large-scale density modulation and rotation), not a precipitation
feature, and they would build on the W7a shell rather than need a new one. That
is a reasonable piece of work — but it is **not** the highest-value next item,
and it is not what was originally sketched. Recommendation: **skip it**, take
**W8 (planet scale)** next, which unblocks **W7b rings** — the item the player
specifically asked for — and revisit storms later if the sky still wants it.

### 11.15 The wind "going down a drain" — unbounded drift collapsed the deck (2026-10-16)

Player report, playing with the Wind slider: *"the wind seems to act like it's
going down a drain, converging to one area as you move the slider"*, localised to
the right side of the planet, mid-to-lower. It got **worse** as the slider rose.

Cause: the drift was applied as `normalize(dir + D*driftDir)` with
`D = cloudTime * cloudWindRate`, growing without bound. `normalize()` discards
magnitude, so as `D` grows every fragment's sample direction tends toward
`driftDir` — and `driftDir` sits at a **fixed** angle off the equatorial plane
(`atan(0.4) = 21.8°`, from the old 0.4 cross-latitude term). Every latitude
therefore collapsed toward the same band:

| fragment latitude | sample latitude as \|D\|→∞ | compression |
|---|---|---|
| +80° | −21.5° | −101.5° |
| +40° | −13.8° | −53.8° |
| 0° | 0.0° | 0 |
| −40° | +13.8° | +53.8° |
| −80° | +21.5° | +101.5° |

Both poles and the whole deck squeezed into one band. A larger Wind slider means
a larger rate, which reaches the collapse sooner — exactly the reported
behaviour, and why it only showed once a session had run long enough for `D` to
grow.

Fix: the drift is now a **rotation about the spin axis** (Rodrigues), shared by
all four consumers (deck, shadow, storm field, lightning cells). Three properties
the translation lacked, all of them bugs:

- **isometric** — `|d|` stays exactly 1, so no sample can ever be dominated, and
  two fragments can never converge (check V1: worst `|len|-1` = 2.2e-16 at angles
  up to 5000 rad; V3: +70° and −70° keep a separation of exactly 2.4435 rad at
  *every* drift angle),
- **periodic** — wraps mod 2π rather than growing without bound (V2),
- **constant angular rate** — instead of decaying like `atan(D)`, which was the
  "known limit" recorded in 11.2 and is now simply gone.

It also removes the tangent frame entirely, so the 11.14 circle class cannot recur
in the drift. Zonal drift is the physically dominant term anyway, and it
correctly goes to zero at the poles on its own.

V4 keeps the regression honest by evaluating the old construction: it moves one
fragment's sample 1.57 rad at a drift of 200.

A/B on the player's exact world (seed `11563922953321689029`, Vuhassoone,
terrestrial, R 43608, wind 0.2, frame 9150 where the old form was deep into
collapse): pre-fix shows radial streaking and a pinch on the right; post-fix is
clean.

### The relief gradient had the SAME bug (and predates the cloud work)

While fixing the drift, `planet.glsl:137` turned out to carry the *same* ternary
for the **terrain relief** tangent frame:

```glsl
vec3 T = normalize(cross(N, (abs(N.y) < 0.9) ? vec3(0,1,0) : vec3(1,0,0)));
```

That is the original "circle" — it shears the height gradient, so it shows as an
arc in the **ground shading**, near the top of the disc, and it is unrelated to
clouds entirely. Now built from the spin axis as well, with the perturbation
faded out where the tangent is undefined. Checks U1/U2 now guard the whole class
at the source level: **no ternary reference-axis basis may exist in executable
shader code**, and both the drift and the relief frame must use the spin axis.

That is three separate bugs (§11.2 drift magnitude, §11.14 drift basis,
§11.15 relief basis) from one recurring mistake, and it is the most useful thing
in this section: *a branch on a sphere coordinate is a circle on the surface.*

### 11.14 The "circle" — a discontinuous tangent basis (found in play, 2026-10-16)

The arc the player kept reproducing was **not** the deck/shadow desync fixed in
11.2, and not the aurora (`render.planet.aurora` was 0 in the reported settings,
which eliminated that immediately). It survived one fix because that fix
addressed the drift's **magnitude**; this one is about the **basis** that
magnitude is measured against.

The drift built its tangent frame like this:

```glsl
vec3 dtl = normalize(cross(nl0, (abs(nl0.y) < 0.9) ? vec3(0,1,0) : vec3(1,0,0)));
```

The reference axis switches from +Y to +X at `|nl0.y| = 0.9`. But `cross(n, +Y)`
and `cross(n, +X)` are **unrelated directions** — not two approximations of the
same vector — so the basis jumps across the latitude circle at
`asin(0.9) = 64.2°`. That is a circle on the sphere, which projects as a hard
arc near the top of the disc.

Measured (check U1): the basis jumps **180°** across that latitude. One side of
the planet drifts one way, the other side drifts *exactly backwards* — which is
precisely the "an inner sphere turning in opposite directions" that was reported.
And it is invisible at wind 0 **only because `cloudDrift` is zero there**, which
is why the symptom tracked the Wind slider and why a frame-300 capture showed
nothing (drift at 5 s is 0.035 rad; it takes ~150 s to reach 1 rad).

Fixed by building the frame from the body's own **spin axis**, which is valid in
local space unchanged — the body rotates *about* that axis, and a rotation about
an axis leaves it invariant:

```glsl
vec3 ax  = normalize(planetSpinAxis);
vec3 raw = cross(nl0, ax);
float tl = length(raw);                       // degenerate only AT a pole
vec3 dtl = (tl > 1e-4) ? raw / tl : normalize(cross(nl0, vec3(1,0,0)));
float polarFade = smoothstep(0.0, 0.06, tl);  // drift -> 0 where "east" is undefined
```

- Continuous everywhere except the two pole **points** (U2: largest basis step
  over a full 2° latitude sweep plus polar longitudes is 0.0304 rad, versus 180°
  before), and the drift fades to zero there anyway (U3).
- Side benefit: the drift now means something. Winds run along lines of
  latitude — "eastward" — rather than an arbitrary tangent, which is both more
  physical and better looking.
- **Reproduced on the player's exact world** (seed `16560706864388890501`,
  Hebonewate, ocean, R 46343, wind 0.1674, shell 0.05532) and re-captured at
  frame 9150 where drift reaches 1.057 rad: clean, no arc.

### Lesson: a latitude circle is a signature

Every artifact here that looked like "a mysterious circle" was a **hard-coded
threshold on a sphere coordinate**: `abs(nl0.y) < 0.9`. When a shader branches on
a latitude or a dot-product threshold, the branch boundary is a circle on the
surface, and it shows up in projection as an arc. Prefer a smooth quantity with
an inherently continuous reference (a per-entity axis) over a ternary that swaps
one arbitrary axis for another.

### 11.13 Storms and aurorae (2026-10-15)

Two planet features added after W7a closed, both chosen because they are in the
"actually visible from orbit" class (§11.12) rather than the sub-pixel one.

**Storms** — darker cloud cells plus intra-cloud lightning, per the player's
brief ("darker clouds with the occasional light flashes").

- Storminess is a **much lower-frequency** field than the deck texture, so a
  storm reads as a whole weather system rather than cloud detail. NASA astronaut
  photography consistently shows convective cells as *darker* than the
  surrounding deck — thick anvils absorb rather than scatter more — so
  storminess **multiplies the deck albedo down** (to 0.45 at full strength),
  it does not add a dark overlay.
- Scaled by the type's **existing `weather` prior** rather than a second table,
  so storminess stays consistent with how wet the world already is: ocean 0.70 /
  terrestrial 0.60 worst, ice 0.40, lava 0.15, desert 0.08 rare, barren+moon 0 —
  which also keeps airless bodies free.
- Flames: each storm cell hashes (cell, time window) so cells flash
  **independently and out of phase**; the planet twinkles rather than strobing in
  unison. 1.6 s windows, ~14% of cells per window, fast attack and exponential
  decay.

**Aurorae** — the player asked for these to be type-gated, and they must be,
because an aurora needs **two** independent things: an atmosphere to excite and
a **global magnetic dynamo**. That is not "any world with air": Venus has a
thick atmosphere and no intrinsic field (no aurora), Titan has air and no dynamo
(no aurora). So it is a per-type `aurora` flag in `Config.App`, set only on
**terrestrial and ocean**. Raising the panel knob will not light up a desert, an
ice world, a lava world, a barren rock or a moon.

Grounded in ISS observations for the look:

| property | source | implementation |
|---|---|---|
| green 100–300 km, red 300–500 km above it | altitude-resolved ISS spectra | two shells, red at 2.2x the green altitude |
| narrow oval near 67° magnetic latitude | oval geometry | `lat` band 0.84–0.93, zero at equator **and** pole |
| concave arcs with gaps | "large concave arcs... with well-defined edges" | two-threshold arc cut (a single `saturate` just floods the oval) |
| activity peaks 180° from the sun | "peak at 180 degrees from the sun" | night weighting, zero on the day side |
| optically thin → long path edge-on | physics | limb weighting, so it is a limb feature |
| "crawls around like a giant green amoeba" | always moving | two advected noise fields, slow + fast |

The two-shell trick gets the vertical structure for free: the higher shell is hit
at a different direction off-axis, so red sits above green at the limb and
directly behind it at nadir — which is what the real altitude split does, for one
extra ray-sphere solve and no extra texture.

**Four bugs found by LOOKING at the output, none by any test:**

1. **Lightning painted visible white SQUARES.** Quantising a unit *direction*
   with `floor()` yields axis-aligned **planar** cells, so a firing cell lit a
   hard-edged square. The grid is only a timing device and must never be visible:
   fixed with a smooth per-cell border window plus a fast noise field to break
   the remaining rounded-square footprint.
2. **The aurora washed the entire disc green.** The oval spanned latitude
   0.70–0.99 (44–82°) — that is not an oval, it is most of a hemisphere. Narrowed
   to a real band.
3. **Storm cells went almost black and the flashes vanished.** `stormAmount` is
   the weather prior times the knob, so it exceeds 1 above `knob = 1/weather`
   (1.8 at storms=3), and `mix(1.0, 0.45, 1.8)` extrapolates to 0.01. Same class
   as the earlier `cov*clouds` trap — **every mix factor fed by a product of a
   prior and a knob must be clamped.**
4. **The arc read magenta** because red was weighted equally with green. From
   orbit the 557.7 nm oxygen band is what you see and 630 nm is a fringe.

**A screenshot is a bad verifier for lightning.** The flash envelope decays
inside each 1.6 s window, so two of three sampled frames landed in the dead part
of it and reported "zero flashes" for a feature that was working. Sampling luck is
not evidence — storms and flashes are now pinned numerically (checks R1–R2, S1–S3)
and the aurora's localisation is pinned by region (T1–T3).

Verified by region on the limb pose: night limb **4.50/255** mean delta, while the
sunlit limb and the day-side control are **exactly 0.000** — so it is precisely
localised to the oval on the night side, not a wash. Perf 0.74 ms at 1280x720.

### 11.8 Closing this out — what is left, and the order to do it in

State as of 2026-10-14. **W7a is the last thing landed**, so W7 is one-fifth
done and the doc is not closeable yet. This is the consolidated list; the
recommended order is §15.4.

**A. Verification debt — cheap, and it gates everything visual**

| item | why it matters | state |
|---|---|---|
| **Fixed-camera harness** | Every look A/B in this doc was taken under a moving camera and a drifting window size. W5 concluded it was needed; §11.6/§12 later proved it twice more. Without it, measurements are only valid *within* a family of identical frame cost. | ✅ **2026-10-14** — see §10.1/§10.2. Bit-identical frames across runs, verified. |
| **S1 speckle watch** | The §11.1 fix was verified on **one** of four recorded repro seeds. | ✅ **2026-10-14** — all four clean, measured. See §11.9. |
| **Re-validate the shipped `Config.App` defaults** | W5 calibrated at High and deliberately shipped `Config.App` unvalidated (density 1.5 / background 0.2 / coverage 2.0 at Low). §11.7 then changed what Low *renders* (10 steps, was 20), so the "re-tune with the harness" note is now doubly out of date. | open |

**B. W6 — FPS, properly**

§11.3's gate claims 3.7 ms/frame at 1024×768 with "the volumetric pass is 30% of
the frame". Two problems: it was measured on an **empty** system, and §11.7's
sweep put the nebula at **+1.07 ms of a 2.37 ms frame at High — about 45%**. So
the figure is stale and the load W6 was supposed to profile (hundreds/thousands
of asteroids, 10–50 NPCs) was never applied. W6's real content is a re-measure
under load, plus `render.resolutionScale` / supersampling as the real levers
(§11.2). Partially advanced by §11.6 (meter gate, −0.9 ms).

**C. W7 remainder**

| piece | depends on | effort | notes |
|---|---|---|---|
| ~~W7a polish~~ | — | S | ✅ **Done 2026-10-15.** Shell + parallax, shadows, spin-relative wind, coverage retune all landed and signed off. Rain/storms deliberately **dropped** — see §11.12. |
| W7b rings | **W8** | M | most self-contained (new entity + shader; touches neither generator nor surface material). **Do W8 first** or the inner radius derives from an untamed radius. |
| W7c biomes | W7a | M | consumes the dead `genColor` channel. The hard part is continuity, not the lookup — biomes must *blend*, never switch (`procedural-space-environment.md` §7). |
| W7d gas giants | W7c | L | banded generator + no-solid-surface path. Explicitly the expensive one; must not start before W6 is re-measured with load. **⛔ deferred 2026-10-14** (see below). |
| W7e atmosphere entry | — | L | gameplay, not rendering, and blocked by nothing. `exp(-altitude/scaleHeight)` → drag/lift → landing zones. **⛔ deferred 2026-10-14.** |

**D. W8 — planet scale** (§11.4). Independent of all lighting work.
`Config.gen.scalePlanet` is dead config; planets are `1e5 * erlang(2)` against
`kSystemScale = 10000` and can engulf the system. **Done when** the config is
honoured as the base and no seed produces a planet that swallows the belt.

**E. Loose ends found during the §11.6/§11.7 audit — deferred to the planned
`.glsl` review, recorded so they are not lost**

- `res/shader/fragment/gen/nebula2.glsl`, `nebula3.glsl`, `nebula4_weak.glsl` —
  **zero references anywhere**; only `gen/nebula`, `gen/nebula_emit`,
  `gen/nebula_absorb` are loaded. The `starGlow` uniform was added to all three
  in commit `8ab0869` for nothing. Delete or wire.
- `nebula.starGlow` is **inert for Nebula2 sectors**: `Nebula2.lua` sets it on
  `gen/nebula_emit`, which does not declare it. Only `gen/nebula` (Nebula1, the
  IFS skybox) honours it.
- `gen/clouds_cube.glsl` still in the tree hardcoding `seed = 1337.0` and
  unreferenced — W7a made it unnecessary.
- `genColor` in `gen/planet.glsl`: a 12-iteration fractal per texel read by
  nothing. W7c consumes it; until then every planet cube pays for it.
- Dead uniforms with working in-shader fallbacks (harmless, not bugs):
  `bloompre.maxBrightness` (falls back 5.0), `tonemap.lensDirtStrength` /
  `lensDirtTex` (stub at 0.0).
- **The baked Central Star amplitude is still unevaluated** (§11.3, part 1). The
  `nebula.starGlow` knob exists (0.35) but nobody has looked at the result. It
  changes the sky *and* everything `irMap` convolves from it.
- §11.3's W7a note blames "the atmosphere shell plus auto-exposure" for washing
  out the surface — auto-exposure no longer exists (§11.6); re-check that
  judgement.
- §11.2's "Low/Med/High = 10/20/48" was **wrong until §11.7 fixed it**; it is
  right now, and `Low` genuinely runs 10 steps for the first time.

**F. Two pending decisions** (§11.5) — these need a human to pick a side, they
are not tasks: the `Material.Metal` ship hull (specular-only → silhouettes), and
lava emission topping out at the albedo clamp (bright colour, not HDR bloom).

**On "done":** closing this doc means A, C(W7a polish + W7b + W7c), D and the two
§11.5 decisions are resolved.

**Decision taken 2026-10-14 — W7d (gas giants) and W7e (atmosphere entry /
landing) are deferred out of this pass**, and **W7b (planetary rings) is
wanted**. So the scope of "done" for this doc is now:

- **in scope:** the fixed-camera harness, S1, re-validated shipped defaults, W6
  under load, W8, W7a polish, **W7b rings**, W7c biomes, and the two §11.5
  look decisions.
- **deferred, explicitly:** W7d and W7e. Both are blocked by nothing in §11.0
  and both are larger than everything in scope combined — they are *new feature
  work*, not finishing the planet pass. They move to a follow-up doc rather than
  silently disappearing, and W7d still should not start before W6's budget is
  re-measured with real load.

**Note the dependency this keeps:** W7c (biomes) is listed as depending on W7a,
and W7d depended on W7c — deferring W7d means W7c is now the **last** item in
scope rather than a stepping stone, so its continuity work (§7 of
`procedural-space-environment.md`) is worth doing properly rather than as a
stepping stone to something bigger.

---

## 15. Resuming this work

1. Read **§11.0** first — it is the ordered list, and the order is the point.
2. Pin the world (`Config.gen.seedGlobal = <n>ULL`) before any measurement.
   Lighting is reproducible as of W1; particle/NPC jitter is not (§11.0 W2).
3. Take the next item off the table, not the next interesting idea. W2/W3/W4/W8
   are independent of each other and can be done in any order; W5 must follow
   W3+W4, W6 must follow W5, W7 follows W6.

### 15.4 Recommended order from here (2026-10-14)

The doc's original dependency order (W6 before W7) has been overtaken by what
§11.6/§11.7 turned up: **measurement came before the profiling it was supposed
to inform**, and every item in group A below is cheap and unblocks the rest.

1. **Fixed-camera harness** — the highest-value small piece in the whole doc.
   It is the precondition for item 2 and for any further look tuning, and it has
   now invalidated measurement three separate times (§11.3 W5's `dt`-drift trap,
   §11.3's "one batch came out 841×1232 portrait", §12's stale `Resolution:`).
   ✅ **Done 2026-10-14** — `CaptureHarness` + `tools/cmp_capture.py` (§10.1,
   §10.2), verified to produce bit-identical frames across runs.
2. **Re-validate the shipped defaults at Low, and run S1** on the three
   unverified speckle seeds — both are now one harness run each, and both are
   trustworthy for the first time. ✅ **Done 2026-10-14** — S1 closed on all four
   seeds (§11.9); the defaults validation found a **boot-crash regression** (§11.10)
   and that **`nebula.quality` changes the rendered density, not just the
   sampling** (§11.11). The open question that fell out is a taste call now
   logged as a third §11.5 decision.
3. **W6 for real** — re-measure under the asteroid/NPC load it never profiled.
4. **W8** — independent of all lighting work, and doing it next unblocks rings,
   whose inner radius currently derives from an untamed radius.
5. **W7b rings** — the most self-contained piece of W7; new entity + shader,
   touching neither the generator nor the surface material, so it cannot break
   the existing look.
6. **W7c biomes** — consumes the dead `genColor` channel; needs W7a's plumbing
   and continuity-aware blending. This is now the **last item in scope**, so its
   continuity requirement deserves a proper pass rather than a token one.
7. ~~W7d / W7e~~ — **deferred 2026-10-14**, out of this pass (§11.8).

The `.glsl` dead-code review (§11.8 E) is deliberately *not* in this list: it is
orthogonal, touches no behaviour, and should ride with a dedicated pass rather
than be smuggled between items.

**Do not** re-run the W5 density sweep. §11.7 established that the marching
integral is step-count independent, so the calibration still holds; the sweep
would only re-measure the harness, not the look.

