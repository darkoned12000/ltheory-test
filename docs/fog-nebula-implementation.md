# Nebula Fog / Dust Volume + Lightning Storm — Implementation Plan (branch: `fog-nebula`)

Goal: build a **participating-media renderer with stylized anisotropic nebula lighting** — not a named-after-one-aesthetic effect. Freelancer/Starlancer are the *visual reference*, not the implementation scope, because the same medium should later serve dust, gas, planetary haze, engine smoke, storm volumes, and nebulae.

Concretely: fly through drifting volumetric dust and nebula plumes that occlude the stars, glow against the sun with anisotropic forward scatter, get cut by independent god-rays, and are torn periodically by **lightning storms** — a branching bolt, a white-hot flash, and a *local* volumetric light that makes the cloud around the strike glow and decay. All opt-out, Perf-gated, and equivalence-tested like GTAO was.

Base branch `main` (GTAO + distance haze merged). Plan opened **2026-09-10**; revised **2026-09-11** (§2, §3, §10).

---

## 1. The asks (verbatim intent, kept as features)

1. **Volumetric nebula/dust** — fly-through volume with parallax, not billboards or a 2D tint.
2. **Sun-lit dust with anisotropy + god-rays** — forward-scatter phase, independent shaft pass.
3. **Stars occluded by dust** — the sky behind a thick bank dims (`scene * T + inscatter`, never `scene + additive`).
4. **Lightning storm spike** — bolt + flash + the dust lights up **locally** at the strike, then decays; a weather event, not a texture; audio hook data-driven behind the visual gate.
  - To bring "electricity and life" into nebulae (roadmap #4), the volumetric pipeline handles lightning strikes via a dynamic LightingEvent struct:  
  - Local Energy Injection (LightingEvent)When an electrical storm triggers in a sector, the Lua game loop creates a temporary event record:
    ```Lua 
    local strike = {
      pos = Vec3f(x, y, z),
      color = Vec3f(0.4, 0.8, 1.0), -- Hot Electric Blue
      energy = 15.0,                -- Intensity multiplier
      radius = 3500.0,              -- Light flash radius
      duration = 0.4                -- Seconds to decay
    }
    ```
  - Volumetric Light Flash inside volume.glsl
    - Inside the half-res raymarch pass, volume.glsl evaluates point-light attenuation from active lightning strikes:
        $$\text{lightningLight} = \frac{\text{strike.color} \cdot \text{energy}}{\text{dist}^2 + 1.0} \cdot \exp(-\text{dist} \cdot \sigma_t)$$
    - Because energy scatters through the local dust, a lightning bolt illuminates the interior of the cloud, causing surrounding gas tendrils to flash white-hot and slowly decay.
  - Camera & Bloom Interaction
    - Powerful strikes instantly trigger auto-exposure adaptation (Renderer:meter) and feed high-luminance pixels into Karis bloom (Renderer:bloom), producing realistic camera lens glare and glowing cloud rims.
5. **Nebula as sector content** — anchor volumes (real local clouds you can orbit), palette from the same generator that makes the sky.
6. **Opt-out + Perf-gated + A/B-toggleable + debug modes** — off = bit-identical frame; a debug visualization enum so tuning stops being "summon screenshots by feel".

---

## 2. Review feedback & architectural corrections incorporated

1. **Density field is world-space, not camera-anchored** — `density(worldPos)`, maintained in a camera-following cell that *snaps on a large grid* (world pos = eye + dir $\cdot$ t). Camera-space lobes cause swimming and break streaming.
2. **No multi-octave FBM in Phase 1** — start with 2 noise evals (low-freq coherent + higher-freq modulation). Detail comes from lighting + jitter.
3. **Transfer/scattering equation is the explicit contract (ADR math)** — $\sigma_t$ (absorption + scattering) separated from $\sigma_s$ (scattering); accumulation via $T *= \exp(-\sigma_t \cdot \rho \cdot ds)$ and $\text{inscatter} += T \cdot \sigma_s \cdot \rho \cdot \text{lighting} \cdot ds$; composite $\text{scene} \cdot T + \text{inscatter}$.
4. **Nested full sun raymarch is prohibited in Phase 1** — `sunTrans` is a fixed-cost approximation. 24 camera steps $\times$ 24 sun steps would blow the budget.
5. **God-rays are a separate pass boundary** — "what does the medium do to light" vs "where do we emphasize directional shafts" are separate products with separate A/B knobs.
6. **Anchors use a bounded active-volume interface, not an ever-growing shader loop** — CPU spatially culls `NebulaVolume` records, uploads only volumes intersecting `[camera ± volumeDist]`, shader iterates that fixed list ($\le 16$).
7. **The volume must not sample the rendered envMap as its radiance** — split the concepts: **palette** (medium albedo, from generator's seed/ramp) and **illumination** (actual lighting: `sunColor` + `irMap` ambient).
8. **Plumes require Euclidean spherical distance falloff (No $L_\infty$ AABBs)** — anchor density envelopes must use $\|p - c\| / r$ with $C^1$ Hermite `smoothstep(1.0, 0.0, dist)` falloffs. Chebyshev box metrics ($L_\infty$) create 90-degree box corners floating in space and are strictly forbidden.
9. **Depth sampling must use LOD 0.0** — both pass A (`volume.glsl`) and pass B (`volblur.glsl`) must sample `texDepth` at base level `0.0`. Bilinear filtering on depth mips across silhouettes causes depth bleeding and premature ray cutoffs.
10. **Bilateral upsample fallback on depth edges** — when 3x3 bilateral gather weights sum to $w_{\text{sum}} < 1\text{e-}4$ at sharp depth edges (e.g., planet silhouette vs. sky), `volblur.glsl` must fall back directly to the center tap `texelFetch(texVol, pH, 0)`. Dividing zero accumulated color by $\epsilon$ creates pure black silhouette outlines.
11. **Lua hash determinism via integer grid** — `NebulaVolumes.lua` must use 32-bit bitwise integer hashing (`hash32`) operating on cell integer coordinates $(i_{cx}, i_{cy}, i_{cz})$ rather than `math.sin` on float world positions to avoid precision loss at large world origins.
12. **Zero-allocation anchor upload** — `Renderer:volume` uses a persistent `self.anchorBytes` buffer instead of allocating 768-byte buffer instances per frame on the C-FFI heap.
13. **Off = renderer-disabled, not density-zero** — test `Config.gpu.nebula = 0` and `nebula.enable = false`, not `density = 0`.
14. **Per-piece perf budget**: base volume $\le 0.65$ ms, reconstruction $\le 0.20$ ms, god-rays $\le 0.30$ ms, lightning $\le 0.10$ ms $\rightarrow$ normal target $\le 0.95$ ms @ 1024x768 2xSS.

---

## 3. Architecture

One half-res world-space volume pass $\rightarrow$ depth-aware bilateral reconstruction with silhouette edge fallback $\rightarrow$ independent god-ray emphasis $\rightarrow$ haze $\rightarrow$ meter $\rightarrow$ tonemap.
```
GBuffer / Lit
│
▼
Volume raymarch      (half-res, world-space density, LOD 0.0 depth, sun scattering + irMap)
│
▼
Reconstruction       (full-res, depth-aware 3x3 gather, LOD 0.0 depth, center-tap edge fallback)
│
▼
God-ray emphasis     (separate low-res shaft pass, own A/B)
│
▼
Haze ──► Exposure meter ──► Tonemap
```

**Medium equation:**

$$\rho(p) = \text{mediumDensity}(p) + \text{anchorEnvelope}(p)$$

$$T *= \exp(-\sigma_t \cdot \rho \cdot ds)$$

$$\text{inscatter} += T \cdot \left(1 - \exp(-\sigma_t \cdot \rho \cdot ds)\right) \cdot \frac{\sigma_s}{\sigma_t} \cdot \left(\text{sunColor} \cdot P(g, \theta) + \text{irMap}\right) \cdot \text{albedo}$$

$$\text{out.rgb} = \text{scene.rgb} \cdot T + \text{inscatter}$$

**Termination & Sky Gate:** $t_{\text{cap}} = (d_{\text{depth}} \ge 900000) ? v_{\text{dist}} : \min(d_{\text{depth}}, v_{\text{dist}})$. Sky pixels ($d \ge 900000$) do not truncate rays early, allowing clouds to occlude stars while preventing double-integration past infinity.

---

## 4. Phases & Status

### Phase 0 — Renderer seam + debug views
- Stub `Renderer:volume()`: half-res RT, LOD 0.0 depth, identity march, depth-aware upsample.
- `nebula.debug` view enum: `off | density | transmittance | lighting | steps | anchors`.

### Phase 1 — Low-frequency participating medium & anisotropic scattering
- World-space snapped cell density, 2 value-noise evals, time drift, exact star transmittance $X \cdot T$.
- Anisotropic Henyey-Greenstein phase $P(g, \theta)$ with $g \approx 0.758$ plus `irMap` ambient.

### Phase 2 — Anchor volumes & spatial culling
- `NebulaVolumes.lua` cell-lattice generator ($CELL = 12000$, 32-bit integer PRNG, $\le 16$ nearest volumes uploaded to `texAnchors` RGBA32F).
- Euclidean spherical plume density with smoothstep falloffs.

### Phase 3 — God-rays (independent product)
- Standalone low-res shaft pass from `starDir`; own A/B on/off controls.

### Phase 4 — LightningEvent & local volumetric flash
- Consume `{position, color, energy, radius, falloff}` as a local light source inside `volume.glsl`.

**Design spec (2026-09-13, pre-implementation):**

A lightning storm is a *weather event*: a storm window (bolts firing over several seconds) that only exists where real cloud is present, is only visible near the player, and decays on its own. The bolt is a `LightningEvent` record consumed by the marching volume pass; the branching bolt itself is a thin life-limited procedural ribbon entity. Nothing in this phase is a texture — the flash is light hitting density.

**Pipeline integration**

```
volume.glsl pass A  ──►  per-step light = sun + irMap + Σ_events LightningEvent(d)
                              ↘
(LightningController.lua: schedule / nucleus / cull)  ──►  GameView renderer:volume({lightning=...})
                              ↘
bolt entity (procedural ribbon, additive) rendered in System:render
```

The flash is a *third light term* inside the half-res march: `light += Σ_event` with the contract from §1.4,
`le = event.color * event.energy / (d² + 1) * exp(-d * σt)`, gated by a soft `clamp(1 - d/event.radius, 0, 1)` hard cutoff so distant events cost nothing. It feeds the **same** `inscatter += tr * (1-stepTr) * σs/σt * light * albedo` accumulation and the **same** plume palette (`mc.yzw`) — so a strike makes the surrounding gas glow — but it must **not touch `tr`**: inscatter is additive; `scene*T + inscatter` ordering is preserved, so a bolt still cannot un-occlude stars behind cloud.

**Shader contract (bounded, mirrors `texAnchors`)**

One persistent 3-column RGBA32F `texLightning` (≤4 rows) re-uploaded only when the active set changes (compare a Lua-built signature to avoid per-frame upload). Row layout:
- col0 = `(pos.xyz, radius)`
- col1 = `(color.rgb, energy)`
- col2 = `(spawnTime, duration, attack, 0)` — the fourth slot is the telegraph ramp baked into the curve (see below)

`volTime` (already uploaded) gives the age: `age = volTime - spawnTime`. The flash envelope is a **rise** then a **decay** — it must be 0 at spawn, peak at `attack`, then fall off — so the telegraph ramp lives *in the curve*, not in per-frame energy re-uploads (which would contradict the "re-upload only on change" optimization):

`flash = smoothstep(0.0, attack, age) * pow(clamp(1.0 - age / duration, 0.0, 1.0), 2.0)`

with `attack ≈ 0.15` for the first bolt of a window (so a bolt never materializes at full energy) and `attack ≈ 0.02` for later strikes (an honest snap). Both rise and decay are pure shader math against constant per-event data; no extra uploads. The loop is `for i < 4` with `if float(i)+0.5 >= lightningCount break` — same early-out pattern as `anchorEnvelope`. A `d > radius` reject precedes the `exp` so idle/distant rows are near-free. Per-step added cost ≈ `count × (length + exp)`, i.e. ≤ 4 × per-step cost of one anchor — expected well inside the **≤ 0.10 ms** budget at half-res; measure with the Profiler before/after and validate in Phase 5.

**The bolt visual (optional-but-specified)**

`LightningBolt.lua`, a non-colliding life-limited Entity (no rigid body, no damage — a storm is weather, not a weapon; killing the player with lightning is out of scope). A jagged polyline from the nucleus toward a 1–2 step random target inside the plume: 12–16 segments, endpoint jitter seeded from the sector seed + strike ordinal (deterministic), additive ribbon ~2–4 units wide, white-hot core fading to `event.color` at the tips, life = event.duration. Drawn in `System:render`, swept by the existing `sweepDestroyed`. Camera exposure and bloom need **no new code** — the meter already adapts to high-luminance pixels and Karis bloom picks up the flash ("lens glare"), which §1.4 explicitly wants.

**Gating — *when you will see one* (answering the review question)**

1. **Vapor gate (prerequisite: real cloud).** Storms never spawn in empty space. The nucleus must be an existing anchor plume from the current `NebulaVolumes.build` cell (one of the same ≤16 anchors already uploaded to `texAnchors`), and its `density × extent` must clear a threshold. No populated plume near the camera ⇒ the controller idles. You see lightning **only when flying through nebula banks** — the same condition that lights the base volume.
2. **Spatial gate.** Events are culled past `strike.radius + margin` from the camera and only ≤4 nearest are uploaded. A storm 20k out is neither lit nor heard; storms are a local, camera-relative phenomenon.
3. **Temporal gate (a window, not a loop).** Deterministic cadence from `hash32(stormSeed, ...)` where **`stormSeed` is the same `self.ltheory.seed` already passed to `NebulaVolumes.build`** — one seed drives both the plume field and the storm schedule, so the "A/B-safe replay" claim is directly verifiable from the sector seed. Clear cooldown 45–120 s between windows; each window lasts 6–14 s and fires 3–12 bolts at 0.4–0.9 s ragged intervals; a single `LightningEvent` lives 0.3–0.5 s; **one storm window active at a time.** Note strikes *can* legitimately overlap — interval (0.4–0.9 s) is shorter than two bolts' combined life — so **2 concurrent events are the normal case, not a corner case**; quality low caps at 2, high at 4, and the budget anchor is the 2-concurrent case (see Testing).
4. **Opt-out + Perf-gating.** Master `Config.gpu.lightningEnable = false` (off = bit-identical frame, renderer-disabled + controller no-op → no audio triggers either) seeded into the renderer's **SETTINGS table as a normal row** — not a one-off boolean — alongside `lightningEnergy`, `lightningRadius`, `lightningQuality` (the same per-field seeding pattern every other feature in `Renderer.lua` uses). Runtime settings live under **`lightning.*` (top-level, matching `nebula.*` / `ssao.*`, NOT `postfx.*`)** so `DebugWindow` auto-builds a dedicated collapsible section: `lightning.enable`, `lightning.energy`, `lightning.radius`, `lightning.quality` (enum, low = 2 / high = 4 concurrent events), `lightning.debug` (enum `off | region | energy` — region draws the storm AABB, energy overlays per-event energy, matching the Phase 0 debug-view discipline).

**Audio hook (data-driven, behind the visual gate)**

One entry in `Config.audio.sfx` — `thunder = { sound = 'thunder', volume = X, minDist = large }` — played as a 3D one-shot at the nucleus on each strike (same pattern as `Turret:fire`), so it attenuates with distance naturally. No thunder asset exists in LFS yet ⇒ the entry is inert-but-valid (missing asset logs and skips, per the engine's resilience convention); hooking gameplay code now means adding the asset later is a pure data change. Storms further than ~minDist are already silent via 3D attenuation — matching the spatial gate.

**Config & state summary**

```
Config.gpu SetSettings row  -- lightningEnable=false, lightningEnergy=1,
                              lightningRadius=3500, lightningQuality=low
lightning.enable   (bool, default false)         -- runtime knob
lightning.energy   (multiplier, default 1)
lightning.radius   (world units, default ~3500)
lightning.quality  (enum, low=2 concurrent / high=4)
lightning.debug    (enum, off|region|energy)
Config.audio.sfx.thunder  (data-driven; missing asset = silent)
```

**Testing**

- Determinism: fixed sector seed → controller replays identical schedule (stormSeed ≡ NebulaVolumes seed); add a `Config.Local.lua` test override (e.g. force one strike at t=1 s) for reproducible screenshots.
- Same-frame A/B: `lightning.debug='energy'` + the banded-split technique used for godrays; off-equivalence via `lightning.enable=false` (frame delta ~0).
- **Budget — combined, not per-pass, and on two tiers.** GTAO (~0.6–1.2 ms) + volume march (two passes, up to 24 steps) + lightning all run simultaneously exactly when this feature matters (flying through a nebula bank during a storm). Measure the *sum* `Render.GTAO + Render.Volume` at the storm trigger moment at low and high quality, on the dev card **and** a mid/low-tier reference (e.g. Mesa llvmpipe / a laptop iGPU) before deciding any of these default on. Anchor the lightning addition on the **2-concurrent** case (the normal overlap, not 1 vs 4 vs 0); Phase 5 gate: combined AO+volume+lightning ≤ 0.95 ms @ 1024×768 2xSS on the low tier, or cut quality.
- **Auto-exposure must be an explicit decision, not a surprise**: the meter's avg/max readout will see a sudden bright flash frame. Check it at both default `postfx.autoexposure.speed` and a fast setting — a post-flash dimming pump is acceptable (real eye adaptation does this and §1.4 wants the glare) but only once we've confirmed it's subtle and tunable.

**Milestones**

1. Volume-pass flash: `texLightning` upload + point-light term with baked rise/decay curve (`attack`/`duration`) + `energy`/`region` debug views + `lightning.*` settings rows.
2. Storm controller: deterministic windows (stormSeed ≡ sector seed), nucleus pick + vapor gate, spatial cull, 2-concurrent overlap math, audio hook.
3. Bolt entity (ribbon + life, additive) + exposure/bloom confirmation — **explicitly at default and fast `postfx.autoexposure.speed`, both tiers**.
4. Validation (validator @ 460, off-equivalence), combined AO+volume+lightning perf audit, docs, status-log close.

### Phase 5 — Polish & performance validation
- Worst-case budget audit, quality matrix verification, documentation closure.

---

## 5. Status Log

- **2026-09-10** — Plan opened on branch `fog-nebula`. External review incorporated.
- **2026-09-11** — **Phases 0, 1, and 2 shipped.** Initial user testing revealed two visual artifacts:
  1. *Black line around planet radius*: Caused by bilateral upsample division-by-zero on sharp depth discontinuities in `volblur.glsl`, combined with depth mip linear filtering in `volume.glsl`.
  2. *Floating cube faces & grid lines*: Caused by $L_\infty$ Chebyshev box metrics in `anchorEnvelope`, sign loss in `cloudSection` via `abs(rd)`, and floating-point `math.sin` hash precision loss in `NebulaVolumes.lua`.
- **2026-09-11** — **Artifact Root Causes Resolved & Validated**:
  - `NebulaVolumes.lua`: Switched to integer cell coordinate hashing via 32-bit bitwise operations (`hash32`).
  - `medium.glsl`: Replaced Chebyshev box metric with Euclidean spherical distance (`length(p - c.xyz) / r`) and $C^1$ smoothstep falloff. Fixed signed ray inverse calculation in `cloudSection`.
  - `volume.glsl`: Standardized depth sampling to LOD `0.0`. Corrected step transmittance integration order.
  - `volblur.glsl`: Standardized depth sampling to LOD `0.0`. Normalized sky depth comparisons ($d \ge 900000 \rightarrow 1000000$). Added edge fallback (`wsum < 1e-4`) to center tap `texelFetch(texVol, pH, 0)`, eliminating black silhouette artifacts.
  - `Renderer.lua`: Cached persistent `self.anchorBytes` memory buffer to eliminate per-frame C-FFI heap allocations inside `Renderer:volume()`.
  - Validator 130/0 @ 460 Core; boot and frame presentation clean across all debug modes.
- **2026-09-13** — **Phase 3 (God-rays) shipped + review fix**:
  - **Review found + fixed a Phase 2 bug**: `NebulaVolumes.lua` stored `local ccz = icy * CELL` (y-cell for z), collapsing every plume's z-position onto a y gridline and killing z-parallax; corrected to `icz * CELL`.
  - `filter/godrays.glsl` (new): independent quarter-res worldray march accumulating only the sun's forward scatter (`hgPhase(godA ≈ 0.92)`), depth/sky-gated exactly like `volume.glsl`; outputs `(shaft, T)`.
  - `filter/godblur.glsl` (new): 16-tap radial crawl toward the sun uv (`exp2(-2i)` weights), composite `scene + acc * godStrength` (mode 0) or raw shaft ×8 debug (mode 1).
  - `Renderer:godrays(med)` two-pass (quarter-res `godView` RGBA16F march → full-res integrate/composite into `buffer1`, `self:swap()`), settings `postfx.godrays.{enable,strength,g,debug}` (debug is a 1-based Settings enum — `(idx-1)` maps to the shader mode, mirroring `volMode`), `godView`/`volView` tied into the renderer release path.
  - `GameView.lua` call site between reconstruction and haze: sun uv from `camera:worldToNDC(camera.pos + starDir·1e5)`, mirrored behind camera, rim-clamped; `'Shaft'` debug bypasses the on/off gate.
  - Validation: **135/0 @ 460 Core**; clean boots; same-frame strength A/B (temp 3-band split) showed scene+shaft ×8 → +18.7 luma, ×1 → +9.6, ×0 → 0 — shaft live, strength knob lands.
  - Debugging note: the shaft read back all zeros for two sessions — the root cause was a **missing `volDensity` uniform in pass A** (`mediumDensity()` returns `volDensity * d`; default 0 ⇒ the whole medium disappears). The march samples the density field only under that gate. When probing a like this, check the medium's own gain uniforms first before suspecting marching or readback.
  - **Post-review hardening (peer shader review, same day):**
    - `godrays.glsl` alpha contract corrected: `a = T` is already folded into `shaft.rgb` via `tr *= stepTr`; the composite must NOT re-apply it (double-occlusion). Header comment no longer claims "composite mask"; alpha stays as a volView-parity/informational slot.
    - `godblur.glsl`: tap count 16 → **8** (weights `exp2(-2i)` are < 0.4% combined past tap 6 — surf of the budget was wasted) and a **blue-noise sub-tap dither** (`t0 = texNoise(uv).x / N`) on the crawl start, reusing the GTAO `texNoise` (bound in pass B) to kill fixed-radial-path stepping/banding.
    - `Renderer:godrays` pass A adds `volMip = 1.0` (declared-by-`medium.glsl` but unread there; kept for full uniform-set parity with the nebula pass).
    - `GameView.lua` sun-gate: new **frustum-edge fade** — `sunFade = clamp(1 - (len - rim)/rim, 0, 1)` eases shafts to zero one rim-depth past the frame edge (behind-camera case included) instead of clamping-and-popping at the rim; the whole pass is **skipped when `sunFade ≤ 1e-3` and debug is off** (`godDbg` gate), so sun-off-screen costs nothing. `godblur` `godStrength` is modulated by `sunFade` (`strength * sunFade`).
    - Verified the `mediumCloud` uniform set is complete in pass A (volDensity/volTime/volFlow/volEvals/volCount/texAnchors/volTint/volTintAmt/starDir/sunColor/σt/σs) — only light is sun+σs·P(godA), no irMap by design. Validator 135/0; boot + frame clean at strength 2.
- **2026-09-17** — **Phase 4 storm rework (user testing: "pulsing purple ball, not lightning")**:
  - Root cause of the ball: `volume.glsl` flash falloff was raw `energy/(d²+1)` at world scales where plumes span 1200–6000 units — at d=100 the gain was already ~0.0015, so only a few dozen units around the strike lit up (a tight ball; purple = white-blue flash over the plume palette). Replaced with a radius-normalized falloff (peak `energy` at strike, ~half at radius/8, soft `(1-d/radius)²` gate to zero at the edge) so the nearby cloud lights up. Same loop, same peak — budget unchanged. Validator 135/0 @ 460 Core.
  - `LightningStorm.lua`: ambient cadence (first window ~3–5 s, cooldowns 12–30 s, windows 8–16 s, 4–12 bolts), sight-range vapor gate (top-4 plumes within nebula radius), each strike picks its own nucleus (deterministic per window+ordinal) so windows read as lightning in many directions; distant strikes still draw ribbons + thunder, only nearby ones load the volume pass. `strikeTarget` now varies per window; fixed the cooldown/windowLength hash-key collision (both used `220+w`).
  - Troubleshooting logs: `fire` lines now carry window/nucleus/dCam/energy/duration, `OPEN` lists all nuclei + distances, `GATE-FAIL` reports volumes count; `Region` debug draws every window nucleus.
- **2026-09-17** — **Phase 4 seed-precision fix (log showed every strike identical: same nucleus, `dur=0.340`)**:
  - Root cause: sector seeds are 64-bit ULL but Lua holds 53-bit ints — `seed*K` rounds to a quantum (~2⁴³) that swallows every small x/y/z/k term, so `hash32` returned ONE constant (measured 0.20107 for all k). Every strike picked the same nucleus/target/duration, bolt jitter collapsed to a straight line, and the plume field itself was a lattice of identical clouds. Fix: `foldSeed` (XOR high/low 32 bits) in `LightningStorm.new` + `NebulaVolumes.build` (same formula, replay link preserved); verified varied hashes + varied plume densities standalone.
  - Latent sign bug exposed by the fix: LuaJIT bitops are signed, so half of all hashes went negative (bolts outside plumes, negative bolt counts) — all three `hash32` copies now return `(h % 2³²)/2³²` in [0,1).
  - Visibility: `pickNuclei` sorts nearest-first (a storm 5k out is a rumor), `activeEvents` drops the `radius+2000` pre-cull (distant strikes cost ~nothing via the shader's per-step reject, and still light their own cloud when viewed), strike life 0.35–0.65 s for readability. Standalone check at the reporter's locale: 2 plumes in 12k, nearest 10.2k — sparse sky, so distant-flash visibility (not local glow) carries this sector.
- **2026-09-17** — **Phase 4 readability pass (strikes live at 9–14k, seen "once, very quick")**:
  - Screen-space strike glow in `GameView:drawLightningUI`: 3 nested quads at the bolt tip (tinted halo → near-white → white core), size `clamp(120000/dCam, 6, 90)` px, so a 10k-out strike reads as a flash instead of a subpixel rumor.
  - Re-strike flicker (`0.72+0.28·sin(43·age)·sin(17·age+1.3)`) on ribbon alpha, glow alpha, AND the `volume.glsl` flash term — all three halves shimmer in agreement instead of one smooth decay. Validator 135/0 @ 460 Core.
  - Denser cadence: strike intervals 0.25–0.6 s (was 0.4–0.9), so windows feel like weather, not isolated pops. Confirmed on the reporter's log: bolt counts/durations/energies/nuclei all vary (seed fix verified live), uploads land every strike.
- **2026-09-17** — **Phase 4 storm scale-up ("want multiples, bigger lightning")**:
  - Concurrency: `texLightning` 4→6 rows (`Renderer:volume`, `volume.glsl` loop), quality caps Low 2→4 / High 4→6, windows 6–14 bolts at 0.15–0.45 s intervals with 0.5–0.9 s lives (typically 2–4 concurrent). Loop early-outs, so quiet frames cost nothing; the 6-live worst case joins the Phase 5 combined AO+volume+lightning perf audit.
  - Bigger: glow sprite `clamp(200000/dCam, 8, 140)` px (was 120000, 6–90), ribbon halo 3 passes at ±2/4/6 px (was 2 at ±1.5/3). Validator 135/0 @ 460 Core; Lua syntax clean ×3.
- **2026-09-17** — **Phase 4 spread pass ("3 in close proximity, want more activity")**:
  - Strikes round-robin across nuclei, rotated per window (`((strike-1+window) % N)+1`) — every window visits every plume evenly instead of uniform-pick clusters; up to 6 host plumes per window (was 4), 8–16 bolts per window (was 6–14). Deterministic. Lua clean.
- **2026-09-17** — **Storm Rate knob ("will any setting create more events?" — none did)**:
  - New `lightning.rate` (0.25–3, default 1, debug panel + `Config.gpu.lightningRate`): multiplies bolts/window and divides strike intervals together, so rate 2 ≈ double the bolts at double pace. Replay stays deterministic for fixed settings; the quality cap (4/6 concurrent volume events) still bounds GPU overlap, so cranking it can't blow the march budget — excess strikes keep ribbons + thunder, they just share volume rows oldest-first. Lua clean ×3.
- **2026-09-17** — **Thunder audibility + forks + target spread**:
  - `res/sound/thunder.wav` is real (3.3 s mono 22 kHz, healthy levels, natural decay) and `onLightningStrike` was already wired — but `thunder.minDist = 500` vs strikes at 5–12k meant total rolloff silence. Raised to 4000 so distant storms rumble and near ones crack.
  - `LightningBolt` grows 2 deterministic side forks (5 segments, 25–45% of parent length, same hash family salted per branch) drawn thinner than the parent channel; verified standalone (15-node main, 6-node forks).
  - `strikeTarget` jitter 0.45→0.65 of plume extent so Energy crosses spread within a plume instead of bunching.
- **2026-09-17** — **Storm preset + Coverage knob ("ideal settings", "denser storm clouds")**:
  - New `nebula.coverage` (0.25–2.5, default 1.0, panel + `Config.gpu.nebulaCoverage`): scales bank extents AND core density together (1.6 ≈ thick storm banks, 0.5 ≈ wisps); 1.0 reproduces the signed-off field exactly. Baked into `cellKey` so the panel slider rebuilds live. Standalone: extent ratio exactly 1.60 at coverage 1.6. Side effect: vapor scores scale with c², so high coverage also hosts more storms.
  - New `script/Config.Local.lua` storm preset (untracked, delete to restore stock): nebula High/2.2/1.6/14000, lightning on/High/22/6000/rate 2/debug Off, bloom 1.0/1.0. Boot = storm showcase; the only remaining toggle is `lightning.enable`.
- **2026-09-18** — **Freelancer-thick preset**: coverage 1.6→2.0, `nebula.g` 0→0.4 (forward-scatter sun-side rims — the biggest untested Freelancer lever), density/background unchanged. Same step count, so ~zero fps delta.
- **2026-09-18** — **March banding fix ("greenish waves that follow me, only nebula-off clears them")**:
  - Root cause: pass A sampled at fixed `(i+0.5)*step` with the bound `texNoise` LUT never read — textbook concentric band shells around the camera that sweep while flying. Invisible at stock gain, obvious at the reporter's 2.44 density × 1.6 coverage (~4× contrast); green tint is that seed's plume palette.
  - Fix: static blue-noise ray-start jitter `(i+bn)*step` (GTAO LUT, `textureSize`-driven, no magic constants), clamped to `tCap` so the last sample can't leak past occluders. Bands become stable fine grain. Validator 135/0 @ 460 Core.
- **2026-09-18** — **Background wash, the actual waves (jitter fix held, waves persisted)**:
  - Correction: `mediumDensity` returns `volDensity × d` with d up to 1 — at the reporter's 2.438 the *everywhere-field* alone reaches OD ≈ 2 over a 14k march (whole sky ~87% cloud), drifting on `volFlow` and tinted by this seed's green-teal `irMap`. That's persistent flying wash the jitter fix can't touch; stock density 1 (≈0.8 OD) kept it subtle, which is why it "appeared with the panel defaults".
  - Fix: `nebula.background` (0–1.5, default 1.0 = old look exactly) scaling only the background term — anchors keep Lua density, so banks stay thick while the sky clears. Set in *both* volume and godrays passes (godrays shares `medium.glsl`; an unset uniform defaults to 0 and would have silently killed its background term). Preset 0.4. Validator 135/0 @ 460 Core; Lua ×3 clean.
- **2026-09-17** — **FOV-aware spawning ("calculate where lightning appears by FOV")**:
  - `GameView:onUpdate` passes `camDir` + `fovY` into the storm ctx; `pickNuclei` flags plumes inside the view cone (half-FOV + 25° margin for bank-sized clouds) and sorts in-view first, nearest inside each group. Round-robin then plays storms where the player looks; off-screen plumes stay in the rotation (turn toward the thunder), just later. `OPEN` log gains `inview=N` to verify. Sort order unit-checked standalone. Lua clean ×2.
- **2026-09-18** — **Phase 4 M3/M4 + Phase 5 headless test campaign (seed 987654321, 1024x768 2xSS, TEMP env hooks, reverted after)**:
  - Method: fixed `seedGlobal`, `PHX_DEBUG_DUMP` frame PNGs (albedo/normal/depth/lit/final), `[T METER]` exposure+live-count series, `[T PERF]` CPU ms around `Renderer:volume`/`renderAO`; runs on :0/XWayland, muted. Harness: warm-state run-to-run noise floor RMSE ~0.02 (cold first run diverges ~0.13 — dt-history); depth buffer bit-identical across runs.
  - Off-equivalence (M4): quiet-frame ON-vs-OFF 0.0253/0.0120/0.0113 (final/lit/albedo) vs OFF-vs-OFF 0.0203/0.0103/0.0083 and ON-vs-OFF-repeat 0.0268/0.0131/0.0120 — delta inside noise on all buffers. HOLDS.
  - Storm cost: 6-live-strike window vol avg 0.195–0.246 ms vs OFF 0.199 ms (noise) — lightning addition unmeasurable, ≤0.10 ms budget HOLDS by margin. Max spikes 0.6–0.76 ms (upload frames).
  - Combined AO+volume (M4/Phase 5): AO Half/4dir/3step avg 0.254 ms; sum 0.50 ms « 0.95 ms gate (dev card, CPU-side timing; GL-async caveat).
  - Quality matrix (partial): Low(8-step) vs High(24-step) RMSE 0.064 (visibly different) at identical perf (±noise, call-bound on 7900 XTX) — keep High default on capable GPUs.
  - Exposure/bloom (M3): meter PROVEN LIVE (sun on/off moves it) but unmoved by the storm at default AND fast (0.05) speed — strikes don't shift avg/max vs the sun-dominated frame, so no pump, no surprise. Bloom cores fed (storm-vs-off max-pixel delta ~1.0, ~16k px > 8%). Verdict: §1.4's "auto-exposure adapts to flashes" does not occur at these ranges — physically honest (distant sheet lightning doesn't pump eyes either); close-strike magnitude unmeasured (test seed strikes were distant).
  - Light-switch update: AE-pump suspect DISPROVEN (meter flat even at fast speed) — remaining suspects are cell-boundary plume swaps (roadmap #13 crossfade) and the godrays frustum-edge skip.
  - Open: low-tier reference numbers (llvmpipe can't do GL 4.6 core — no low-tier run possible here), thunder-by-ear (user sound issue, parked), spec-text-vs-implementation sync (§1.4 formula, cadence/cap numbers, thunder-asset-missing note all stale).
- **2026-09-18** — **Pre-merge cleanup**: all `[lt]` storm prints deleted (CLOSE/fire/OPEN/GATE-FAIL/upload/probe + dead `camPos`/`_camPos`/`debugStormCam` code); zero remaining in `script/`. Silent-boot verified headless (seed 987654321, dumps saved, exit 0, no errors). Found that `dump_2_lit.png` never saves (call site guards on `__dumpGBuffer` instead of `__dumpLit`) — left as-is, one-word fix on request. Also repaired `script/Config.Local.lua`: the storm preset write had clobbered its tracked content (debug/vsync/gen setup) — merged, now purely additive (+33/-0).
