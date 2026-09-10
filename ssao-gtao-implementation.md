# SSAO / GTAO — Implementation Plan (branch: `ssao-gtao`)

Goal: ship screen-space ambient occlusion for the deferred renderer, tuned for the
"wow" of **space**: soft contact darkening that makes near-field geometry — asteroid
pockmarks, ship hull canyons, planet crater relief — feel solid and heavy — without
shadowing the sun (ambient-only), without flicker, for ~0.5 ms.

Verified today what AO can actually see (G-buffer audit, 2026-09-09): every opaque
render — asteroids, ships, and the planet terrain sphere (`material/planet` under
`BlendMode.Disabled`) — writes `zBufferL` + `buffer1`, so GTAO shadows them and they
mutually occlude. The **atmosphere** shell is NOT deferred (see §1 audit note), and
**no ring entities exist**, so the original "planet-ring self-shadowing" promise was
dropped from this plan.
Controls land in the Debug panel automatically (Settings prefix `ssao.*`), and the
branch leaves everything OPT-OUT-able: `ssao.enable=false` reproduces the current
frame exactly.

Status: **Phase A landed** (2026-09-09). All Phase A items are in: passes 1/2/3 wired
(view-ray, horizon slice integral, depth-aware full-res upsample+denoise), the
material-aware `global.glsl` dispatch (Diffuse/Ice full AO, Metal at 15% strength and
`aoRadius*2`, `ssao.show` A/B preview), `ssao.*` settings (9) + `Config.gpu` seeds,
AO-off = white fallback + `aoStrength 0` (reproduces the pre-AO frame exactly),
validator green (129 OK / 0 FAIL), clean boot. Perf gate (§7) measured and satisfied:
`Render.AO` **avg 0.056 ms** at 4800×2700 @2x SS on RX 7900 XTX (≈0.014 ms projected at
the 1024×768 @2x SS gate, vs ≤1.2 ms target); lab memory at that res ≈ 42 MB
(aoView RGBA16F half-res + aoRaw R8 + aoFull R8), ≈10 MB at the gate res — the plan's
"<3 MB" estimate was optimistic (full-res aoFull alone exceeds it at larger windows).
A real bug was found & fixed during bring-up: the horizon integral was dividing by
`dirCount` twice (`sliceVisibility` already averages) → uniform 0.25 everywhere.
Phases B/C/D still pending (§8 has the B notes).

---

## 1. Why GTAO, and why here

- The light passes already reconstruct the world from `zBufferL` (linear eye
  distance, `res/shader/fragment/light/point.glsl` does `worldOrigin + depth *
  normalize(worldDir)`). An AO pass uses the same G-buffer — nothing new to render.
- Ambient comes from exactly ONE place: `light/global.glsl` (irMap + the sun
  hemisphere fill). Multiplying the *ambient* term by an AO factor in that pass =
  correct AO semantics (AO occludes indirect light, never the sun itself), costs
  one extra texture fetch, and cannot break the direct-sun/dir-shadow work.
- **GTAO** (Jimenez 2016, "Practical Real-Time Strategies for Accurate Indirect
  Occlusion") is the modern standard: horizon-based per-pixel, bilinear-tapped,
  thickness-aware. It reads ~2× fewer samples than classic push-hemisphere SSAO for
  the same quality and produces crisper, correlation-free darkening — exactly what
  we want on procedural craters and hand-drawn ship hulls. Implementation is only
  modestly more complex than naive SSAO, so there is no reason to ship naive SSAO.

### Technique summary
For each pixel: build a local orthonormal frame from the surface normal, slice the
tangent hemisphere into N azimuthal directions (rotated per-pixel by blue noise),
and along each slice march P steps reading the reconstructed view-space surface.
Track the maximum "horizon" elevation angle above the tangent plane on both sides.
The occlusion is the integrated cosine-window of the visible sky above that
horizon. A thickness heuristic biases against marking thin silhouettes (asteroid
rims) as fully occluded. The result is `ao ∈ [0,1]`, stored at half/quarter res and
bilateral-blurred.

### The two ingredients the engine already gives us
- `zBufferL` is **linear eye distance** (`setDepth()` = `length(pos-eye)` in
  `res/shader/include/deferred.glsl`). Distance along a ray is exactly what GTAO
  wants for radius/thickness math (no near/far plane curve distortion from a log
  depth buffer — the G-buffer depth is planar-encoded for writes but the light
  passes reconstruct true world positions, which is what we consume).
- `createBuffer()` in `Renderer.lua` calls `genMipmap()`, so `zBufferL` (R32F)
  already has real mip levels. Sampling at `aoMip = log2(sx/aoSx)` gives us a
  **free** downsampled depth for tap reads — no dedicated downsampling pass and no
  extra depth buffer.

### G-buffer audit (2026-09-09) — what AO can and can't see
- **In the G-buffer (AO shadows these, they mutually occlude):** every
  `BlendMode.Disabled` opaque render — asteroids, ships, stations, and the planet's
  terrain sphere (`material/planet`, `Planet.lua:47-63`). They write `zBufferL` +
  `buffer1`.
- **NOT in the G-buffer:** the atmosphere shell (`Planet.lua:65-89`,
  `BlendMode.Alpha` + `PreMultAlpha`, `material/atmosphere`) and the UI render AFTER
  lighting via `Renderer:startAlpha`. AO therefore does not apply to the atmosphere
  (fine — it is emissive) and the atmosphere cannot occlude anything. Consequence:
  expect NO contact darkening on the atmosphere's inner rim; that needs its own term
  later, not AO. Do not "fix" this by drawing the shell into the G-buffer.
- **No planet rings exist in this codebase** (no ring mesh/shader). Nothing to defer
  or promise; this branch targets asteroid/ship/planet-crater AO only. If rings are
  added later they must render opaque to participate in AO. A recoverable reference
  exists (not in this repo): upstream ltheory's ring shader, forward/alpha `.jsl`,
  few dozen lines — flat disc in the ring plane, radial UV, 1D `rings` band-LUT,
  inline cookTorrance + a manual planet-shadow ray-march (auto-correct with our sun
  shadow map if converted to an opaque deferred disc). Full source preserved below
  (verbatim, recovered 2026-09-09):

  ```glsl
  #include frag.jsl
  #include math.jsl
  #include noise.jsl
  #include lighting.jsl
  #include scattering.jsl

  layout(location=15) FRAG_IN vec3 normal;
  layout(location=13) FRAG_IN vec3 position;
  layout(location=19) FRAG_IN vec3 origin;

  uniform sampler2D rings;

  void main() {
    float r = length(2.0 * (uv - 0.5));
    float d = texture2D(rings, vec2(r, 0.5)).x;
    vec3 V = eye - position;

    /* Alpha. */
    float alpha = 1.0;
    alpha *= 0.5;
    alpha *= 1.0 - exp(-64.0 * max(0.0, r - 0.5));
    alpha *= d * exp(-64.0 * max(0.0, r - 0.8));
    alpha *= 1.0 - exp(-pow2(1.5 * length(V) / scale.x));
    alpha = saturate(alpha);
    alpha *= 1.0 - getFoginess(length(V));

    vec3 c = mix(vec3(0.5, 0.8, 0.9), vec3(1.0, 1.0, 1.0), d);

    /* Lighting. */
    vec3 L = normalize(starPos);
    vec3 n = normalize(normal);
    n *= sign(dot(n, V));
    float l = 10000.0 * cookTorrance(L, position, n, 0.10, 1.0);
    c *= 1.0 + l;

    /* Shadow. */
    vec3 toOrigin = (origin - position);
    vec3 toStar = normalize(starPos - position);
    float OS = dot(toOrigin, toStar);
    float rshadow = max(0.0, length(toOrigin - toStar * OS) / scale.x - 1.0);
    if (OS > 0.0)
      c *= 1.0 - exp(-32.0 / max(0.0, length(toOrigin) / scale.x - 1.0) * pow2(rshadow));
    alpha *= sqrt(abs(dot(normal, normalize(V))));

    RETURN(vec4(c, alpha));
  }
  ```
  Conversion notes when that feature lands: geometry = flat radial-UV disc in the ring
  plane (tilted with the planet), NOT camera-facing; `rings` gradient → procedural
  banded albedo; lighting + fog + fades move to the deferred light passes; the
  manual planet-shadow march is replaced by the existing sun shadow map; only the
  alpha fades are lossy through the G-buffer (replace inner/outer/edge fades with
  `discard`/alpha-cut in an `BlendMode.Disabled` material so AO + sun shadows both
  apply, per feedback #1).
- **Sky depth semantics:** `Renderer:start` binds `zBufferL` as a color target and
  `Draw.Clear(0,0,0,0)` (`Renderer.lua:434,437`) zeros it on un-drawn (sky) pixels;
  `setDepth()` writes `length(pos-eye) > 0`. So `skyMask(dist ≈ 0)` in pass 2 is
  CORRECT (0 = sky, not far-plane). Kept intentionally; documented so it is never
  "helpfully" flipped.

---

## 2. Pipeline & integration

New passes live INSIDE the `Lighting` block in `GameView.lua:draw`, immediately
**before the `light/global` ambient pass** (they need the camera matrices and the
`sunColor`/`sunFill` autovars still staged; the `worldray` vertex provides
`worldOrigin`/`worldDir` from `mProjInv`/`mViewInv` like every other light pass).

```
Opaque pass (G-buffer written: buffer0 albedo, buffer1 normal+rough+mat, zBufferL depth)
   │
   ├─ AO pass 1  aoview   : zBufferL(mip) ──▶ aoView   (RGBA16F, half-res; rgb=view-space pos, a=NDotV)
   ├─ AO pass 2  ao       : aoView ──▶ aoRaw  (R8,      half-res; GTAO horizon integral)
   ├─ AO pass 3  aoblur   : aoRaw ──▶ aoFull (R8,      full-res; depth-aware upsample + bilateral denoise)
   │
   ├─ global pass    : ambient = (irMap + sunFill)*AO   ◀── texAO = aoFull (or 1x1 white when off)
   ├─ dir pass       : direct sun (UNTOUCHED by AO)
   ├─ point pass     : local lights (UNTOUCHED)
   ├─ composite      : albedo * lighting
   └─ post chain / UI
```

AO resources (created lazily in `GameView:Create`, torn down like the other cached
textures):
- `self.aoView` — RGBA16F @ (sx/2, sy/2). rgb = view-space position, a = N·V.
- `self.aoRaw`  — R8 @ (sx/2, sy/2) (GTAO horizon-integral output).
- `self.aoFull` — R8 @ (sx, sy) (depth-aware upsample + denoise — THE texture
  `global.glsl` samples; not a plain bilinear upsample, see §3 pass 3).
- `self.aoWhite` — persistent **1×1 white R8** fallback bound whenever SSAO is off
  (mirrors the magenta-fallback pattern) — so `light/global.glsl` can sample
  `texAO` unconditionally and skip a branch.
- Optional `self.aoNoise` — 64×64 blue-noise R8 LUT (generated once on the CPU
  side with a tiny Lua XOR-shift loop, `Tex2D.Create(64,64,TexFormat.R8)`), tiled +
  frame-rotated per frame to kill banding with far fewer slices.

`Renderer:free()` gains the frees (guard like the others). Everything is only
allocated if `Settings.get('ssao.enable')` was ever true or if `ssao.quality` is on
so the texture-heavy path stays off on weak GPUs until the user opts in (see §6).

### The `light/global.glsl` hook
Add `uniform sampler2D texAO;` + `uniform float aoStrength;` and, inside each
`mat` ambient branch, multiply the *ambient* contribution:
```glsl
float aoF = mix(1.0, ao, aoStrength);                 // ao = texture(texAO, uv).r (aoFull, full-res)
// Diffuse & Ice:  ambient = irMap hemisphere + sun hemisphere fill; AO scales ALL of it
light += (linear(textureLod(irMap, N, 8.0).xyz) * envScale + fill) * aoF;
// Metal:          env reflection already carries its own occlusion cues — hold AO to 15%
light += (linear(textureLod(irMap, R, 2.0).xyz) * envScale + fill * 0.6)
         * mix(1.0, ao, 0.15 * aoStrength);
```
Concrete dispatch (no TODOs): Diffuse and Ice take **full** AO; Metal takes a fixed
**15%** of the AO factor (`0.15` soft-coded in the `Material_Metal` branch — not a
Settings entry this branch; `NoShade` materials skip the branch entirely). Combined
with the wider metal radius in §6, hull plating reads brushed, not muddy.

---

## 3. Shader specs (pseudo-GLSL, to be written in `res/shader/fragment/filter/`)

All three passes are `#include fragment/math/deferred`-style fullscreen quads drawn
with the `worldray` vertex (they must declare the uniform names they read. If a
name needs an `#autovar` (matrix shared from the camera), copy the 
`#autovar mat4 mProjInv` pattern from `res/shader/vertex/worldray.glsl`).

### Pass 1 — `filter/aoview.glsl` (view-space reconstruction, half-res → aoView)
```glsl
#autovar mat4 mProjInv
in vec2 uv;
uniform sampler2D texDepth;   // zBufferL
const float aoMip = 1.0;      // = log2(sx/aoSx), set by Lua
void main() {
  float dist = textureLod(texDepth, uv, aoMip).x;
  vec4 v = mProjInv * vec4(uv * 2.0 - 1.0, 1.0, 1.0); v /= v.w;
  vec3 viewPos = v.xyz * dist;                  // dist along the unit view ray
  float ndv = ...;  // N·V from normalMat, packed into alpha below
  fragData0 = vec4(viewPos, ndotv);             // RGBA16F
}
```
(Reading the normal at half-res via `texture(texNormalMat, uv)` — bilinear over
the full-res buffer is fine here; encode N·V for the blur weight.)

### Pass 2 — `filter/ao.glsl` (GTAO horizon integral → aoRaw)
```glsl
uniform sampler2D texView;    // aoView
uniform sampler2D texNormal;  // buffer1 (full res, sampled bilinear)
uniform float     aoRadius;   // world units (settings)
uniform float     aoIntensity;// pow curve (settings)
uniform int       dirCount;   // 2/4/6/8
uniform int       stepCount;  // 2/3/4
uniform float     thickness;  // heuristic bias 0..1
uniform float     timeSeed;   // Renderer.frameSeed for rotating slices
const float sampleSpacing = 1.0 / 3.0; // FOV-ish falloff, see tuning §6

void main() {
  vec3 P = texture(texView, uv).xyz;            // view-space center
  vec3 N = decodeNormal(texture(texNormal, uv).xy);
  // assemble orthonormal T1,T2 from N (robust to N≈±Y)
  float ao = 0.0;
  for (i in dirCount) {
    float ang = i/dirCount * TAU + rotate(noise(uv, timeSeed));
    vec2 dir = T1*cos(ang) + T2*sin(ang);
    // march the slice in both directions, track max horizon elevation
    float h0 = 0.0, h1 = 0.0;                   // in tangents
    for (s in stepCount) {
      float t = (s+1) * aoRadius * sampleSpacing; // radially increasing
      vec3 Q0 = viewPosOf(uv + project(P + dir*t), t); // bilinear 2x2 tap
      vec3 Q1 = viewPosOf(uv + project(P - dir*t), t);
      h0 = max(h0, horizon(angleOf P->Q0));      // with thickness term
      h1 = max(h1, horizon(angleOf P->Q1));
    }
    ao += integrate(h0, h1);                     // cosine-windowed sky integral
  }
  occl = pow(clamp(1.0 - ao / dirCount, 0.0, 1.0), aoIntensity);
  fragData0.r = skyMask(dist) * occl;            // 0 on sky pixels -> 1.0 AO
}
```
`viewPosOf()` reads the depth at a bilinear offset and reconstructs the tap's
view-space point from its own linear distance (identical math to pass 1) — removing
the classic per-tap matrix inverse. `project()` routes `view-space -> uv` via the
`mProj` autovar. The thickness heuristic compares the tap distance behind/at P and
smooths the horizon so thin silhouettes don't over-darken. `skyMask` zeroes out
pixels where `dist ≈ 0` so the starfield is never darkened — correct for this engine
(zBufferL is `Draw.Clear(0,0,0,0)`-zeroed on sky, §1 audit).

### Pass 3 — `filter/aoblur.glsl` (depth-aware FULL-RES upsample + bilateral denoise → aoFull)
The composite samples AO at full resolution, so a plain bilinear upsample of the
half-res buffer would bleed soft dark halos around silhouettes (ship against
starfield, asteroid against space). aoRaw is therefore upsampled AND denoised in ONE
full-res pass: for each center pixel, gather a 3×3 neighborhood of half-res aoRaw
texels and weight each by (a) depth closeness of that texel's linear distance vs the
center pixel's true `zBufferL` (`textureLod(zBufferL, uv, 0)`) and (b) a `N·V`
factor — a depth-aware, denoised full-res AO with no bleed across depth
discontinuities. Fall back to a 2×2 gather (4 taps) if 9 taps is too much on a weak
integrator. Output `aoFull` (R8, full-res) is what `global.glsl` samples; a 1×1
`aoWhite` substitutes whenever SSAO is off.

---

## 4. GameView / Renderer wiring

`GameView`
- `local function aoSize(sx, sy)` → split by `Settings.get('ssao.quality')`
  (Off / Half / Quarter); return `max(1, floor(sx/k)), max(1, floor(sy/k))`.
- `GameView:renderAO(world)` — allocates/caches `aoView/aoRaw/aoFull/aoNoise`
  (re-interned on resolution change), runs pass 1 → 2 → 3 inside
  `RenderTarget.Push(aoW, aoH)` + `BindTex2D(<target>)` + fullscreen
  `Draw.Rect(-1,-1,2,2)`, wrapped in one `Profiler.Begin('Render.AO')` region
  (join the existing `renderTimes`; it feeds the debug Profiling panel already).
- Called from the Lighting block before the global pass:
  `if Settings.get('ssao.enable') then self:renderAO(world) end`.
- Global pass: when `self.aoFull` exists set `texAO = aoFull, aoStrength =
  Settings.get('ssao.intensity') or 1`; else bind `aoWhite`.
- Optional preview: when `ssao.show` is on, the AO pass's output REPLACES the
  ambient term (global.glsl branch) so the panel shows pure AO — makes tuning and
  screenshots trivial, reuses the existing dump machinery (`PHX_DEBUG_DUMP`).

`Renderer.lua`
- `Renderer:free()` frees the AO textures (guard).
- `Renderer:meter()` — no change, but `self.frameSeed` (already cycling 0–4096)
  is passed as `timeSeed` to rotate the GTAO slices per frame (temporal jitter → no
  shimmer at 2x supersample).

`Config.App.lua` (`Config.gpu`) seeds each `ssao.*` setting (names below).

---

## 5. Debug panel controls (auto-listed, no DebugWindow changes)

`Settings` prefix `ssao` → `DebugWindow:createSettingsSections()` renders a
collapsible **ssao** section automatically (first key segment). Registration block
in `Renderer.lua` next to the other Settings:

| Key | Type | Default | Notes |
|-----|------|---------|-------|
| `ssao.enable`            | bool  | false | master switch. **Default OFF** on this branch (opt-in) until the mid-tier perf gate in §7 is measured; false = 1x1 white, frame identical to pre-SSAO |
| `ssao.quality`           | enum  | Half  | Off / Half / Quarter resolution |
| `ssao.radius`            | float | 500   | world-space occlusion radius (0.1..4000) |
| `ssao.intensity`         | float | 1     | AO `pow` curve / strength (0..3) |
| `ssao.directions`        | enum  | 4     | GTAO slices (2/4/6/8) |
| `ssao.steps`             | enum  | 3     | taps per slice (2/3/4/6) |
| `ssao.thickness`         | float | 0.25  | silhouette bias 0..1 |
| `ssao.blur`              | enum  | 1     | bilateral denoise passes (0/1/2) |
| `ssao.show`              | bool  | false | preview: render pure AO (for tuning/screenshots) |

`Config.gpu` seeds: `aoEnabled` (false), `aoQuality`, `aoRadius`, `aoIntensity`,
`aoDirections`, `aoSteps`, `aoThickness`, `aoBlur`. (Naming is the engine's existing
split on purpose: `Config.gpu.*` is camelCase like `sunAmbientFill`/`sharpenStrength`,
while Settings keys are dotted `ssao.*` like `render.sun.fill`; consistent, not a bug.)

Because the panel builds from `Settings.getAll()`, these controls literally appear
the first boot after the branch is built — no extra UI code.

---

## 6. Tuning targets & "space wow" specifics

- **Radius vs the scale problem.** The game spans ship (≈4 u) → asteroid (10–60 u)
  → planet (2000 u) → field (2000 u spawn box). A fixed world radius that is great
  at asteroid scale does nothing at planet scale. Design:
  - Primary: `radius` world units scaled by a mild screen-consistency term —
    `R = ssao.radius * clamp(dist/1000, 0.2, 4)` (dist from the AO center pixel).
    Near geometry gets small, snappy AO; receding geometry keeps proportionally
    sized darkening the way a real camera would. Both knobs exposed.
  - `thickness` tuned so **asteroid rim silhouettes read as lit, not as flat black
    rings** — the classic GTAO-with-thickness win, and the difference between
    "magic space" and "crusty vignette".
- **Ambient-only.** The sun pass and every point light are untouched. The "wow" is:
  craters/pockmarks get *locally* dark so the sunlit side pops with depth, but you
  never get sun-side dimming or shadow acne from this feature.
- **Scale philosophy (accepted trade).** One world radius cannot serve both asteroid
  pockmarks (sub-meter) and planet-scale relief (hundreds of units) at equal camera
  distance — the distance clamp keeps screen footprint consistent but cannot tell
  those scales apart. Decision: AO is a **close-range hero feature**; planet AO from
  orbit reads as generic "soft roundness", which is fine — no one stares at planet
  AO. Per-material radius *is* cheap and grounded (the G-buffer carries the material
  ID in `normalMat.w`), so Metal gets `aoRadius * 2.0` + the 15% strength from §2:
  wide, subtle hull AO instead of tight darkening. Per-tag radius (crater vs ring)
  is deferred until material tags exist.
- **No starfield halo, no flicker.** `skyMask` keeps AO=1 on sky; blue-noise slice
  rotation + frame jitter (`frameSeed`) plus the denoise pass keeps it stable at
  2x supersample (the shipped default) — AO should read rock-solid, not animated.
- **Metal:** AO applied ~10–20% weaker to the `Material_Metal` env reflection so
  lit hull plating doesn't go muddy.

Phasing (each commit boots clean + validator-green):
1. **Phase A** — plumbing: AO textures, `aoview`+`ao`+`aoblur` passes, `ssao.*`
   settings, `Config.gpu` seeds, global-pass hook. Working but naive first pass
   (uniform-horizon approximation) so the diff is inspectable early.
2. **Phase B** — upgrade pass 2 to the full GTAO horizon integral + blue-noise LUT
   + per-frame `timeSeed`. This is where quality arrives.
3. **Phase C** — bilateral denoise tuning + `thickness`/`radius`/`intensity`
   defaults calibrated on the asteroid field and a planet approach (this is the
   actual "wow" tuning — expect this phase to eat half the time).
4. **Phase D** — extras (below), each additive and toggle-gated.

---

## 7. Validation & acceptance

- `python3 configure.py test` — the offline validator auto-discovers new `.glsl`
  files (it globs `res/shader`), so pass 1–3 are compile+link-checked headlessly.
  New shaders that `#autovar` an un-staged name will **Fatal at load** (good: the
  validator won't catch missing stack entries — boot test will).
- Boot checklist: engine boots clean; F9 opens the panel with the `ssao` section;
  toggle `ssao.enable` → identical frame (use `ssao.show` + `PHX_DEBUG_DUMP`
  screenshots at a fixed seed to compare; also A/B the pre-branch commit).
- Perf gate (`Render.PostFx`/`Render.AO` profiler regions, panel Profiling):
  AO chain ≤ ~0.6 ms at 1024×768, ≤ ~1.2 ms at 2x SS on the RX 7900 XTX; memory
  delta < ~3 MB (aoView RGBA16F half-res + aoRaw + aoFull + 64×64 LUT); QFR's
  regulator `lt64r` stays at target FPS.
- **Mid-tier gate for the ship-enabled default:** `ssao.enable` stays OFF until ONE
  reference measurement on a GTX 1060 / RX 580-class GPU (a real Steam-survey slice)
  at 1024×768 with §6-settings holds ≤ ~0.6 ms. Flip the default + note it here when
  that measurement exists; until then everything is measured on the 7900 XTX only.
- Quality gate: no AO on sky; no shimmer at 2x; craters/ship/planet silhouettes
  darkened but not turned to black outlines; **no halo bleed on hull edges against
  the starfield** (that is the §3 pass-3 depth-aware upsample's job — a plain
  bilinear wouldn't pass this); sun side untouched; `ssao.quality=Quarter` visibly
  coarser but usable.

## 8. Risks / mitigations
- **Per-tap view reconstruction cost** (someone always suggests a raw depth-pass
  blur instead): 24 bilinear taps at half-res is cheap on any GPU made in 7+ years
  on MXM; if a low-end integrator profile needs headroom we already have
  `ssao.quality=Quarter` + `ssao.directions=2`. The real risk is C—tuning produces
  a look ("plastic Crater 2K") that fights the Freelancer palette; mitigate with
  conservative defaults and the power-curve `intensity` knob.
- **Fog/tonemap interaction**: GTAO darkens ambient *before* tonemap → normalized
  exposure compensates slightly and the AE meter (`lit`) stays representative; if
  the meter dumps shift outside the `max ∈ [1.5,3] / over ∈ [1,5%]` window after
  enabling AO, that is expected; re-tune defaults (not the AE).
- **`ssao.quality` full-res**: never merged by default; kept as an enum slot for
  future TAA-grade quality (do NOT add a full-res mode until we have temporal
  accumulation to pay for it).

---

## 9. Recommended companion tweaks (knock-on "wow" + perf, all optional / gated)

These are intentionally OUT of the core SSAO diff but worth grabbing while the
branch is open — every one is data-driven + debug-panel-presented:

**Visual pops**
1. **Distance haze / heat-layer fog (`postfx.fog.*`, off by default)** — the
   single biggest "space vastness" win after the sun: exponential depth haze toward
   a deep bluish-neutral `fogColor`, folded into the composite (uses `texDepth`
   linear distance, no extra render). Opt-in `fog.enable/density/color` so the
   branch stays focused; a first pass at roadmap #13's fog item (#13's streaming is
   out of scope here).
2. **Star disc occlusion garnish — the "mood" knob** — with ambient-out-of-GTAO we
   can optionally modulate `sunColor`'s hemisphere fill by AO too (a *second*,
   user-visible knob `ssao.fillOcclude`, default **off**) so huge structures cast
   soft "ambient shadow" inside caves under the sun. (Correct AO is ambient-only;
   this is the stylized, game-y variant — hence opt-in.) Reframed by the 2026-09-09
   design review: this is the deliberate **storytelling** lever — a canyon that goes
   truly dark reads mysterious, not photometric. When tuning with `fillOcclude` on,
   bias toward cliff-darkness over accuracy.
3. **Bloom default nudge + sun-scale knee**: current defaults are already
   sign-off'd; leave unless the planet-atmosphere rim starts clipping.
4. **Ship/planet specular falloff tweak**: `lighting.specular` roughness remap
   (a `pow(r,…)` remap on `normalMat.z`) makes metal gleam read as brushed rather
   than plastic — half-day, contained to `pbr.glsl` + a knob.

**CPU / memory / FPS**
5. **Pool the per-frame `lights` table** (existing TODO in `GameView.lua:draw`) —
   no more per-frame table + closures; micro but free.
6. **Sun shadow map is the current second-most-expensive pass** — add a
   `render.sun.shadowSize` (256/512/1024/2048) enum; 1024 is ~indistinguishable at
   gameplay distances for a third of the fill+filter cost. Debounce/convert on
   toggle.
7. **Reuse for AO**: `zBufferL` mips (no new depth buffer), half-res R8 AO buffers,
   single blue-noise LUT reused across all three passes and the existing grain pass
   (already has a hash — leave).
8. **Grazing-angle cull** in GTAO (skip slices when `N·V` small) — bounded win,
   cheap to add in Phase B.
9. **Watch `Render.Submit` vs `Render.PostFx`** — the profiler regions now split
   these; if PostFx dominates, the AO chain shows up there immediately.
10. **Sound carries "heavy/solid" better than shading does** (design review) —
    weighty hull-scrape / asteroid-impact SFX (`Config.audio.sfx`) outsell AO
    pixels for making geometry feel real. Out of scope here; listed as the
    highest-leverage §9-adjacent win.
11. **Land §9.1's dust/haze together with AO** — once GTAO carves asteroid
    canyons, the depth-based dust/heat haze reads as genuinely volumetric; the two
    are designed as a pair (this branch ships only the AO half).
12. **Scale-contrast beats scale-consistency** — a tiny ship against a planet that
    keeps its size while you approach is a bigger "wow" than any shader.
    Parallax-correct planet sizing is a camera/HUD roadmap concern; explicitly NOT
    in this branch.

---

## 10. Non-goals for this branch
- Temporal accumulation / reprojection-based AO (TAA-class). The 2x supersample
  default + per-frame slice jitter gives stable AO at the shipped settings; adding
  a history buffer is a bigger decision best made with a real TAA item.
- HBAO/HBIL alternatives — GTAO subsumes them for our budget.
- Physical contact shadows from the sun (that's existing shadow work; AO is
  ambient).
- Any change to the sun/dir shadow pass itself.

## 11. File touch-list
- New: `res/shader/fragment/filter/aoview.glsl`, `filter/ao.glsl`,
  `filter/aoblur.glsl`, `ssao-gtao-implementation.md` (this doc).
- Edit: `res/shader/fragment/light/global.glsl` (texAO/aoStrength hook), `pbr.glsl`
  (optional §9.4), `script/phx/util/Renderer.lua` (settings + AO texture
  alloc/free + `frameSeed` export), `script/Game/GUI/GameView.lua` (renderAO +
  lighting-block call + profiler region + preview branch), `script/Config.App.lua`
  (`Config.gpu` seeds), `AGENTS.md` + `ROADMAP.md` (status line + close out #2 at
  the end).
- Validator/`configure.py test`: no changes needed (auto-discovers shaders).