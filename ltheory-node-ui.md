# Node-Based UI / Inventory Visualization — Implementation Plan (LTheory)

**Status:** Planning document + pre-implementation review (2026-09-18, §11). No code changes yet.
**Inspiration:** ComfyUI-style node graph + inventory/workbench visualization, shown by Josh Parnell in a video; must be **live/auto-populated from real game data**, not hand-authored in an editor.

---

## 1. TL;DR Decision

| Question | Answer |
|---|---|
| New bespoke canvas engine? | **No.** Extend the existing retained-mode Lua UI framework (`script/UI/`) and add exactly one dashed-line shader primitive (straight solid lines already exist via `DrawEx.Line`). |
| GL / render pipeline changes? | **No.** The node graph is screen-space 2D UI composited *after* the full post-chain (same path as `SystemMap`, HUD, debug panels). |
| New libraries? | **None.** Reuses: engine LuaUI framework, `Cache.Shader` on-demand loader + graceful degradation, shared `vertex/ui.glsl` viewport-quad vertex, existing entity/socket/economy data APIs. |
| Live from real game data? | **Yes.** Nodes = entities (via `getPos`/`getName`/`getScale`/health + capability predicates); edges = Sockets (`child` links), Economy jobs (`Mine`/`Transport` src→dst), parent-child hierarchy — all already queryable at runtime and seeded procedurally in the sector. |
| Two layout modes? | **Logical/graph** (default: chained resource-flow view, free-form drag) **+ optional world-projection mode** (spatial overview like `SystemMap`). |
| What does it look like? | Josh's reference (`screenshot/Screenshot_2026-09-17_22-02-50.png`, `..._22-51-00.png`, §12): glowing **rings** (size/brightness = importance), **straight** edges — solid for hierarchy/mine links, **dotted** for trade routes — labels on major nodes only, corner-bracket selection reticle, all as a translucent overlay on the live scene. No Bézier curves anywhere in the reference. |

### Why "extend framework + one shader" is right here
Every custom UI shape in this engine already follows the same two mechanisms:

1. **Batched widget path** (`Draw.WidgetRect` + capped C++ array, roadmap #15) — for box/line/panel/ring. Adding a wire to *this* path would require C++ edits (capped `WidgetVert`, new shader enum). **Not required.**
2. **Standalone SDF primitives** (`Point`/`Ring`/`Tri`/`Wedge`) — each is `Cache.Shader('ui','ui/<name>')` → set uniforms → `Draw.Rect` viewport quad → `shader:stop()`. A dashed line fits this pattern exactly with **zero C++ work**: the shader loads on demand and degrades gracefully if it fails to compile. (A dash parameter can NOT go through the batched `Draw.WidgetRect` path — `Draw.cpp:356-358` packs a capped C++ `WidgetVert` array, so per-line style would need a vert change. Standalone it is.)

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
| Node data model | Entity API (`getPos`, `getName`, `getScale`, health; node color via capability predicates like `hasActions`/`hasFlows` — there is no `e:type()`), Sockets, Economy jobs, parent-child | `script/Game/{Entity.lua, Components/Sockets.lua, Components/Economy.lua, Components/Children.lua}` |
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
   Draw edges: straight solid (`DrawEx.Line`) per socket-child/hierarchy/mine link, straight dotted (`DrawEx.Dash`) per `Jobs.Transport` route
```

### 3.3 Node ↔ Edge mapping from existing data
| Element | Source | How to get it |
|---|---|---|
| **Node** (entity) | `system:iterChildren()` | `e:getPos()`, `e:getName()`, `e:getScale()`, node color via capability predicates (`hasActions`/`hasFlows`/`hasYield`/`hasFactory`/`hasTrader` — SystemMap-style; no `e:type()` exists), health if `addHealth` used |
| **Edge** (socket link) | `Components/Sockets.lua` + `Game.SocketKind` | `socket.child` gives the linked entity → curve node A→B |
| **Edge** (resource flow) | Economy `Jobs` cache | `Jobs.Mine(src,dst)` / `Jobs.Transport(src,dst,item)` cached on the economy object (Mine + trader-arbitrage; flow-based Transport caching is `if false`-disabled) → straight solid edges w/ flow color (hierarchy/mine) or straight dotted edges (`Jobs.Transport` trade routes) |
| **Edge** (hierarchy) | `Entity:getParent()/getChildren()` (`Components/Children.lua`) | parent→child tree links, auto-laid-out (§7) |

All of these are already computed at runtime and re-queryable each frame — the graph is inherently live/auto-populated.

---

## 4. Existing Files That Need Modification

> **Goal: minimal edits.** Ideally *only* adding `DrawEx.Dash` (a small, self-contained wrapper) plus optional config keys. Everything else stays untouched.

| File | Change | Required? |
|---|---|---|
| `script/UI/DrawEx.lua` | Add `DrawEx.Dash(x1,y1,x2,y2,color,dashPeriod)` following the `Tri` standalone-SDF pattern (explicit min/max bbox, nil-check, PushAdditive, uniforms, `Draw.Rect`, Pop). Solid lines already exist via `DrawEx.Line` (batched path — no change needed). | **Yes** — trade-route edges call the primitive. |
| `res/shader/fragment/ui/dashline.glsl` *(NEW)* | New standalone dashed-line fragment (see §6): `line.glsl`'s segment-distance math plus a `dashPeriod` uniform (`0` = solid). Reuses shared `vertex/ui.glsl`; no vertex file to touch, no manifest entry. | **New** (validated by `./configure.py test`). A curved Bézier `wire.glsl` is **deferred** — the reference shows zero curves (see §12); revive only if a curved aesthetic is explicitly requested (reviewed sample kept in git history). |
| `script/Config.App.lua` / `Config.Local.lua` | Optional: add semantic node/edge colors as flat keys under `Config.ui.color` (convention: `accent`, `selection`, … — e.g. `nodeWire`, `nodeSelected`) + demo toggles (`nodegraph.{mode,showEdges}`). Pure Lua; no C++ change. | Optional — defaults can be hardcoded in NodeGraph with Local.lua overrides for tuning. |
| `script/App/NodeGraphDemo.lua` *(NEW, optional harness)* | Standalone demo app (same pattern as `TestEcon.lua`) for developing the widget without booting the full game. The primary host is the LTheory overlay (§13), not this demo. | Optional — run via `./run.sh NodeGraphDemo`. |
| `script/Game/SystemMap.lua` | **Read-only reference** — do not modify; it is the closest prior art and seeding pattern. | None (reference only). |

**No changes required to:** C++ rendering path, shader manifest, build system (`CMakeLists.txt`), FFI bindings, or any other `.lua`. The new fragment auto-loads via `Cache.Shader`; if it ever fails to compile the existing last-good fallback skips the pass (see §10).

---

## 5. Entity / Data API Surface (verified)

These methods are already used by `SystemMap`/`Batcher`, so they exist and work on game entities:
- `e:getPos()` → `Vec3f { .x, .y, .z }` — world position (node screen pos = projection of these).
- `e:getName()` for the label (per-subclass; `Job`/`Action` assert NYI — exclude those types in `isGraphWorthy`); node color via capability predicates (`hasActions`/`hasFlows`/`hasYield`/`hasFactory`/`hasTrader`), **not** `e:type()` (does not exist).
- `e:getScale()` — node size.
- Health/state via `Entity:addHealth(max, rate)` / `d:damage(...)` → `Event.Destroyed` (optional health bar on nodes).
- Sockets: `Components/Sockets.lua`, `SocketKind` = `{ Generator, Thruster, Turret }` (required as `Game.SocketKind`); a socket's `child` is the linked entity.
- Economy edges: `Jobs.Mine(src, dst)` / `Jobs.Transport(src, dst, item)` (`script/Game/Jobs/`) cached on the economy object — real `.src`/`.dst` entity refs. Per-entity `flows[item]` are rate *numbers*, not links; do not cite them as edges. Note the flow-based Transport caching block is `if false`-disabled, so live edges are Mine + trader-arbitrage only.
- Hierarchy: `Entity:addChild/getParent/getChildren/iterChildren` (`Components/Children.lua`).

> **Note:** `getPos`, `getName`, `getScale` are resolved on the entity metatable (LuaOOP-style); they work via the normal `:` call even though the base `Entity` class only defines `delete/register/send`. Use them directly — no extra plumbing.

---

## 6. New File: `res/shader/fragment/ui/dashline.glsl`

Follows the exact convention of `triangle.glsl` / `line.glsl`:
- `#include fragment` (provides `layout(location=0) out vec4 fragColor;`).
- **Perf / bounding box:** `DrawEx.Dash` must call `Draw.Rect(xMin,yMin,sx,sy)` with a bbox = `min/max(p1,p2) + width + dashPeriod`, not the full screen. Only fragments inside that quad run the (trivial) math.
- Additive blend (pushed by `DrawEx.Dash`) → dotted trade routes glow without covering nodes.
- Straight segment distance field like `line.glsl` (projection clamped to [0,1] — tight endcaps by construction), multiplied by a dash mask. `line.glsl` itself is NOT extended: it serves the shared batched `Draw.WidgetRect` path, where a per-line dash uniform cannot travel without a C++ vert change (`Draw.cpp:356-358`).

### Design of the dash SDF
For segment from `A(p1)` to `B(p2)` with dash period `dash` (px, `0` = solid):
- `rel = fragPos - p1`, `u = clamp(dot(rel, seg)/dot(seg,seg), 0, 1)`, `d = length(fragPos - (p1 + seg*u))` — same as `line.glsl:27-29`.
- Core + halo exactly like `line.glsl:32-33` (`0.8·exp(-2·max(0,d-0.5))` + `0.2·exp(-pow(max(1e-5,0.2·d),0.75))`), preserving the existing line look so solid and dotted edges match.
- Dash mask: `m = (dash < 0.5) ? 1.0 : step(0.5, fract(u * length(seg) / dash))`. Square-wave dots; the reference uses round dots — the halo falloff rounds them visually at small widths.
- Endpoint fade: keep `line.glsl:35` (`alpha *= exp(-2·(1-t))`) so dotted routes melt into their target node exactly like solid lines do.

### Sample fragment (convention-matched)
```glsl
#include fragment

layout(location = 0) out vec4 fragColor;

// Endpoints + width, in pixel space (matches vertex/ui.glsl viewport quad).
uniform vec2 p1;        // A : start of edge segment
uniform vec2 p2;        // B : end of edge segment
uniform float width;    // line width (px)
uniform float dash;     // dash period (px); < 0.5 = solid line
uniform vec4 color;

void main() {
  vec2 fragPos = pos.xy;   // pixel space (from vertex/ui.glsl viewport quad)

  vec2 seg = p2 - p1;
  float segLen = max(length(seg), 1e-6);
  float u = clamp(dot(fragPos - p1, seg) / (segLen * segLen), 0.0, 1.0);
  float d = length(fragPos - (p1 + seg * u));

  float alpha = 0.0;
  alpha += 0.8 * exp(-2.0 * max(0.0, d - 0.5));
  alpha += 0.2 * exp(-pow(max(1e-5, 0.2 * d), 0.75));

  // Dash mask (square wave along the segment); solid when dash < 0.5.
  if (dash >= 0.5) {
    alpha *= step(0.5, fract(u * segLen / dash));
  }

  float t = 1.0 - u;                              // 1 at A → 0 at B
  alpha *= exp(-2.0 * (1.0 - t));                 // endpoint fade, like line.glsl:35

  vec4 outCol = alpha * color.w * vec4(color.xyz, 1.0);

  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b) || isnan(outCol.a)) {
    outCol = vec4(0.0);
  }

  fragColor = max(vec4(0.0), outCol);
}
```

> **Notes:** `t` here runs A→B to mirror `line.glsl:30` (`t = saturate(1 - projLength/l)`, 1 at p1). Luminance follows `line.glsl:36` (`alpha·w·vec4(c,1)`, no 2x boost — UI lines, unlike triangle fills, don't double). Dots read round via the halo falloff; if they ever need geometric roundness, square the mask with a second perpendicular `fract` — not needed at wire widths. `#version` is auto-prepended (`Shader.cpp:27`) — do **not** add it here. The reviewed Bézier `wire.glsl` sample (segment-clamped, interpolated `bestT`) is superseded by this file; keep it out of the tree unless curves are requested.

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
| `function NodeGraph:onDraw (focus, active)` | Translucent dim (or none — the reference shows the live scene behind, unlike `SystemMap`'s opaque rect); per node: `DrawEx.Ring` sized by importance + `DrawEx.Point` core + label under major nodes only; per edge: `DrawEx.Line` or `DrawEx.Dash` by kind; corner-bracket reticle (4 short `DrawEx.Line`s) on selection; free-form drag + pan/zoom. | SystemMap.onDraw draws points+rings per entity. |
| `function NodeGraph:onInput (state)` | Pan (WASD/arrows), zoom (scroll/P/O like SystemMap), node drag, focus/select on click. Distinguish **drill** (click a node with children → push context) vs **select** (click for inspector detail). Edge hover-testing TBD (§8 Phase 5 — cheap point-to-segment test, no curve math). | SystemMap.onInput: pan + zoom math. |
| `self.nodes = {}` keyed by id | Node table keyed by stable entity handle (`self.nodes[entity] = {...}`), NOT array index, so per-node state (position, drag offset, selection, hover, animated target) survives rebuilds and merges (§7 \"Node identity\"). | — |
| `self.edges = {}` | Edge list of `{a, b, width, c1, c2, label, rate?}`. `rate`/labels added only if wires are interactive (Phase 5 decision). | — |
| `self.stack`, `self.top` | Navigation context stack (`{ {context=rootSystem, camera={zoom,pos}} }`) + current index; drill pushes, back pops (§7 \"Drill-down state\"). | — |
| `applyCamera (camera)` | Restore/lerp the per-level camera+zoom when popping a context (§7 "Drill-down"); animates rather than snapping. | — |
| `function NodeGraph.isGraphWorthy (entity)` | LOD/importance predicate: return true only for graph-worthy entities so dense sectors don't flood the view with asteroid nodes. Capability-predicate include-list first; smarter clustering later if needed (§8 Phase 2). | — |
| `self.mode`, `self.zoom`, `self.pos` | Layout mode + pan/zoom state. | SystemMap fields. |
| `node.pinned` (per node) | Set true on drag-start so the auto-layout pass treats it as a fixed anchor and lays out everything else around it — lets \"drag to rearrange\" coexist with re-layout when new nodes appear (§8 Phase 3). | — |
| `function NodeGraph.Create (system, opts)` | Seed: `self.system = system`; set stretch; init node/edge tables keyed by id; push initial context onto stack (`self.stack = {context=system}`); set mode + zoom + pos. Returns self. | `SystemMap.Create(system)`. |

### Node identity across frames (design for before Phase 2)
`onUpdate` must **not** replace the node table each frame — that would wipe per-node state (drag offset, selection, hover, animated target) because index *i* this frame isn't guaranteed to be the same entity as last frame. Instead:
- Key `self.nodes` by the integer **`entity.id`** (not the entity object or array index). Verified safe here: entities are plain Lua tables (`class(...)`) held by reference in parent `children[]`, never reconstructed per query, and each gets a unique monotonic id assigned once at birth — so identity is stable across frames. No `getId()` needed.
- On rebuild, **merge** into existing entries (update `target.x/target.y`, color, scale) rather than reassign; contract stale ones over time.
- This is what makes lerp smoothing (§above) and drag-to-reposition survive the next tick.

### LOD / importance filter (`isGraphWorthy`)
Before Phase 2 ships, decide which entities are \"graph-worthy\" so a populated sector doesn't flood the graph with hundreds of asteroid nodes. Start with a simple **capability-predicate include-list** (`hasFactory`/`hasTrader`/`hasYield`/named bodies — and only types with working `getName`; `Job`/`Action.getName` assert NYI) — that already gets you the screenshot look; no k-means/quadtree needed yet. `isGraphWorthy(entity)` returns true only for those; everything else is skipped in seeding and draw.

### Drill-down / navigation state (design for before Phase 2)
Drill-down (screenshots: click a sector node → reveal its planets/asteroids/NPCs, with back/breadcrumb) is a **navigation stack**, not a mode flag. NodeGraph owns it:
```lua
-- One context per level; store camera/zoom PER level so \"back\" restores the prior view
self.stack = { { context = rootSystem, camera = { zoom = 1.0, pos = Vec2f(0,0) } } }
self.top   = 1

function NodeGraph:push (context, opts)   -- drill into a node with children
  self.stack[#self.stack + 1] = { context = context, camera = opts and opts.camera or {} }
  self.top = #self.stack
end
function NodeGraph:pop ()                 -- back out; restore previous level's view (: = method, needs implicit self param)
  if self.top > 1 then self.top = self.top - 1 end
  self:applyCamera(self.stack[self.top].camera)   -- animate/restore zoom+pan, don't reset to default
end
```
- **Drill vs select:** clicking a node with children → `push` (drill); otherwise invoke the `onNodeSelected` callback / show inspector detail (`select`).
- When pushing, animate/transition camera+zoom into the new level instead of jarring recenter — store per-level camera so `pop()` restores it.

### Inspector / detail panel (decision: decide now)
Is node-click detail a separate widget composed alongside NodeGraph, or baked in? **Decision (review 2026-09-18): separate, via callback.** Nothing in `script/UI` sends events (`Entity:send` is entity-level only), so the outward channel is a callback field — e.g. `self.onNodeSelected(node)` invoked from `onInput`'s click handler, which `GameView`/debug panels assign to render the inspector (health, sockets, economy flows). This is codebase-idiomatic (buttons take closures) and keeps NodeGraph pure node-graph logic. Baked-in only if you want zero extra wiring for the demo.

### Edge style per mode (locked by reference, §12)
Josh's shots show **straight lines everywhere** — solid spokes from hubs plus **dotted** long-haul routes. No curves. So:
- **Logical/graph mode:** straight solid edges for hierarchy/sockets/mine links (`DrawEx.Line`, batched, zero new code); straight **dotted** edges for `Jobs.Transport` trade routes (`DrawEx.Dash`, the §6 primitive). Edge kind → style mapping is data-driven: `Jobs.Transport` ⇒ dotted, everything else ⇒ solid.
- **World-projection mode:** same two straight styles (matches the sector-map look in the screenshots).
- Bézier `wire.glsl` is out of scope unless a curved aesthetic is explicitly requested later.

### Node label via poll hook (reuse `UI.Graph`'s proven pattern)
Each node stores an optional `pollFn(dt)` that returns its label text; `onDraw` calls it live so names/state stay current without recompiling the graph. This mirrors `Graph:onUpdate` (`if self.pollFn then self:append(self.pollFn(state.dt)) end`).

### World-projection mode
When `mode == WorldProjection`, project each node's world position onto screen using the same math as SystemMap (§5 of that file): subtract a reference point, scale by zoom, offset into widget local space. Logical mode ignores world coords and uses auto-layout / free-form drag positions only.

---

## 8. Phased Implementation Plan

**Phase 0 — Dash primitive (foundation)**
- Create `res/shader/fragment/ui/dashline.glsl` (§6). Add `DrawEx.Dash(...)` in `script/UI/DrawEx.lua`. Validate: `./configure.py test` compiles+links the new fragment headlessly via moderngl/EGL. A typo fails fast here — **must pass before runtime.**

**Phase 1 — NodeGraph container skeleton**
- Create `script/UI/NodeGraph.lua`: extends Widget/Container, pan/zoom + free-form node drag (SystemMap math), focus/select highlight, border panel. No data yet — just the interactive canvas.

**Phase 2 — Live seeding from game data**
- `NodeGraph.Create(system)` seeds nodes filtered by `isGraphWorthy` (§7 LOD); edges from sockets/economy/hierarchy. Key nodes by stable id + merge-not-replace (§7 identity) so per-node state survives; lerp smoothing baked into onUpdate (`1 - exp(-k*dt)`). Re-query every frame.

**Phase 3 — Layout algorithm + modes**
- Logical auto-layout in a new `script/UI/GraphLayout.lua` if it grows past ~50 lines, else inline (§8 Phase 3 note). `node.pinned = true` on drag-start so the layout pass treats pinned nodes as fixed anchors and lays out everything else around them. World-projection mode (straight-line edges per §7 edge style). Node labels via poll hooks; health bar if tracked.

**Phase 4 — Drill-down / navigation stack**
- `self.stack` context push/pop (§7 drill-down); distinguish **drill** (click a node whose type has children → push) vs **select** (invoke the `onNodeSelected` callback). Store per-level camera so `back` restores the prior view instead of recentering; animate zoom+pan transitions. Back/breadcrumb navigation.

**Phase 5 — Inspector + demo app**
- Decide inspector-outward-event vs baked-in (§7 inspector decision); edge hover-testing (point-to-segment distance, trivial for straight edges) if routes are interactive (§9). `NodeGraphDemo.lua`: build a system, spawn stations/entities, show graph in both modes; run via `./run.sh NodeGraphDemo`. Config.Local overrides for colors/toggles.

**Acceptance criteria (end-to-end):**
1. `./configure.py test` passes with the new shader compiling+linking headlessly.
2. Primary host is the LTheory overlay (§13, F10 toggle): nodes auto-populate from the live system, filtered by importance; solid edges reflect socket/hierarchy/mine links, dotted edges reflect `Jobs.Transport` routes. `NodeGraphDemo` remains an optional dev harness.
3. Free-form drag + pan/zoom work; selection draws the corner-bracket reticle; labels update live on major nodes.
4. Drill into a node reveals its children (suppressed levels stay unlabeled per §13); back restores the prior view/camera.
5. No C++ changes, no build-manifest edits, graceful degradation if the shader fails to compile.
6. Visual check against §12 references: rings + straight/dotted edges + selective labels + overlay (no opaque panel), monochrome blue family.

---

## 9. Risks & Fallbacks

- **Shader compile failure:** `Cache.Shader` already returns last-good / skips pass (`Cache.lua:51–58`). The wire degrades (no edges) instead of crashing — same resilience as Point/Ring/Tri/Wedge.
- **Per-edge raster cost + bounding box:** the dash math is trivial (one segment projection); cost stays bounded because `DrawEx.Dash` bounds its `Draw.Rect` to `min/max(p1,p2) + width + dash`, so only fragments near the edge are rasterized (see §6).
- **Wire draw-call ceiling:** one Cache.Shader bind + uniform set + Draw.Rect per dotted edge, per frame (solid lines ride the shared batch). Fine for dozens of trade routes; if economy fans out to hundreds, batch segments by sharing one bbox-tiled draw or shorten dotted routes to hub spokes only (§8 Phase 5 note).
- **Edge hit-testing cost:** straight edges need only a point-to-segment test per edge — trivial on CPU, no GPU mirroring required. If routes are interactive, `self.edges` still wants flow rate/labels from Phase 2 onward, but hover cost is negligible.
- **Coordinate-space confusion:** `vertex/ui.glsl` maps through `mProjUI*mViewUI`, so edge uniforms (`p1/p2`) must be in the same pixel space as node screen positions — keep this invariant documented (see §6). World-projection mode explicitly converts world→screen before passing to `DrawEx.Line`/`DrawEx.Dash`.
- **Naming clash:** `script/UI/Graph.lua` is a *data-plotting* widget (bars/lines of values), not a node graph. Keep the new file `NodeGraph.lua` to avoid semantic confusion.
- **Entity API gaps:** if some entity type lacks `getPos`/`getName`, seed only those that do and log a warning (matching the engine's "missing image → fallback" philosophy).
- **Per-frame full rebuild revisit (non-blocking):** starting with `onUpdate` rebuilding node/edge tables 60×/sec is fine for demo scale; if entity counts grow, replace with a dirty-flag/change-detection path. Don't be surprised if this needs revisiting after Phase 2 — it's not a blocker now.

---

## 10. Validation & Testing

| Stage | Command | Purpose |
|---|---|---|
| Shader compile/link | `./configure.py test` | Headless GLSL validator (`tools/validate_glsl.py`) compiles+links every `.glsl` incl. new `fragment/ui/wire` via moderngl/EGL at the engine's GLSL level — **fail fast on typos.** Interpreter resolved from project venv / `$PHX_VALIDATOR_PY` / `python3`. |
| Runtime overlay | Boot LTheory, press F10 | NodeGraph over the live system; drill system → bodies/ships → components (§13). |
| Runtime demo (harness) | `./run.sh NodeGraphDemo` | Widget without the full game; no `LD_LIBRARY_PATH` needed (`$ORIGIN` RUNPATH + absolute FFI loader). |
| Config tuning | Edit `Config.Local.lua` | Toggle modes, colors, show/hide edges — no gameplay code changes. |

**Pre-edit rule:** always run `./configure.py test` before any `.glsl` edit (AGENTS.md: a typo now fails at configure time). The validator's interpreter comes from the project venv, so configure as `./configure.py`.

---

## 13. Scenario & drill-down flow (2026-09-18)

### PoC vs real data: real data from the start
No proof-of-concept with fake data — data access is the entire risk (which entities expose what, §5), and static nodes would prove nothing. `NodeGraph` seeds from the live system from Phase 2 onward; `NodeGraphDemo` is an optional harness, not the deliverable.

### Host + toggle: in-game overlay, F10
- There is **no map in the game** today (`SystemMap` is demo-only, used solely by `TestEcon`). NodeGraph ships as a GameView child overlay, attached exactly like the debug window (`LTheory.lua:130`: `gameView:add(widget, visibleFlag)`), drawn above the game screen in the UI composite pass.
- Toggle with **F10** in `GameView:onUpdate`, mirroring the F9 debug toggle (debounced, same function). Do NOT use **M** — it mutes music (`GameView.lua:926`). WASD/QE/Space/Esc are flight/UI-bound; the overlay must not reuse them (see Input below).
- LTheory spawns ~100 AI ships + 60 asteroids + stations (`LTheory.lua`), so `isGraphWorthy` LOD is load-bearing from day one, not a later optimization.

### Scope correction: one system today, galaxy later
`LTheory` builds exactly **one** `Entities.System` per run — no multi-sector galaxy exists. So the drill-down top level is the **current system** (label `"System <seed>"` until systems get names), not a galaxy map:
- Level 0 (system): planets, moons, stations, gates, ships, wormholes — rings + selective labels, hub spokes + dotted trade routes (the §12 look).
- Level 1 (drill into a body/ship/station): its children — ship sockets (Generator→Thruster→Turret), inventory (`Inventory` component), station markets/factories, moonlets.
- Level 2+ (drill into a component/node): live stats + `onNodeSelected` inspector detail.
- A future galaxy level slots in as just another stack entry (the §7 stack already supports it) — no widget changes needed when multi-sector arrives.

### Suppressed-layer rule
Nodes below the current stack level render as **plain dim rings only** — no labels, no edges, no inspector, no hover. Data appears if and only if its level is on top of the stack. This is both a perf discipline (nothing computed for hidden levels) and the focus contract: the screen never shows two levels' data at once.

### Node identity block (what the player reads)
Real data only — no invented fields:
- `getName()` (fallback `Entity @ %p` reads verbatim; NYI types excluded by LOD), integer `entity.id`.
- Kind tags from capability predicates (`hasTrader`, `hasFactory`, `hasYield`, socket types present) — this is the "function" line, derived, not stored.
- Live stats already on the entity: health bars (`addHealth`), flow rates (`getFlows`), position/scale.
- There is **no description field** in the data model. Either ship without flavor text (recommended — identity + tags + stats suffice) or add optional `Name.desc` (3-line change, Phase 2 at the earliest).

### Ship view / inventory: same widget, different context
No second implementation: open NodeGraph with `context = shipEntity` instead of `context = system`. Sockets seed hub-and-spoke edges, `Inventory`/`Capacitor`/`Health` seed stat nodes, drill-down reaches individual components. The stack, LOD, labels, and inspector path are shared.

### Input modality while open
The overlay is modal-ish: while visible, ship flight controls are suspended (standard map behavior — otherwise panning the map flies the ship). Map input uses mouse (drag = pan/rearrange, scroll = zoom, click = drill/select) + arrow keys; WASD stays flight-bound so it must not pan the map (unlike standalone `SystemMap`, which uses WASD because no ship is listening).

---

## 11. Pre-implementation review (2026-09-18)

Every claim below was checked against the tree (read, not assumed). The doc has been corrected inline where marked **[fixed]**; the rest are decisions or follow-ups.

### Verified — architecture stands as written
- Extend-framework + one wire shader; zero C++/pipeline/manifest changes required.
- `Cache.Shader('ui', …)` on-demand load + last-good fallback (`script/phx/util/Cache.lua:46-63`); standalone wrappers nil-check and skip.
- `pos.xy` is pre-transform pixel space (`res/shader/vertex/ui.glsl:8`); wire uniforms in `Draw.Rect` coords satisfy the coordinate invariant.
- `entity.id` monotonic counter (`script/Game/Entity.lua:1-6`) — keying nodes by id is safe; base Entity is delete/register/send only.
- `socket.child` links, `Jobs.Mine/Transport` `.src/.dst/.item`, `Children` add/get/iter, `Widget.__call` (both `X(y)` and `X.Create(y)` work), Graph poll pattern, `Config.ui.color` flat keys, Vec2f, `TestEcon` canvas pattern, validator auto-includes new files.

### Must-fix (all **[fixed]** inline above)
1. **Wire endcaps.** Distance-to-line reads ~0 past both endpoints → caps stick out. Fixed: per-segment clamped projection (triangle.glsl:28-30 pattern) + interpolated `bestT` (also kills the medial-axis gradient seam).
2. **`e:type()` does not exist.** Node color/labels use capability predicates + working `getName` only.
3. **No widget `:send`.** Inspector channel is an `onNodeSelected` callback field, not an event.
4. **Economy edges = `economy.jobs`, not per-entity flows** (rate numbers, not links). Note flow-based Transport caching is `if false`-disabled: live edges are Mine + trader-arbitrage.
5. `SocketKind` is `Game.SocketKind`; `Config.ui.color` takes flat keys; Tri uses an explicit bbox (not PadAndCenter); core alpha retuned (`exp(-2·idm/width)`, verify visually).

### Should-fix during implementation
- Node circles: use `DrawEx.Point`, no custom SDF.
- `isGraphWorthy` must exclude `getName`-less types (`Job`/`Action` assert NYI).
- Idea 8 (defer world-projection) contradicts Phase 3's deliverable — pick one before Phase 3.

### Open decisions (blocking polish, not Phase 0)
- **Real-game host:** plan builds only the demo. Where does NodeGraph live in LTheory, and what toggles it?
- **Numeric perf acceptance:** suggest the proven Phase-4/5 method — seeded demo + `PHX_DEBUG_DUMP` frame PNG + frame-ms. Dotted-edge budget ≈ N routes × bbox px (trivial math); measure, don't assert.
- **`rate` in edge metadata:** decide in Phase 2 (hover preview wants it) even if hit-testing waits for Phase 5.

### Reference pass (2026-09-18)
Viewed both Josh screenshots; they override the Bézier premise — see §12. Doc reworked: `dashline.glsl` replaces `wire.glsl` as the Phase 0 primitive (demoted, not deleted from history), edge-kind→style mapping locked (solid hierarchy/mine/sockets, dotted `Jobs.Transport`), node/selection/label language taken from the shots.

### Scenario pass (2026-09-18)
New §13, all verified: real-data-from-start (no PoC), F10 overlay host (M is music-mute; WASD/QE/Space/Esc all bound), single-system scope correction (no galaxy exists — top level is the current system, galaxy slots in later as a stack entry), suppressed-layer rule, node identity from real fields only (no description field exists — derive function from capabilities), ship/inventory as same-widget-different-context, modal-ish input (flight suspended, mouse+arrows for the map).

---

## 12. Visual reference (Josh Parnell video frames)

- `screenshot/Screenshot_2026-09-17_22-02-50.png` — sparse system map over a planet: ring nodes in varying sizes, straight solid spokes fanning from a top hub, one bright selected node with label ("Trbuscant"), dim unlabeled minors, live 3D scene (planet, asteroids) visible behind — overlay, no opaque panel.
- `screenshot/Screenshot_2026-09-17_22-51-00.png` — denser map: central bright hub ("Kinrbuscant") with spokes to labeled majors ("Mrbanta Minor", "Kykyon 7", "RXMKM-3533X", "W-579U"), one long clearly **dotted** route to a far node, corner-bracket selection reticle on a node, small white name labels under majors only, clouds of tiny blue dots (minor bodies) around the lanes.

### Visual language (normative for implementation)
- **Nodes:** glowing rings, size + brightness = importance; bright core on the selected/major node. Implementation: `DrawEx.Ring` + `DrawEx.Point` — no custom node SDF.
- **Edges:** straight lines only. Solid = hierarchy/socket/mine spokes; dotted = long-haul `Jobs.Transport` trade routes. No Bézier curves anywhere.
- **Labels:** small white text under major nodes only; minors unlabeled (two-tier LOD: rings+labels vs points).
- **Selection:** corner-bracket reticle (4 short lines) + brightened ring.
- **Composition:** translucent overlay on the live scene (unlike `SystemMap`'s opaque rect); monochrome blue/cyan family, brightness encodes importance.

---

## Appendix A — Reused conventions checklist
- Fragment header: `#include fragment`; output via redeclared `layout(location=0) out vec4 fragColor;` (matches triangle.glsl). No `#version` line (auto-prepended).
- DrawEx standalone pattern: PadAndCenter → nil-check shader → PushAdditive → uniforms (`SetFloat/SetFloat2/SetFloat4`) → `Draw.Rect(xMin,yMin,sx,sy)` → stop → Pop.
- Node graph widget: mirror SystemMap — `setmetatable(..., UI.Window)`, `Create(system)`, iterate `system:iterChildren()`, pan/zoom in `onInput`.

## Appendix B — File inventory (final)
**New:**
- `res/shader/fragment/ui/dashline.glsl` — dashed-line SDF fragment (solid when `dash < 0.5`).
- `script/UI/NodeGraph.lua` — node graph + inventory visualization widget (§7 state home).
- `script/UI/GraphLayout.lua` — layout algorithm (layered/Sugiyama or spring), **optional/new** if it grows past ~50 lines; else stays inline in NodeGraph (§8 Phase 3).
- `script/App/NodeGraphDemo.lua` — demo app.

**Modified (minimal):**
- `script/UI/DrawEx.lua` — add `DrawEx.Dash(...)` (+ bbox padding).
- `script/Config.App.lua`, `Config.Local.lua` — optional semantic colors/toggles (pure Lua).

**TBD / may be a separate widget:** node inspector/detail panel (§7 Inspector decision) composed alongside NodeGraph, fed by the `onNodeSelected` callback.

**Reference only (unchanged):** `script/Game/SystemMap.lua`, all of `script/UI/*.lua` framework, entity/socket/economy components.

---

## Additional implementation ideas we may be missing

A few things worth considering beyond the plan, in no particular order:

1. **Start with the inventory/ship-systems tree as the MVP**, not a full sector overview. Straight solid + dotted edges (reference §12) work on small structured trees (Generator→Thruster→Turret sockets; Mine/Transport jobs) where every edge is meaningful. A dense sector overview gets LOD-filtered anyway and reads better as the existing straight `SystemMap`. This also keeps Phase 2's `isGraphWorthy` predicate simple from day one.

2. **Make NodeGraph context-aware from Day 1 (depth-1 stack).** Store `self.stack = {context=system}` and route seeding through the *current top of stack*, so a future push/pop is just swapping which system you seed — no rewrite of Create/onUpdate. Phase 4 then becomes "add push/pop + camera transition" rather than "refactor state."

3. **Straight + dotted per mode — confirmed by reference (§12).** Logical mode uses solid `DrawEx.Line` + dotted `DrawEx.Dash`; world-projection uses the same two styles. No curves anywhere — `wire.glsl` stays out of the tree.

4. **Inspector as a callback, composed in GameView.** Assign `nodeGraph.onNodeSelected` and let existing debug-panel/inspector infrastructure render detail (health, sockets, economy flows). Zero extra wiring for the demo; real inspector reuse later without touching NodeGraph's click handling.

5. **Animate camera transitions per stack level** — store `{zoom,pos}` on each entry so `back` restores the prior view instead of snapping to default. Small thing that disproportionately affects how "polished" drill-down feels (per Claude's feedback); bake it into §7 push/pop now rather than Phase 4.

6. **Hover preview for edges before deciding interactivity.** Even if wires start decorative, showing a tooltip/flow-rate readout on hover gives value with minimal cost and informs the Phase 5 hit-testing decision early — decide then whether `rate` belongs in self.edges from Phase 2 onward (see §9).

7. **Lerp smoothing should cover node scale/color too** (health bars), not just position. Health-bar alpha/height updating frame-to-frame will otherwise flicker as the ship moves or takes damage; same `1 - exp(-k*dt)` trick, baked into onUpdate from Phase 2.

8. **World-projection can stay thin.** The reference sector map *is* straight lines over the live scene, so world-projection mode is just: project entity positions into the canvas + draw the same straight solid/dotted edges. No separate visual language to invent — the screenshots already specify it.

