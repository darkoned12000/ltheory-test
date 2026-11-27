# Limit Theory Reboot: Nodal UI / Holo Node Plan — Verified Revision 2

**Date:** 2026-11-26

**Status:** Phase A standalone demo implemented and visually approved on branch `nodeui2`; uncommitted. Phase B1 density/provider foundations and the Phase B2 real-entity provider, mesh-preview, and command-router core are implemented. Live F10 wiring and navigation hardening remain pending. F10 `NodeGraph` and the renderer pipeline remain unchanged.
**Supersedes:** the original drop-in `HoloNodeDemo` snippets in this document. Those snippets were a useful visual sketch, but they were not runnable or safe to integrate as written.

## Phase A implementation status (2026-11-26)

The standalone demo is now runnable:

```bash
./run.sh HoloNodeDemo
```

Automated runtime smoke test:

```bash
tools/run_holo_test.sh
# or: python3 configure.py test
```

Implemented files:

- `script/UI/HoloLayout.lua`
- `script/UI/HoloField.lua`
- `script/UI/HoloRenderer.lua`
- `script/UI/HoloGraph.lua`
- `script/UI/HoloInfoPanel.lua`
- `script/App/HoloNodeDemo.lua`
- `res/shader/fragment/ui/holonode.glsl`
- `tools/validate_holo_layout.lua`
- `tools/validate_holo_input.lua`
- `tools/validate_holo_renderer.lua`
- `tools/validate_holo_field.lua`
- `tools/validate_holo_info.lua`
- `tools/validate_holo_demo.lua`
- `tools/validate_holo_runner.py`
- `tools/validate_ring_edge.py`
- `tools/run_holo_test.sh`

Controls:

- Single click: select a node and open its base actions
- Double click / Enter / Gamepad A: drill or edit
- Right-click / Backspace / Mouse X1 / Gamepad B: back
- Middle mouse: pan
- Wheel: cursor-anchored zoom
- Arrow keys or right-drag: tilt/yaw
- F1 / F2 / F3: 0° / 15° / 25° tilt presets
- Tab: cycle layout
- Left stick: angular selection
- Select a node: open the upper-right preview and context-action menu
- Escape / Gamepad B: cancel editor, then back, then quit

The demo includes five layouts, 0–25 degree tilt, semantic zoom, cached one-level previews, an opt-in 45-second star-system preview orbit, preview-to-child expansion, crimson active paths, tooltips, live mock values, and a numeric editor. Components, inventory previews, and asteroid previews remain stationary. Normal nodes/edges/previews are batched; only active accents use the custom shader. Screenshots are written to `./screenshot/` by `PHX_HOLOTEST=1`.

### Review hardening

- Camera pan is restored on drill/back; screen unprojection rejects non-finite, near-plane, and near-horizon rays.
- Gamepad Y follows the engine's positive-up convention, and confirm retains the last selection after mouse hover clears.
- Slow right drags accumulate total displacement instead of being misclassified as clicks; outside mouse presses cannot pan or drill back.
- Nested/sibling UI uses focus-gated input; only a sole Canvas child runs in standalone input mode.
- Invalid or rejected numeric edits keep the editor open and display an error; records without setters are read-only.
- Preview snapshots retain at most 32 points and switch between 8/20/32 rendered points with zoom.
- Graph drawing is clipped to its widget, tooltips are vertically clamped, and custom active beams are capped at eight per frame.
- Runtime stages assert every context, stack depth, editor transition, and committed value. Both runners require a clean zero exit status, even after seeing the PASS marker.

### Completed visual/density fixes

- ✅ Opt-in star-system preview orbit: only descriptors with `preview.orbit = true` rotate; the root system preview completes one revolution in 45 seconds.
- ✅ Non-system previews stay stationary: components, inventory, research, and asteroid previews do not rotate.
- ✅ Shared ring shader fades to zero at its square quad edge, removing the faint background square beneath nodes.
- ✅ Demo asteroids are marked minor and no longer receive default system-hub spokes.
- ✅ Upper-right selected-node preview card with procedural live schematic, description, stats, and context-action menu.
- ✅ Mock actions are interactive and node-specific: Inspect/Open, Goto, Target, Dock, Trade, Factory, Scan, Mine, Hail, Configure, and Edit.
- ✅ Nested menus support station commodity buy/sell and refinery production controls with Back navigation.
- ✅ Provider-owned structural snapshots prevent reused scratch arrays/records from changing an open Holo context.
- ✅ Major graph nodes are separated from a batched minor asteroid/debris field.
- ✅ Deterministic spatial clusters unpack into selectable points with zoom; selected minors remain individually visible.
- ✅ 2,000-point renderer batching and 10,000-asteroid field/LOD contracts pass without minor spokes, labels, or custom shader starts.
- ✅ Asteroid field markers render at 75% radius while retaining a usable hit target.
- ✅ Single-click selects; double-click drills. Enter/Gamepad A remain explicit drill/edit actions.
- ✅ Player ship uses a yellow-gold node identity distinct from NPC ships.
- ✅ Mock Scan, Dock, and Trade actions are distance-gated and display `You are not within range to perform action.` when unavailable.
- ✅ Preview descriptors accept `{ kind, entity }` live references; the mock still draws a procedural schematic until the Phase-B2 adapter lands.
- ⏳ Live-map wiring for the real-provider adapters and remaining navigation hardening are pending.

### Phase B2 core added

- `UI.HoloProvider`: real-entity identity, description, live stats, exact mesh preview descriptor, and capability/range-aware actions.
- `UI.HoloPreview`: cached, normalized CPU wireframe rendered from the selected entity's real mesh.
- `Game.HoloCommands`: app-level Goto, Target, Scan, Mine, Dock, Trade, Travel, and factory-info command routing.
- `LTheory.holoCommands`: command service is constructed with the real app/player; Holo UI wiring remains Phase C.

Phase B1 is complete. Phase B2's provider/preview/command core is implemented and unit-tested; wiring it into the live F10 selection path remains pending. Before that wiring, the adapter must continue supplying stable owned snapshots (or revision keys), because the existing `GraphProvider` reuses scratch arrays.

A 500-node stress mode is available for profiling:

```bash
PHX_MUTE=1 PHX_WINDOWED=1 PHX_FIXED_SIZE=1280,800 \
  PHX_FIXED_DT=0.016 PHX_HOLO_STRESS=500 PHX_PERF=60 PHX_PERF_EXIT=300 \
  ./run.sh HoloNodeDemo
```

Measured on the development host after warm-up: approximately **0.50–0.58 ms mean frame time** with 500 mock nodes.

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
| `script/UI/HoloField.lua` | Batched minor-entity field, deterministic clustering, and LOD | B1 |
| `script/UI/HoloInfoPanel.lua` | Selected-object preview/action card | B2 |
| `script/UI/HoloProvider.lua` | Real-entity info, mesh-preview descriptor, and action adapter | B2 |
| `script/UI/HoloPreview.lua` | Cached CPU-projected live mesh preview | B2 |
| `script/Game/HoloCommands.lua` | App-level Goto/Target/Scan/Mine/Dock/Trade command router | B2 |
| `script/UI/HoloActions.lua` | Proposed UI action contract and validation | B |
| `script/App/LTheory.lua` | Proposed app-level Goto command routing | B |
| `script/UI/NodeGraph.lua` | Optional Holo mode and `z`/layout/preview records | C |
| `tools/validate_holo_layout.lua` | Projection, pan, layout, preview, and camera tests | A |
| `tools/validate_holo_input.lua` | Duplicate-input, editor, and gamepad tests | A |
| `tools/validate_holo_info.lua` | Preview-panel layout, action, and close contracts | B |
| `tools/validate_holo_field.lua` | 2,000/10,000-asteroid clustering, LOD, and selection contracts | B1 |
| `tools/validate_holo_actions.lua` | Proposed selection, info, and Goto command contracts | B |
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
  field = false,                -- proposed: minor point, no default spoke/label
  cluster = nil,                -- proposed: { count, bounds, summary }
  info = nil,                   -- proposed: provider key/descriptor
  actions = nil,                -- proposed: provider key or action descriptors

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
- `major` nodes participate in the relationship graph; `field` minors are rendered by the batched field layer.
- Cluster records are virtual nodes with stable IDs, member counts, bounds, and deterministic summaries.
- `info` and `actions` are provider-owned descriptors; the UI must not invent gameplay policy.
- `HoloGraph.Create` owns structural snapshots of context/child/edge/preview/info/action arrays so providers may reuse scratch arrays after entry; live entity handles and getter/setter functions remain references.
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

Proposed Phase B additions:

```text
provider.field(ctx, budget)
  -> { points = {...}, clusters = {...} }

provider.info(node)
  -> { image, title, subtitle, description, stats = {...} } | nil

provider.actions(node)
  -> { { id, label, enabled, reason }, ... }
```

`field` supplies aggregate/budgeted minor-entity data. `info` feeds the shared detail card. `actions` advertises context-sensitive commands such as Goto, Target, Dock, Mine, Trade, or Interact; the app remains responsible for executing them safely.

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
2. Draw the batched minor-entity field and aggregate clusters.
3. Clip long edges to the widget rect.
4. Sort elevated nodes far-to-near.
5. Draw normal edges with batched `DrawEx.Line`; never draw default spokes to field minors.
6. Draw preview dots with batched ring widgets; only opt-in star-system groups orbit.
7. Draw normal nodes with batched ring widgets.
8. Draw selected/hovered nodes and active beams with `holonode.glsl`.
9. Draw crisp labels, tooltips, editor, inspector, and breadcrumb in the normal UI pass.

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

### 8.6 Opt-in star-system preview orbit

Only preview descriptors with `orbit = true` rotate. The demo opts in the `KAMW-3533X` region's five star-system micro-nodes; component, inventory, research, and asteroid previews remain stationary.

The default speed is `2π / 45 rad/s`: exactly one revolution every 45 seconds.

Implementation contract:

- Animation is renderer-only; preview IDs and drill-origin descriptors remain stable.
- Parent nodes, labels, and graph edges stay stationary.
- Z/elevation is preserved while preview X/Y offsets rotate.
- `Renderer.Create({ previewOrbitSpeed = 0 })` disables the motion for reduced-motion or deterministic capture modes.
- `tools/validate_holo_renderer.lua` asserts opt-in motion, a 45-second revolution, stationary non-system previews, a fixed parent, and zero-speed disablement.

### 8.7 Selected-node preview and action panel

`HoloInfoPanel` is an upper-right `Container` that opens for the current `NodeGraph`/Holo selection. It draws a procedural holographic schematic, provider-supplied title/subtitle/description, live stats, status text, and up to four context actions.

The standalone mock now supplies `info` and `actions` descriptors for regions, systems, stations, ships, asteroids, weapons, inventory, research, and editable values. Buttons use the normal UI focus/click path plus Holo styling; disabled actions display their reason. Actions can open nested submenus with a Back button. The panel closes without clearing the graph selection and reopens when selection changes.

`info.preview` accepts either the mock's procedural kind string or a live descriptor such as `{ kind = 'mesh', entity = node.entity }`. Phase B2's preview adapter will resolve that exact entity/image, so a selected asteroid, ship, station, factory, or planet can display its own real mesh/image. The current standalone demo intentionally remains procedural.

Real images/meshes and real action execution remain provider/app integration work. Mock Goto/Target/Dock/Trade/Scan/Mine/Hail actions only update mock state and panel feedback; they do not move a ship.

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

The approved density, inspector, action, and navigation structure is tracked in section 19. Before F10 integration, the same widget must run against real data:

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
- single-click selects without drilling and double-click drills;
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

1. boot and open the selected region preview;
2. cycle all layouts;
3. drill into a preview node;
4. open a station preview, exercise Goto, then open Trade and sell ore through the nested menu;
5. back restores camera/focus and the root preview;
6. hover activates the SDF path;
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

Profile the Phase B field separately with 2,000 and 10,000 asteroids. Targets are batched field geometry, no default minor spokes/labels, deterministic cluster IDs, and graceful point/cluster LOD rather than linear UI-record growth.

Runtime stress command:

```bash
PHX_MUTE=1 PHX_WINDOWED=1 PHX_FIXED_SIZE=1280,800 \
  PHX_FIXED_DT=0.016 PHX_HOLO_ASTEROIDS=10000 PHX_HOLOTEST=1 \
  PHX_PERF=60 PHX_PERF_EXIT=300 ./run.sh HoloNodeDemo
```

Development-host runs completed without crashes: approximately **0.9–1.3 ms mean** in early/root stages and **1.1–2.1 ms mean** while the 10,000-asteroid system field was active. Pure tests also verify the 4,096-point close-up cap and selected-minor retention.

### 16.7 Phase B feature tests

Add focused contracts as these features land:

- `tools/validate_holo_field.lua`: major/minor partition, no minor spokes, deterministic clustering, selected-minor promotion, point/cluster budgets, and 2,000-asteroid smoke coverage.
- `tools/validate_holo_provider.lua`: real-entity identity, stats, exact preview entity, capability-aware actions, market submenus, and range reasons.
- `tools/validate_holo_preview.lua`: missing-mesh fallback and normalized real-mesh wireframe projection/drawing.
- `tools/validate_holo_commands.lua`: Goto/Target/Scan/Mine/Dock/Trade/Travel routing, range rejection, docking requirements, and market-screen handoff.
- `tools/validate_holo_info.lua`: selected-node preview data, live entity preview descriptors, upper-right layout, bottom action menu, disabled/range reasons, nested submenus/Back, action callbacks, and close behavior.
- `tools/validate_holo_actions.lua`: selection opens the shared info data, actions are provider-owned and validated, virtual nodes cannot receive physical Goto commands, and each target type routes to the correct action.
- Navigation tests: destroyed/removed targets cancel safely, navigation cancellation clears thrust, arrival completes once, and replacing an existing action has explicit semantics.
- Inspector tests: `NodeGraphInspector.show/hide` and `NpcInfoPanel.setSubject` remain compatible with classic mode; Holo styling does not fork entity data.
- Renderer tests: only opt-in star-system previews orbit; the default revolution is 45 seconds; `previewOrbitSpeed = 0` is deterministic; minor nodes receive no default hub spokes.
- `tools/validate_ring_edge.py`: headless pixel test proving the shared ring shader is transparent at every square quad edge while the ring band remains visible.

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
- only opt-in star-system previews orbit, with a 45-second revolution and no change to parent position or drill identity;
- mouse/keyboard/gamepad interactions agree;
- the 100-node demo has no obvious frame-rate or focus problems;
- screenshots demonstrate the intended Update #10/#11 feel.

Phase B is complete when:

- real sectors, gates, stations, markets, ships, sockets, inventory, and `ShipEquipment` data populate the same widget;
- no static mock tree is required;
- live values update;
- validated edits affect real data;
- provider scratch/lifetime issues are covered by tests;
- sector views separate major relationship nodes from the batched asteroid/minor field;
- dense asteroid fields cluster and unpack through semantic zoom without per-asteroid spokes or labels;
- selecting a field point or major node opens shared image/description/stat data;
- provider-owned actions route Goto, Target, Dock, Mine, Trade, and Interact through app-level command handlers;
- Goto uses the existing action stack, handles standoff/arrival/cancellation, and never teleports or mutates transforms directly.

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
| Asteroid density turns the map into a hairball | Major graph + batched field layer; no default minor spokes; cluster/point LOD |
| UI Goto corrupts movement or leaves stale thrust | App-level command handler; action-stack replacement rules; validity checks; explicit thrust cleanup |
| Info panel forks entity data or breaks classic mode | Shared normalized info adapter; preserve existing inspector/NPC panel contracts |

---

## 19. Interaction structure and implementation tracking

**Decision status (2026-11-26):** the Phase-A visual direction is approved. The standalone demo, opt-in 45-second system orbit, ring-edge cleanup, provider snapshots, major/minor split, batched asteroid field, deterministic clustering/LOD, and mock selected-node preview/action panel are implemented. Real info/action adapters, Goto, F10 integration, navigation, and renderer-pipeline work remain unstarted.

### 19.1 Status board

| Feature | Status | Notes |
|---|---|---|
| Standalone Holo demo and validators | ✅ Implemented | Phase A; visually approved |
| Opt-in star-system preview orbit | ✅ Implemented | 45-second revolution; non-system previews stationary |
| Faint square ring-background removal | ✅ Implemented | Shared ring shader fades to zero at quad edges |
| No default asteroid hub spokes | ✅ Implemented | Minors are excluded from the relationship graph |
| Stable provider-owned snapshots | ✅ Implemented | Structural records/arrays copied on context entry |
| Major graph + batched minor field split | ✅ Implemented | Ships/stations/planets remain graph nodes; asteroids enter the field |
| Asteroid clustering and semantic-zoom LOD | ✅ Implemented | Deterministic clusters, zoom unpacking, selected-minor promotion |
| Selected-node preview/action panel | ✅ Mock implemented | Upper-right schematic, description, stats, and interactive menu |
| Real image/description/stat adapter | ✅ Core implemented | `HoloProvider` + cached real-mesh `HoloPreview`; live F10 wiring pending |
| Provider-owned action contract | ✅ Core implemented | Capability/range-aware `HoloProvider`; live F10 wiring pending |
| Goto command routing | ✅ Core implemented | `LTheory.holoCommands` routes real actions; UI wiring pending |
| Navigation cancellation/validity/thrust hardening | ⏳ Pending | Required before shipping Goto |
| Optional F10 Holo mode | ⏸ Deferred | Phase C; preserve classic `NodeGraph` |
| Dedicated HDR Holo layer and audio polish | ⏸ Deferred | Phase D |

### 19.2 Sector display: relationship graph + population field

The sector view uses two distinct layers:

- **Graph layer:** ships, stations, outposts, bases, factories, suns, planets, wormholes, and important player assets. These receive icons, labels, previews, and meaningful spokes/links.
- **Field layer:** asteroids, debris, dust, and minor contacts. These are batched points and aggregate clusters, not full graph nodes with default labels or hub spokes.

Design rule:

> Lines explain connections. Dots show what is out there.

An asteroid belt is one region containing thousands of objects, not thousands of relationships to the sector hub. `GraphProvider` already classifies rocks as minor and named asteroid fields/zones as major; Holo should consume that policy rather than inventing a second classification system. Existing dense-minor and economy-edge caps remain owned by `NodeGraph`.

Fallback hub spokes are limited to `major ~= false`. Explicit provider links may still describe meaningful minor relationships when required.

### 19.3 Asteroid clustering and LOD

Implemented behavior:

- **Far zoom:** dense belts become softly glowing clusters with stable virtual IDs, member counts, bounds, and deterministic summaries.
- **Mid zoom:** clusters unpack into individual batched blue points without labels or spokes.
- **Close zoom:** points become selectable; hover/selection promotes one to a ring, label, tooltip, and optional single accent line.
- **Selected minor:** remains individually visible even while its surrounding cluster is aggregated.
- **Transitions:** crossfade cluster/point representations instead of popping.

Implemented contracts:

- Deterministic spatial hash clustering; no first-N truncation of live scratch arrays.
- Structural context/child snapshots are owned by Holo; live entity handles and getter/setter functions remain references.
- Cluster/point identities stay stable for a context; selected minors are forced into the visible LOD.
- Hit-testing considers clusters and points; selected field data feeds the same info/action panel.
- Close-up points are capped at 4,096 and clusters at 256 per frame; selected objects are retained.
- Field geometry uses batched widget rings; only the selected/hovered field object uses the custom accent shader.
- `PHX_HOLO_ASTEROIDS=2000|10000` supplies a runtime stress count for the first mock system.

### 19.4 Shared selected-object info card

The existing map already has reusable detail systems:

- `script/UI/NodeGraphInspector.lua` draws the selected entity's mesh/wireframe or fallback plus identity, live stats, distance, and bearing. Its public API is `show(node)` / `hide()`, driven by `NodeGraph.focus = node.id`.
- `script/Game/GUI/NpcInfoPanel.lua` is a `Container` with `setSubject(entity)`, an actual mesh preview, and compact live rows. It is the easier base for an interactive card.
- There is no generic prose-description contract yet. Ship archetype descriptions, region `desc`, and system descriptions exist but are not propagated through a common info adapter.

The standalone mock implements `HoloInfoPanel` with procedural schematics and mock `info`/`actions`. Phase B2 now adds `HoloProvider`, which enriches real entity nodes with identity, description, live stats, capability/range-aware actions, and `info.preview = { kind = 'mesh', entity = ... }`. `HoloPreview` caches and draws the selected entity's actual normalized mesh wireframe. The live F10 selection path still needs to pass its player/app context into the panel.

The real-provider version should reuse the same normalized entity data and selection identity, then restyle the shell:

- sliding holographic detail panel;
- existing image/mesh preview with a restrained scan/frame treatment;
- name, classification, description, live stats, distance, and bearing;
- context-sensitive action buttons;
- gamepad navigation and explicit close/back behavior;
- procedural type emblem when no image exists.

Classic mode keeps its current inspector. Holo mode must not fork health, cargo, market, or equipment data.

### 19.5 Actions and Goto

The UI emits intent; the app executes gameplay policy. The standalone mock currently routes menu callbacks through `HoloNodeDemo:onHoloAction` and updates mock target/status state only; it does not push real actions or move a ship.

Mock availability rules demonstrate the intended distance gating: Scan uses a 3,000-unit range, while Dock and Trade use a 1,600-unit service range. Unavailable actions are disabled and display `You are not within range to perform action.` Real providers compute these values from actual ship/target positions and gameplay ranges.

Phase B2 adds `Game.HoloCommands`, constructed as `LTheory.holoCommands`. It validates real targets, enforces Scan/Mine/Dock/Trade ranges, routes Goto/Target/Scan/Mine/Dock/Travel through the existing action stack, and opens the existing market screen for docked Trade. Factory start/stop remains disabled because production is automatic. Navigation cancellation and target-loss hardening remain Phase B3.

Existing movement APIs:

- `Actions.MoveTo(target, range)` steers toward a live target and completes at a **surface-gap** range. `range` is required.
- `Actions.TravelTo(gate)` approaches and automatically warps.
- `Actions.DockAt(station)` approaches an exterior berth and docks automatically.
- `Actions.Stop()` actively brakes, but does not cancel an action underneath it.
- `CommandControl` already routes a “Move To” command through `sendAction` and `pushAction`.
- `Targeting.IsTargetable` and `Actions.TargetValidity.Usable` provide target eligibility checks.

Proposed command path:

```text
Holo action button
  -> NodeGraph/Holo selection callback(node)
  -> LTheory:commandGoto(node)
  -> resolve entity + validate target
  -> controlling ship:pushAction(...)
```

Routing:

| Target | Action |
|---|---|
| Asteroid / ship / planet | `MoveTo(target, standoff)` |
| Station Goto | `MoveTo(station, standoff)` |
| Station Dock | `DockAt(station)` |
| Wormhole | `TravelTo(gate)`; Jump/confirmation remains explicit |
| Sector / region / far-gate virtual node | Reject physical Goto unless resolved to a real waypoint |

Optional HUD targeting uses `ship:setTarget(target)`; targeting alone does not command movement.

Required navigation hardening before release:

- `MoveTo` currently lacks target-validity checks and `onStop` thrust cleanup; destroyed/removed targets need safe cancellation.
- Cancelling navigation must remove only the navigation action and clear the `ThrustController`. Push `Stop` after removing `MoveTo` if braking is desired.
- Define replacement semantics instead of blindly stacking Goto over mining, docking, travel, or another move.
- Add arrival/cancellation state for route display, ETA, and target-loss handling.
- Never teleport, call raw `setPos`, or mutate transforms from UI code.

UI feedback should include a route preview, target marker, distance/ETA, and a visible cancel action. Recommended default: setting course closes/minimizes the map and returns to space; this remains an open preference decision.

### 19.6 Universal interaction grammar

Each provider supplies classification, children, links, field summaries, previews, info, and actions. The UI remains generic.

| Object | Drill/preview | Example actions |
|---|---|---|
| Asteroid | Composition and deposit clusters | Goto, Scan, Mine |
| Station / mining rig | Market, services, docking layout | Goto, Dock, Trade → buy/sell, Factory → production |
| Factory | Inputs, production flow, outputs | Goto, Manage, Inspect |
| NPC ship | Faction, cargo, equipment, relations | Target, Goto, Hail |
| Ship system | Component stats and connections | Toggle, Repair, Configure |
| Inventory item | Attributes and compatible slots | Use, Equip, Drop |
| Wormhole | Destination preview and route | Goto, Align, Jump |

### 19.6.1 Mock menu behavior by node and level

Single-click selects a drillable node and opens its base menu; double-click drills. Enter/Gamepad A remain explicit drill/edit controls.

- **Region:** Open Region, Scan, Routes.
- **Star system:** Open System, Goto, Scan, Jumpgates.
- **Mining rig / station / factory:** Goto, Dock, Trade, Factory.
  - **Trade:** Buy Energy Cells, Buy Machine Parts, Sell Rochalite Ore, Sell Isotopes.
  - **Factory:** View Inputs, View Outputs, Start Production, Stop Production.
- **Ship:** Inspect Ship, Goto, Target, Hail.
- **Asteroid:** Goto, Scan, Mine, Composition.
- **Weapon:** Configure, Edit Value, Reload.
- **Inventory:** Open Cargo, Use / Equip, Drop.
- **Research:** Open Research, Research, View Modifiers.
- **Editable scalar:** Edit Value.

Nested menus use the same selected-node identity and return through Back. Mock trade actions update cargo/credits; factory controls toggle mock production state. Scan, Dock, and Trade are distance-gated in the mock. Real market and production adapters remain pending.

### 19.7 Style and “wow” guidelines

The wow factor should come from coherence, density, and purposeful motion—not uniform extra glow.

- **Cluster unpacking:** a blue asteroid cloud separates into selectable rocks as the camera approaches.
- **Preview expansion:** stations reveal markets/services; ships reveal systems; asteroids reveal composition.
- **Continuous identity:** objects keep stable symbols and colors from galaxy view down to inventory.
- **Focus mode:** the selected subgraph stays bright while unrelated content recedes.
- **Object lenses:** the info card feels like examining an object through a holographic instrument.
- **Route motion:** restrained flowing dashes communicate active navigation.
- **Slow system orbit:** opt-in star-system micro-nodes complete one revolution every 45 seconds; parent nodes, non-system previews, and drill identity remain fixed.
- **Sound:** subtle selection ticks, drill transitions, confirmation chirps, and quiet ambience.
- **Readability:** keep text and inspector content in the crisp normal UI layer; reserve bloom for Holo geometry.
- **Accessibility:** retain 0° tilt, reduced-motion/zero-orbit support, high contrast, and type shapes rather than color alone.
- **Color semantics:** do not reuse the crimson interaction accent as the only hostile/faction signal.

### 19.8 Implementation sequence

1. **B1 — provider snapshots + graph/field split**
   - ✅ Owned structural records/arrays.
   - ✅ Major/minor partition and no default asteroid spokes.
   - ✅ Batched asteroid field, deterministic clusters, selected-minor promotion.
   - ✅ 2,000- and 10,000-asteroid validation.
2. **B2 — shared info card + action contract**
   - ✅ Mock normalized info/action descriptors and Holo-styled interactive panel.
   - ✅ Real-entity info/action provider and cached mesh preview core.
   - ✅ App-level command router for Goto/Target/Scan/Mine/Dock/Trade/Travel.
   - ⏳ Wire the real provider/panel/commands into the live F10 selection path.
3. **B3 — Goto and navigation hardening**
   - Command routing, validity checks, action replacement, thrust cleanup, arrival/cancel state.
4. **C — optional F10 Holo mode**
   - `NodeGraph.visualMode = 'classic' | 'holo'`.
   - Preserve all existing controller behavior and 88 checks.
5. **D — HDR/audio polish**
   - Dedicated Holo buffer/bloom only after real-data approval.

### 19.9 Open decisions to resolve during implementation

- Final cluster thresholds and point/cluster budgets.
- Whether the interactive info card wraps `NpcInfoPanel` or uses a new widget over `NodeGraphInspector` data.
- Single-click behavior: resolved — select + info; double-click drills. Cluster unpack remains an explicit action.
- Whether Goto closes the map automatically or leaves a minimized route panel open.
- Navigation replacement policy when another action is already active.
- Wormhole flow: Goto/align versus automatic `TravelTo` warp confirmation.

---

## 20. Final recommendation

**Phase A is implemented and visually approved.** Do not replace F10 `NodeGraph` and do not modify the renderer pipeline yet.

The standalone demo now provides:

1. tested camera/layout math in `HoloLayout`;
2. owned structural snapshots plus deterministic minor-field clustering/LOD in `HoloField`;
3. batched nodes/edges/previews, opt-in 45-second system orbit, ring-edge cleanup, and active SDF accents in `HoloRenderer`;
4. an upper-right selected-node preview and mock context-action menu in `HoloInfoPanel`;
5. real-entity info/action and mesh-preview adapters plus `LTheory.holoCommands`;
6. a full mock hierarchy and interaction app in `HoloNodeDemo`;
7. layout/input/renderer/field/provider/preview/commands/info/demo validators and a runtime smoke test.

Finish Phase B2 by wiring the real provider, preview panel, and command service into the live F10 selection path while preserving classic behavior. Then proceed to Phase B3 navigation cancellation/target-loss hardening. Only after the real-provider demo is approved should Holo become an optional `NodeGraph.visualMode`; dedicated HDR/audio polish remains last.

That sequence captures the old Limit Theory ambition without discarding the working map or turning a visual experiment into a risky rewrite.
