# Shader Review — `res/shader/`

Comprehensive inventory and examination of every shader in `res/shader/`, on the `reviewcode` branch.
Work order: **compute → fragment → include → vertex**. Each pass records usage, correctness, and recommendations.

Status legend: ✅ OK/used, ⚠️ note, ❌ issue, 🗑️ unused candidate (safe to delete).

---

## 1. Compute shaders (`res/shader/compute/`)

| Shader | Status | Usage | Notes |
|---|---|---|---|
| `particle_simulate.glsl` | ✅ | GPUParticles | Semi-implicit Euler integration. Buffer size tied to `Config.gpu.maxParticles` (131072). |
| `particle_spawn.glsl` | ✅ | GPUParticles | Spawn distribution (sphere/cone/box). Paired with simulate. |
| `selftest.glsl` | ✅ | Validator only | Test infrastructure. Keep. |

---

## 2. Fragment shaders (`res/shader/fragment/`)

### 2a. `filter/` — post-processing chain (Renderer.lua)
All referenced filters are live. Key findings:

- **`aberration.glsl`** ⚠️ — chromatic aberration. NaN guard needed (aspect divide). Gated behind `postfx.aberration.enable` (default false). Fixed in code (aspect passed explicitly).
- **`ao.glsl` / `aoview.glsl` / `aoblur.glsl`** ✅ — GTAO 3-pass. Avg 0.056 ms @2xSS. Well-documented in `docs/ssao-gtao-implementation.md`.
- **`bloom*.glsl`** ✅ — Karis bloom pipeline (pre, down, up, composite). Multiple intermediate buffers. Could reduce buffer count on low-end.
- **`colorgrade.glsl`** ❌ — `Renderer:colorgrade` method exists but is **never called**. Dead code. Candidate for removal.
- **`dither.glsl`** ❌ — never used as a filter (ditherOffset is a shader var, not this pass). Dead code.
- **`fogw.glsl`** 🗑️ — already removed (distance haze deleted 2026-10-14).
- **`fxaa.glsl`** ✅ — gated by GPU setting.
- **`glitch.glsl`** ✅ — used by ImageFilter.lua.
- **`grain.glsl`** ✅ — gated behind `postfx.grain.enable` (default false).
- **`radialblur.glsl`** ✅ — gated behind `postfx.radialblur.enable` (default false).
- **`tonemap.glsl` / `tonemap2.glsl`** — `tonemap` is live (ACES/AgX/Filmic/Khronos). `tonemap2` is unused. 🗑️
- **`ui_overlay.glsl`** ✅ — composites HUD above post chain.

**Unused filter candidates (0 references):** `bloom2`, `blurhdr`, `dither`, `fade`, `invert`, `log`, `madd`, `overlay`, `prebloom`, `radialminmax`, `tonemap2`.

### 2b. `material/` — surface materials
| Shader | Status | Notes |
|---|---|---|
| `alphacolor` | ✅ | |
| `asteroid` | ✅ | 207 refs |
| `atmosphere` | ✅ | 23 refs |
| `devmat` | ✅ | debug material |
| `devmatenv` | 🗑️ | 0 refs — debug env material, unused |
| `metal` | ✅ | 15 refs |
| `ore` | ✅ | 361 refs |
| `planet` | ✅ | 390 refs |
| `ring` | ✅ | 756 refs |
| `solidcolor` | ✅ | 1 ref |
| `triplanar` | ✅ | 2 refs (uvbake) |
| `uv_metal` | 🗑️ | 0 refs |

### 2c. `effect/` — particle/beam effects
| Shader | Status | Notes |
|---|---|---|
| `beam` | 🗑️ | 0 refs |
| `dustcloud` | ✅ | backlight effect |
| `dustfleck` | ✅ | |
| `explosion` | ✅ | 6 refs |
| `gpu_particle` | ✅ | compute particles |
| `pulsehead` / `pulsetail` | ✅ | pulse effects |
| `railbracket` | ✅ | |
| `thruster` | ✅ | 21 refs |
| `warprail` | ✅ | 3 refs |
| `wormhole` | ✅ | 27 refs |

### 2d. `gen/` — procedural generation
| Shader | Status | Notes |
|---|---|---|
| `moon` | ✅ | 45 refs |
| `nebula` / `nebula_absorb` / `nebula_emit` | ✅ | nebula generation (3-pass) |
| `planet` | ✅ | 390 refs |

### 2e. `light/` — lighting passes
| Shader | Status | Notes |
|---|---|---|
| `composite` | ✅ | 13 refs |
| `dir` | ✅ | 287 refs (directional sun + shadows) |
| `global` | ✅ | 40 refs (ambient fill + SSAO dispatch) |
| `point` | ✅ | 196 refs (point lights + shadow maps) |

### 2f. `sdf/` — signed distance field
| Shader | Status | Notes |
|---|---|---|
| `asteroid` | ✅ | 207 refs |

### 2g. `ui/` — UI rendering
| Shader | Status | Notes |
|---|---|---|
| `box`, `circle`, `composite`, `dashline`, `flat`, `grid`, `hex`, `hologram`, `icon`, `line`, `logo`, `panel`, `panelglow`, `point`, `ring`, `shadow`, `text`, `triangle`, `wedge` | ✅ | All used |
| `circle-old` | 🗑️ | 0 refs (superseded by circle) |
| `ringdim` | 🗑️ | 0 refs |

### 2h. `brush/` — procedural texture brushes (Gen system)
| Shader | Status | Notes |
|---|---|---|
| `blur`, `desat`, `tone` | ✅ | Used |
| `erode`, `gauss1`, `gaussdodge`, `perlinflow`, `worley1`, `worleyflow` | 🗑️ | 0 refs — dead brush shaders |

### 2i. `compute/` (under fragment/)
| Shader | Status | Notes |
|---|---|---|
| `irmap`, `occlusion`, `occlusion_sdf`, `tilenoise` | ✅ | Used (irradiance maps, occlusion, tiling noise) |

### 2j. `uvbake/`
| Shader | Status | Notes |
|---|---|---|
| `paint`, `triplanar` | ✅ | Used |

### 2k. Top-level fragment shaders
| Shader | Status | Notes |
|---|---|---|
| `depth`, `ptracer`, `ptracer_out`, `simple_color`, `simple_image`, `skybox`, `skybox_dynamic`, `skybox_spheremap`, `starbg`, `terrain`, `text` | ✅ | Used |

---

## 3. Include files (`res/shader/include/`)

| Include | Status | Notes |
|---|---|---|
| `bezier`, `brush`, `color`, `common`, `deferred`, `fdm`, `filter`, `fog`, `fragment`, `gamma`, `lighting`, `math`, `medium`, `noise`, `pbr`, `planetlocal`, `quat`, `random`, `raytrace`, `scattering`, `scattering2`, `texcube`, `texturing`, `tonemapping`, `vertex` | ✅ | All `#include`d by fragment/vertex shaders |
| `raytrace` | ⚠️ | 0 direct references in script/ — only self-reference (include guard). May be included by other includes. Verify. |

Note: `fog.glsl` still exists as an include even though the fog filter was removed. Check if it's still included anywhere.

---

## 4. Vertex shaders (`res/shader/vertex/`)

| Shader | Status | Notes |
|---|---|---|
| `billboard/axis`, `billboard/quad`, `billboard/quadpos`, `billboard/wrapped` | ✅ | Used |
| `farplane`, `identity`, `particles`, `shadow`, `ui3D`, `ui`, `ui/widget`, `uvspace`, `vp`, `worldray`, `wv`, `wvp`, `wvp_zoff` | ✅ except below |
| `wvp_zoff` | 🗑️ | 0 refs |

---

## Summary of unused candidates (safe to delete)

**Fragment filters:** bloom2, blurhdr, dither, fade, invert, log, madd, overlay, prebloom, radialminmax, tonemap2
**Fragment materials:** devmatenv, uv_metal
**Fragment effects:** beam
**Fragment ui:** circle-old, ringdim
**Fragment brush:** erode, gauss1, gaussdodge, perlinflow, worley1, worleyflow
**Vertex:** wvp_zoff
**Include:** raytrace (verify)

**Total unused candidates: ~20 shaders** (out of 163).

## Recommendations
1. **Delete unused shaders** to reduce VRAM/file size. Verify each with the offline validator after deletion.
2. **Color grading** (`colorgrade.glsl`) — method exists but is never called. Either wire it into the post chain or remove.
3. **Bloom pipeline** — uses multiple intermediate buffers. Could reduce buffer count on low-end (Config.gpu already gates bloom on/off).
4. **Aberration** — gated off by default, contains NaN-prone code. Consider removing entirely or fixing the math.
5. **Nebula gas capture** — no shader yet for the capture equipment (future feature).
6. **Memory:** The filter chain creates many intermediate textures (buffer0, buffer1, bloom buffers). Could pool/reuse on low-end.

## Next steps
- Vertex shader review (math correctness, transform pipelines)
- Include file review (math formulas, noise quality)
- Engine/libphx review (separate pass)