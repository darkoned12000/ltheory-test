# Limit Theory Reboot: Nodal UI / Holo Node Plan — Verified Revision 2

**Date:** 2026-11-26  
**Status:** implementation plan only; no Holo files have been added and no F10 behavior has changed.  
**Supersedes:** the original drop-in `HoloNodeDemo` snippets in this document. Those snippets were a useful visual sketch, but they were not runnable or safe to integrate as written.

**Reference material:**
- Limit Theory Development Update #10 — `KN3tKT0E0t8`
- Limit Theory Development Update #11 — `Ekq56VZqQvs`

---

## 1. Bottom line

The Update #10/#11 direction is worth prototyping:

- layout polymorphism;
- semantic zoom;
- one-level-ahead micro-previews;
- SDF rings and glowing edges;
- subtle 3D tilt;
- gamepad angular selection;
- one graph spanning galaxy, sector, ship, inventory, and developer data.

The correct implementation path is **not** to replace the existing F10 `NodeGraph` wholesale.

The existing `NodeGraph` is already provider-driven and contains substantial tested behavior: robust fitting, declutter, category filters, off-screen indicators, region/topology display, click-centering, zoom anchoring, per-level camera/focus restoration, inspector integration, and flight-input suppression. Replacing it would regress working behavior.

The recommended architecture is:

> **Keep `NodeGraph` as the controller. Add `HoloLayout` and `HoloRenderer` as an optional visual/layout mode over the existing provider records.**

That gives us the old Limit Theory feel while preserving the current map's data model, navigation, tests, and game integration.

---

## 2. Verified current architecture

These facts were checked against the current tree, not inferred from the original proposal.

### 2.1 `NodeGraph` already uses SDF primitives

The original claim that the current graph is mainly CPU `Draw.Line` rings and dashes is outdated.

Current code uses:

- `DrawEx.Ring` + `DrawEx.Point` for nodes: `script/UI/NodeGraph.lua:1070-1071`
- `DrawEx.Line` / `DrawEx.Dash` for edges: `script/UI/NodeGraph.lua:1005-1010`
- `DrawEx.Ring` is batched through `Draw.WidgetRect`: `script/UI/DrawEx.lua:214-222`
- `DrawEx.Line` is also batched: `script/UI/DrawEx.lua:123-136`

Raw `Draw.Line` remains for small crosses, brackets, and similar details. The main rings and edges are already shader-based.

**Implication:** the real visual gap is layout, perspective, previews, animation, and density—not “2D lines versus SDF.”

### 2.2 `NodeGraph` is already a capable map controller

Existing behavior includes:

- galaxy, sector, and region contexts;
- robust p90 outlier trimming;
- declutter and dense-minor caps;
- category filters;
- off-screen indicators;
- region markers and topology;
- click selection/centering/zoom;
- cursor- and locked-node zoom anchoring;
- real drag-to-pin behavior;
- per-level camera and focus restoration;
- inspector and NPC info-panel integration;
- F10 overlay and flight-input suppression.

Relevant code:

- Provider contract: `script/UI/GraphProvider.lua:9-17`
- Drill/camera restoration: `script/UI/NodeGraph.lua:406-508`
- Fit/declutter: `script/UI/NodeGraph.lua:196-319,510-660`
- Input behavior: `script/UI/NodeGraph.lua:1353-1508`
- F10 integration: `script/Game/GUI/GameView.lua:1432-1436`
- Flight suppression: `script/Game/Controls/HUD.lua:840-852`

The current suite has **88 NodeGraph checks**. Those checks are a regression floor for any Holo mode.

### 2.3 The provider layout hook exists but is not connected

`GraphProvider` documents:

```lua
provider.layout(nodes) -- optional; assign node x/y for logical views
```

at `script/UI/GraphProvider.lua:16-17`, but `NodeGraph` never calls it.

`GraphProvider.grid` also expects an id-keyed map, while `children` returns an array. This mismatch should be fixed rather than hidden by a second graph implementation.

This is a real and useful gap for Holo work to fill.

### 2.4 UI storage is HDR, but UI misses scene bloom and tonemapping

`uiBuffer` is `RGBA16F`, not an SDR-clamped target:

- `script/phx/util/Renderer.lua:447,907-917`

The accurate pipeline description is:

1. Render world.
2. Render UI into `uiBuffer`: `script/Game/GUI/GameView.lua:950-978`
3. Run bloom: `GameView.lua:992-994`
4. Run volumetrics, god rays, tonemap, and other post effects: `GameView.lua:995-1150`
5. Composite UI: `GameView.lua:1152`

So UI is **excluded from scene bloom and tonemapping**, then composited afterward.

### 2.5 `Sector.Region.place` does not generate previewable star systems

`Region.place` generates region metadata, not planets, stations, ships, or belts:

- `script/Game/Region.lua:310-337`

A system micro-preview needs one of:

- a deterministic summary provider;
- a cache produced by the real planet/place/field generation paths;
- a live query of materialized entities.

Calling `Region.place` alone cannot produce the preview shown in the original demo.

### 2.6 Reflection is only partly generic

Lua tables and custom `CType.Struct` values are tractable. Custom structs have field metadata and `__pairs`:

- `script/phx/util/Type.lua:63-74`
- `script/phx/util/CStruct.lua:16-28`

Ordinary FFI values such as `Vec3f`, `Quat`, `Matrix`, pointers, and opaque libphx structs do not expose universal field enumeration.

A read-only Lua walker may be roughly 100 lines. A safe editor needs:

- type schemas;
- cycle/depth/node caps;
- validated setter adapters;
- explicit handling for vectors, inventories, markets, and engine handles;
- no blind pointer dereferences or raw cached-state mutation.

### 2.7 The original demo is a mock, not a live simulation

The supplied `HoloNodeDemo` builds static Lua tables, increments `simOre`, clears the screen, and draws the graph. It does not spawn a world, ships, physics, or AI. Its `laserStats` table is detached from real turrets and projectiles.

That is acceptable for a **look-and-feel prototype**, but it must be labeled as a mock. It is not proof of real-data integration.

---

## 3. Goals and non-goals

### 3.1 Goals

- Preserve all existing `NodeGraph` behavior and tests.
- Add optional spatial/radial/cardinal/rectilinear/spiral layouts.
- Add semantic zoom and one-level-ahead previews.
- Add a subtle 3D UI camera with exact mouse inversion.
- Add SDF holographic nodes and active-path beams without a draw-call explosion.
- Support mouse, keyboard, and gamepad input without duplicate dispatch.
- Move from mock data to real provider data before F10 integration.
- Keep an optional path for a dedicated HDR Holo layer later.

### 3.2 Non-goals for the first demo

- Replacing `NodeGraph`.
- Rebuilding the renderer.
- Putting all UI into scene bloom.
- Generic arbitrary C++ reflection.
- Shipping a player-facing raw-memory editor.
- Supporting thousands of fully detailed preview children.
- Reusing WASD in the in-game overlay.

---

## 4. Proposed architecture

```text
GraphProvider
  ├─ entity/context data
  ├─ stable unit IDs
  ├─ links
  ├─ drill policy
  ├─ layout policy
  └─ preview summaries / validated value adapters
        │
        ▼
NodeGraph controller
  ├─ merge + stable visual identity
  ├─ fit / declutter / LOD
  ├─ drill stack + camera/focus restore
  ├─ filters / indicators / inspector
  └─ input routing
        │
        ├─ Classic renderer (existing)
        │
        └─ Holo mode
             ├─ HoloLayout: pure layout + camera math
             └─ HoloRenderer: batched nodes/edges/previews + active SDF accents
```

### 4.1 File plan

| File | Role | Phase |
|---|---|---|
| `script/UI/HoloLayout.lua` | Pure camera/layout/preview math | A |
| `script/UI/HoloRenderer.lua` | Batched classic primitives plus optional SDF accents | A |
| `script/App/HoloNodeDemo.lua` | Standalone mock look-and-feel demo | A |
| `res/shader/fragment/ui/holonode.glsl` | Selected/hovered node and active beam shader | A |
| `script/UI/GraphProvider.lua` | Provider v2 contract and layout invocation support | B |
| `script/UI/NodeGraph.lua` | Optional Holo mode and `z`/layout/preview records | C |
| `tools/validate_holo_layout.lua` | Projection, pan, layout, preview, and camera tests | A |
| `tools/validate_holo_input.lua` | Duplicate-input, editor, and gamepad tests | A |
| `script/UI/HoloReflection.lua` | Read-first schema-driven developer provider | D |
| `res/shader/fragment/filter/holo_overlay.glsl` | Optional dedicated HDR Holo composite | D |
| `script/phx/util/Renderer.lua` | Optional `holoBuffer` lifecycle | D |

---

## 5. Provider contract v2

The provider should own **data and policy**, not rendering.

### 5.1 Unit record

Extend the existing unit record without breaking current providers:

```lua
local unit = {
  id = 'ship:player',          -- stable graph identity
  entity = ship,               -- optional for virtual contexts
  context = 'ship:player',     -- optional virtual drill context

  major = true,
  cat = 'ship',

  -- World coordinates remain untouched.
  wx = ship:getPos().x,
  wy = ship:getPos().y,
  wz = ship:getPos().z,

  -- Layout coordinates are separate and may be authored by provider.layout.
  x = wx, y = wz, z = wy,
  tx = wx, ty = wz, tz = wy,

  r = 18,
  label = 'YOU',
  layout = 'cardinal',         -- child context layout
  preview = 'ship',            -- preview provider key, not eager children

  getValue = function () return ship.health end,
  setValue = function (value) return ship:setHealth(value, ship.healthMax, 0) end,
}
```

Rules:

- `wx/wy/wz` are refreshed from live entities every update.
- `x/y/z` are layout coordinates.
- `tx/ty/tz` are interpolation targets.
- `preview` is a provider key or descriptor, not an eagerly retained child array.
- `getValue`/`setValue` are optional validated adapters.
- Virtual contexts have stable IDs even when `entity == nil`.

### 5.2 Provider methods

```text
provider.classify(entity)
  -> worthy, major, cat

provider.children(ctx, isRoot)
  -> owned array of unit records

provider.links(ctx, nodes)
  -> { a = id, b = id, kind = string, job = any }

provider.drillable(entityOrContext)
  -> bool

provider.noDrillReason(entityOrContext)
  -> nil | 'empty' | 'other-view' | string

provider.layout(nodes)
  -> assign x/y/z for logical contexts

provider.preview(ctx, node, budget)
  -> { points = {...}, layout = 'radial'|'spatial'|... }

provider.resolveContext(id)
  -> context object or nil
```

Current contract problems to fix:

- `children`, `links`, and `drillable` are documented as optional but called unconditionally.
- `provider.layout` is never invoked.
- `GraphProvider.grid` expects a map while `children` returns an array.
- `classify` is wired to the module-level default provider, not necessarily the instance provider.
- Provider scratch arrays are reused; previews must copy or summarize records rather than retain them.
- Sector records have no entity; virtual context resolution is required.

### 5.3 Array/map normalization

Do not make every provider guess the container shape:

```lua
function GraphProvider.each (nodes, fn)
  if type(nodes) ~= 'table' then return end
  if nodes[1] ~= nil then
    for i = 1, #nodes do fn(nodes[i], i) end
  else
    for id, node in pairs(nodes) do fn(node, id) end
  end
end
```

`NodeGraph` should invoke layout only for contexts that declare a logical layout:

```lua
if self.context and self.context.layout and self.provider.layout then
  self.provider.layout(self.nodes)
end
```

World contexts leave `layout = nil` and keep true entity coordinates.

---

## 6. `HoloLayout.lua` — camera and layout math

### 6.1 Correct projection and inversion

The original `project` / `unproject` pair is mathematically sound for the `z = 0` plane. It was tested with 10,000 randomized round-trips. The missing piece was using `unproject` for panning.

Reference implementation:

```lua
local HoloLayout = {}

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

function HoloLayout.project(cam, x, y, z, vx, vy, vsx, vsy)
  z = z or 0
  local zoom = cam.zoom or 1
  local dx = (x - (cam.x or 0)) * zoom
  local dy = (y - (cam.y or 0)) * zoom
  local dz = (z or 0) * zoom

  local cy, sy = math.cos(cam.yaw or 0), math.sin(cam.yaw or 0)
  local rx = dx * cy - dy * sy
  local ry = dx * sy + dy * cy

  local cp, sp = math.cos(cam.pitch or 0), math.sin(cam.pitch or 0)
  local py = ry * cp - dz * sp
  local pz = ry * sp + dz * cp

  local f = cam.fovDist or 900
  local depth = f + pz
  if depth < 40 then return nil end

  local scale = f / depth
  return vx + vsx * 0.5 + rx * scale,
         vy + vsy * 0.5 + py * scale,
         scale, depth
end

function HoloLayout.unproject(cam, mx, my, vx, vy, vsx, vsy)
  local nx = mx - (vx + vsx * 0.5)
  local ny = my - (vy + vsy * 0.5)
  local cp, sp = math.cos(cam.pitch or 0), math.sin(cam.pitch or 0)
  local f = cam.fovDist or 900

  local denom = cp * f - ny * sp
  if math.abs(denom) < 1e-4 then return nil end

  local ry = ny * f / denom
  local scale = f / (f + ry * sp)
  local rx = nx / scale

  local cy, sy = math.cos(-(cam.yaw or 0)), math.sin(-(cam.yaw or 0))
  local dx = rx * cy - ry * sy
  local dy = rx * sy + ry * cy
  local zoom = cam.zoom or 1

  return (cam.x or 0) + dx / zoom,
         (cam.y or 0) + dy / zoom
end
```

### 6.2 Correct tilted panning

Panning must preserve the world point grabbed under the cursor:

```lua
function HoloLayout.pan(cam, fromX, fromY, toX, toY, vx, vy, vsx, vsy)
  local ax, ay = HoloLayout.unproject(cam, fromX, fromY, vx, vy, vsx, vsy)
  local bx, by = HoloLayout.unproject(cam, toX, toY, vx, vy, vsx, vsy)
  if not ax or not bx then return false end
  cam.x = (cam.x or 0) - (bx - ax)
  cam.y = (cam.y or 0) - (by - ay)
  return true
end
```

Do not use raw `deltaX / zoom` once yaw, pitch, or perspective is active.

### 6.3 Radius projection

Graph radius and screen radius must use the same convention:

```lua
function HoloLayout.projectRadius(cam, radius, scale)
  return math.max(1.0, (radius or 1) * (cam.zoom or 1) * (scale or 1))
end
```

The original `sqrt(zoom)` scaling made nodes shrink relative to the layout as zoom increased.

### 6.4 Layout policies

```lua
function HoloLayout.radial(children)
  local n = #children
  if n == 0 then return end

  local perRing = 12
  local rings = math.max(1, math.ceil(n / perRing))
  local baseRadius = 170
  local ringGap = 105

  for i = 1, n do
    local ring = math.floor((i - 1) / perRing)
    local slot = (i - 1) % perRing
    local count = math.min(perRing, n - ring * perRing)
    local a = -math.pi * 0.5 + math.pi * 2 * slot / count
    local r = baseRadius + ring * ringGap
    children[i].tx = math.cos(a) * r
    children[i].ty = math.sin(a) * r
    children[i].tz = 0
  end
end

function HoloLayout.cardinal(children)
  local n = #children
  local angles = { -math.pi * 0.5, 0, math.pi * 0.5, math.pi }
  for i = 1, n do
    local a
    if n == 2 then
      a = i == 1 and math.pi or 0
    else
      local layer = math.floor((i - 1) / 4)
      a = angles[((i - 1) % 4) + 1] + layer * 0.35
    end
    local r = 190 + math.floor((i - 1) / 4) * 90
    children[i].tx = math.cos(a) * r
    children[i].ty = math.sin(a) * r
    children[i].tz = 0
  end
end

function HoloLayout.rectilinear(children)
  local n = #children
  local cols = math.max(2, math.ceil(math.sqrt(n)))
  local rows = math.ceil(n / cols)
  for i = 1, n do
    local col = (i - 1) % cols
    local row = math.floor((i - 1) / cols)
    children[i].tx = (col - (cols - 1) * 0.5) * 150
    children[i].ty = (row - (rows - 1) * 0.5) * 85
    children[i].tz = 0
  end
end

function HoloLayout.spiral(children)
  local golden = 2.399963229728653
  for i = 1, #children do
    local r = 48 * math.sqrt(i)
    local a = i * golden
    children[i].tx = math.cos(a) * r
    children[i].ty = math.sin(a) * r
    children[i].tz = math.sin(i * 0.5) * 14
  end
end

function HoloLayout.spatial(children)
  local maxR = 1
  local hasSpatial = false
  for i = 1, #children do
    local c = children[i]
    if c.wx or c.wz then
      hasSpatial = true
      local d = math.sqrt((c.wx or 0)^2 + (c.wz or 0)^2)
      if d > maxR then maxR = d end
    end
  end

  -- Never collapse a logical tree at the origin just because Tab selected
  -- spatial mode. Fall back to radial until a spatial provider is available.
  if not hasSpatial then return HoloLayout.radial(children) end

  local norm = 320 / maxR
  for i = 1, #children do
    local c = children[i]
    c.tx = (c.wx or c.x or 0) * norm
    c.ty = (c.wz or c.y or 0) * norm
    c.tz = (c.wy or c.z or 0) * norm * 0.35
  end
end

function HoloLayout.apply(mode, children)
  if mode == 'spatial' then HoloLayout.spatial(children)
  elseif mode == 'cardinal' then HoloLayout.cardinal(children)
  elseif mode == 'rectilinear' then HoloLayout.rectilinear(children)
  elseif mode == 'spiral' then HoloLayout.spiral(children)
  else HoloLayout.radial(children) end
end
```

Layout rules:

- `NodeGraph` remains responsible for fit and declutter.
- Large logical views use multiple radial rings or provider-specific layouts.
- Switching to a layout without the required data must use an explicit fallback.
- True world coordinates are not rewritten by layout code.

### 6.5 Preview descriptors

Previews should be summaries, not retained live child arrays:

```lua
function HoloLayout.previewOffsets(spec, budget)
  budget = math.min(budget or 16, 32)
  local points = spec.points or {}
  local count = math.min(#points, budget)
  local out = {}

  if spec.layout == 'spatial' then
    local maxR = 1
    for i = 1, count do
      local p = points[i]
      local d = math.sqrt((p.x or 0)^2 + (p.z or 0)^2)
      if d > maxR then maxR = d end
    end
    for i = 1, count do
      local p = points[i]
      out[i] = {
        dx = (p.x or 0) / maxR * 38,
        dy = (p.z or 0) / maxR * 38,
        dz = (p.y or 0) / maxR * 12,
      }
    end
  else
    local r = spec.radius or 26
    for i = 1, count do
      local a = -math.pi * 0.5 + math.pi * 2 * (i - 1) / count
      out[i] = { dx = math.cos(a) * r, dy = math.sin(a) * r, dz = 0 }
    end
  end
  return out
end
```

Preview rules:

- Query only visible drillable majors.
- Cache by `(context, node id, provider revision)`.
- Use 4–8 points at low LOD, 16–32 at high LOD.
- Remote sector previews use deterministic aggregate summaries.
- Preview points must share stable IDs with the eventual drilled children if they are to visually expand into them.

---

## 7. Corrected `holonode.glsl`

Use the custom shader initially only for selected/hovered nodes and active beams. Normal nodes and previews should use batched primitives.

```glsl
/* res/shader/fragment/ui/holonode.glsl */
#include fragment

layout(location = 0) out vec4 fragColor;

uniform int   mode;        // 0 node, 1 beam
uniform float time;
uniform float state;       // 0 normal, 1 active
uniform float drillable;
uniform float radius;      // exact screen-space ring radius
uniform vec4  colPrimary;
uniform vec4  colAccent;
uniform vec2  quadSize;
uniform vec2  segA;
uniform vec2  segB;
uniform float thickness;

float coverage(float d, float width) {
  float lo = max(0.0, width - 0.6);
  float hi = max(lo + 0.001, width + 0.6);
  return 1.0 - smoothstep(lo, hi, d);
}

void main() {
  if (mode == 0) {
    vec2 p = (uv - 0.5) * quadSize;
    float r = length(p);
    float maxR = min(quadSize.x, quadSize.y) * 0.5;
    float ringR = max(1.0, radius);

    vec3 baseCol = mix(colPrimary.rgb, colAccent.rgb, clamp(state, 0.0, 1.0));
    float alpha = colPrimary.a;

    float ring = coverage(abs(r - ringR), thickness);
    float dRing = abs(r - ringR);
    float glow = exp(-dRing * 0.22) * 0.55 + exp(-r * 0.14) * 0.35;

    float coreR = max(2.2, ringR * 0.22);
    float core = coverage(r, coreR);

    float inner = 0.0;
    if (drillable > 0.5 && ringR > 7.0) {
      inner = coverage(abs(r - ringR * 0.68), 1.2) * 0.65;
    }

    float outerHalo = 0.0;
    if (state > 0.5) {
      float outerR = ringR * 1.32 + sin(time * 5.0) * 1.5;
      float angle = atan(p.y, p.x) + time * 1.4;
      float dashes = smoothstep(-0.2, 0.2, sin(angle * 12.0));
      outerHalo = coverage(abs(r - outerR), 1.4) * dashes * 0.95;
    }

    float intensity = ring * 1.35 + glow + core * 1.5 + inner + outerHalo * 1.2;
    float clip = 1.0 - smoothstep(maxR - 4.0, maxR, r);
    float a = alpha * clip;

    // Additive blending is GL_ONE/GL_ONE: RGB must carry its own coverage.
    vec3 rgb = (baseCol * intensity + vec3(core * 0.45)) * a;
    float outAlpha = clamp(intensity * a, 0.0, 1.0);
    fragColor = vec4(rgb, outAlpha);
  } else {
    vec2 p = uv * quadSize;
    vec2 pa = p - segA;
    vec2 ba = segB - segA;
    float len2 = max(dot(ba, ba), 1e-4);
    float t = clamp(dot(pa, ba) / len2, 0.0, 1.0);
    float d = length(pa - ba * t);

    vec3 beamCol = mix(colPrimary.rgb, colAccent.rgb, t * clamp(state, 0.0, 1.0));
    float core = coverage(d, thickness);
    float halo = exp(-d * 0.28) * (0.45 + 0.35 * state);
    float pulse = state > 0.5
      ? 0.85 + 0.25 * sin(t * 18.0 - time * 8.0)
      : 1.0;

    float intensity = (core * 1.3 + halo) * pulse;
    float a = colPrimary.a;
    vec3 rgb = beamCol * intensity * a;
    float outAlpha = clamp(intensity * a, 0.0, 1.0);
    fragColor = vec4(rgb, outAlpha);
  }

  if (isnan(fragColor.r) || isnan(fragColor.g)
      || isnan(fragColor.b) || isnan(fragColor.a)) {
    fragColor = vec4(0.0);
  }
}
```

Required fixes embodied above:

- `fragColor` is declared explicitly.
- No reversed `smoothstep`.
- Additive RGB is coverage-weighted.
- `radius` exactly matches Lua hit-testing.
- NaN output is rejected.

---

## 8. `HoloRenderer.lua` — batched first, custom accents second

### 8.1 Rendering order

1. Cull to widget rect plus margin.
2. Clip long edges to the widget rect.
3. Sort elevated nodes far-to-near.
4. Draw normal edges with batched `DrawEx.Line`.
5. Draw preview dots with batched ring widgets.
6. Draw normal nodes with batched ring widgets.
7. Draw selected/hovered nodes and active beams with `holonode.glsl`.
8. Draw crisp labels, tooltips, editor, and breadcrumb in the normal UI pass.

### 8.2 Batched ring helper

```lua
local WidgetShader_Ring = 3
local BlendMode_Additive = 0

local function ring(x, y, r, color, pad)
  pad = pad or 6
  local sx = math.max(2.0, r * 2 + pad * 2)
  local sy = sx
  local a = color.a * DrawEx.GetAlpha()
  Draw.WidgetRect(
    WidgetShader_Ring, BlendMode_Additive,
    x - sx * 0.5, y - sy * 0.5, sx, sy,
    color.r, color.g, color.b, a,
    r, sx, sy, 0,
    0, 0, 0, 0)
end
```

Normal nodes and preview dots should use this path. It batches consecutive same-shader/blend widgets instead of starting a shader per point.

### 8.3 Segment clipping

Long diagonal beam bounding boxes create unnecessary fragment work. Clip before drawing:

```lua
local function clipSegment(ax, ay, bx, by, minX, minY, maxX, maxY)
  local dx, dy = bx - ax, by - ay
  local t0, t1 = 0.0, 1.0

  local function edge(p, q)
    if math.abs(p) < 1e-9 then return q >= 0 end
    local r = q / p
    if p < 0 then
      if r > t1 then return false end
      if r > t0 then t0 = r end
    else
      if r < t0 then return false end
      if r < t1 then t1 = r end
    end
    return true
  end

  if not edge(-dx, ax - minX) then return nil end
  if not edge( dx, maxX - ax) then return nil end
  if not edge(-dy, ay - minY) then return nil end
  if not edge( dy, maxY - ay) then return nil end

  return ax + dx * t0, ay + dy * t0,
         ax + dx * t1, ay + dy * t1
end
```

### 8.4 Active node/beam shader wrapper

```lua
local function activeNode(shader, time, x, y, r, color, state, drillable)
  if not shader then return end
  local pad = r * 2.4 + 12
  BlendMode.PushAdditive()
  shader:start()
    Shader.SetInt('mode', 0)
    Shader.SetFloat('time', time)
    Shader.SetFloat('state', state)
    Shader.SetFloat('drillable', drillable and 1 or 0)
    Shader.SetFloat('radius', r)
    Shader.SetFloat4('colPrimary', color.r, color.g, color.b,
      color.a * DrawEx.GetAlpha())
    Shader.SetFloat4('colAccent', 1.0, 0.18, 0.32, 1.0)
    Shader.SetFloat2('quadSize', pad * 2, pad * 2)
    Shader.SetFloat('thickness', math.max(1.3, r * 0.11))
    Draw.Rect(x - pad, y - pad, pad * 2, pad * 2)
  shader:stop()
  BlendMode.Pop()
end
```

Only a handful of active nodes/beams should use this path. If profiling shows named uniform lookup is expensive, cache locations with `ShaderVarCache` and use `Shader.ISet*`.

### 8.5 Depth and LOD

- Nodes with nonzero `z` are sorted by projected depth.
- Text is disabled below the semantic-zoom threshold.
- Previews use a smaller point budget at low zoom.
- Off-screen nodes use the existing `NodeGraph` indicator system rather than custom Holo indicators in Phase A.
- Minor caps remain owned by `NodeGraph`, not duplicated in `HoloRenderer`.

---

## 9. `HoloGraph` construction and input

### 9.1 Correct construction

`Container()` is not constructible. Use the same pattern as `NodeGraph` or a plain container instance:

```lua
local HoloGraph = {}
HoloGraph.__index = HoloGraph
setmetatable(HoloGraph, Container)

function HoloGraph.Create(rootNode, opts)
  local self = setmetatable({
    children = List(),
    rootNode = rootNode,
    stack = {},
    activeNodes = {},
    inputConsumed = false,
  }, HoloGraph)

  self:setStretch(1, 1)
  self:setEState(Container.EState.Enabled)
  self.cam = {
    x = 0, y = 0, zoom = 1, targetZoom = 1,
    pitch = 0.26, targetPitch = 0.26,
    yaw = 0, targetYaw = 0, fovDist = 900,
  }
  return self
end
```

For F10 integration, prefer constructing through the existing `NodeGraph` path rather than creating a second top-level controller.

### 9.2 Avoid duplicate input dispatch

Canvas sends input twice to a focusable root child:

- focused dispatch: `script/UI/Canvas.lua:143-149`
- root-child dispatch: `Canvas.lua:151-155`

Standalone demo pattern:

```lua
function HoloGraph:inputFocused(state)
  -- Root-child Container:input already calls onInput exactly once.
end

function HoloGraph:onInput(state)
  self.inputConsumed = false
  -- ... actual input handling ...
end
```

Embedded focus-only pattern:

```lua
function HoloGraph:inputFocused(state)
  self.inputConsumed = false
  self:onInput(state)
end

function HoloGraph:input(state)
  -- Suppress the unfocused per-child dispatch.
end
```

The embedded mode must explicitly focus HoloGraph when opened and guard mouse/wheel input with `containsPoint`.

### 9.3 Escape consumption

The editor must consume Escape without the app immediately navigating back:

```lua
function HoloGraph:onInput(state)
  self.inputConsumed = false
  if self.editNode then
    if Input.GetPressed(Button.Keyboard.Escape) then
      self.editNode = nil
      self.inputConsumed = true
      return
    end
    -- ... editor input ...
    return
  end
  -- ... graph input ...
end
```

App pattern:

```lua
function HoloNodeDemo:onInput()
  self.canvas:input()
  if Input.GetPressed(Button.Keyboard.Escape) and not self.holo.inputConsumed then
    if not self.holo:drillOut() then self:quit() end
  end
  self.holo.inputConsumed = false
end
```

### 9.4 Global Tab conflict

The base application binds Tab to wireframe before app input: `script/phx/util/ApplicationBindings.lua:5`.

Standalone demo fix:

```lua
function HoloNodeDemo:anyScreenOpen()
  return true
end
```

Embedded fix: use the existing overlay-blocking mechanism or choose a non-conflicting layout key after auditing all bindings. Do not let Tab simultaneously toggle wireframe and cycle layouts.

### 9.5 Gamepad confirm/cancel and angular selection

The original prose described A/Cross and B/Circle, but the code only read the left stick.

```lua
function HoloGraph:activateHovered()
  if self.hoveredId == '__parent' then return self:drillOut() end
  for i = 1, #self.activeNodes do
    if self.activeNodes[i].id == self.hoveredId then
      return self:drillInto(self.activeNodes[i])
    end
  end
  return false
end

function HoloGraph:gamepadSelection()
  local gx = Input.GetValue(Button.Gamepad.LStickX)
  local gy = Input.GetValue(Button.Gamepad.LStickY)
  if gx * gx + gy * gy <= 0.15 then return end

  local vx, vy, vsx, vsy = self:getRectGlobal()
  local hx, hy = HoloLayout.project(self.cam, 0, 0, 0, vx, vy, vsx, vsy)
  if not hx then return end

  local gl = math.sqrt(gx * gx + gy * gy)
  local bestScore, bestId = -2, nil
  for i = 1, #self.activeNodes do
    local n = self.activeNodes[i]
    if n._sx then
      local dx, dy = n._sx - hx, n._sy - hy
      local nl = math.sqrt(dx * dx + dy * dy)
      if nl > 1e-3 then
        local score = (gx * dx + gy * dy) / (gl * nl)
        if score > bestScore then bestScore, bestId = score, n.id end
      end
    end
  end
  if bestId then self.hoveredId, self.selectedId = bestId, bestId end
end
```

Input mapping:

- `Button.Gamepad.A` → `activateHovered()`
- `Button.Gamepad.B` → editor cancel or `drillOut()`
- `Button.Keyboard.Return` → `activateHovered()`
- `Button.Keyboard.Backspace` or `Button.Mouse.X1` → `drillOut()`
- Remove the false `Mouse4` legend entry; the real side buttons are `X1`/`X2`.
- Tune stick Y sign against the current control conventions.
- For multiple gamepads, query the intended device explicitly rather than assuming device 0.

### 9.6 Embedded controls

In-game Holo mode must not reuse WASD. Existing `NodeGraph` uses arrow keys and reserves right-click for back:

- `script/UI/NodeGraph.lua:1353-1388`

Phase C must either preserve those semantics or deliberately redesign and test them. Mouse tilt, wheel, and clicks must be ignored when the pointer is outside the graph.

---

## 10. Drill transitions and previews

The original preview expansion was only described, not implemented.

Required behavior:

- Drill stack stores `{ context, camera, focusId, selectedId, layout }`.
- `drillOut` restores the actual previous node and camera.
- Children begin at the clicked node's projected screen position.
- Child visual scale starts at `0.12` and eases to `1.0`.
- Preview points share IDs with the eventual child visuals.
- Moving entities continue updating `tx/ty/tz` after creation.
- Parent breadcrumb represents the actual previous node, not a generic fixed left-side node.

Reference transition fields:

```lua
local visual = {
  id = child.id,
  x = startX, y = startY, z = startZ,
  tx = layoutX, ty = layoutY, tz = layoutZ,
  scale = 0.12, targetScale = 1.0,
}
```

`NodeGraph` should own the drill stack and restoration. `HoloRenderer` should only consume the resulting visual state.

---

## 11. Standalone demo scope

The first demo is explicitly a **mock look-and-feel harness**.

It should demonstrate:

- five layouts;
- 0°/15°/25° tilt presets;
- semantic zoom;
- drill/back;
- preview-to-child expansion;
- selected/hovered SDF accents;
- mouse, keyboard, and gamepad parity;
- numeric editing of mock values.

It does not need:

- a live 3D star system;
- AI miners;
- real physics;
- real market data;
- renderer changes.

### Corrected launch

```bash
./run.sh HoloNodeDemo
```

`Main.lua:61` prefixes the app argument with `App.`. Do not pass `App/HoloNodeDemo`. `NpcKTest.lua` does not exist in this checkout; use `UI_Demo` or `InputTest` as current examples.

### Demo app skeleton

```lua
local HoloGraph = require('UI.HoloGraph')

local HoloNodeDemo = Application()

function HoloNodeDemo:anyScreenOpen()
  return true -- suppress global Tab/wireframe and other app shortcuts
end

function HoloNodeDemo:onInit()
  self.canvas = UI.Canvas()
  self.canvas.showCursor = true
  self.holo = HoloGraph.Create(self:buildMockGraph())
  self.canvas:add(self.holo)
  Input.SetMouseVisible(false)
end

function HoloNodeDemo:onInput()
  self.canvas:input()
  if Input.GetPressed(Button.Keyboard.Escape) and not self.holo.inputConsumed then
    if not self.holo:drillOut() then self:quit() end
  end
  self.holo.inputConsumed = false
end

function HoloNodeDemo:onUpdate(dt)
  self.simOre = (self.simOre or 0) + dt * 1.5
  self.canvas:update(dt)
end

function HoloNodeDemo:onDraw()
  Draw.Clear(0.01, 0.015, 0.03, 1.0)
  self.canvas:draw(self.resX, self.resY)
end

return HoloNodeDemo
```

Font scaling should move to `onResize` so the resizable demo does not keep stale font sizes.

---

## 12. Phase B — real-provider demo

Before F10 integration, the same widget must run against real data:

- sectors and jumpgates;
- current sector/region state;
- stations, markets, factories;
- ships and sockets;
- inventory/cargo;
- `ShipEquipment` definitions and installed module tiers;
- live health/shield/capacitor values.

This is the important proof. Fake nodes prove drawing; they do not prove data access.

### Required adapters

- `GalaxyProvider`: sector nodes and gate links.
- `SectorProvider`: existing `GraphProvider.system()`.
- `ShipProvider`: sockets, inventory, health, shield, capacitor, equipment.
- `MarketProvider`: bids/asks and depth.
- `EquipmentProvider`: canonical `ShipEquipment.Defs` plus installed tier.

### Live editing rules

- Numeric config/equipment values use explicit setters.
- Entity vectors use `getPos`/`setPos` or component setters, not raw cdata writes.
- Inventory changes use `addItem`/`removeItem` so cached free mass stays correct.
- Market changes use market methods so escrow/sorting invariants stay correct.
- Unknown FFI pointers are displayed read-only.
- Projectile color is not currently a data field; `Pulse.Render` hard-codes it. Add a real field before claiming live color editing.

---

## 13. Phase C — optional F10 Holo mode

F10 integration is a visual mode, not a new map.

### Integration rules

- Preserve all 88 existing NodeGraph checks.
- Keep `NodeGraph` as owner of fit, declutter, filters, indicators, inspector, drill stack, and camera restoration.
- Add `visualMode = 'classic' | 'holo'`.
- Add optional `z`, `layout`, and `preview` fields to unit records.
- Invoke provider layout for logical contexts.
- Let `HoloRenderer` consume normalized node/edge records.
- Keep classic rendering as the fallback if the Holo shader fails.
- Do not duplicate input handling in a second widget.
- Do not reuse WASD.
- Register Holo mode with the existing overlay/input-blocking path.

### Conceptual `NodeGraph` hook

```lua
function NodeGraph:onDraw(focus, active)
  if self.visualMode == 'holo' and self.holoRenderer then
    self.holoRenderer:draw(self, focus, active)
  else
    self:drawClassic(focus, active)
  end
end
```

The existing draw body becomes `drawClassic`; behavior remains unchanged when `visualMode ~= 'holo'`.

---

## 14. Phase D — optional HDR Holo layer

Only pursue this after the SDR demo and real-provider demo are approved.

### 14.1 Recommended pipeline

- Keep normal UI in `uiBuffer` and composite after tonemapping.
- Add a transparent `RGBA16F holoBuffer`.
- Render only Holo nodes/edges/previews into `holoBuffer`.
- Blur/bloom `holoBuffer` independently.
- Composite `scene + holo + holoGlow * strength` after tonemapping.
- Keep labels, tooltips, editor, inspector, and the dark backdrop in the crisp normal UI layer.

### 14.2 Renderer lifecycle sketch

```lua
-- In Renderer:start, when resolution changes:
self.holoBuffer = createBuffer(sx, sy, TexFormat.RGBA16F)
self.holoBlur = createBuffer(math.max(1, math.floor(sx / 4)),
                            math.max(1, math.floor(sy / 4)), TexFormat.RGBA16F)

-- In Renderer:free:
if self.holoBuffer then self.holoBuffer:free(); self.holoBuffer = nil end
if self.holoBlur then self.holoBlur:free(); self.holoBlur = nil end
```

### 14.3 GameView pass sketch

```lua
-- After world/TAA, before normal UI:
renderer:startHolo(uiKx, uiKy)
holoRenderer:draw(self.nodeGraph)
renderer:endHolo()

-- Normal UI pass continues unchanged.
renderer:startUI(renderer.uiBuffer)
-- ... existing children, HUD, inspector, labels ...
renderer:endUI()

-- Existing scene bloom/post chain.
-- Then composite normal UI and the independent Holo layer.
```

`startHolo` must establish:

- `RenderTarget.Push` and `BindTex2D(holoBuffer)`;
- transparent clear;
- viewport;
- `ClipRect` transform;
- `mViewUI` scaling;
- additive blend;
- depth test/write disabled;
- cull disabled;
- balanced pop/free of all temporary matrices and state.

Do not use `Renderer:startUI(renderer.buffer0)` for this: it clears the scene. Do not merely reference `buffer0` without binding it.

### 14.4 Composite shader sketch

```glsl
/* res/shader/fragment/filter/holo_overlay.glsl */
#include filter

layout(location = 0) out vec4 fragColor;

uniform sampler2D scene;
uniform sampler2D holo;
uniform sampler2D holoGlow;
uniform float glowStrength;

void main() {
  vec3 c = texture(scene, uv).rgb;
  c += texture(holo, uv).rgb;
  c += texture(holoGlow, uv).rgb * glowStrength;
  fragColor = vec4(c, 1.0);
}
```

This avoids putting Holo text/backdrop through scene tonemapping, volumetrics, sharpen, FXAA, or grain.

---

## 15. Phase D — reflection/editor provider

### 15.1 Read-only first

Start with a schema-driven read-only provider. Add editing only for known safe fields.

```lua
local Schema = {}

Schema.Vec3f = {
  fields = { 'x', 'y', 'z' },
  get = function(v, key) return v[key] end,
  set = function(v, key, value)
    if type(value) ~= 'number' then return false end
    v[key] = value
    return true
  end,
}

local function ctypeName(value)
  local ok, name = pcall(function()
    return tostring(ffi.typeof(value))
  end)
  return ok and name or nil
end

local function walk(value, path, depth, seen, out)
  if depth > 6 or #out >= 256 then return end
  if type(value) == 'table' then
    if seen[value] then return end
    seen[value] = true
    for key, child in pairs(value) do
      walk(child, path .. '.' .. tostring(key), depth + 1, seen, out)
    end
    return
  end

  local name = ctypeName(value)
  local schema = name and Schema[name]
  if schema then
    for i = 1, #schema.fields do
      local key = schema.fields[i]
      out[#out + 1] = {
        id = path .. '.' .. key,
        label = key,
        value = schema.get(value, key),
        setValue = function(v) return schema.set(value, key, v) end,
      }
    end
    return
  end

  if type(value) == 'number' or type(value) == 'string' or type(value) == 'boolean' then
    out[#out + 1] = { id = path, label = path, value = value }
  end
end
```

### 15.2 Editing policy

Allowed first:

- numeric config values;
- `ShipEquipment` definition values;
- simple scalar fields with explicit setters.

Require adapters:

- entity position/rotation;
- inventory counts;
- market orders;
- health/shield/capacitor;
- module replacement.

Forbidden initially:

- arbitrary pointers;
- raw engine handles;
- unknown cdata;
- direct mutation of cached inventory/market structures;
- inherited method enumeration as if it were data.

Override serialization should record validated `(path, value)` pairs and merge them into a mod/config file. Do not dump raw tables or pointers.

---

## 16. Test plan

### 16.1 `tools/validate_holo_layout.lua`

GL-free tests:

- 1,000+ project/unproject round-trips under varied yaw/pitch/zoom;
- near-plane and degenerate-denominator rejection;
- tilted pan keeps the grabbed world point under the cursor;
- projected radius matches hit-test radius;
- deterministic output for every layout;
- radial layouts do not overlap for 1, 12, 13, 50, and 100 nodes;
- spatial fallback when logical nodes lack world coordinates;
- preview budgets and deterministic ordering;
- explicit depth values for elevated nodes.

### 16.2 `tools/validate_holo_input.lua`

Stub only the input boundary and assert graph behavior:

- focused + root dispatch invokes `onInput` once;
- Tab cycles one layout;
- Backspace/X1 pops one level;
- editor Escape is consumed without app back;
- gamepad A activates hovered node;
- gamepad B cancels/back;
- Return activates `__parent`;
- angular selection uses projected screen directions;
- mouse wheel is ignored outside the widget;
- no duplicate editor characters.

### 16.3 Extend `tools/validate_nodegraph.lua`

- provider layout is invoked exactly once for logical contexts;
- world contexts do not invoke logical layout;
- array/map provider normalization;
- virtual context drill/resolve;
- preview cache invalidation;
- `z` survives merge and interpolation;
- drill/back restores camera, focus, and selection;
- classic mode remains behavior-identical;
- all existing 88 checks still pass.

### 16.4 Shader validation

Always run before shader edits:

```bash
python3 configure.py test
```

`holonode.glsl` must compile/link at GLSL 460 through `tools/validate_glsl.py`.

The validator cannot verify blend conventions, uniform names, render-target binding, or eager autovar setup; those need runtime smoke tests.

### 16.5 Runtime smoke test

Add `PHX_HOLOTEST=1` stages to the demo:

1. boot;
2. open root;
3. cycle all layouts;
4. drill into a preview node;
5. back restores camera/focus;
6. hover activates SDF path;
7. editor applies and cancels;
8. gamepad selection/confirm/back;
9. resize;
10. quit.

Capture screenshots at:

- tilt 0°;
- tilt 15°;
- tilt 25°;
- zoomed out with labels hidden;
- zoomed in with previews visible;
- classic versus Holo A/B.

### 16.6 Performance budget

Profile with:

- 25 nodes;
- 100 nodes;
- 500 logical nodes;
- existing dense sector map.

Targets:

- no per-preview shader start/stop;
- normal nodes/edges/previews batch;
- only active Holo accents use the custom shader;
- no off-screen draw work beyond indicators;
- preview queries are cached and budgeted;
- no full-tree rebuild per visible node per frame;
- no obvious focus/input regression at 100 nodes.

---

## 17. Acceptance criteria

Phase A is complete when:

- the demo launches with `./run.sh HoloNodeDemo`;
- the shader validates;
- no duplicate input occurs;
- all five layouts work;
- spatial fallback prevents origin collapse;
- drill/back restores camera and focus;
- preview children expand from the clicked node;
- mouse/keyboard/gamepad interactions agree;
- the 100-node demo has no obvious frame-rate or focus problems;
- screenshots demonstrate the intended Update #10/#11 feel.

Phase B is complete when:

- real sectors, gates, stations, markets, ships, sockets, inventory, and `ShipEquipment` data populate the same widget;
- no static mock tree is required;
- live values update;
- validated edits affect real data;
- provider scratch/lifetime issues are covered by tests.

Phase C is complete when:

- Holo is an optional F10 mode;
- classic mode is unchanged;
- all existing NodeGraph checks pass;
- flight input remains suppressed;
- existing filters, indicators, inspector, and NPC selection still work;
- projection, pan, preview, and camera-restoration tests pass.

Phase D is optional and complete when:

- the dedicated HDR layer composites correctly;
- normal UI remains crisp and outside scene bloom;
- the reflection editor is read-first and schema-safe;
- performance remains acceptable with the real map.

---

## 18. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Holo mode regresses the current map | Keep `NodeGraph` controller and classic renderer; optional mode only |
| Draw-call explosion | Batch normal nodes/edges/previews; custom shader only for active accents |
| Preview cost grows with sector density | Visible-major query, provider cache, LOD budgets, aggregate summaries |
| 3D tilt hurts readability/precision | Subtle default tilt, 0° preset, screen-facing Phase-A nodes, crisp post-UI text |
| Input conflicts with flight/UI | Focus-only embedded mode, existing overlay blocking, no WASD |
| Drill transitions feel discontinuous | Shared child IDs, projected click origin, scale animation, camera/focus stack |
| Generic editor corrupts state | Read-first schemas, validated setters, depth/cycle caps, no unknown pointers |
| HDR pass changes world appearance | Dedicated `holoBuffer` and independent composite; do not reuse scene bloom blindly |
| Provider scratch data invalidates previews | Owned snapshots or provider revision keys |
| Layout mode lacks required data | Explicit fallback policy and tests |

---

## 19. Final recommendation

**Proceed with a corrected Phase-A demo.** Do not replace F10 `NodeGraph` and do not modify the renderer yet.

Build the demo as:

1. `HoloLayout` for tested camera/layout math;
2. `HoloRenderer` for batched nodes/edges/previews plus active SDF accents;
3. a small standalone mock app;
4. layout/input/shader validators.

Once the look and interaction are approved, move the same renderer/layout behind an optional `NodeGraph.visualMode`, connect the real providers, and only then evaluate a dedicated HDR Holo layer.

That sequence captures the old Limit Theory ambition without discarding the working map or turning a visual experiment into a risky rewrite.
