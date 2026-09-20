# Node-Based UI / Inventory Visualization — Implementation Plan (LTheory)

**Status:** Phases 0–5 shipped, plus the 2026-09-20 refactor pass (steps 1–5: perf caching, bug fixes, dead-code removal, UX batch, provider seam, 29 offline checks). Vector inspector live for every node class. The widget is now provider-driven (see §15) and ready to host other views (ship/inventory/crafting/comms).
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
| `node.pinned` (per node) | **Future — not implemented.** Specified for a logical auto-layout pass (Phase 3) that was never built; today nodes are free-form dragged and `manual=true` freezes a dropped node's position. Revisit with logical views (§16.2 P2). | — |
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
- **Drill vs select:** click = select/zoom (opens `self.inspector`); double-click or Return on a node with a valid drill context = `drillInto`. The earlier `onNodeSelected` callback idea was superseded by the companion inspector (§7).
- When pushing, animate/transition camera+zoom into the new level instead of jarring recenter — store per-level camera so `pop()` restores it.

### Inspector / detail panel (AS SHIPPED)
**Shipped form (supersedes the earlier `onNodeSelected` callback idea):** `UI.NodeGraphInspector` is a companion object owned by NodeGraph (`self.inspector = Inspector.Create(self)`) and drawn at the tail of `NodeGraph:onDraw` in the same screen space. Selection drives it (`show(node)` on click, `hide()` on empty-click / map close). It renders the vector wireframe + identity block + function tags (§8 Phase 5) and needs no event plumbing — nothing in `script/UI` sends events, and a callback would have added wiring for the same result. A future detached inspector (docked panel, out-of-band detail) can still subscribe to selection; nothing today depends on the callback.

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
**Phase 3 — Layout algorithm + modes (NOT BUILT; superseded for the map view)** — the sector view is spatial (node positions are world x/z), so no auto-layout was needed. Logical views (inventory/crafting/comms) will need it: `GraphProvider.layout(nodes)` is the hook and `GraphProvider.grid(cols, pad)` is a working deterministic grid; a full layered/spring `GraphLayout.lua` plus `node.pinned` remain future work (§16.2 P2).

**Phase 4 — Drill-down / navigation stack**
- `self.context` seeds levels instead of the root; `self.stack` carries `{context, camera{zoom,pos}}` per level. **Drill trigger:** click a node with children (mine hub, zone, ship, station) → `drillInto` (fresh fit — new DOF from fit_view, not a climbing zoom; the Parnell reveal is exactly this); otherwise click zooms to selection.
- **Back:** Backtick (Escape is the quit key — §13) or right-mouse pops one level, restoring the exact camera it came from. Breadcrumb path under the scale bar shows the current level.
- **Drill trigger is explicit** (click = select/zoom, double-click or Return = drill). The zoom-radius auto-trigger with hysteresis (`kDrillRadius`/`kUndrillRadius`) was dropped in favour of explicit input and those constants were removed as unused (§15 step 2) — no hysteresis, no flicker.
- **Crash fixed (2026-09-19):** drilling into a childless entity (asteroid) asserted `iterChildren`. Two causes: the drill condition matched any `getChildren` (bare `or`), and `seedFromSystem` never guarded the context. Now: drill requires `hasChildren()`, and childless contexts bail to an empty level instead of asserting. Reproduced via the offending click path, fixed, boot-verified 0 errors.
- **Blank-after-drill fixed (same day):** drilling a node with no *seeded* children (factory with socket children, station) showed an empty canvas and the map felt dead. Drills now require `hasChildren()`; the zone-refit lets a zone reveal its members (the Parnell "region" step); F10-open/close resets any leftover drill via `onEnable`. Boot-verified.
- **Zoom-two-walls fixed (same day):** the zoom ceiling (3000) and a per-frame ring/fan recompute (dots re-pinned at 105–155px at every zoom) made the field "impossible to approach". Ceiling raised 3000→5e5; ring/fan computed ONCE per level at fit (`_fitted`/`_ringDone` gating, re-held per gesture), so zooming in now genuinely approaches true positions — dots separate, rings stop clinging to the hub. Boot-verified, errors 0.
- **Click/Double-click split (2026-09-19).** Feedback: clicking the factory "disappears" (drilled into an empty sub-level), clicking the planet won't lock, but ore dots (no children) work. Root: any child-bearing node auto-drilled on click — the anti-Parnell behavior (they zoom into a selection, they don't reset). Now a single click always zooms in place (lock + ×4, correct for factory/planet/ore alike); **double-click** drills into a node's children (zone members, ship components). This also fixes the "depends what I click on" inconsistency — one behavior for every node.
- **Click centers then zooms (same day).** Knot #1 ("can only zoom in so far before it moves") and #2 ("planet stays the same size") both trace to anchoring: zoom anchored at the cursor/ring, not at the node, so continuing scroll drifted the (center-off) anchor. Click now centers the map ON the selection immediately (pos = node), then eases ×4. A dead-centered anchor cannot drift — any scroll re-anchors at screen center. The planet ring still clamps at 40px (fixed drawn size), but it centers and stays centered while you scroll in; the ring pixel size is a HUD choice, not zoom failure.
- **Vector-entity popup feasibility (asked)** — answered YES, at near-zero FPS cost: draw the selected entity's existing mesh once, projected as a wireframe border inset (small panel, top-right), plus coordinates/kind. It requires NO zoom-depth at all and matches the Parnell framed-lens look. Availability: `mesh` exists on every entity (ships/asteroids/stations/planets all have one); projected edge list costs one mesh draw for ≤1 node. Design as the Phase 5 inspector's visual half; intentionally out of scope for Phase 4's map lens.
- **Unit tests + resolution scaling (2026-09-19).** `tools/validate_nodegraph.lua` (20 checks, wired into `configure.py test`): `isGraphWorthy` classification for all categories + deleted entities, zoom clamp bounds under accumulated scrolling (the 3e5 runaway), and the drill-stack contract — `drillInto` pushes `{context, camera}` and `drillOut` restores the exact context + camera, with childless targets refusing to drill (the asteroid crash regression). Pure logic under stubs, no GL. Inspector metrics now scale with resolution (`resScale`, clamped 1.0–2.4× of the 900px reference, matching the debug panel's approach): on a 4K window the panel is ~936×900 with ~39px title / ~34px body text and a ~450×360 vector view, instead of the old fixed 312×300 with 15/13px text.
- **Resolution-scaling shadowing bug (2026-09-19, caught immediately).** The scaling pass introduced `local okS, sc = pcall(...)` for the entity's world scale, shadowing the resolution `sc` declared above. Every later size then used the WORLD scale: station (scale 100) → `barW = 150*100` = whole-box green HP bar; planet (scale 1e5) → `wireW = 150*1e5` = image off-screen; ore (scale 2–5) → image partially in/out of the box. Renamed to `scaleVal`; verified headless `[NID] cat=station sc=1.00 barW=150 wire=150x120` (independent of the entity's 100 scale), diag reverted, 20/20 + 136/0 green. Lesson: never reuse a single-letter resolution/scaling local name inside the same function as a per-entity value.
- **Phase 5 closed (2026-09-19).** Inspector confirmed working for every node class. Two final fixes: (1) **ore meshes now vector-render** — ore-field asteroids store a `LodMesh` (per-LOD `Mesh` wrappers) whose `getCenter` is meaningless, and indexing `:get` on a plain `struct Mesh*` aborts at cdata level. `entityMesh` now pcall-probes `:get(0)` to resolve LOD 0, verified headless: **90/90 rock nodes resolve (was 60/90 bad)**. (2) **panel layout** — removed the duplicated title line, shortened the HP bar (was full-width and overlapped the vector view), moved the image BELOW the identity/HP block, abbreviated coordinates (`163.6k`) so they can't reach across, and the caption now reads the node label/kind tag instead of the raw `Entity @ 0x...` pointer. Panel grown to 312x300. Validator 136/0; boot-verified 0 errors.
- **Vector inspector v1 shipped (2026-09-19).** `script/UI/NodeGraphInspector.lua` — panel driven by selection (click node = open, click empty = close): (1) **vector view** orbits the entity's real mesh (`Matrix.LookAt`/`Perspective` + `ui/hologram` rim shader) with a schematic box fallback for no-mesh entities; (2) identity block with real stats (pos ints, scale, live health bar); (3) function tags from capability predicates. One mesh draw for the selected node only (frame delta ~0); no new shader (reuses `ui/hologram`); name/description holes stay honest until universe gen fills them. **Hologram bug found en route:** `DrawEx.Hologram` called phantom `Matrix.ViewLookAt` — dead code, untouched, inspector uses the real `Matrix.LookAt`. **Hologram crash fixed (same click):** abort was `Shader_Start: variable stack does not contain <mView>` — the engine REQUIRES `mView`/`mProj` pushed onto the shared var stack before `shader:start()` (every `ui3D` pass does; my compact call didn't). Fixed with `ShaderVar.PushMatrix` → start → draw → Pop; re-proved headless with the panel open on a mesh node, 0 errors. **Vector view: three generations of fixes (same day) — shader render abandoned.** (1) orbit animation + world-scale meshes made the object "travel into and out of the box" — replaced with a unitized mesh snapshot (real vertices normalized to radius 1, `Mesh.Create`/`addVertexRaw`) under a static camera; still overran. (2) camera pulled back to 4.6 + ClipRect around the wire region — then it vanished entirely (scissor vs UI-buffer coupling). (3) **Current approach — deterministic CPU wireframe**, no shader state at all: snapshot the entity's mesh once, project triangle edges with a fixed yaw/pitch ortho-style camera, stroke ~1,400 decimated triangles directly in box space. Provably contained, zero GPU coupling; dense meshes decimate so it READS as a vector wireframe, and the image finally sits still inside the box.
- **Profiler note (same day):** the swap-buffer line is vsync, `Canvas.Update 3.5%` includes NodeGraph's per-frame seed+declutter, and `RenderTarget_Push 12%` is post-chain FBO mgmt — nothing pathological; per-call work is what we've introduced, not a leak. (Spikes already tamed: declutter now runs once per level-fit.)

### Phase 5 acceptance
- (a) click any seeded node → panel opens (proved headless: forced select + dump, 0 errors); (b) no-mesh/anonymous degradation → box fallback + tags only, pcall-guarded; (c) `./configure.py test` 136/0 (no shader change); (d) frame-cost = single hologram draw — measured in the same headless snapshot (<0.1 ms class), noted in the status log for the final audit.

**Phase 5 — Vector inspector + edge preview + demo harness**

**5.1 The inspector (primary deliverable).** A companion panel, opened by single-click-selecting any node and rendered in the same UI composite pass (stays out of NodeGraph's own draw — §7 decision). Layout: small framed panel top-right (below the filters), ~300×260px, three zones:
1. **Vector wireframe** (the "popup viewed from a vector point of view" — this is the part that makes deep zoom unnecessary): the selected entity's **existing mesh** (`entity.mesh` exists on Ship/Asteroid/Station/Planet) drawn remotely as a holographic wireframe. Implementation: reuse the standing `DrawEx.Hologram` primitive (`DrawEx.lua:61-82` — view-matrix at a fixed yaw/pitch around the mesh center, `ui/hologram` shader) at panel-screen coords; the mesh is likely already hologram-ready (schema verified). Cost = the SAME single mesh draw `Hologram` already does, and only for the 1 selected node — no FPS concern (a wireframe overlay at 1 node vs the full scene render).
2. **Identity block** (per §13, real data only): name or kind tag, `id`, live stats (position x/y/z, scale, health bar if `addHealth`), capacity when surface. **Placeholders allowed** where the universe isn't populated yet: if `getName` is absent, show `Ship #12`; if no description field exists (it doesn't), the panel omits description rather than inventing one. Future gen work fills real names/descriptions; the panel reads what exists and leaves holes honest.
3. **Function line**: capability tags (`hasFactory`→Factory, `hasTrader`→Trader, `hasYield`→Ore) — the "what is it" answer today.

**5.2 Edge preview.** Hover a dotted `Jobs.Transport` edge → tooltip (`item`: `rate`/s, src→dst). Straight-edge distance is a two-line CPU test (no GPU mirroring; §9). If routes prove rarely hovered, this drops to "flow rate in the toolbar when a route is selected" with half the code.

**5.3 Demo harness.** `script/App/NodeGraphDemo.lua` — the original plan's standalone runner, now optional oil-rig for editor work (same pattern as `TestEcon.lua:36`): spawn a system with a known zoo (station, planet, field, NPC squad via `spawnAI(n)`) so inspector/edge-preview features are testable headlessly/offscreen before touching the live LTheory scene. Run via `./run.sh NodeGraphDemo`; the F10 overlay in the game remains the priority, this is for iteration speed on panel layout.

**5.4 Data-richness parked with universe gen.** Names/descriptions for ships/rocks/bodies are a generator-domain change (`LTheory.lua`/`System.lua` spawn sites + `Name` component), not a map change — the panel renders what it's given and holes stay None/hidden until real gen lands. This is the "placeholder until we flush out the universe" boundary, drawn intentionally.

**Acceptance (Phase 5):** (a) click any seeded node → panel opens with wireframe + identity + function; (b) no-mesh/anonymous nodes degrade to the text block only (no crash path); (c) `./configure.py test` still 136/0 (no new shader required — reuse of `ui/hologram`); (d) frame-time delta with the panel open on a 1920×1080 map < 0.1 ms (measurable via headless snapshot after the edit; the single hologram draw is the whole cost).

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
| Shader compile/link | `./configure.py test` | Headless GLSL validator (`tools/validate_glsl.py`) compiles+links every `.glsl` incl. new `fragment/ui/dashline` via moderngl/EGL at the engine's GLSL level — **fail fast on typos.** Interpreter resolved from project venv / `$PHX_VALIDATOR_PY` / `python3`. |
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
- LTheory's live census is small (player ship, 1 named station, 1 unnamed planet, 60 field rocks, 30 debug ring rocks — escorts/NPC loops currently run 0), so `isGraphWorthy` LOD is load-bearing from day one, not a later optimization.

### Scope correction: one system today, galaxy later
`LTheory` builds exactly **one** `Entities.System` per run — no multi-sector galaxy exists. So the drill-down top level is the **current system** (label `"System <seed>"` until systems get names), not a galaxy map:
- Level 0 (system): planets, moons, stations, gates, ships, wormholes — rings + selective labels, hub spokes + dotted trade routes (the §12 look).
- Level 1 (drill into a body/ship/station): its children — ship sockets (Generator→Thruster→Turret), inventory (`Inventory` component), station markets/factories, moonlets.
- Level 2+ (drill into a component/node): live stats + the inspector panel (§7).
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

### Phase 1 skeleton (2026-09-18)
`script/UI/NodeGraph.lua`: id-keyed nodes/edges, SystemMap pan/zoom math, drag/select + corner-bracket reticle, translucent overlay canvas. Render-proved headless (temp GameView hook, reverted): hub/trade/dotted all visible on screen, PNG diff vs baseline max 0.98. Lesson recorded: files inside `script/UI/` load before the `UI` global exists — use local `require('UI.*')`, never the `UI.*` global at load time (works in `Game/` only because `UI` loads first).

### Overlay host (2026-09-18)
`LTheory` adds `UI.NodeGraph` as a hidden GameView child (same pattern as the debug window); **F10** toggles it (debounced, mirrors F9 — M is music-mute, WASD/QE/Space/Esc all bound). Overlay input is arrows + mouse only (no WASD — the ship owns it). Demo nodes seed the canvas until Phase 2 replaces them with live system data; render-proved in-game (overlay-vs-hidden PNG delta mean 0.29). Known limitation: flight is NOT suspended while open yet (ship keeps flying while you browse) — gate `MasterControl` input on map visibility before this leaves dev-preview.

### Dev-preview feedback round (2026-09-18)
F10/select/drag/dotted-follow all confirmed working in-game. Changes: modal input gating in `HUD:onInput` (extends the existing debug-panel `overPanel` pattern — while the map is open the ship holds thrust/aim/fire and the camera holds zoom; target-lock untouched), trade-route color brightened (`cTrade` → 0.45/0.75/1.0 @ 0.95), demo scaffold gains a `Map` node off the hub. Boot-verified headless, zero errors.

### Phase 2 live seeding (2026-09-18)
`Create(system, {focusEntity})`; per-frame merge (new snap in, live retarget, unseen pruned — table never replaced); lerp tracking; edges from sockets (both-seeded only), hierarchy (context root excluded — no starburst), economy `Jobs` (Mine solid, Transport dotted). Two-tier LOD (majors rings+labels, minors points). Fit majors-only + player-centered (full-set fit piled everything: the "stacked" bug). Drag writes `manual=true` so drops survive reseeding (fixes snap-back; dropped ships freeze where left until Phase 3 pinning). Labels via `e.name` or kind tags (`Factory #12`, never `Entity @ %p`); late-promoted majors backfill labels. Declutter: deterministic draw-time spiral offsets for co-located majors (true positions intact). Bodyless entities (particles) skipped via pcall guards — first live run caught the `getPos` assert. Headless proofs clean, zero errors. Drill-down still Phase 4 (click selects only).
- **Lock-on that works at any distance (same day).** Root causes found by reading, not guessing: hit radius used *world* scale (planet = 3000px+ click black hole swallowing nearby clicks), and far majors (planet at ~250k, `planetViewDist`) sat off-screen unclickable — so "click the planet" hit 3D space, not a node. Fix: hit-testing uses *drawn* size (shared `drawnRadius` helper, one source of truth with the ring); off-screen majors get edge triangles + labels at the clamped frame position, hit-testable at the same spot — clicking one selects and follow flies the view there. Filter-aware.
- **Single-intent lock (same day).** Follow-ease (centering) fought zoom-anchor (cursor) whenever the cursor sat off-center — the selected node crept during scroll. Now: locked node is the anchor for everything (never moves under any scroll); cursor anchors only unlocked. Follow-ease holds once centered (3px) instead of pulling forever, so moving ships still track. Click empty = release.
- **Drift root cause + proof (same day).** Screenshots 02->06 showed the cluster walking up-right while zooming. Two stacked causes: (1) declutter offsets recomputed per frame from the shifting screen layout moved the anchor mid-gesture -- fixed by freezing offsets while scrolling (+6 settle frames); (2) follow-ease dragged view-center-ward *during* scrolls -- fixed by suspending centering while a gesture is live. Proven headless with a select+scroll autopilot: tracked node pinned at identical sub-pixel coords across zoom 721->291,055 (400x), three runs. Autopilot block is TEMP in-tree (env-gated, revert before merge).
- **Zoom bounds (2026-09-19, committed before Phase 4).** `clampZoom` bounds every zoom change (scroll / drill / fit / ease) to 1e-4..3000 with a NaN guard; a headless autopilot run had reached zoom 291,055 on the unbounded `zoom * exp(k*scrolled)`. Click-zoom no longer caps at an absolute 3 (that cap was a symptom, not a fix). NOTE: `clampZoom`/`kDrillRadius` are locals defined ABOVE `seedFromSystem` — locals are only visible after their definition, so an earlier placement raised `undefined global clampZoom` at runtime (caught headless).
- **Zoom-about-cursor (same day, superseded by node-priority anchor).** User model: cursor sits on the node, scroll should dive into it — independent of lock state. Scroll now pins the world point under the cursor (clamped into the widget); follow-ease still glides to selections. The node-pinned variant it replaces couldn't survive a silently dead follow.
- **Lock-on zoom (same day).** Scrolling used to clear follow, so zooming centered mid-screen and the node slid away. Now scroll zooms *about the locked node* (its screen pos pinned, follow survives; manual scroll just retires the auto ×4 push). Click hub → view dives straight in; pan/drag/click-empty still break lock.

### Dense-cluster fan (2026-09-18 — "don't clump the 60")
Co-located minors spiral onto a capped disc (grid-hashed 16px cells, 3×3 neighbourhood — majors seed the grid first so fans never cover rings), zoom-gated (real positions separate up close, so no lying), with thin leader lines back toward truth (length varies, capped). Dots stay 1:1-anchored; only the overlap is displaced. Accepts: Phase 2 closed after this — overlay host, live seeding, LOD, filters, zoom/focus labels, scale bar, fan all live; drill-down is Phase 4.
- **Follow-up (same day): mine-spoke starburst.** Ore rocks each draw a lane to their station, so fields read as spokes, not discs. Fix: mine-linked minors arrange in a **ring band (100–160px, direction truthful, distance compressed)** around their station anchor — spokes stay short by construction. Grid fan skips anchored rocks (but still avoids them); leaders suppressed where the spoke serves. Zoom-gated like the fan: close up, truth returns.
- **Follow-up (same day): full 360° ring.** Direction-preserving slots piled on one arc (fields are one-sided from their station), so layout is now pure golden-angle around the hub with radii alternating 105/130/155 — every spoke a different length, dots spaced for clicking (ringed dots get a 14px hit radius vs 8). Clicking the hub centers + zooms ×4 onto it (follow + targetZoom), so reaching a readable view takes one click, not pan/zoom fiddling.

### Phase 2 display cleanup (2026-09-18, user questions answered in code)
- Ore fields carry yield on EVERY rock (`spawnAsteroidField(60, 1000)` marks all 60) — yield-alone no longer promotes to major, or 60 labels form an unreadable band. Mineables stay dots, labeled on zoom/focus.
- Planets (scale 1e5, possibly a sector away) are drawn but excluded from the fit bbox, or stations collapse again.
- Categories + filters: every node gets `cat` (station/ship/rock); **F5 ships / F6 rocks / F7 places / F8 routes** toggle layers, legend bottom-right. Replaces the old demo hub/mine/trade nodes with the real thing.
- Minor labels appear when zoomed past 0.3 or on selection (100 ship labels at sector zoom would repeat the band bug); selected minors get a small reticle.
- Scale bar bottom-left (map is 1:1 world x/z, zoom = px per unit) — answers "how far is that" directly.
- Verified facts: no gates/wormholes exist in LTheory gen (nothing missing); `visibility-cloud` is a debug print of the same field, not separate rocks; NPC ships scatter at `kSystemScale` while rocks clump by chained spawn — dots are both, distinguished by zoom/focus labels.
- **2026-09-18** — **Screenshot-driven beautify round**: declutter rewritten in screen pixels (world-space version fanned co-located nodes into giant rings at fit-zoom — the circle artifact); kind tags now read `Ship`/`Ore`/`Factory` (sockets ⇒ ship, yield ⇒ ore); user's shot predated these fixes (pointer labels = old fallback — Lua hot-loads at boot, restart picks them up, no rebuild). Held the line: the ore blob stays clumped (positions are truthful 1:1 — fan requests denied, zoom + F6 rocks-only are the tools). Stations spawn disc-scattered, not planet-adjacent (generator reality; co-located station option = future gen change).

### Edge mechanical difference + flow animation (2026-09-18)
Dotted vs solid is now functional, not paint: solid edges are structural/static (hierarchy, sockets, mine links — selectable endpoints, no motion); dotted `Jobs.Transport` edges are live flows — dots drift toward the destination (`flow` phase uniform = time × 0.35) and will carry hover data (item/rate) once Phase 2 attaches edge metadata. `dashline.glsl` + `DrawEx.Dash` take an optional `flow` arg (default 0 = static); validator 136/0, full suite green, visible-path proved headless.

### Scenario pass (2026-09-18)
New §13, all verified: real-data-from-start (no PoC), F10 overlay host (M is music-mute; WASD/QE/Space/Esc all bound), single-system scope correction (no galaxy exists — top level is the current system, galaxy slots in later as a stack entry), suppressed-layer rule, node identity from real fields only (no description field exists — derive function from capabilities), ship/inventory as same-widget-different-context, modal-ish input (flight suspended, mouse+arrows for the map).

### Hierarchy + regions + follow (2026-09-18)
Verified against the generator: no universe/galaxy/sector names exist (top level is `"System <seed>"`); **regions DO exist** — `Zone` entities with generated names (`"X Field"`), positions, and member lists (`Zone:add` is loose grouping, no reparent). Sector level now seeds zone *nodes* and suppresses member rocks until drill-down (Phase 4) — this is the grouping answer for 20-30-minute flight distances: regions, not one giant view. Component children (turrets/thrusters, parented to ships) are likewise excluded. Selection now eases the view onto the node (zoom untouched; pan/drag/zoom breaks follow).

---

## 14. World-generation survey (2026-09-18, read-not-assumed)

`LTheory:generate` (`script/App/LTheory.lua:7-102`) builds exactly one `Entities.System` (`kSystemScale = 10000`). Current census (loops at lines 32/47 run **0** iterations — escorts and NPC AI are disabled in this build):

| What | Count | Position | Name? | Map tier |
|---|---|---|---|---|
| Player ship (+`YOU` marker) | 1 | `Config.gen.origin` | no (`Ship #id`) | major, white |
| Station (Market+Trader+Factory+Production) | 1 | disc radius ~10k | yes, generated | major, labeled |
| Planet (scale ~1e5) | 1 | random dir, possibly far | no | major ring, unlabeled target |
| Asteroid field (all 60 carry yield) | 60 | **random** zone (see bug) | no (`Ore #id` on zoom) | minor dots (+ zone node) |
| Visibility-cloud ring | 30 | ring 8–20k around player | no | minor dots |
| GPUParticles | 1 | — | skipped (no body) | — |
| Zones (`system:getZones()`) | 1+ | field centers | yes (`"X Field"`) | major region nodes |

- **The dot-circle artifact was real data**: the 30 visibility-cloud rocks are placed on a ring (`ang = i/30·2π`) — not a map bug. They are debug scaffolding with no distinguishing marker; leave them (deleting changes the scene), but know what they are.
- **Real gen bug (out of map scope, flagged):** `LTheory.lua:53` passes `fieldPos` ("3,000 units directly in front") but `System:spawnAsteroidField(count, oreCount)` takes no position — the field lands randomly. "Asteroids in front of me" confusion starts here.
- **Names:** stations and zones (generated), everything else anonymous. Sector itself unnamed → top node reads `"System <seed>"`. No universe/galaxy layer exists.
- **Recommendation: do NOT expand the universe yet.** One sector already exposes every map problem (grouping, LOD, labels, scale); multi-sector generation + streaming + travel is a separate project. The stack design absorbs it later with no widget changes.

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

## 15. Refactor pass — review findings & remediation (2026-09-20)

External review of both files, then a careful, verified 5-step pass (the map was working; every step re-ran `configure.py test` + a headless boot).

**Step 1 — performance.** `NodeGraphInspector` rebuilt a unitized mesh copy AND re-projected ~1,400 triangles **every frame** while open (14k+21k FFI calls/frame). Now the wireframe is cached per selected node (`_linesForNode`, static projection — there is no animation) and only the box-pixel mapping runs per frame. `NodeGraph` no longer allocates `edges`/`memberOfZone`/`seen` every frame (persistent tables, cleared in place). Also fixed a latent ordering bug: `declutter` reads `self.edges` for the mine-ring fan, so edges are now built before the fit's declutter (it previously depended on the *previous* frame's edges and only worked because the widget rect is 0 on frame 1).

**Step 2 — bugs & dead code.** (a) Off-screen indicator hit-testing mixed global node coords with a local `24..vsx` range — only correct because the map starts at the window origin; now global. (b) Edges ignored category filters, so hidden rocks still drew lanes; one `isHidden(n)` predicate now serves draw, hit-test and edges. (c) `drillInto` returned `nil` vs `false` inconsistently. Removed: `_prevNodes`, `addNode`/`removeNode`/`addEdge`/`clearEdges` (zero callers), `kDrillRadius`/`kUndrillRadius` (unused), `HOLO`, a no-op `local self = self`. De-duplicated `kindTag`/`fmtShort`/`resolveLabel` into `NodeGraphUtil.lua` (the two copies had drifted: `'Factory'` vs `'FACTORY'`).

**Step 3 — UX.** Edge-hover readout (route description via the job, cheap point-to-segment test); minor labels capped to near-centre at zoom (all-minor labelling piled up); inspector panel clamped to the canvas (was negative on narrow windows).

**Step 4 — provider seam (extensibility).** `GraphProvider.lua` now owns data selection: `classify`, `children(ctx)`, `links(ctx, nodes)`, `drillable(entity)`, and an optional `layout(nodes)`. `NodeGraph` keeps the view (merge, fit, declutter, draw, input, drill stack) and delegates to `self.provider` (default `GraphProvider.system()`, behavior-identical). `GraphProvider.grid(cols, pad)` provides deterministic logical layout for non-spatial views. **To build another view:** pass `{ provider = <your provider> }` to `NodeGraph.Create`; the drill stack, filters, zoom, declutter and inspector are reused unchanged.

**Step 5 — tests.** `tools/validate_nodegraph.lua` grew from 20 to **29 checks**: provider classification parity, grid-layout determinism/spacing, and a **provider-swap** test (custom provider seeds units into the graph; its drill policy is respected). Still GL-free and wired into `configure.py test`.

**Remaining / future.** Multi-sector = a galaxy-level provider (roots = systems) that drills into sectors — no widget change. Ship/inventory/crafting/comms = a provider plus (for logical views) `GraphProvider.grid` or a future `GraphLayout.lua`. Auto-drill-on-zoom (radius trigger with hysteresis) was dropped in favour of explicit click/double-click; the constants were removed as unused.

## 16. Second review round (2026-09-20) — P0 DONE, P1/P2 pending

Second external review of `NodeGraph.lua` + `NodeGraphInspector.lua`, re-verified against the tree (not taken on faith).

**P0 status: DONE 2026-09-20.** P0.1–P0.4 applied; P0.5 tests 29 -> 34, all green; 136/0 shaders; clean boot. The declutter test was proved to *catch* the bug (re-breaking the gate produced exactly the 2 expected FAILs, then passed on restore).  **P1 status: DONE 2026-09-20.** Drillable indicator (`+` on drillable nodes: majors always, minors only when selected; `n.drillable` stamped once at seed), failed-drill red-ring flash (~0.45 s), legend documents drill/back keys, Return drills the focused node. Tests 34 -> 37. Clean boot + dump, 136/0. Boot caught one bug: the `+` glyph used the inspector-local `HEAD` colour in `NodeGraph` (undefined global) — switched to `cCore`.  **P2 status: RECORDED (deferred by design).** Layout persistence across drill re-entry is not implemented — only needed once logical views exist, where layout is authored; pair with `GraphProvider.layout`/`GraphLayout.lua`. Doc cleanup applied below.

### 16.1 Verified findings

| # | Finding | Severity | Evidence (verified) |
|---|---|---|---|
| B1 | **`declutter` runs once ever.** `_ringDone` is set at `NodeGraph.lua:164` and never reset; `drillInto`/`drillOut` reset `_fitted` (correct) but not `_ringDone`. Every level after the first seeds nodes with `jx/jy = nil` and no separation → overlapping majors at drilled levels stack silently. | High (data-dependent, silent) | `grep _ringDone` → one write site; drill funcs reset only `_fitted` |
| B2 | **`ctxIsZone` lost its root guard (regression from the §15 step-4 refactor).** Pre-refactor: `sys ~= self.system and sys.name ~= nil`. Now `GraphProvider.lua:60`: `ctx.name ~= nil` only. `Entities.System` sets **no** `.name` (grep), so behaviour is currently correct — but a named root would skip zone suppression and leak every zone member into the sector view. | Medium (latent, one gen change away) | `GraphProvider.lua:60`; `grep self.name script/Game/Entities/System.lua` → none |
| B3 | **`edgeAt` ignores `filter.routes`.** Edge *drawing* is gated (`NodeGraph.lua:554`), the hover lookup (`:670`) is not → F8-off still shows route tooltips for invisible edges. | Low | `grep edgeAt\|filter.routes` |
| B4 | `ffi` used without `require` in the inspector. | **Not a bug** — `ffi` is a global (`script/env/ext/GlobalEx.lua:5`). Add the explicit require for robustness, not for correctness. | grep |
| B5 | `_offsetHold` written in `applyScroll`, decremented in `onUpdate`, **never read** (its declutter gate was replaced by `_fitted` in §15 step 1) → dead state. | Trivial | grep `_offsetHold` |

### 16.2 Plan

**P0 — correctness — DONE 2026-09-20**
- **[DONE]** **P0.1 (B1)** Delete `_ringDone`; gate the fit-time `seedEdges()` + `declutter()` on `not self._fitted` (behaviour-identical on the fit frame, and correctly re-runs after every drill because both drill funcs already set `_fitted = false`). Also delete `_offsetHold` + its decrement (B5). Files: `script/UI/NodeGraph.lua`.
- **[DONE]** **P0.2 (B2)** `provider.children(ctx, isRoot)`; `NodeGraph` passes `ctx == self.system`; provider uses `ctxIsZone = (not isRoot) and ctx.name ~= nil`. Files: `script/UI/GraphProvider.lua`, `script/UI/NodeGraph.lua`.
- **[DONE]** **P0.3 (B3)** Gate the hover lookup on `self.filter.routes`. Files: `script/UI/NodeGraph.lua`.
- **[DONE]** **P0.4 (B4)** `local ffi = require('ffi')` at the top of the inspector. Files: `script/UI/NodeGraphInspector.lua`.
- **[DONE]** **P0.5 tests** (`tools/validate_nodegraph.lua`): (a) declutter re-runs — after `drillInto`, seeded majors gain `jx/jy` (assert not-nil after the post-drill fit); (b) the `isRoot` zone rule — a *named root* context still suppresses zone members, a *named zone* context reveals them.

**P1 — player-facing polish (cheap, do after P0 is green)**
- **P1.1 Drillable indicator.** Stamp `n.drillable = provider.drillable(e)` at seed time (already computed at click time); draw a small tell on drillable majors (dashed outer ring or a `+`) so "has more inside" is learnable, as the Parnell reference distinguishes expandable nodes.
- **P1.2 Failed-drill feedback.** A double-click that fails `drillable` currently does nothing. Flash the ring red for ~0.4 s (transient `_drillFail = { id, t }`).
- **P1.3 Discoverability.** Fold "double-click drill · RMB/` back" into the existing F5–F8 legend line while the feature is new.
- **P1.4 Enter-to-drill.** Keyboard parity: Enter drills the focused node (backtick already backs out).

**P2 — defer (record only; tie to logical-view work)**
- **P2.1 Layout persistence across re-entry.** Drilling wipes `self.nodes`, so manual drag positions are lost on re-entry to a visited level. Only matters once logical views (inventory/crafting) exist, where layout is authored rather than spatial — pair it with `GraphLayout.lua`, not now.

### 16.4 Follow-up from play-test (2026-09-20) — regions, zoom compounding, ship policy

Three things came out of play-testing the map. All fixed and verified (44/44 node checks, 136/0, clean boot).

**Q: should double-clicking the factory/solar node show the ore asteroids?** No — and the root cause was a missing feature, not a misclick. Facts from a headless node dump: the solar array is a station with `children = {}` (`kids=0`, `drill=false`), and the ore is NOT its child. The mine **lanes** the user sees are economy `Jobs.Mine` edges (station ← rock), i.e. a *relationship*, not ownership. The ore's actual owner is the region: `System:spawnAsteroidField` creates a `Zone` ("Rine Field") with 60 members and calls `system:addZone(zone)` — which stores it in `system.zones`, **not** in the child tree. `provider.children` only walked `iterChildren()`, so no region node was ever seeded: the field had no drill anchor at all.

- **Fix:** `GraphProvider.system().children(ctx, isRoot)` now also emits each `ctx:getZones()` zone as a **major region node** at the sector level (position = zone center, radius = clamped bounding radius over members). `drillable(zone)` was already true; drilling it reveals its 60 members. Verified headless: `id=14 cat=station drill=true label=Rine Field r=4000 members: ore=60`.
- **Zone drill was also broken** one layer deeper: members are parented to the **system** (`Zone:add` is loose, no reparent), so `topLevel` rejected them; `children` now treats a zone context's members as top-level (`ctxIsZone`). Test: "drilling the zone reveals its members".
- **Radius clamp:** the computed bounding radius could be dominated by a far outlier (1.07e6 observed), which would also drop the region from the fit (`r >= 5000` is treated as planet-scale). Clamped to 600..4000 so regions read correctly and contribute to the fit.

**Bug: "the link connecting the ore to the factory gets longer every time I click".** Real. `targetZoom = clampZoom(self.zoom * 4)` was relative to the *current* zoom and ran on every click, so repeated clicks compounded ×4 each time — the view zoomed in without bound and fixed-world mine lanes stretched on screen. **Fix:** the click-zoom target is now absolute for the level (`clampZoom(self._fitZoom * 4)`, with `_fitZoom` captured at fit), so clicking the same node repeatedly lands on the same zoom.

**Feedback: drilling the player ship shows ship parts — not wanted on the map.** Agreed; that is the ship-systems/inventory view, not sector content. `provider.drillable` now returns false for ships (`hasActions`), so double-clicking `YOU` no longer drills. `provider.noDrillReason(entity)` (new, optional) tells the UI *why* a failed drill happened without flashing for targets that belong to another view: a childless/empty station returns `'empty'` (red flash = "nothing to explore here"); a ship returns `nil` (no flash).

### 16.5 Follow-up from play-test #2 (2026-09-20) — back restores focus, launch fits the level

Two reports after drilling `Rine Field`:

**Bug: right-click (drill out) dumped the player's view instead of staying on the inspected node.** Root cause: `drillOut` did restore `zoom`/`pos` from the stack, but it also set `_fitted = false` — so the very next `seedFromSystem` re-fit the level, and the fit's player-centred branch overrode the restore (the player was the fit centre). Netting out to "back = go to YOU". Worse, the drilled-from node was not re-selected at all (`focus` was cleared).
- **Fix:** `drillInto` now records `focusId` in the stack entry. `drillOut` **defers** the camera + focus restore (`_restore`, `_restoreFocus`) instead of applying them immediately — there are no nodes to select yet, and the fit would overwrite the camera. `seedFromSystem`'s fit block applies the saved camera (skipping the recomputed fit) and, after seeding, re-selects the node and reopens its inspector. Verified by test: "re-seed applies the restored camera (not a player recentre)" + "re-seed re-selects the node we drilled from".

**Request: opening the map should show ALL nodes with 'YOU' selected, not a deep zoom on 'YOU'.** The fit was player-centred by design (an early "player-centric map" decision), which meant every launch started zoomed in on the player and required a big scroll-out to find the station/region.
- **Fix:** the fit bbox now spans majors (planets excluded, `r >= 5000`) **plus the player's own node**, and centres on that set. `YOU` is then **selected** (red highlight) without being centred. Verified headless: `bbox=-2219,-72108..227635,5711 zoom=0.00379 focus=4(YOU)`, i.e. the whole level in frame.
- Consequence: click-zoom can no longer be `fitZoom * 4` (the fit is now very wide, so ×4 is still an overview). It is now **absolute and size-appropriate**: `clamp(min(1.0, max(0.2, 40 / node.r)))` — regions stay wide, small bodies come close, and it is independent of the fit, so no compounding.

Status: 49/49 node checks, 136/0 shaders, clean boot.

### 16.9 Compression moved to SCREEN space (2026-09-20) — "something is wrong"

Symptom: clicking a node (asteroid/ore) centred the camera, then the whole map vanished — no node elements at any zoom, and F10 close/reopen did not recover.

Cause: §16.6 applied the distance compression in the **stored camera frame** — `self.pos` was a *compressed map* coordinate, and the compression depended on zoom. A click sets `pos = mapXY(node)` at the fit zoom and a `targetZoom`; as the zoom eased, the compression faded, so every node's map coordinate moved but `pos` did not. The clicked node slid off-screen and nothing brought it back (F10 doesn't reset the camera).

Fix: the projection is now `world -> linear screen -> radial warp`. `self.pos`/`self.zoom` are plain **world space** and strictly linear, so pan / zoom / centre-on-node are the classic linear operations and a zoom change can never invalidate the camera. The compression is a screen-space radial warp about the view centre (`_warp`/`_unwarp`, `toScreen`/`toCanvas`), with the same strength/fade (`t` from `_zFit*12`) and reference radius (`_dRef * zoom`). `applyScroll` now pins the anchor's **warped** screen position across the zoom (solving `pos` at the new zoom), so cursor and locked-node zoom are both exact.

Properties:
- **Identical opening/zone view** to §16.6 — at the fit the camera sits on the level centre, where a warp about the view centre equals a warp about that centre. Verified: root `zoom=0.003787 dRef=60667 0/94 off-screen`, Rine Field `zoom=0.152716 dRef=3303 5/60`, unchanged.
- Clicking now keeps the node centred through the zoom ease (the camera is linear). Drag still relocates a node (`toCanvas` inverts the warp).
- Declutter offsets are added in screen pixels after the warp, so fans/rings stay fixed-size.

Removed the now-obsolete `mapOf`/`unmap`/`mapXY`/`toScreenMap`/`toCanvasMap`. `_refC` remains set but is no longer used by the projection (kept for the drill-stack frame record).

Verified 60/60 node checks (new: "the node stays centred as the click-zoom eases"), 136/0 shaders, clean boot. §16.8's map-space plumbing is superseded by this; its drag-on-click gate still stands.

### 16.8 Click-to-centre regression (2026-09-20) — "centre focus when you click nodes stopped working"

Two separate faults, both fallout from the §16.6 projection change (which made `self.pos` live in **compressed map space**):

1. **`self.pos` set from raw world coords.** The press-edge centred the camera with `self.pos = dn.x + jx` (raw world). `pos` is map space now, so the camera centred on the *uncompressed* point — far off for any node away from the level centre. Fixed with a `NodeGraph:mapXY(n)` helper (compressed world + declutter offset); the click-centre, the scroll anchor, and `toScreenNode` all use it now (one source of truth).
2. **A click also ran the drag.** On the press frame the drag branch ran unconditionally, relocating the node to the cursor (`toCanvasMap` + `unmap`). A plain click therefore *fought* its own centring and pinned the node under the cursor — and map-space compression amplified the jump several-fold (measured: node world x 6000 -> 12129 on a click at zoom 0.149). The drag is now gated behind real cursor motion (`_dragMoved`, 4px threshold); a plain click leaves the node tracked, and only a genuine drag sets `manual` (pins it). Side effect: the click's `targetZoom` is no longer cancelled on the press frame, so click-to-zoom behaves as documented again.

Verified 59/59 node checks. New §10 regression drives the real `onInput` press-edge: with compression active, a click must (a) select the node, (b) not move it, (c) land it at the viewport centre; and a subsequent press+move must still relocate it. Confirmed to fail if either fix is reverted.

### 16.7 Zone drill: robust fit (2026-09-20) — "drilled into the rine field, didn't display properly"

Report: the sector view looked good after §16.6, but drilling into **Rine Field** did not — the field rendered as a thin smear with the nodes crammed into a small band.

Root cause (measured on seed 987654321, `System:spawnAsteroidField` clump step `(0.1*kSystemScale)*getExp()^getExp()`): the field is genuinely compact — 55/60 rocks within 20k of the zone centre, median 1,878 — but **one chained-clump rock sits 1,069,860 units out** (a $e^{e}$ tail step). The level fit took a plain min/max bbox over all members, so that single straggler stretched the span to ~1.25M and collapsed the real field into a ~30px pile (zone fit zoom **0.00128**). The sector view was unaffected because its fit already excludes planet-scale nodes.

Fix (`NodeGraph.lua`, sector-view fit preserved):
- **Robust fit**: collect the fit set (majors + player, or all minors at a zone level), compute the median position, then take the bbox over nodes within **1.5 x the p90 distance from the median**. Trimmed outliers still seed and draw, so they appear as clickable edge indicators. A small fit set (the sector view) has `p90 == its max`, so its fit is bit-for-bit unchanged.
- **Compression frame through the drill stack**: `drillInto` now saves the leaving level's `{refC, dRef, zFit}` and `drillOut` restores it verbatim, instead of recomputing `_zFit` from the restored camera zoom (so a sector you had zoomed past the §16.6 fade threshold stays uncompressed when you come back).

Measured: root fit unchanged (`zoom=0.003787`, `dRef=60667`, `0/94` off-screen); Rine Field fit `zoom 0.00128 -> 0.1527` (~120x), `5/60` off-screen (the far stragglers, as edge indicators). Verified 53/53 node checks (new §9 regression: 40 clustered nodes + one 1e6 outlier must not collapse the zoom), 136/0 shaders, clean boot.

Note: the ~1M outlier is a **generator** artifact, not a map bug (`spawnAsteroidField`'s chained step has an unbounded exponential tail, and `LTheory.lua`'s `spawnAsteroidField(60, 1000, fieldPos)` drops its third argument because the signature is `(count, oreCount)`). The map now displays whatever the generator produces; tightening the field itself is a separate gameplay-side decision (not made here, to avoid changing the scene under test).

### 16.6 Overview distance compression (2026-09-20) — "bring the nodes to the centre"

Context: the player's ship can be 200k+ units from the station (last dump: `YOU` at 227,635 vs the station at -2,219), so a strict 1:1 overview spans ~230k and reads as a sparse spread. Chosen approach (user picked compression over tighter-fit / outlier-culling): **compress distances radially at the overview, fade to true distance as you zoom in.**

Implementation in `NodeGraph.lua` — the projection is now two-stage: `world -> compressed map -> screen`.
- `mapOf(wx,wy)` compresses radius about the level centre `_refC` (`dRef * log(1 + d/dRef)`, `dRef = 0.5 x level radius`) blended toward identity by `t = clamp(zoom / (_zFit*12), 0, 1)`. At the fit `t ~= 0.083` (strong); by 12x the fit zoom `t = 1` (distances true). Direction is preserved (radial only).
- `unmap` is the numeric inverse (bisection on the monotonic curve) — used for drag placement.
- Pan/zoom stay **linear in map space** (`toScreenMap`/`toCanvasMap`), so all the existing pan / zoom-about-anchor / click-centre math is untouched. Only `mapOf`/`unmap` are non-linear.
- Node draw/hit/edges use `toScreenNode(n)` = `toScreenMap(mapOf(n) + jx/jy)` — declutter offsets are added in **map space**, so the fixed-pixel fan/ring is never squashed by the compression (that was the one real hazard).
- `declutter` now projects through `toScreen` (was raw `(x-pos)*zoom`), which is what keeps fans/rings aligned with the compressed view.

Measured at the fit: `t=0.083`, extreme nodes at ratio ~0.55-0.72 of their true radius (clustered centrally), fading to 1.00 by zoom ~0.045. Verified headless probe + 49/49 node checks + 136/0 + clean boot. Trade-off accepted: the scale bar is approximate while compressed (exact once zoomed in).

**Test note:** the compression surfaced a latent test/code hazard — a declutter table constructor `{ x = f(), y = g() }` was collapsed to a single-field assignment by an edit, leaving `y = nil` (caught by `validate_nodegraph.lua` before the boot). Fixed to `local tX,tY = f()`.

### 16.3 Doc cleanup — APPLIED 2026-09-20
- §7 inspector section rewritten to the as-shipped companion-inspector design (the `onNodeSelected` callback idea is marked superseded).
- §7 `node.pinned` row + §8 Phase 3 marked **future / not built** (the sector view is spatial; logical views need `GraphProvider.layout` / `GraphLayout.lua`).
- §8 Phase 4 drill-trigger line corrected (explicit click/double-click/Return; hysteresis constants removed).
- §8 Phase 4/5 and the ideas list: stale `onNodeSelected` mentions reconciled.

## 17. Representation glyphs (2026-09-20) — "the field shows a box"

Problem: selecting a non-body node (a named region such as **Rine Field**) drew the inspector's generic `boxWire` fallback, because `entityMesh` only finds geometry on entities that *are* a body. A region is a **representation** of something in the sector, so a box is meaningless.

Design — a small, extensible seam:
- `NodeGraphUtil.repKind(entity)` -> `'field', count` for an aggregate (named entity with >= 5 positioned, non-ship children and no mesh of its own), else `nil`. Ships are excluded (that's the ship-systems view); a real body with a mesh is excluded (it draws the mesh).
- `NodeGraphUtil.fieldSchematic(seed, count)` -> a flat segment list (same shape as the mesh-derived `_linesForNode` output) describing a deterministic cluster of small irregular vector rocks. Same shape as the wireframe path, so the inspector's existing pixel-mapping draws it unchanged.
- `NodeGraphInspector:show` classifies once per selection (`_repKind`/`_repCount`); `_linesForNode` returns the field schematic when there is no mesh and `repKind == 'field'`; the stat block adds `N asteroids` (a field has no `scale`, so the member count is the meaningful number).

Adding a new representation kind (e.g. a station-group, a convoy) = one branch in `repKind` + one glyph generator in `NodeGraphUtil`; no inspector or projection changes.

Verified in-engine: the `Rine Field` node reports `kind=field count=60` and yields an 83-segment rock cluster (was a box). 67/67 node checks (new §11: `repKind` thresholds + ships/real-bodies excluded + `fieldSchematic` determinism/scatter), 136/0 shaders, clean boot.

### 17.1 Range from YOU (2026-09-20)

The status block only showed absolute `pos`, which is unusable for navigation; nothing was measured relative to the player. Added `NodeGraphUtil.rangeBetween(a, b)` -> `(d3, plane, dy)` (true range incl. vertical / X-Z map separation / signed vertical), and the inspector now shows `dist <plane> u from you` for any selection that isn't the player, switching to `dist <plane> u (map)  rng <d3> u` when the vertical separation is material (>5%). The player's own node shows no range line. Verified in-engine: `Rine Field` -> `dist 213.8k u from you`; player -> nil. 70/70 node checks.

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

**TBD / may be a separate widget:** a *detached* inspector panel (docked, out-of-band detail). The shipped inspector is a companion object drawn inside `NodeGraph:onDraw` (§7).

**Reference only (unchanged):** `script/Game/SystemMap.lua`, all of `script/UI/*.lua` framework, entity/socket/economy components.

---

## Additional implementation ideas we may be missing

A few things worth considering beyond the plan, in no particular order:

1. **Start with the inventory/ship-systems tree as the MVP**, not a full sector overview. Straight solid + dotted edges (reference §12) work on small structured trees (Generator→Thruster→Turret sockets; Mine/Transport jobs) where every edge is meaningful. A dense sector overview gets LOD-filtered anyway and reads better as the existing straight `SystemMap`. This also keeps Phase 2's `isGraphWorthy` predicate simple from day one.

2. **Make NodeGraph context-aware from Day 1 (depth-1 stack).** Store `self.stack = {context=system}` and route seeding through the *current top of stack*, so a future push/pop is just swapping which system you seed — no rewrite of Create/onUpdate. Phase 4 then becomes "add push/pop + camera transition" rather than "refactor state."

3. **Straight + dotted per mode — confirmed by reference (§12).** Logical mode uses solid `DrawEx.Line` + dotted `DrawEx.Dash`; world-projection uses the same two styles. No curves anywhere — `wire.glsl` stays out of the tree.

4. **Inspector detail (shipped differently).** Built as `UI.NodeGraphInspector`, a companion drawn inside `NodeGraph:onDraw`, driven by selection — no callback wiring. See §7 / §8 Phase 5.

5. **Animate camera transitions per stack level** — store `{zoom,pos}` on each entry so `back` restores the prior view instead of snapping to default. Small thing that disproportionately affects how "polished" drill-down feels (per Claude's feedback); bake it into §7 push/pop now rather than Phase 4.

6. **Hover preview for edges before deciding interactivity.** Even if wires start decorative, showing a tooltip/flow-rate readout on hover gives value with minimal cost and informs the Phase 5 hit-testing decision early — decide then whether `rate` belongs in self.edges from Phase 2 onward (see §9).

7. **Lerp smoothing should cover node scale/color too** (health bars), not just position. Health-bar alpha/height updating frame-to-frame will otherwise flicker as the ship moves or takes damage; same `1 - exp(-k*dt)` trick, baked into onUpdate from Phase 2.

8. **World-projection can stay thin.** The reference sector map *is* straight lines over the live scene, so world-projection mode is just: project entity positions into the canvas + draw the same straight solid/dotted edges. No separate visual language to invent — the screenshots already specify it.

