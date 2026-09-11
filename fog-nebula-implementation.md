# Nebula Fog / Dust Volume + Lightning Storm — Implementation Plan (branch: `fog-nebula`)

Goal: build a **participating-media renderer with stylized anisotropic nebula lighting** — not a
named-after-one-aesthetic effect. Freelancer/Starlancer are the *visual reference*, not the
implementation scope, because the same medium should later serve dust, gas, planetary haze,
engine smoke, storm volumes, and nebulae.

Concretely: fly through drifting volumetric dust and nebula plumes that occlude the stars, glow
against the sun with anisotropic forward scatter, get cut by independent god-rays, and are torn
periodically by **lightning storms** — a branching bolt, a white-hot flash, and a *local*
volumetric light that makes the cloud around the strike glow and decay. All opt-out, Perf-gated,
and equivalence-tested like GTAO was.

Base branch `main` (GTAO + distance haze merged). Plan opened **2026-09-10**; reviewed by an
LLM renderer engineer the same day and revised (§2). Status at the bottom.

---

## 1. The asks (verbatim intent, kept as features)

1. **Volumetric nebula/dust** — fly-through volume with parallax, not billboards or a 2D tint.
2. **Sun-lit dust with anisotropy + god-rays** — forward-scatter phase, independent shaft pass.
3. **Stars occluded by dust** — the sky behind a thick bank dims (`scene * T + inscatter`, never
   `scene + additive`).
4. **Lightning storm spike** — bolt + flash + the dust lights up **locally** at the strike, then
   decays; a weather event, not a texture; audio hook data-driven behind the visual gate.
5. **Nebula as sector content** — anchor volumes (real local clouds you can orbit), palette from
   the same generator that makes the sky.
6. **Opt-out + Perf-gated + A/B-toggleable + debug modes** — off = bit-identical frame; a debug
   visualization enum so tuning stops being "summon screenshots by feel".

## 2. Review feedback incorporated (2026-09-10)

An independent renderer-engineer review (LLM) was solicited; its high-value corrections are now
hard requirements, not suggestions:

1. **Density field is world-space, not camera-anchored** — `density(worldPos)`, maintained in a
   camera-following cell that *snaps on a large grid* (world pos = eye + dir · t). Camera-space
   lobes cause swimming (clouds rotate/translate with you) and break streaming. Snapping cell =
   deterministic coords, infinite traversal, no giant world primitive. (§3)
2. **No multi-octave FBM in Phase 1** — start with 2 noise evals (low-freq coherent + one
   higher-freq modulation). Large-scale structure beats fractal detail; detail can come from
   lighting + jitter. Add octaves only if A/B shows they buy something. (§3, §5)
3. **Transfer/scattering equation is the explicit contract (ADR math)** — `sigma_t` (absorption +
   scattering) separated from `sigma_s` (scattering); accumulation via `T *= exp(-sigma_t·ρ·ds)`
   and `inscatter += T·sigma_s·ρ·lighting·ds`; composite `scene*T + inscatter`. This is what
   makes "opaque core that still glows past its silhouette" controllable. (§3)
4. **Nested full sun raymarch is prohibited in Phase 1** — `sunTrans` is a fixed-cost
   approximation (`exp(-ρ·sunShadowDistance·sigmaSolar)` or ≤4 sun samples per volume sample).
   24 camera steps × 24 sun steps would blow the budget; Phase 3 may refine. (§3)
5. **God-rays are a separate pass boundary** — "what does the medium do to light" vs "where do we
   emphasize directional shafts" are separate products with separate A/B on/off knobs. (§4)
6. **Anchors use a bounded active-volume interface, not an ever-growing shader loop** — CPU
   spatially culls `NebulaVolume` records (center/halfExtent/seed/density/tint/noiseScale),
   uploads only volumes intersecting `[camera ± volumeDist]`, shader iterates that fixed list.
   Streaming-ready for #13. (§3)
7. **The volume must not sample the rendered envMap as its radiance** — env-influencing-env is
   visually weird. Split the concepts: **palette** (medium albedo, from the nebula generator's
   seed/ramp) and **illumination** (actual lighting: `sunColor`/`sunFill` + `irMap` ambient). The
   `irMap` (already-integrated ambient gradient) is the medium's base light — one of the
   strongest ideas in the plan. (§3)
8. **Lightning is a first-class `LightingEvent`** — one data record
   `{position, color, energy, radius, falloff, startTime, duration, seed}` drives bolt +
   local volumetric light + exposure contribution + bloom + audio. Never a pile of visual hacks.
   (§6)
9. **Authored flash, responsive exposure** — the flash is the light itself; autoexposure merely
   *responds* (otherwise flash→meter→scene-darkens feedback muddies it). (§6)
10. **Bolt = procedural camera-facing ribbon** (deterministic from storm seed; branching
    topology via recursive midpoint displacement); GPUParticles reserved for sparks/secondary
    arcs/storm particulate — each system does what it's good at. (§6)
11. **Temporal reprojection is a Phase-5+ candidate, not Phase 1** (motion/history/invalidation
    are a separate bug class; get the static volume right first). (§8)
12. **Three termination conditions, explicitly**: `tEnd = min(sceneDepth, volumeDist,
    volumeIntersectionEnd)`, `tStart = volumeIntersectionStart` — skip empty space before an
    anchor; major optimization once local nebulae exist. (§3)
13. **Off = renderer-disabled, not density-zero** — the A/B contract means *no allocation, no
    pass, no uniform binds, no shader invocation, no state mutation* (a zero-density pass can
    still perturb FP/render-target behavior). Test `Config.gpu.nebula = 0` and
    `nebula.enable = false`, not `density = 0`. (§7)
14. **Per-piece perf budget, not one number** — base volume ≤0.65, reconstruction ≤0.20,
    god-rays ≤0.30, lightning ≤0.10 → normal target ≤0.95 ms; measured at *worst-case* density,
    max anchor count, max lightning complexity at **1024×768 @2×SS**, not the prettiest scene. (§7)
15. **Quality ladder is a resource matrix internally, one public enum externally** — Q0 disabled /
    Q1 half-res 8 steps 2 evals no shafts / Q2 half-res 16 steps 2–3 evals optional shafts /
    Q3 half-res 24 steps 3–4 evals shafts + better reconstruction. Change internals without
    breaking the settings contract. (§5)
16. **Debug modes**: `nebula.debug = off | density | transmittance | lighting | steps | anchors`
    (black→white density, black→opaque transmittance, false-color step count, AABB overlays). (§5)
17. **Test fixtures**, not subjective screenshots: A = white sun/black sky (anisotropy, sun
    lighting, density, transmittance); B = stars behind dense volume (occlusion `X*T`, depth
    termination, sky gate); C = lightning in dense volume (local flash, bolt, exposure, bloom,
    decay, no residual state). (§7)

---

## 3. Architecture

One half-res world-space volume pass → depth-aware reconstruction → independent god-ray emphasis
→ haze → meter → tonemap. No new rendering subsystem — this is the GTAO/haze pass family.

```
GBuffer / Lit
   │
   ▼
Volume raymarch      (half-res, world-space density, sun scattering + irMap ambient)
   ▼
Reconstruction        (depth-aware upsample/denoise — the AO discipline)
   ▼
God-ray emphasis      (separate low-res shaft pass, own A/B)
   ▼
Haze
   ▼
Exposure meter        (pre-meter: storms read correctly)
   ▼
Tonemap
```

**Conceptual dataflow (what feeds what):**

```
Nebula generator
   ├── envMap    → sky            (unchanged; the volume does NOT sample this for radiance)
   ├── irMap     → ambient medium illumination   (sample as base light)
   └── palette   → medium albedo                (generator ramp, seeded, art-directable)
Anchors/cells → density field
LightningEvent → bolt + volume lighting + exposure + bloom + audio
```

**Medium equation (the contract — put on the wall):**

```
ρ(p)  = sectorMedium(worldPos) * noise(worldPos * scale + drift)      // + modulations from anchors
T     += -sigma_t * ρ * ds           (accumulate transmittance; T starts at 1)
inscatter += T * sigma_s * ρ * light * ds
out.rgb = scene.rgb * T + inscatter
sigma_t = absorption + scattering      // separate from sigma_s = scattering
sunLight = irMap_ambient + sunColor * Phase(g, sunDir·viewDir) * sunTrans  // sunTrans ≈ fixed-cost (no nested ray)
```

**Termination:** `tEnd = min(sceneDepth, volumeDist, volumeIntersectionEnd)` and
`tStart = volumeIntersectionStart` (skip empty space before anchors). Sky gate reuses the haze
lesson: `zBufferL >= 950000` = sky — the volume can still *occlude* it via `T` (that's the whole
point of star occlusion), but must not double-integrate past it.

**Density field:** animated off a *snapped* world cell (large-scale grid under the camera) so cloud
drift is deterministic (`seedGlobal`-seeded, minutes-long phase — no per-frame `timeSeed`, the
GTAO lesson), coverage simply follows the player with no swimming.

**Anchors:** per-frame CPU cull → compact `NebulaVolume` list upload; shader evaluates that
bounded list only. Streaming (#13) later just means feeding the culler from the streaming system.

**Post-pass discipline (regenerate from the AGENTS gotchas):** autovars (`envMap`/`irMap`/`starDir`
`/sunColor`) are popped at `System:endRender`; every binding is explicit
(`Shader.SetTexCube`/`SetFloat3`) or `ShaderVar.Push`. Matrix re-push around the pass (`mViewInv`/
`mProjInv`) exactly as the haze pass already does. Reject `#autovar` additions for this pass.

## 4. Phases (each = validator + boot + A/B, self-contained)

### Phase 0 — renderer seam + debug views
- Stub `Renderer:volume()`: half-res RT, read depth, identity march, depth-aware upsample.
  Confirm matrix re-push, explicit env/ir/star uniforms, blue-noise jitter here, profiler
  `Render.Volume`, `nebula.*` settings + `Config.gpu` seeds, and the debug-view enum
  (density/transmittance/lighting/steps/anchors) end-to-end.
- Acceptance: pass runs at both reses; `enable=false` is a true no-op (§2.13); validator green;
  boot clean; A/B toggles.
- Deliverables: `filter/volume.glsl` stub, `nebula.debug` views, settings chassis, profiler label.

### Phase 1 — low-frequency participating medium with correct transmittance
- World-space density (snapped cell), **2 noise evals** (low-freq coherent + one modulation),
  time-drift, correct `scene*T + inscatter` (star occlusion visible), half-res + blue noise +
  upsample/denoise. **Fixed-cost sunTrans only** (§2.4).
- Tuning: `nebula.{enable,density,color,tint,steps,radius,g; sunShadowDistance}`.
- Acceptance: flying banks through patches with parallax (no swimming); **Fixture B** — starfield
  reads `X*T` behind a dense bank; **Fixture A** lit. Gate ≤0.65 ms; off = no-op.

### Phase 1.5 — anisotropic sun scattering
- Add `Phase(g, θ)` forward-scatter term + `irMap` ambient base light; `g ≈ 0.758` (matches the
  planet atmosphere's `g`, `ltheory-planet-research.md`).
- Acceptance: sun-side cloud self-glow warm; changing `g` 0 → 0.9 is visibly "rock → jewel".
  Fixture A.

### Phase 2 — anchor volumes + spatial culling
- `NebulaVolume` records (center/extent/seed/density/tint/noiseScale) from a per-sector structure;
  CPU cull to the active list; parallax-correct orbit around plumes; color descends from the same
  `Gen('Nebula')` palette (*albedo*, not envMap sampling — §2.7); `tStart/tEnd` skip-empty-space
  optimization.
- Acceptance: orbiting a plume reads layered parallax vs the fixed sky; overlapping plumes
  composite; culled outside `volumeDist`. Debug anchors overlay + steps view.

### Phase 3 — god-rays (independent product)
- Standalone low-res shaft pass (from `starDir`, `sunTrans`-derived emphasis OR its own shaft
  integral — still no nested full raymarch of the volume); own `scan.show`, `intensity`, `width`,
  `quality`; own A/B on/off without touching the volume.
- Acceptance: sun-in-dust = money shot, not noise; Fixture A with shafts; ≤0.30 ms.

### Phase 4 — LightningEvent + local volumetric flash
- One event record (§2.8). The volume pass consumes `{position,color,energy,radius,falloff}` as a
  **local light** — distance/phase-dependent illumination of the cloud (the "cloud lights up
  *around* the bolt" shot), plus authored flash light (150–300 ms decay) with exposure merely
  responsive, plus optional bloom reach and an `audio` slot.
- Acceptance: Fixture C (dense volume + strike → local glow, decay, no residual bloom level);
  clears fault-free; ≤0.10 ms strike overhead.

### Phase 4.5 — bolt rendering
- Procedural camera-facing ribbon mesh, deterministic from the storm seed (recursion-branch
  topology, stable endpoints, controllable silhouette, variable branch width). GPUParticles later
  for sparks/secondary arcs/storm particulate.
- Acceptance: strikes vary by seed; never overlap-steal; look stable across camera motion.

### Phase 5 — performance/equivalence/polish, docs close
- Worst-case budget audit (§2.14), quality-matrix defaults locked, numeric A/B screenshots,
  `ssao-gtao`-style close entry here, AGENTS.md + ROADMAP.md updated, user sign-off, merge to
  `main`.

### Later (candidate backlog, not committed)
- Temporal reprojection (half-res accumulation) — only after the static volume is stable.
- Richer FBM/octaves, planet-haze/engine-smoke on the same medium, streaming-fed anchors (#13),
  storm weather per sector.

## 5. Tuning contract & quality ladder

Public enum `nebula.quality` (advance to `render.nebula.quality` if the family grows);
internally a **resource matrix** so implementation can change without contract churn:

```
Q0  disabled / legacy Dust billboards
Q1  half-res | 8 steps  | 2 noise evals | no shafts
Q2  half-res | 16 steps | 2–3 evals    | optional shafts
Q3  half-res | 24 steps | 3–4 evals    | shafts + better reconstruction
```

Debug views: `nebula.debug = off | density | transmittance | lighting | steps | anchors`.
Enum-index seeding contract applies (`Settings.addEnum` → index, `sunShadowIdx` lesson).

## 6. LightningEvent (the first-class record)

```
LightningEvent
  position, color, energy, radius, falloff
  startTime, duration, seed
  ├─ emissive bolt        (ribbon mesh, §4.5)
  ├─ local volumetric light  (volume pass consumes it — distance/phase falloff)
  ├─ exposure contribution (emergent — meter just responds)
  ├─ bloom reach           (optional)
  └─ audio event            (Config.audio.sfx.lightning — behind the visual gate)
```

## 7. Verification & the equivalence contract

- **Off = renderer-disabled** (no alloc/pass/uniform/shader/state), tested via
  `Config.gpu.nebula = 0` and `nebula.enable = false` — *not* `density = 0`.
- Validator (`python3 configure.py test`, 0 FAIL) on every shader change; Luajit `SYNTAX-OK`;
  clean boots.
- Budget per piece (§2.14) measured at worst-case density / max anchors / max lightning,
  **1024×768 @2×SS** on RX 7900 XTX (GTAO bench methodology).
- **Fixtures** (§2.17): A white sun/black sky · B stars behind dense volume (star occlusion is a
  validator fixture — `stars = X*T`, and the failure mode `scene + additive fog` is forbidden) ·
  C lightning in dense volume. Phase screenshots go to `/screenshot` with a purpose, not vibes.
- User is the visual instrument (model cannot view images); numeric checks on saved frames.

## 8. Risks / gates

- Nested sun raymarch creeping in (§2.4) — prohibited in the ADR.
- Camera-anchored swimming (§2.1) — world-space snapped cell required.
- envMap self-influence (§2.7) — palette vs illumination split is mandatory.
- Scene+additive instead of scene*T+inscatter — Fixture B catches it in CI-style A/B.
- Half-res silhouette artifacts — AO's depth-aware upsample/denoise discipline, not bilinear.
- Storms eating the budget via boom-glow — LightningEvent radius clamped by `nebula.quality`.
- Settings contract — enum index seeding, `Config.gpu` defaults must seed Settings exactly.

## 9. Dependencies / ordering

Pure post-chain work on committed infrastructure (worldray posts, `envMap`, GPUParticles, panel
contract). Independent of #13 streaming/LOD (anchors are authored; streaming later only feeds the
culler). Audio (zipper + rapid-SFX) is orthogonal and may light up the storm sound after the
visual gate is committed.

## 10. Status log

- **2026-09-10** — plan opened on branch `fog-nebula` (from `main`). External renderer-engineer
  review same day; §2 corrections folded in (world-cell density, transfer-equation contract,
  fixed-cost sun shadow, bounded anchor list, palette/illumination split, LightningEvent,
  per-piece budget, fixtures, debug views, no-op-commit contract). Phase 0 next.