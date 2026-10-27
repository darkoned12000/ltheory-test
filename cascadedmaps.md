# Cascaded Shadow Maps (CSM)

## Problem

The sun's directional shadow originally used one orthographic map covering
the entire `render.sun.shadowRange`. Its texels were visible on the ship and
nearby asteroids, especially with the camera facing the sun. Increasing the
single map resolution helped but did not provide enough detail over both near
and distant world geometry.

## First implementation and why it was insufficient

The initial three-map implementation used concentric, camera-centered boxes
with different radii, then selected a map by Euclidean distance from the
camera. This was an approximation, **not proper CSM**: it neither fitted each
map to a camera-frustum slice nor used view-space depth for cascade selection.
Playtesting continued to show coarse shadows and pixelation.

## Corrected implementation (current on `cascadedmaps`)

### Frustum slices

`GameView:renderSunShadow` now obtains the camera frustum corners by
unprojecting NDC corners through `mProjInv`, scaling their view-space rays to
each split depth, and transforming them to world space with `mViewInv`.

Default view-depth splits:
- Near: 0.1–1000 world units
- Mid: 1000–3000
- Far: 3000–`render.sun.shadowRange` (default 5000)

Splits are reduced proportionally if the configured range is smaller.

### Light-space fit and stability

Each slice is projected onto the sun-aligned light-space basis. The orthographic
square is fitted to the slice's light-space X/Y bounds, rather than using a
large camera-centered sphere. The projection center is snapped to shadow-texel
increments to reduce shimmer as the camera moves. The light-space depth range
is extended sunward to retain occluders in front of the receiver slice.

Each cascade currently uses the configured shadow-map resolution (default
2048, Depth32F). Cascade selection uses positive view-space depth:
`dot(worldPosition - eye, cameraForward)`. Shadow factors are smoothly blended
across each split boundary.

### Integration

- `script/Game/GUI/GameView.lua`: fits and renders three cascade maps; binds
  their textures, matrices, view-depth splits, and blend widths.
- `res/shader/fragment/light/dir.glsl`: selects/blends the appropriate cascade
  and runs Poisson PCF sampling.
- The nebula volume shader does **not** sample these maps; this CSM only shadows
  opaque direct sunlight. Apparent dark nebula structures are the volume's own
  density/lighting, not ship/asteroid shadow projections.
- God Rays are a separate effect: their quarter-resolution shaft image is
  radially gathered toward the sun. It previously gathered across depth edges,
  leaking shafts from behind ships/asteroids as ghostly shadow-like silhouettes.
  The shaft image now stores log eye-depth and `godblur` uses a bilateral depth
  gate to reject cross-silhouette taps (see `filter/godrays.glsl` and
  `filter/godblur.glsl`).

### Cost and remaining validation

CSM renders the shadow-caster scene three times per update and allocates three
Depth32F maps (about 48 MiB total at 2048²). Existing `render.shadow.period`
amortizes updates. Validate on several camera orientations/aspect ratios and
profile before considering higher resolutions. If near shadows remain too
coarse, the next refinement is independent per-cascade resolutions or tighter
near splits—not simply increasing every map.

## Playtest diagnosis guide

- Disable **Sun Light → Shadows** only: if ship/asteroid shadow artifacts
  disappear, they are from the directional shadow maps.
- Disable **Nebula Volume** only: changes to broad cloudy/screen-aligned blocks
  identify volumetric integration/upsampling artifacts instead.
- Bloom and sharpen may soften/emphasize artifacts, but neither should be
  required to prevent large rectangular patches.
