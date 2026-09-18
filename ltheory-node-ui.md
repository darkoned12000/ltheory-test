# Node-Based UI / Inventory Visualization — Implementation Plan (LTheory)

**Status:** Planning document only. No code changes yet.
**Inspiration:** ComfyUI-style node graph + inventory/workbench visualization, shown by Josh Parnell in a video; must be **live/auto-populated from real game data**, not hand-authored in an editor.

---

## 1. TL;DR Decision

| Question | Answer |
|---|---|
| New bespoke canvas engine? | **No.** Extend the existing retained-mode Lua UI framework (`script/UI/`) and add exactly one curved-wire shader primitive. |
| GL / render pipeline changes? | **No.** The node graph is screen-space 2D UI composited *after* the full post-chain (same path as `SystemMap`, HUD, debug panels). |
| New libraries? | **None.** Reuses: engine LuaUI framework, `Cache.Shader` on-demand loader + graceful degradation, shared `vertex/ui.glsl` viewport-quad vertex, existing entity/socket/economy data APIs. |
| Live from real game data? | **Yes.** Nodes = entities (via `getPos`/type/name/scale/health); edges = Sockets (`child` links), Economy flows (yields↔markets↔factories), parent-child hierarchy — all already queryable at runtime and seeded procedurally in the sector. |
| Two layout modes? | **Logical/graph** (default: chained resource-flow view, free-form drag) **+ optional world-projection mode** (spatial overview like `SystemMap`). |

### Why "extend framework + one shader" is right here
Every custom UI shape in this engine already follows the same two mechanisms:

1. **Batched widget path** (`Draw.WidgetRect` + capped C++ array, roadmap #15) — for box/line/panel/ring. Adding a wire to *this* path would require C++ edits (capped `WidgetVert`, new shader enum). **Not required.**
2. **Standalone SDF primitives** (`Point`/`Ring`/`Tri`/`Wedge`) — each is `Cache.Shader('ui','ui/<name>')` → set uniforms → `Draw.Rect` viewport quad → `shader:stop()`. A curved wire fits this pattern exactly with **zero C++ work**: the shader loads on demand and degrades gracefully if it fails to compile.

So the entire feature is: **(a)** one new fragment shader + wrapper, **(b)** a Lua widget that seeds from the system and draws nodes/edges each frame. No build manifest edits, no ABI risk, no pipeline changes.

---

## 2. Libraries — none new (reuse existing)

**New external libraries:** None. Introducing one would add build/version/licensing surface for a shape we can express in ~60 lines of GLSL. The cost/benefit is poor; the engine already has everything needed.

| Concern | Reused mechanism | File(s) |
|---|---|---|
| UI widget lifecycle (draw/update/input/layout, focus/highlight) | Retained `UI.Window`/`UI.Container` base + `Widget.onDraw/onUpdate/onInput/onLayoutPos` hooks | `script/UI/{Window,Container,Widget}.lua` |
| Screen-space 2D drawing composited after post-chain | GameView UI composite pass (`startUI/endUI`, `self.children[i]:draw`) | `script/Game/GUI/GameView.lua:638` |
| On-demand shader load + graceful degradation on compile failure | `Cache.Shader(vs, fs)` (last-good fallback) | `script/phx/util/Cache.lua:46` |
| Viewport-filling unit quad for standalone SDF fragments | Shared default UI vertex | `res/shader/vertex/ui.glsl` (+ `fragment` include header) |
| Node data model | Entity API (`getPos`, type, name, scale, health), Sockets, Economy flows, parent-child | `script/Game/{Entity.lua, Components/Sockets.lua, Components/Economy.lua, Components/Children.lua}` |
| Prior art for seeding + pan/zoom 2D map | `SystemMap` widget | `script/Game/SystemMap.lua` |

**Shader tooling:** The new fragment is validated by the offline GLSL validator (`./configure.py test` → `tools/validate_glsl.py`, moderngl/EGL headless) — see §10. No shader-authoring CLI needed; a typo fails fast at configure time.

---

## 3. Architecture & Where It Lives

### 3.1 Screen-space positioning
The whole node graph renders in the **UI composite pass** (post-chain), so:
- Coordinates are screen pixels, not world space (unless using *world-projection* mode — §7).
- Every widget here draws into a dedicated `uiBuffer` and composites after tonemap+sharpen (`filter/ui_overlay.glsl`, straight alpha) — see GameView.lua:632–644. This means wires/nodes are unaffected by the 3D post-chain, shadows, or planet rendering; they always sit "on top" like the HUD/reticle/explain-meter.
- Node graph is added to a container/canvas and drawn via `for i = 1, #self.children do self.children[i]:draw(focus, active) end` (GameView.lua:638). **No new C++ draw hook needed.**

### 3.2 Data flow each frame
```
system:iterChildren()                     -- live entity list from the sector
   │  e:getPos() → Vec3f{x,y,z}           -- node world position (see §5)
   └→ NodeGraph:onUpdate(state) re-queries nodes/edges (live, every frame)
         │
   Draw nodes (circle SDF + label via poll hook)
   Draw edges: bezier curve per socket-child link / economy flow / hierarchy
```

### 3.3 Node ↔ Edge mapping from existing data
| Element | Source | How to get it |
|---|---|---|
| **Node** (entity) | `system:iterChildren()` | `e:getPos()`, `e:getName()`, type, `e:getScale()`, health if `addHealth` used |
| **Edge** (socket link) | `Components/Sockets.lua` + `SocketKind` | `socket.child` gives the linked entity → curve node A→B |
| **Edge** (resource flow) | `Components/Economy.lua` | yields↔markets↔factories relationships → curved edges w/ flow color/rate |
| **Edge** (hierarchy) | `Entity:getParent()/getChildren()` (`Components/Children.lua`) | parent→child tree links, auto-laid-out (§7) |

All of these are already computed at runtime and re-queryable each frame — the graph is inherently live/auto-populated.

---

## 4. Existing Files That Need Modification

> **Goal: minimal edits.** Ideally *only* adding `DrawEx.Wire` (a small, self-contained wrapper) plus optional config keys. Everything else stays untouched.

| File | Change | Required? |
|---|---|---|
| `script/UI/DrawEx.lua` | Add `DrawEx.Wire(x1,y1,x2,y2,c1,c2,width,{control})` following the `Tri`/`Wedge` standalone-SDF pattern (PadAndCenter, nil-check, PushAdditive, uniforms, `Draw.Rect`, Pop). Also add a small padding constant `padWire`. | **Yes** — this is where nodes call the primitive. |
| `res/shader/fragment/ui/wire.glsl` *(NEW)* | New standalone SDF fragment (see §6). Reuses shared `vertex/ui.glsl`; no vertex file to touch, no manifest entry. | **New** (validated by `./configure.py test`). |
| `script/Config.App.lua` / `Config.Local.lua` | Optional: add semantic node/edge colors under `Config.ui.color.*` (e.g. `color.node`, `color.edge.flow`, `color.edge.socket`) + demo toggles (`nodegraph.{mode,showEdges}`). Pure Lua; no C++ change. | Optional — defaults can be hardcoded in NodeGraph with Local.lua overrides for tuning. |
| `script/App/NodeGraphDemo.lua` *(NEW)* | Demo app that builds a system, spawns stations/entities, and shows the node graph (both layout modes). Prior art: `TestEcon.lua` (`self.canvas:add(SystemMap(self.system))`). | New — run via `./run.sh NodeGraphDemo`. |
| `script/Game/SystemMap.lua` | **Read-only reference** — do not modify; it is the closest prior art and seeding pattern. | None (reference only). |

**No changes required to:** C++ rendering path, shader manifest, build system (`CMakeLists.txt`), FFI bindings, or any other `.lua`. The new fragment auto-loads via `Cache.Shader`; if it ever fails to compile the existing last-good fallback skips the pass (see §10).

---

## 5. Entity / Data API Surface (verified)

These methods are already used by `SystemMap`/`Batcher`, so they exist and work on game entities:
- `e:getPos()` → `Vec3f { .x, .y, .z }` — world position (node screen pos = projection of these).
- `e:getName()` / type (`e:type`) — node label + color.
- `e:getScale()` — node size.
- Health/state via `Entity:addHealth(max, rate)` / `d:damage(...)` → `Event.Destroyed` (optional health bar on nodes).
- Sockets: `Components/Sockets.lua`, `SocketKind` = `{ Generator, Thruster, Turret }`; a socket's `child` is the linked entity.
- Economy flows: `Components/Economy.lua` computes yield↔market↔factory relationships.
- Hierarchy: `Entity:addChild/getParent/getChildren/iterChildren` (`Components/Children.lua`).

> **Note:** `getPos`, `getName`, `getScale` are resolved on the entity metatable (LuaOOP-style); they work via the normal `:` call even though the base `Entity` class only defines `delete/register/send`. Use them directly — no extra plumbing.

---

## 6. New File: `res/shader/fragment/ui/wire.glsl`

Follows the exact convention of `triangle.glsl` / `ring.glsl`:
- `#include fragment` (provides `layout(location=0) out vec4 fragColor;`).
- **Perf / bounding box:** `DrawEx.Wire` must call `Draw.Rect(xMin,yMin,sx,sy)` with a bbox = `min/max(p0,p1,p2,p3) + width`, not the full screen. Since only fragments inside that quad are rasterized, this is what keeps the 48-sample loop cheap; a full-screen rect would make it cost `48 samples × entire framebuffer × N wires`.
- Additive blend (pushed by `DrawEx.Wire`) → wires glow over nodes without covering them.
- 1D distance field along a **cubic Bézier**: sample the curve, compute perpendicular distance, apply alpha falloff like ring/triangle (`exp(-max(0,d-half))` fill + soft glow).

### Design of the wire SDF
For segment from `A(p0)` to `B(p3)` with controls `p1,p2`:
- Parametrize `t ∈ [0,1]`, evaluate cubic Bézier `P(t)`.
- Tangent `T = dP/dt` (analytic); normalize.
- Distance field: for each fragment mapped near the curve, `d = clamp(||(P − fragPos) × n̂||)` where `n̂` is the normalized binormal; simplest robust approach is a **tube SDF** — distance from point to the Bézier tube of radius `width/2`. Use the standard 3D-ish tube test reduced to 2D by projecting onto the tangent-binormal plane, or approximate with a few control radii.
- Alpha: `fill = exp(-idm)` inside; `glow = exp(-pow(max(1e-5, k*edm), 0.75))` halo — mirrors triangle.glsl lines 45–46.

### Sample fragment (convention-matched)
```glsl
#include fragment

layout(location = 0) out vec4 fragColor;

// Control points + width, in pixel space (matches vertex/ui.glsl viewport quad).
uniform vec2 p0;      // A : start of wire segment
uniform vec2 p1;      // control 1
uniform vec2 p2;      // control 2
uniform vec2 p3;      // B : end of wire segment
uniform float width;  // half-width / radius of the tube (px)
uniform vec4 colorA;  // per-endpoint color (lerped by t^2*(1-t)^2 for gradients)
uniform vec4 colorB;

const float kGlow = 0.35;   // halo strength factor (see triangle.glsl:46)

vec2 safeNormalize(vec2 v) {
  float len = length(v);
  return (len > 1e-6) ? (v / len) : vec2(0.0);
}

// 2D cross product ("z of cross"): perpendicular distance from the origin to v.
float cross2(vec2 a, vec2 b) { return a.x * b.y - a.y * b.x; }

// Cubic Bézier point + tangent at t in pixel space.
vec2 bezier(vec2 p0, vec2 p1, vec2 p2, vec2 p3, float t) {
  float mt = 1.0 - t;
  return mt*mt*mt*p0 + 3.0*mt*mt*t*p1 + 3.0*mt*t*t*p2 + t*t*t*p3;
}

vec2 bezierTangent(vec2 p0, vec2 p1, vec2 p2, vec2 p3, float t) {
  float mt = 1.0 - t;
  return 3.0*(mt*mt*(p1 - p0) + 2.0*mt*t*(p2 - p1) + t*t*(p3 - p2));
}

void main() {
  vec2 fragPos = pos.xy;   // pixel space (from vertex/ui.glsl viewport quad)

  float bestT = 0.0;
  float bestD = 1e9;      // closest perpendicular distance to the curve
  for (int i = 0; i < 48; ++i) {        // sample curve at ~48 steps (cheap, smooth)
    float t = float(i) / 47.0;
    vec2 pt = bezier(p0, p1, p2, p3, t);
    vec2 tan = safeNormalize(bezierTangent(p0, p1, p2, p3, t));
    // Perpendicular distance from fragment to this sample (2D cross product).
    float d = abs(cross2(tan, pt - fragPos));
    if (d < bestD) { bestD = d; bestT = t; }
  }

  // Tube SDF: point is "inside" the wire when distance <= width/2.
  float idm = max(0.0, width * 0.5 - bestD);   // inside-distance (>=0)
  float edm = max(1e-5, bestD);                // outside distance for glow falloff

  float fill    = exp(-1.0 * idm / max(1e-4, width));     // sharp-ish core
  float glow    = exp(-pow(edm / max(1e-4, width), 0.75)) * kGlow;

  float alpha = 0.85 * fill + glow;

  // True A->B gradient along the wire (linear in t). Use smoothstep(0,1,bestT)
  // for an eased ramp; do NOT use t^2*(1-t)^2 — that peaks at t=0.5 and yields a
  // bell curve with colorA at both endpoints (see plan §6 note).
  float grad = bestT;                 // linear A->B
  vec3 base = mix(colorA.xyz, colorB.xyz, clamp(grad, 0.0, 1.0));

  vec4 outCol = alpha * colorB.w * vec4(2.0 * base, 1.0);   // match triangle/ring luminance scaling

  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b) || isnan(outCol.a)) {
    outCol = vec4(0.0);
  }

  fragColor = max(vec4(0.0), outCol);
}
```

> **Notes:** This mirrors `triangle.glsl`'s fill+glow structure and the ring/triangle luminance convention (`alpha * color.w * vec4(2*rgb,1)`). The 48-step sampling keeps it cheap (one pass per wire segment) while smooth; a more exact tube SDF can replace the loop with a proper 3D tube distance if perf ever matters — the sampled approach is sufficient for UI-scale graphs. **Perf caveat:** the sampling cost only stays bounded because `DrawEx.Wire` bounds its `Draw.Rect` to `min/max(p0,p1,p2,p3) + width`; a full-screen rect would make each fragment run all 48 samples, i.e. `48 × framebuffer-size × N-wires`. The gradient decision (linear vs eased) is locked above — pick one in Phase 5 rather than leaving it "optional". `#version` is auto-prepended (`Shader.cpp:27`) — do **not** add it here (matches all other `fragment/ui/*.glsl`).

---

## 7. New File: `script/UI/NodeGraph.lua`

Extends the retained framework like `SystemMap` does. Node graph and inventory both live in `script/UI/` as screen-space widgets composited after the post-chain — **not** a bespoke canvas engine.

### Structure (mirrors SystemMap)
```lua
local DrawEx = require('UI.DrawEx')   -- local-require, like Graph.lua style
local Widget = require('UI.Widget')

local NodeGraph = {}
NodeGraph.__index = NodeGraph
setmetatable(NodeGraph, Widget)       -- or UI.Container for a border frame
NodeGraph.name = 'NodeGraph'
NodeGraph.focusable = true

-- Layout modes + settings (tunable via Config.Local.lua)
NodeGraph.Mode = { Logical = 0, WorldProjection = 1 }
```

### Key methods / fields to implement
| Member | Purpose | Prior art |
|---|---|---|
| `function NodeGraph:onUpdate (state)` | **Live re-query** each frame, keyed by stable id and merged rather than rebuilt wholesale (§7 \"Node identity\"). Lerps node positions toward targets (`1 - exp(-k*dt)`) so world/camera motion is smooth instead of snapping. Rebuilds edges from sockets/economy/hierarchy; updates health bars + selection highlight. | SystemMap iterates children every draw. |
| `function NodeGraph:onDraw (focus, active)` | Draw node panel border; for each node: circle + label (via poll hook) + optional health bar; for each edge: straight line or `DrawEx.Wire(...)` per mode (§7 \"Edge style per mode\"). Free-form drag + pan/zoom. | SystemMap.onDraw draws points+rings per entity. |
| `function NodeGraph:onInput (state)` | Pan (WASD/arrows), zoom (scroll/P/O like SystemMap), node drag, focus/select on click. Distinguish **drill** (click a node whose type has children → push context) vs **select** (click for inspector detail). Wire hit-testing TBD (§8 Phase 5). | SystemMap.onInput: pan + zoom math. |
| `self.nodes = {}` keyed by id | Node table keyed by stable entity handle (`self.nodes[entity] = {...}`), NOT array index, so per-node state (position, drag offset, selection, hover, animated target) survives rebuilds and merges (§7 \"Node identity\"). | — |
| `self.edges = {}` | Edge list of `{a, b, width, c1, c2, label, rate?}`. `rate`/labels added only if wires are interactive (Phase 5 decision). | — |
| `self.stack`, `self.top` | Navigation context stack (`{ {context=rootSystem, camera={zoom,pos}} }`) + current index; drill pushes, back pops (§7 \"Drill-down state\"). | — |
| `applyCamera (camera)` | Restore/lerp the per-level camera+zoom when popping a context (§7 "Drill-down"); animates rather than snapping. | — |
| `function NodeGraph.isGraphWorthy (entity)` | LOD/importance predicate: return true only for graph-worthy entities so dense sectors don't flood the view with asteroid nodes. Type-based include-list first; smarter clustering later if needed (§8 Phase 2). | — |
| `self.mode`, `self.zoom`, `self.pos` | Layout mode + pan/zoom state. | SystemMap fields. |
| `node.pinned` (per node) | Set true on drag-start so the auto-layout pass treats it as a fixed anchor and lays out everything else around it — lets \"drag to rearrange\" coexist with re-layout when new nodes appear (§8 Phase 3). | — |
| `function NodeGraph.Create (system, opts)` | Seed: `self.system = system`; set stretch; init node/edge tables keyed by id; push initial context onto stack (`self.stack = {context=system}`); set mode + zoom + pos. Returns self. | `SystemMap.Create(system)`. |

### Node identity across frames (design for before Phase 2)
`onUpdate` must **not** replace the node table each frame — that would wipe per-node state (drag offset, selection, hover, animated target) because index *i* this frame isn't guaranteed to be the same entity as last frame. Instead:
- Key `self.nodes` by the integer **`entity.id`** (not the entity object or array index). Verified safe here: entities are plain Lua tables (`class(...)`) held by reference in parent `children[]`, never reconstructed per query, and each gets a unique monotonic id assigned once at birth — so identity is stable across frames. No `getId()` needed.
- On rebuild, **merge** into existing entries (update `target.x/target.y`, color, scale) rather than reassign; contract stale ones over time.
- This is what makes lerp smoothing (§above) and drag-to-reposition survive the next tick.

### LOD / importance filter (`isGraphWorthy`)
Before Phase 2 ships, decide which entities are \"graph-worthy\" so a populated sector doesn't flood the graph with hundreds of asteroid nodes. Start with a simple **type-based include-list** (stations, named bodies, gates) — that already gets you the screenshot look; no k-means/quadtree needed yet. `isGraphWorthy(entity)` returns true only for those; everything else is skipped in seeding and draw.

### Drill-down / navigation state (design for before Phase 2)
Drill-down (screenshots: click a sector node → reveal its planets/asteroids/NPCs, with back/breadcrumb) is a **navigation stack**, not a mode flag. NodeGraph owns it:
```lua
-- One context per level; store camera/zoom PER level so \"back\" restores the prior view
self.stack = { { context = rootSystem, camera = { zoom = 1.0, pos = Vec2f(0,0) } } }
self.top   = 1

function NodeGraph:push (context, opts)   -- drill into a node whose type has children
  self.stack[#self.stack + 1] = { context = context, camera = opts and opts.camera or {} }
  self.top = #self.stack
end
function NodeGraph:pop ()                 -- back out; restore previous level's view (: = method, needs implicit self param)
  if self.top > 1 then self.top = self.top - 1 end
  self:applyCamera(self.stack[self.top].camera)   -- animate/restore zoom+pan, don't reset to default
end
```
- **Drill vs select:** clicking a node whose type has children → `push` (drill); otherwise fire an outward event / show inspector detail (`select`). This decision affects whether click handling fires an event up vs. manages its own state (§Inspector).
- When pushing, animate/transition camera+zoom into the new level instead of jarring recenter — store per-level camera so `pop()` restores it.

### Inspector / detail panel (decision: decide now)
Is node-click detail a separate widget composed alongside NodeGraph, or baked in? This affects whether `onInput`'s click handler fires an event outward (`self:send(Event.NodeSelected(node))`) vs. manages its own state. **Recommendation:** fire it outward as an event so GameView/debug panels can render the inspector — keeps NodeGraph pure node-graph logic and composes cleanly (matches how DebugWindow is a separate child). Baked-in only if you want zero extra wiring for the demo.

### Edge style per mode
The curved Bézier wire (`DrawEx.Wire`) is one visual language; your screenshots also show a **straight dashed sector map** (that's `SystemMap`, unchanged — leave it as-is). Decide which edge style each mode uses:
- **Logical/graph mode:** curved Bézier wires (ComfyUI-style) for the inventory/ship-systems tree.
- **World-projection mode:** if meant to mirror your screenshots, use **straight lines** (or Bézier with colinear control points) so it matches the existing sector-map look rather than diverging visually.

### Node label via poll hook (reuse `UI.Graph`'s proven pattern)
Each node stores an optional `pollFn(dt)` that returns its label text; `onDraw` calls it live so names/state stay current without recompiling the graph. This mirrors `Graph:onUpdate` (`if self.pollFn then self:append(self.pollFn(state.dt)) end`).

### World-projection mode
When `mode == WorldProjection`, project each node's world position onto screen using the same math as SystemMap (§5 of that file): subtract a reference point, scale by zoom, offset into widget local space. Logical mode ignores world coords and uses auto-layout / free-form drag positions only.

---

## 8. Phased Implementation Plan

**Phase 0 — Wire primitive (foundation)**
- Create `res/shader/fragment/ui/wire.glsl` (§6). Add `DrawEx.Wire(...)` in `script/UI/DrawEx.lua`. Validate: `./configure.py test` compiles+links the new fragment headlessly via moderngl/EGL. A typo fails fast here — **must pass before runtime.**

**Phase 1 — NodeGraph container skeleton**
- Create `script/UI/NodeGraph.lua`: extends Widget/Container, pan/zoom + free-form node drag (SystemMap math), focus/select highlight, border panel. No data yet — just the interactive canvas.

**Phase 2 — Live seeding from game data**
- `NodeGraph.Create(system)` seeds nodes filtered by `isGraphWorthy` (§7 LOD); edges from sockets/economy/hierarchy. Key nodes by stable id + merge-not-replace (§7 identity) so per-node state survives; lerp smoothing baked into onUpdate (`1 - exp(-k*dt)`). Re-query every frame.

**Phase 3 — Layout algorithm + modes**
- Logical auto-layout in a new `script/UI/GraphLayout.lua` if it grows past ~50 lines, else inline (§8 Phase 3 note). `node.pinned = true` on drag-start so the layout pass treats pinned nodes as fixed anchors and lays out everything else around them. World-projection mode (straight-line edges per §7 edge style). Node labels via poll hooks; health bar if tracked.

**Phase 4 — Drill-down / navigation stack**
- `self.stack` context push/pop (§7 drill-down); distinguish **drill** (click a node whose type has children → push) vs **select** (fire outward inspector event). Store per-level camera so `back` restores the prior view instead of recentering; animate zoom+pan transitions. Back/breadcrumb navigation.

**Phase 5 — Inspector + demo app**
- Decide inspector-outward-event vs baked-in (§7 inspector decision); wire hit-testing (CPU-side bezier distance mirroring shader) if wires are interactive (§9). `NodeGraphDemo.lua`: build a system, spawn stations/entities, show graph in both modes; run via `./run.sh NodeGraphDemo`. Config.Local overrides for colors/toggles.

**Acceptance criteria (end-to-end):**
1. `./configure.py test` passes with the new shader compiling+linking headlessly.
2. Demo runs (`./run.sh NodeGraphDemo`); nodes appear auto-populated from live entities, filtered by importance; edges reflect socket/economy links.
3. Free-form drag + pan/zoom work; selection highlights a node; labels update live.
4. Drill into a node reveals its children; back restores the prior view/camera.
5. No C++ changes, no build-manifest edits, graceful degradation if the shader fails to compile.

---

## 9. Risks & Fallbacks

- **Shader compile failure:** `Cache.Shader` already returns last-good / skips pass (`Cache.lua:51–58`). The wire degrades (no edges) instead of crashing — same resilience as Point/Ring/Tri/Wedge.
- **Per-segment sampling cost + bounding box:** 48 samples × N wires is cheap for UI-scale graphs — but only because `DrawEx.Wire` bounds its `Draw.Rect` to `min/max(p0,p1,p2,p3) + width`, so only fragments inside the wire's bbox are rasterized (see §6). A full-screen rect would make each fragment run all 48 samples: `48 × framebuffer-size × N-wires`.
- **Wire draw-call ceiling:** one Cache.Shader bind + uniform set + Draw.Rect per wire, per frame. Fine for dozens; potentially not fine for hundreds (economy flows yield↔markets↔factories fan out fast). Escape hatch if this becomes a bottleneck: batch multiple segments into one draw with control points passed as a UBO/array rather than a per-wire uniform — bigger change, so flag now as a known ceiling (§8 Phase 5 note).
- **Wire hit-testing CPU cost:** interactive wires need a CPU-side bezier-distance function mirroring the shader (same 48-sample or analytic approach) because you can't hit-test against the GPU. Decide in §7 \"Inspector\" whether wires are decorative or interactive — if interactive, self.edges needs richer metadata (flow rate/labels from Phase 2 onward) and onInput pays this cost per hovered wire.
- **Coordinate-space confusion:** `vertex/ui.glsl` maps through `mProjUI*mViewUI`, so wire uniforms (`p0..p3`) must be in the same pixel space as node screen positions — keep this invariant documented (see §6). World-projection mode explicitly converts world→screen before passing to `DrawEx.Wire`.
- **Naming clash:** `script/UI/Graph.lua` is a *data-plotting* widget (bars/lines of values), not a node graph. Keep the new file `NodeGraph.lua` to avoid semantic confusion.
- **Entity API gaps:** if some entity type lacks `getPos`/`getName`, seed only those that do and log a warning (matching the engine's "missing image → fallback" philosophy).
- **Per-frame full rebuild revisit (non-blocking):** starting with `onUpdate` rebuilding node/edge tables 60×/sec is fine for demo scale; if entity counts grow, replace with a dirty-flag/change-detection path. Don't be surprised if this needs revisiting after Phase 2 — it's not a blocker now.

---

## 10. Validation & Testing

| Stage | Command | Purpose |
|---|---|---|
| Shader compile/link | `./configure.py test` | Headless GLSL validator (`tools/validate_glsl.py`) compiles+links every `.glsl` incl. new `fragment/ui/wire` via moderngl/EGL at the engine's GLSL level — **fail fast on typos.** Interpreter resolved from project venv / `$PHX_VALIDATOR_PY` / `python3`. |
| Runtime demo | `./run.sh NodeGraphDemo` | Launches the node graph over the live game/world; no `LD_LIBRARY_PATH` needed (`$ORIGIN` RUNPATH + absolute FFI loader). |
| Config tuning | Edit `Config.Local.lua` | Toggle modes, colors, show/hide edges — no gameplay code changes. |

**Pre-edit rule:** always run `./configure.py test` before any `.glsl` edit (AGENTS.md: a typo now fails at configure time). The validator's interpreter comes from the project venv, so configure as `./configure.py`.

---

## Appendix A — Reused conventions checklist
- Fragment header: `#include fragment`; output via redeclared `layout(location=0) out vec4 fragColor;` (matches triangle.glsl). No `#version` line (auto-prepended).
- DrawEx standalone pattern: PadAndCenter → nil-check shader → PushAdditive → uniforms (`SetFloat/SetFloat2/SetFloat4`) → `Draw.Rect(xMin,yMin,sx,sy)` → stop → Pop.
- Node graph widget: mirror SystemMap — `setmetatable(..., UI.Window)`, `Create(system)`, iterate `system:iterChildren()`, pan/zoom in `onInput`.

## Appendix B — File inventory (final)
**New:**
- `res/shader/fragment/ui/wire.glsl` — curved-wire SDF fragment.
- `script/UI/NodeGraph.lua` — node graph + inventory visualization widget (§7 state home).
- `script/UI/GraphLayout.lua` — layout algorithm (layered/Sugiyama or spring), **optional/new** if it grows past ~50 lines; else stays inline in NodeGraph (§8 Phase 3).
- `script/App/NodeGraphDemo.lua` — demo app.

**Modified (minimal):**
- `script/UI/DrawEx.lua` — add `DrawEx.Wire(...)` (+ `padWire`).
- `script/Config.App.lua`, `Config.Local.lua` — optional semantic colors/toggles (pure Lua).

**TBD / may be a separate widget:** node inspector/detail panel (§7 Inspector decision) composed alongside NodeGraph if it stays an outward event.

**Reference only (unchanged):** `script/Game/SystemMap.lua`, all of `script/UI/*.lua` framework, entity/socket/economy components.

---

## Additional implementation ideas we may be missing

A few things worth considering beyond the plan, in no particular order:

1. **Start with the inventory/ship-systems tree as the MVP**, not a full sector overview. Curved Bézier wires shine on small, structured trees (Generator→Thruster→Turret sockets; economy yields↔markets↔factories) where every edge is meaningful. A dense sector overview gets LOD-filtered anyway and reads better as the existing straight `SystemMap`. This also keeps Phase 2's `isGraphWorthy` predicate simple from day one.

2. **Make NodeGraph context-aware from Day 1 (depth-1 stack).** Store `self.stack = {context=system}` and route seeding through the *current top of stack*, so a future push/pop is just swapping which system you seed — no rewrite of Create/onUpdate. Phase 4 then becomes "add push/pop + camera transition" rather than "refactor state."

3. **Hybrid edge styles per mode, not one wire shader.** World-projection mode (to match your straight-dashed screenshots) can reuse a trivial straight-line draw while Logical mode uses `DrawEx.Wire`. Don't force world-projection to look curvy — that's where visual divergence from the screenshots would come from.

4. **Inspector as an outward event, composed in GameView.** Emit `NodeSelected(node)` and let existing debug-panel/inspector infrastructure render detail (health, sockets, economy flows). Zero extra wiring for the demo; real inspector reuse later without touching NodeGraph's click handling.

5. **Animate camera transitions per stack level** — store `{zoom,pos}` on each entry so `back` restores the prior view instead of snapping to default. Small thing that disproportionately affects how "polished" drill-down feels (per Claude's feedback); bake it into §7 push/pop now rather than Phase 4.

6. **Hover preview for edges before deciding interactivity.** Even if wires start decorative, showing a tooltip/flow-rate readout on hover gives value with minimal cost and informs the Phase 5 hit-testing decision early — decide then whether `rate` belongs in self.edges from Phase 2 onward (see §9).

7. **Lerp smoothing should cover node scale/color too** (health bars), not just position. Health-bar alpha/height updating frame-to-frame will otherwise flicker as the ship moves or takes damage; same `1 - exp(-k*dt)` trick, baked into onUpdate from Phase 2.

8. **Reconsider whether full "world-projection" is needed for the demo.** If your screenshots' straight sector map = unchanged SystemMap and curved wires are only for the inventory tree, ship Logical mode + world-projection as a thin alias that projects entity positions into the logical canvas — deferring more complex full-3D projection.

