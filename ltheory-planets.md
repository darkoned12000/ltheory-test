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
6. **W5 density + god-rays re-tune** — next; see §11.0.

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
| W5 | Re-tune density ⇒ god-rays gain together | W3, W4 | S | open |
| W6 | FPS: profile on the *final* W5 settings | W5 | M | open |
| W7 | Deferred features (clouds, gas giants, rings, biomes, atmosphere entry) | W6 | L | §11.3 |
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
  0.7, extZ 1.0, extX 1.0), so plumes are genuinely thinner per bank. Part of
  that is offset by the rim now being brighter in the mid-body than a full-rim
  mix would be. Do the density/god-ray re-tune with this in mind rather than
  assuming the sliders are lying.
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

**W5 — density and god-rays are coupled.** `nebula.density` feeds both the
volume and `Renderer:godrays`, and the god-ray default gain (**8**) was tuned
against the *old* medium calibration. The nebula veil is **quadratic** in density
(`OD = 5e-5 · density² · background · radius`), so any density change moves the
wash and the rays non-linearly. Tune them **together, last**, after W3/W4 have
stopped changing the medium.
- **Done when:** `nebula.{density, background, coverage}` and
  `render.godrays.gain` reach a look you like with no wash-over-everything and
  no rays that vanish.

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

### 11.3 Deferred features (= §11.0 W7)

**Gate: do not start any of these until W6 has a measured perf budget.** Two of
them are explicitly expected to be the expensive ones, and the reason they were
deferred is that we never established the budget.

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

## 12. Traps (engine-level — cost us time; know them)

- **An unused uniform is optimized out, and setting a missing uniform
  ABORTS the process** (`Shader_GetVariable`). Hence `mountain`/`crater`/
  `valley`/`crack` are passed only to `gen/planet`, and `coef`/`atmoTint`/
  `hasAtmo` are kept genuinely used. **Never** declare a uniform "for symmetry".
- **The medium noise hash is `fract(sin(x) * c)`** — it loses float precision
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
  (§11.0 W3).
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

## 13. Verification workflow

1. Edit.
2. `python3 configure.py test` → 137/0 shaders + suite + node checks.
   (`./configure.py` is not executable in this checkout — prefix with `python3`.)
3. Headless boot with a dump; grep for `FATAL` / `attempt to` / `Shader_Get`.
4. For behaviour, env-gated probes (always reverted before commit).
5. For look/perf, the debug panel + `Config.gen.seedGlobal` to pin the world.
6. **Determinism check** (do this whenever you touch a generated texture — it is
   cheap and it is the check that catches seeded-from-the-clock bugs):
   pin `Config.gen.seedGlobal`, boot twice with an env-gated
   `TexCube_Save/SaveLevel` dump of the generated cube, and `sha256sum` the two
   sets. Identical ⇒ deterministic. This is how W1 was verified.

## 14. Non-goals (this pass)

Rings, gas-giant rendering, true biomes, atmosphere entry/landing — see §11.3;
each is a separate, larger effort, and each is gated behind §11.0 W6.

---

## 15. Resuming this work

1. Read **§11.0** first — it is the ordered list, and the order is the point.
2. Pin the world (`Config.gen.seedGlobal = <n>ULL`) before any measurement.
   Lighting is reproducible as of W1; particle/NPC jitter is not (§11.0 W2).
3. Take the next item off the table, not the next interesting idea. W2/W3/W4/W8
   are independent of each other and can be done in any order; W5 must follow
   W3+W4, W6 must follow W5, W7 follows W6.

