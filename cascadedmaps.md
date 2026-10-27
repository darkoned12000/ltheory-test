# Cascaded Shadow Maps (CSM) — Design Spec

## Problem
The sun's directional shadow uses a single orthographic projection box
(`render.sun.shadowRange` = 5000, `render.sun.shadowSize` = 2048). When the
camera looks toward the sun, the shadow texels become visible as blocky
shadows on the ship, asteroids, and the volumetric medium (nebula). Increasing
resolution helps but doesn't eliminate the issue — a single map can't cover
both near (high detail) and far (large area) simultaneously.

## Solution: Cascaded Shadow Maps
Split the shadow frustum into N cascades (near/mid/far), each with its own
shadow map at appropriate resolution. The near cascade covers a small area at
high resolution; the far cascade covers a large area at lower resolution.

### Design

#### Cascade count
- 2 cascades for low-end (Config.gpu.sunShadows = true, default quality)
- 3 cascades for high-end (Config.gpu.sunShadows = true, quality = high)
- Configurable via `render.sun.shadowCascades` (enum: 2/3/4)

#### Cascade split distances
- Cascade 0 (near): 0 → 500 world units
- Cascade 1 (mid): 500 → 2000
- Cascade 2 (far): 2000 → 5000 (or shadowRange)

Split distances are in view-space depth (distance along camera forward).
Use practical split scheme (geometric + uniform blend) for smooth transitions.

#### Shadow map resolution
- Each cascade uses the same resolution (render.sun.shadowSize, default 2048)
- Total VRAM: 2-3 × 2048×2048 × 4 bytes = 32-48 MB (Depth32F)
- Could reduce far cascade resolution (1024) to save VRAM

#### Rendering
- For each cascade:
  1. Compute ortho frustum from sun direction + camera frustum slice
  2. Render shadow map (depth-only pass) into cascade's texture
  3. Store view-projection matrix for sampling
- Bind all cascade maps as a texture array or separate samplers

#### Sampling (in `light/dir.glsl` and `filter/volume.glsl`)
- Determine which cascade to sample based on view-space depth
- Sample the appropriate shadow map with PCF
- Blend between cascades at boundaries (avoid hard seams)

#### Implementation files
- `GameView.lua`: `renderSunShadow()` → `renderSunShadowCascade(i, world, splitNear, splitFar)`
- `light/dir.glsl`: add cascade selection + multi-map sampling
- `filter/volume.glsl`: add cascade selection for volumetric shadows
- `Config.App.lua`: add `sunShadowCascades` setting
- `Renderer.lua`: add to SETTINGS panel

#### Estimated effort
- 2-3 days for 2-cascade version
- Additional day for 3-4 cascade + blending
- Testing: visual comparison (before/after), performance profiling

#### Risks
- Performance: 2-3× shadow render passes. Mitigate with shadow update period (already exists: render.shadow.period).
- Seam blending: need smooth transition between cascades to avoid visible bands.
- Memory: 2-3× shadow map VRAM. Mitigate with reduced far-cascade resolution.

## Current state (single map)
- Resolution: 2048 (default, up from 1024)
- Range: 5000 (down from 8000)
- Quality: good for nearby objects, blocky at distance when looking toward sun
- Perf: ~1.7 ms/frame for the sun shadow pass

## Recommendation
Implement 2-cascade version first. Test visually. If quality is sufficient, ship. Add 3rd cascade only if needed.