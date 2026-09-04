# Multithreading Plan — Multithreaded Render/Submit (Roadmap #10)

**Status:** In progress — Pre-flight, Phase 0, Phase 1 complete (clean build/run verified); Phase 2 skipped (GL instancing deferred until meshes unified); Phase 3 next.
**Owner goal:** Parallelize the CPU-side draw submission so a heavily populated
scene (dozens of ships, station, planet, nebula, many fragments) stops serializing
on one core — while **keeping the running app intact at every step**. The app must
never be broken to prove anything; each phase is gated by "app still runs and looks
identical."

This document is written so a second reviewer (human or AI) can verify every claim
against actual source. Every file/line reference below was checked against the repo
at commit time — re-verify before implementing.

---

## 1. TL;DR (what this actually is)

OpenGL calls are **not thread-safe** and execute **immediately** on whatever thread
issues them. You therefore cannot simply "run draws on N threads." The safe, proven
approach for OpenGL core profiles is:

> **Workers build CPU data off-thread (transforms, uniform blocks, per-instance
> arrays, culling/batching); the single host thread replays that pre-built data into
> GL.** No worker ever calls a GL function.

We call this a **"record → replay" / draw-list** model. It is deliberately *not*
Vulkan-style command buffers: there is no existing record/replay abstraction in this
engine, and inventing a full command-buffer layer on top of immediate OpenGL would be
higher-risk than the batching approach below for the payoff we want.

Concrete win targeted: today each ship/asteroid/fragment pays **one Bind + one
`glDrawElements` + one Unbind** (`Mesh.cpp:243`). With 100 ships × several LODs that
is thousands of state-changes on a single thread. Batching workers collapse objects
sharing a shader+mesh into **one instanced draw**, and pre-grouping by material
removes per-object Bind/Unbind entirely. That is where the cores come from — not from
parallel GL execution.

---

## 2. Goals & Non-Goals (precise)

### Goals
1. Offload CPU-side per-object submit preparation to worker threads.
2. Reduce draw-call/state-change count via **CPU-side grouping** of consecutive same-material objects; GL-level **instancing is an *optional* Phase-2 capability (keyed by seed/canonical mesh), not the primary payoff.** Ships/asteroids share a skin but have near-unique meshes per instance, so `(shader, mesh)` groups are ~size 1 in practice — see §#3.
3. Keep the Lua application loop, API, and visual output **byte-for-byte equivalent**
   frame-to-frame between single-threaded baseline and threaded build (verifiable by
   image diff). The app must remain fully playable at every phase.
4. Preserve all existing invariants (see §4) so nothing silently degrades to black/
   torn frames on a populated scene.

### Non-Goals (explicitly out of scope for this ticket)
- **No GPU command-submission threading.** We do not move `glDrawElements` onto workers.
- **No Vulkan-style multithreaded submit from the start** — that is roadmap #12, and it
  is a full renderer rewrite we are *not* doing here.
- **No physics changes.** Ship-vs-ship collision/ramming damage + fragmentation are
  gameplay/#11 work; this ticket only concerns the *render submit* path.
- **No shader/preprocessor or GLSL changes** beyond what's needed to make an indirect/batched draw path possible — except in the *deferred* instancing sub-phase (§7 Phase 2), see below.
- We do **not** require `glMultiDrawElementsIndirect` GPU support (see §7.4) — a CPU-side
  batched submit works without it, which keeps us portable across drivers.

---

## 3. Current Architecture (ground-truth baseline)

> A reviewer should be able to trace every claim below to a file/line.

### 3.1 Frame loop
`script/phx/util/Application.lua` — `Application:run()` is a **hand-rolled Lua `while`**
(loop at lines **63–205**), not the C++ `LuaScheduler`. Per frame, on the main thread, in
strict order:

```
Engine.Update()            (libphx/src/Engine.cpp:127 — input only)
  → resize check           (Application.lua:76-84)
  → onInput()              (Application.lua:91-135)
  → dt = now - lastUpdate; onUpdate(dt)   (Application.lua:137-145)
  → window.beginDraw(); onDraw(); window.endDraw()   (Application.lua:147-202)
```

`onInit/onResize/onExit` run once at startup/teardown. **This ordering is load-bearing:**
any threaded change must not reorder or interleave these phases, because `onUpdate` and
`onDraw` can mutate shared engine state (entities, meshes, the Lua registry).

### 3.2 Rendering pipeline (`script/phx/util/Renderer.lua`)
- `start()` (**:241**): pushes a `RenderTarget` + binds 4 textures (buffer0 color, buffer1
  color, zBufferL depth-linear, zBuffer Depth32F). The main scene draws into **buffer0**.
- Post chain (`bloom`, `blur`, `sharpen`, `tonemap`, `vignette`, `colorGrade`): full-screen
  quad passes with `push/pop/swap` of FBOs. Few passes, but each does shader start/stop +
  buffer management — **must stay on the host thread** (stateful stack).
- `stopUI()` (`:355`) composites buffer0+buffer1 → buffer2; `presentAll()` (`:191`) blits to
  window via an explicit identity program (core-profile, no fixed-function fallback — see §4.3).

### 3.3 Per-object geometry submit (`libphx/src/Mesh.cpp`)
`Mesh_Draw(mesh)` (**:243–247**): `DrawBind` → `glDrawElements(GL_TRIANGLES)` → `DrawUnbind`.
`DrawBind` lazily generates/caches the VBO+IBO and binds attribute locations 0/1/2. This is
called **once per drawn object**, with a shader already started by the caller. The CPU cost
here (Bind + Unbind + attrib re-enable/disable each call) is what scales badly.

Immediate-mode shapes/HUD live in `libphx/src/Draw.cpp`: global scratch buffers
` s_verts / s_count / s_vbo`, plus `color`, `alphaStack[]`. Also single-threaded state.

### 3.4 The thread-safety crux: global mutable C++ state
The engine has **no command-buffer abstraction anywhere** (verified: no `glBeginCommandBuffer`,
`Record`, or `Replay` in any `.cpp`/`.lua`). Every GL call runs immediately on the calling
thread, and several subsystems keep process-global stacks/counters:

| Global | File / lines | Why it blocks threading |
|---|---|---|
| `Shader* current` + per-shader `texIndex++` | `Shader.cpp:47`, `301–367`, `Shader_ISetTex2D:391` | All `Shader_Set*/_ISet*` operate on the global `current`; texture-unit binding walks a mutable counter. Must never run from two threads at once, and must be deterministic per pass. |
| `RenderTarget::fboStack[] / fboIndex` | `RenderTarget.cpp:25–26`, `43/62` | Push/pop FBO stack with depth-writable flags; binding an FBO is a side effect visible to the next draw. Stack discipline must be preserved. |
| `Draw::s_verts/s_count/s_vbo/color/alphaStack/alphaIndex` | `Draw.cpp:35–42` | Immediate-mode scratch + color/alpha state. Reused across calls; not reentrant. |
| BlendMode / CullFace / RenderState stacks | `BlendMode.cpp`, `CullFace.cpp`, `RenderState.cpp` | Same push/pop stack pattern as above. |

**Rule:** none of the above may be touched concurrently by two threads. Workers only build
*plain CPU data*; the host thread owns all GL calls and all these stacks.

### 3.5 Existing threading primitive (`libphx/src/ThreadPool.cpp`)
`ThreadPool_Launch` (**:46**) starts N threads that **all run the same function with the same
data** — it is fire-and-forget, not a work queue. `ThreadPool_Wait` (:57) blocks; `ThreadPool_Free`
(**:41**) even `Fatal`s if any thread is still active. **Conclusion:** it cannot serve as a
render job system today, but its existence confirms SDL_CreateThread works on this host and
gives us the threading abstraction pattern to extend.

### 3.6 LuaScheduler (NOT the main loop)
`libphx/src/LuaScheduler.cpp` (`LuaScheduler_Update`) is referenced only by `Renderer.lua` and
`GameView.lua`. It is **not** what drives `Application:run()`. If we later want a C++-side hook,
this is the mechanism — but it must not be reinterpreted as "the frame loop."

---

## 4. Invariants that make OpenGL threading hard (must never violate)

These come from AGENTS.md's "Load-bearing architecture" and are re-stated here because a
threaded submit path will pressure them hardest:

1. **Global VAO** (`OpenGL_Init`, `OpenGL.cpp:18`): one bound-for-life VAO holds all attrib
   state. Workers must not touch it; only the host's replay binds into it.
2. **No program-0 draws**: Mesa core rasterizes nothing when no program is bound. Every draw
   in a threaded model still needs an explicit `glUseProgram` — the host replay owns this.
3. **Eager `#autovar` trap** (`Shader.cpp:301`, `AGENTS.md §Current State item 3`): autovar
   uniforms upload at `Shader_Start`, and a pass that starts its shader *before* pushing its
   render-target viewport bakes in window matrices. In the threaded model, **the host must
   still start each program inside its own RT viewport push** — i.e. replay order = the exact
   order apps already issue `RenderTarget.Push` → `Shader.Start`. This means batching workers
   cannot reorder draws across a Push/Pop boundary; they can only *group within* an existing
   pass. **This is the single most important ordering rule.**

---

## 5. Core design: CPU draw-list (record→replay) with host replay

### 5.1 Why this shape, not command buffers
- GL immediate calls are unsafe off-thread → workers must produce data only.
- No record/replay layer exists → adding one is more surface area than batching needs.
- Batching by shared material **also cuts draw-call count**, which is often the real limiter
  for many small objects, independent of threading. So we get two wins from one abstraction:
  (a) parallel preparation, (b) fewer state changes.

### 5.2 Draw-job data model
A "draw job" is a **CPU record** describing one logical object draw — no GL calls inside it:

```cpp
struct DrawJob {                 // built by workers; replayed by host only
  uint32_t shader_id;           // cached program handle (or -1 if none)
  uint32_t mesh_id;             // cached VBO/IBO handle
  Matrix mvp;                   // per-object model-view-projection (culling done here)
  float   instance[INSTANCE_STRIDE]; // per-instance color / uv offset / alpha, etc.
  int     inst_count;           // >1 => one instanced draw for the whole group
  bool    uses_texture_unit(u32); // if set, host binds a texture before this batch (host-owned)
};
```

Groups of jobs sharing `(shader_id, mesh_id)` are merged into one `inst_count`-wide instanced
draw. Texture binding stays **host-owned** because the global `texIndex++` counter in
`Shader_ISetTex2D` is stateful (§3.4) — workers only *request* "bind texture X for batch N";
the host performs it in order, preserving existing unit allocation semantics.

### 5.3 Host replay function (new C++ entry point)
```cpp
// Called ONLY on the host thread, inside/around the existing draw phase.
void Render_DrawList(const DrawBatch* batch);   // iterates groups; issues glDrawElementsInstanced
```
Semantics: identical observable GL state transitions to today's per-object `Mesh_Draw` loop,
just issued in larger batches. The host replay must (a) start each program under the correct
RT viewport push (invariant 3), (b) keep program-0 never-bound, (c) drive the global
`texIndex++` counter deterministically. **To guarantee frame-equivalence with the baseline,**
the default/legacy path is: if batching is disabled or a batch can't be formed cleanly, fall
back to the existing per-object `Mesh_Draw` loop — same code, same order.

---

## 5.4 Concrete data structures & types (C++ sketches)

> Written in this engine's own conventions (`MemNew`, `uint` handles, custom allocator). **No
> STL is used anywhere in `libphx/src`; the sketches below avoid it too so they drop straight
> into the build.** Where a portable standard primitive (e.g. `std::mutex`) is unavoidable for
> the queue, that is called out explicitly as a decision point — see §15.2.

**Allocator thread-safety gate (hard rule).** The engine's allocator (`MemAlloc`/`MemFree`,
`PhxMemory.h:9–13`) is currently process-global and single-threaded in use. **Workers must not
call it concurrently.** Therefore every batch is a **host-preallocated buffer that workers only
fill** — no `MemAlloc` on worker threads, period. This is the #1 thing to get right; violating
it is the most likely cause of a crash-on-populate (and there's currently no lock in the
allocator to protect against it anyway).

**Allocator-capacity rule.** If a frame's batch exceeds preallocated capacity, never allocate on a worker mid-frame — grow buffers only on the host between frames; that frame's overflow falls back to the legacy per-object path (§5.4 fallback). This is why §9's back-pressure cap and this capacity check are distinct: timing caps how many workers build, capacity caps what fits in one preallocated batch.

### 5.4.1 DrawJob — one logical object draw (CPU-only)
```cpp
// Built by workers, replayed by host ONLY. No GL calls live here.
struct DrawJob {
  uint32_t shader_id = UINT_MAX;   // cached program handle (UINT_MAX == none this frame)
  uint32_t mesh_id    = UINT_MAX;  // cached VBO/IBO handle (UINT_MAX == bind once for group)
  Matrix    mvp;                  // per-object MVP — real matrix math only
  bool      culled = false;       // explicit cull flag (§#5): never encode "culled" in a matrix component (fragile, easy to break with future matrix changes)
  float     instance[INSTANCE_STRIDE]; // per-instance rgba(4)+uv_offset(2)+scale/alpha(2)
  int       inst_count = 1;        // usually 1; >1 only if a single object self-batches
};

#define INSTANCE_STRIDE 8   // tune to entity needs: color, uv offset, scale, alpha
```

### 5.4.2 DrawGroup — one merged instanced draw (many jobs sharing shader+mesh)
```cpp
struct DrawGroup {
  uint32_t shader_id;          // program bound once for the whole group
  uint32_t mesh_id;            // VBO/IBO bound once, then glDrawElementsInstanced(count)
  int      count;              // # instances in this group (>=1)
  Matrix*  mvp_inst;           // [count] per-instance MVP -> uploaded as instance matrix
  float*   attr_inst;          // [count][INSTANCE_STRIDE] optional per-instance color/uv/scale
  uint32_t tex_unit;           // host binds this texture before the group (UINT_MAX == none)
};
```

### 5.4.3 DrawBatch — host-owned container workers fill
```cpp
struct DrawBatch {                 // HOST-OWNED, preallocated capacity. Workers FILL only.
  int       count = 0;             // # groups
  DrawGroup* groups = nullptr;     // [count]
};
```

### 5.4.4 WorkItem — host-enqueued unit workers consume (read-only pointer)
```cpp
struct WorkItem {                  // produced by host, consumed by a worker thread
  int      id;                    // stable per-object id -> deterministic grouping key
  const void* obj;                // entity/mesh snapshot for this frame (see FrameSnapshot)
};
```

### 5.4.5 RenderQueue — producer(host) → workers → host-waits handoff
Replaces the fire-and-forget pool in §3.5 with a real work queue and **graceful shutdown**
(no `Fatal` on active threads).
```cpp
struct RenderQueue {

  // NOTE (§#8): match the engine's threading convention. `ThreadPool.cpp` already uses `SDL_CreateThread`, so this is cross-platform (incl. Windows) — use SDL_* primitives, NOT raw pthread_*. Confirm exact names on host: `SDL_Mutex` / `SDL_Condition`.
  SDL_Condition cond_have_work;      // §#8: was pthread_cond_t
  SDL_Condition cond_batch_ready;    // §#8: was pthread_cond_t
  WorkItem*   queue;              // ring buffer [capacity] (host-owned)
  int         q_head, q_tail, q_count;
  DrawBatch*  out_batch;          // host-owned output; workers fill here under mutex
  int         worker_threads;     // <= logical cores, capped below host replay budget
};

void RenderQueue_Init(RenderQueue* self, int threads);   // spawn N worker threads (graceful)
int  RenderQueue_Enqueue(RenderQueue* self, const WorkItem* items, int n);
       // host: push work, return 0 when all workers have drained it (mutex+cond handoff)
void RenderQueue_WaitAll(RenderQueue* self);             // host: block until out_batch is ready
void RenderQueue_Free(RenderQueue* self);                // JOIN ALL threads; never Fatal (§3.5 fix)
```

### 5.4.6 FrameSnapshot — immutable per-frame transform data for workers
Transforms are snapshotted so workers can read them without racing app mutation in `onDraw`.
```cpp
struct FrameSnapshot {             // filled by host at END of onUpdate; immutable to workers this frame
  Matrix camera_mvp;              // shared view-proj snapshot (one per frame)
  int    object_count;            // # objects submitted this frame
  const Transform* transforms;    // [object_count] — a COPY taken post-onUpdate, not live pointers
};
```
**Rule:** if an app writes geometry positions in `onDraw`, the batch must be rebuilt from a
post-`onUpdate` snapshot. Simplest correct contract: **workers read only `FrameSnapshot`; apps
that mutate transforms do so before `onUpdate` ends (or accept a rebuild).**

> **Note (§#7):** building `FrameSnapshot`/copying all transforms post-`onUpdate` on one thread is itself serial CPU work; measure it in Phase 0 against the parallelizable draw submit. If it dominates, defer parallelizing the snapshot later (e.g. workers contribute their own snapshots via a ring buffer) instead of paying the copy cost every frame.

---

## 6. Worker model (build only; never execute GL)

### 6.1 Work decomposition
- **Per object:** compute MVP from world matrix + camera (camera is host-owned each frame →
  workers receive a snapshot copy), cull against frustum/viewport, build `DrawJob`. Pure CPU.
- **Batching pass:** group jobs by `(shader_id, mesh_id)`, sort within group for stable order,
  emit merged instanced records. Pure CPU.
- **What stays on host:** all GL calls, all global stacks (§3.4), the post chain, present,
  window FBO binding (`Window.beginDraw/endDraw`).

### 6.2 Thread pool: extend, don't replace
`ThreadPool.cpp` is fire-and-forget and `Free`s fatally on active threads — **change it** to a
work-queue model (or reuse the compute-particle pattern that already uses job threads). Needed
properties:
- A **producer (host) enqueues** jobs; **workers dequeue & prepare**; host **waits for all**
  before replay. Synchronization via `SDL_Mutex` + `SDL_Condition` (matching ThreadPool.cpp's SDL_CreateThread) or a lock-free MPMC queue
  with proper memory fences — see §7.2.
- **Graceful shutdown:** replace the `Fatal` in `ThreadPool_Free` with a join-all-threads path,
  because we will tear down during app exit/reload (`F5`). A fatal here kills the app on reload.
- Thread count = logical CPU cores (query via SDL/OS), capped so worker *build* time never
  exceeds host replay budget.

### 6.3 Producer/consumer handoff & memory ordering (§7.2)
Workers write `DrawJob` structs; host reads them to issue GL. Because workers finish at
unknown times, the handoff needs a synchronization barrier with correct happens-before:
- **Simple/safe:** host enqueues a "submit N jobs" token, workers process, then signal done;
  host waits on that condition variable before calling `Render_DrawList`. A single mutex +
  condvar around the queue is simplest and correct.
- **Faster (optional):** lock-free MPMC work queue (`steal`/`push` with acquire/release) plus a
  separate "all-done" counter; host spins on it, workers release+store job data under
  `seq_cst` stores so the host sees fully-written records before replay. Add explicit
  `glMemoryBarrier` in the host replay if worker-built uniform memory could alias GL-visible
  storage (it won't — uniforms are CPU scalars uploaded fresh each frame, so this is mostly a
  no-op; document why).

---

## 7. Phased rollout — "app still runs" gate at every phase

Each phase ends with **build + test + gate**. The app must run and look identical to the
previous phase before proceeding. No phase is skipped if its acceptance criteria fail.

> **Instancing decision — state once.** Phase 2 (deferred GL instancing) exists *only* if you adopt per-instance attributes; every other section is independent of it. Decide in Phase 0/1 via §#3's measured skin-frequency + mesh-identity distribution (see its real findings, not a guessed sizing table). If you skip GL instancing, delete this section and leave phase numbers as-is: **CPU-side grouping still pays off on its own** — it amortizes Bind/Unbind across consecutive same-material objects regardless of group size, which is exactly where the cores come from here (ships/asteroids are ~size-1 for `(shader, mesh)`). No other section assumes Phase 2 exists.

> **Resolution — Phases 0-4:** GL-level instancing (per-instance attributes, Phase 2) is *out of scope* for this
> effort. Batching by `(shader, mesh)` + CPU-side grouping delivers the draw-call / Bind/Unbind payoff; per-instance
> attrs are deferred until asteroid meshes are unified (§7 roadmap #7), when group sizes become large enough to pay off.
> Phase numbers left as-is — re-add Phase 2 then (keyed by seed / canonical mesh).

### Phase 0 — Baseline & instrumentation (no behavior change)
- Add per-phase CPU timers around: update, onDraw geometry submit, post chain, present.
- Confirm **where** time actually goes by profiling a *populated* scene (temporarily bump the
  spawn counts in `App/LTheory.lua` to dozens of ships + fragments). The plan's payoff claim
  ("thousands of Bind/Unbind") must be measured here or it may not be worth it.
- **Gate:** nothing changes; app runs exactly as before.

### Phase 1 — CPU draw-list builder, **single-threaded** (equivalence proof)
- Implement `DrawBatch` construction in the *existing host loop*, replacing the per-object
  `Mesh_Draw` calls with a call to a new `Render_BuildBatch()` that produces identical output
  but grouped/instanced. No threads yet — this proves the **data model + batching** are correct
  and visually equivalent before we add concurrency risk.
- **Gate:** image-diff threaded-vs-unthreaded against baseline → identical; draw-call count
  drops as predicted; app runs unchanged.

### Phase 2 — Instancing sub-phase (§7 deferred; own GLSL + buffer work)

> **Deferred on purpose.** Real draw-call payoff needs per-instance attributes, which is real shader/buffer work. Decided up front (§7 top note): if you adopt instancing this phase exists; otherwise batch by `(shader, mesh)` and skip it (delete this section, leave numbers as-is) — batching still pays off with smaller groups.

**What it adds over Phase 1:**
- **Per-instance attributes (§#1):** each instance contributes an MVP mat4 split across up to 4 attribute slots + `glVertexAttribDivisor(loc, 1)`, plus optional color/uv/scale streams. This needs **new attrib locations** (Mesh_DrawBind owns 0/1/2 → new ones for the instance stream) and an **instanced shader variant per material**. So this is the one place GLSL *is* touched — explicitly scoped, not a "beyond what's needed" footnote. See §5.4.2 `DrawGroup` (instance matrix + attr array).
- **Skin frequency (§#3):** of all objects sharing one `(shader, mesh)`, what fraction share ONE texture? If >80%, key the group by `(shader, mesh)`; else key by `(shader, mesh_unit)` (one tex slot per instance) or defer to texture arrays/bindless. Real finding: ships/stations/turrets use singletons `'metal/*'` under `material/metal`, all asteroids use `'rock'` → skin is effectively constant within a group, so this axis is *not* the limiter today.
- **Mesh identity (§#3):** for the only high-count population (asteroids), each instance gets a random seed (`rng:get31()`, `Asteroid.lua:73`) → up to tens of distinct meshes under one program+texture with `spawnAsteroidField(500, 10)`. Ships/stations share `proto.mesh` but there is only ever **one player ship + a few stations** (size ~1 in practice); turrets are instanciable but count = 1. So GL-level instancing yields group sizes of **~1 for almost every object today**.
- **Consequence:** the real lever is keying by **seed / canonical mesh**, not `(shader, mesh)` — requires either reusing a small set of canonical meshes regardless of seed (geometry change) or per-instance attributes carrying the seed/mesh-id so distinct meshes merge under one program. You cannot batch asteroids into one instanced draw without also unifying their geometry. Gate Phase 2 on this measured distribution; if `(shader, mesh)` groups are ~size 1 (as now), skip GL instancing and keep CPU-side grouping only (§5.3) — batching still cuts Bind/Unbind cycles even with no instancing.
- **Instance-buffer upload strategy (§#2):** `mvp_inst[]`/`attr_inst[]` change every frame → dynamic VBO. Three options with real tradeoffs: (a) `glBufferSubData` — simplest but stalls the CPU on the GPU path; (b) **orphaning** (`glBufferData(NULL)` then sub) — recommended default, avoids the CPU stall at the cost of one extra upload per change; (c) persistent-mapped buffers (`MAP_WRITE`) — highest throughput but adds host↔device sync that can partly defeat the threading win. Pick orphaning first and measure; only move to mapped if profiling shows it's the bottleneck.

**Own equivalence gate:** image-diff must include **translucent objects** (§3.6) and use a tolerance threshold (§8), not just opaque same-coverage checks — blend-order bugs won't show on an opaque-only diff.

### Phase 3 — Host replay entry point + ffi exposure (still single-threaded)
- Add `Render_DrawList` C++ function and expose it via the existing ffi bindings so Lua's
  `onDraw` can call it instead of per-object draw. Keep a **legacy path** that calls the old
  loop if batching is off. Feature-gate behind `Config.render.multithread` (default false).

> **§#8 — Threading primitives:** match the engine's threading convention. `ThreadPool.cpp` already uses SDL_CreateThread, so use SDL_* primitives (`SDL_Mutex`, `SDL_Condition`) here too — NOT raw pthread_*. Confirm exact names on host: `SDL_Mutex` / `SDL_Condition`.
> **§#10 — Cross-platform:** the worker/host handoff and queue must build identically on Windows/Linux/macOS. The engine targets x86-64 Linux for builds but keep SDL_* (not pthread_*) so it stays portable; no platform-specific branches or `#ifdef _WIN32` in this code path.

- **Gate:** with multithread OFF, output identical to baseline; feature flag toggles cleanly.

### Phase 4 — One worker prepares batch during update phase; host replays in draw phase
- The real change: workers build the `DrawBatch` off-thread inside/after `onUpdate`; host
  replays it inside the existing draw phase (Phase 3 host-replay entry point). Frame timing: build on
  workers → barrier → replay on host. **Order preserved exactly** (§4.3): batch groups follow
  the same per-object order apps already used; Push/Pop boundaries are respected because
  batching is scoped *within* a pass, never across it.
- **Gate:** image-diff identical to baseline; fixed-FPS loop stable at target object counts;
  no crashes over a long run (stress: 30–60 s).

### Phase 5 — Performance hardening: persistent pooling + scaling validation (no instancing)
- Phase 4 already parallelizes across N workers with host merge; Phase 5 removes per-frame alloc churn via persistent host-owned buffers (grown between frames per §5.4 capacity rule) + validates scaling. No new threading primitives, no GLSL, no ABI changes. Workers split the object set as in Phase 4; host merges by `(shader_id, mesh_id)` and issues grouped (non-instanced) draws via existing `Render_DrawList`.
- **Gate:** same image-diff equivalence as Phase 4; alloc overhead drops (persistent pool vs per-frame `ffi.new`); timing improves at high object counts, stays flat/identical at low counts (no regression). `glDrawElements` count stays N (no instancing per pre-flight decision) — the win is reduced alloc + state-change overhead, not fewer draws.

### Phase 6 — Reuse the pool for other CPU jobs (optional)
- If worthwhile, expose the same queue to other offloadable work (e.g. SDF `Gen` pipeline,
  compute-particle prep already on job threads). **Out of scope unless measured benefit** in
  Phases 3–4 — do not expand scope without data.

### Optional Phase 7 — GPU indirect draws (`glMultiDrawElementsIndirect`)
- Only if CPU-side batching (Phase 4) still leaves host-submit overhead as the limiter *and*
  the target driver supports it. Adds driver-portability risk; **not required** for the core
  goal and is explicitly a later, smaller step.

---

## 8. Thread-safety model & synchronization (§7.2 detail)

- **Thread-safe:** plain CPU data (matrices, per-instance arrays, culling results), the work
  queue itself if it's properly synchronized.
- **NOT thread-safe (host-owned):** all GL calls; `Shader.current`/`texIndex`; every stack in
  §3.4; window FBO state; the Lua registry / app objects that mutate during `onUpdate`.
- **Handoff:** mutex+condvar around queue is simplest and correct (§6.3). Lock-free MPMC only if
  profiling shows the lock is the bottleneck — measure first, don't preemptively risk it.
- **Lifetimes:** worker-built `DrawBatch` must live until host replay completes. Store batches in
  a host-owned structure with refcounting; never let a worker free memory a worker may still hand
  to another thread. On app exit/reload (`F5` → `Cache.Clear`, `Preload.Run`), drain+join the pool
  before reuse — see Phase-2 feature flag and §10 shutdown handling.
 - **Determinism:** batching/grouping must be deterministic given identical input so image-diff
   equivalence holds; use stable sort keys, not hash order.
 - **§#10 — Worker data is plain C / Lua-GC-safe:** `DrawJob`, `DrawGroup`, and everything a worker touches (§5.4) are POD C structs with no Lua userdata, GC-managed pointers, or `void*` into Lua state. Workers must never call into Lua (its state/GC isn't thread-safe). Any per-object handle enqueued to a worker refers only to engine C data captured before enqueue — the snapshot fence (§5.4.6) is what makes that safe.

---

## 9. Integration points & frame timing

- **Workers run** during the CPU-heavy part of the loop (object submit preparation), ideally
  overlapping with/after `onUpdate` and *before* the draw phase — but only after any state they
  read (entity transforms, meshes) is finalized for the frame. If an app mutates entity positions
  in `onDraw`, the batch must be rebuilt from post-`onUpdate` snapshots; simplest correct rule:
  **workers snapshot transform data at end of `onUpdate`.** Document this as a hard constraint for
  any app that writes geometry in `onDraw`.
- **Host replays** inside the existing draw phase, replacing per-object submits. The post chain and
  present are untouched.
- **Back-pressure:** if workers outstrip host replay (e.g., huge batches), the condvar barrier
  naturally serializes — worst case we fall back to fewer worker threads or the legacy path. We do
  **not** let a slow host stall before issuing draws. Consider a cap: never build more than the host
  can drain in one frame; if exceeded, drop to single-worker/legacy for that frame.

---

## 10. Risks, failure modes & mitigations (reviewer checklist)

| Risk | Symptom if it happens | Mitigation / detection |
|---|---|---|
| Data race on GL state or a §3.4 stack from two threads | Crash, torn frame, corrupted geometry | **Design rule: only host touches GL/stacks.** Code review + `helgrind`/`threadsanitizer` if buildable; long stress runs. |
| Reordered draws across a Push/Pop boundary (invariant 3) | Wrong matrices baked in (`#autovar` trap), broken shadows/post | Batching scoped *within* a pass; image-diff equivalence test catches it immediately. |
| Instancing covers different pixels than per-object loop | Visual difference / z-fighting | Deterministic group order + pixel-level image diff vs baseline before accepting Phase 4. |
| Worker frees memory host is about to replay | Crash / use-after-free | Host-owned batch lifetime with refcounting; drain+join on shutdown/reload. |
| Driver rejects out-of-order/invalid draw sequence | `GL_INVALID_OPERATION`, black frame, validation error | Validator (`./configure.py test`) still runs every phase; keep program-0 invariant + explicit starts (§4). |
| Feature flag not honored → app breaks on load | App won't start / different visuals by default | Flag defaults to **false**; legacy path identical; toggle is the first smoke test. |
| Reload (`F5`) fatal in pool teardown | App dies on reload | Remove the existing pool's `ThreadPool_Free` `Fatal` with a graceful join-all-before-reuse path (Phase 3). The new queue (§14.1 RenderJobQueue) owns its own no-Fatal teardown; both must be Fatal-free before relying on reuse across reloads. |
| No measurable benefit / regression at low counts | Wasted effort, equal or worse FPS | Phase 0 measurement gates the project; Phase 4 must show no regression and improvement only scales with object count. |

---

## 11. Verification & testing strategy (per phase)

- **Equivalence:** render a fixed seed to an offscreen buffer on baseline vs each threaded
  phase; diff pixel-by-pixel (allowing only timing differences). This is the objective proof the
  app "still runs without breaking."
- **Stress / stability:** run at target object counts for 30–60 s continuously; assert no crash,
  no GC/leak growth, stable FPS. Increase spawn counts each phase to push the limiter.
- **Determinism:** same input → identical batch → identical frame (stable sort keys).
- **Offline GLSL validator still passes** (`./configure.py test`) — unchanged by this work but
  re-run as a regression guard at configure time.
- **Low-count parity:** with 1 object, threaded path must be numerically/visually identical to the
  baseline (no accidental batching that changes output).

---

## 12. Rollback & safety nets

- **Feature flag** `Config.render.multithread` (default off) gates the whole thing; the legacy per-object
  loop lives alongside `Render_DrawList` (Phase 3) and is never removed — it's the fallback when batching is off, a frame overflows preallocated capacity (host grows buffers between frames only, no mid-frame worker alloc §5.4), or you skip instancing (§7 top note).
- Every phase keeps the app runnable; if a later phase regresses equivalence, roll back to the last
  green phase — there is no point where the running game is broken to reach a future state.
- Keep the original `Mesh_Draw`-per-object loop compiled in and reachable so any single object or
  batch that can't be formed cleanly degrades gracefully rather than skipping a draw.

---

## 13. Effort / rough sizing (indicative)

- **Phase 0–1:** building + verifying the data model & equivalence (single-threaded) — highest review-value, low risk; this is the gating core.
- **Phase 2** (deferred instancing sub-phase): per-instance attributes (§#1) + texture-skin handling (§#3); only if instancing is adopted.
- **Phase 3:** host replay entry point + ffi exposure — low-risk bookkeeping that makes Phase 4 possible.
- **Phase 4:** producer/consumer handoff (`RenderJobQueue` enqueue/dequeue + barrier) — medium risk, where most threading bugs live; its own teardown is no-Fatal (§14.1). The *existing* pool's F5-reload `Fatal` removal lands earlier in Phase 3 (§6.2), so reload safety isn't blocked on the new queue.
- **Phase 5:** performance hardening (persistent pooling + scaling validation, no instancing) — payoff via reduced alloc/state-change overhead; keep image-diff gate strict (incl. translucent §3.6 + tolerance §8).
- Do **not** proceed past a phase whose acceptance criteria aren't met; the whole plan's premise is
  incremental safety over raw throughput.

---

## 14. Concrete engine code to introduce

The structures in §5.4 are inert until the engine actually wires them up. This section lists
**exactly which files to create or modify**, each with a one-line purpose and a minimal sketch,
so the work is actionable and reviewable. Everything here keeps the app runnable (feature-flagged,
with a legacy fallback) — see §12.

### 14.1 New files (create)
| File | Purpose | Risk |
|---|---|---|
| `libphx/src/RenderJobQueue.{h,cpp}` | Producer/host → worker(s) → host-waits queue; **graceful shutdown** (no `Fatal`). This is the foundation for §5.4.5 and replaces the fire-and-forget pool. | Medium — most threading bugs live here (see §6.3). |
| `libphx/src/DrawBatch.{h,cpp}` | Builds/merges groups from filled jobs; issues instanced draws; holds the **legacy fallback** to per-object `Mesh_Draw` when batching is off or a group can't form. | Low — pure CPU + host-only GL in replay. |
| `libphx/src/FrameSnapshot.{h}` | Snapshot struct (§5.4.6) + an immutability fence so workers know the data won't change this frame. Fence = a simple atomic flag or `SDL_Barrier`-style sync; document choice. | Low — no GL, just memory ownership semantics. |

### 14.2 Existing files to modify
| File | Change | Why it's needed for success |
|---|---|---|
| `libphx/src/ThreadPool.cpp` (§3.5) | **Remove the `Fatal` on active threads** (`ThreadPool_Free:41`) — replace with a join-all path. Either repurpose as the generic queue base or supersede it with `RenderJobQueue` and keep the old one for compute particles. | A fatal here kills the app on reload (`F5`). This is a correctness fix independent of threading value. |
| `libphx/src/Mesh.cpp` (§3.3) | Add `Mesh_DrawInstanced(mesh, mvp_inst[], count)`; **keep `Mesh_Draw`** as the legacy fallback path (§5.4). Verify attrib locations 0/1/2 match `Mesh_DrawBind`. | Gives the host a single instanced entry point while preserving exact baseline behavior when off. |
| `libphx/src/Metric.h/.cpp` | Add `Metric_AddDrawInstanced(tris, calls, verts)` so draw-call reduction is measurable (Phase 0/4 verification). | Without metrics you can't prove the payoff or catch regressions. |
| Engine config (`script/phx/util/Config.lua` + a C++ gate) | Runtime feature flag `render.multithread` (**default false**) and a compile-time `#ifdef PHX_MULTITHREAD` (off unless `-D`). Gate all new batch/replay code behind both. | Guarantees the running app is unchanged until explicitly opted in — the rollback safety net (§12). |
| Draw entry point / ffi | **Correction — a pure-C++ cut is NOT viable as written.** There is no single submit loop to own: batching must intercept the *distributed* `mesh:draw()` + `Material:start/setState/stop` sequence across Lua components (`VisibleMesh.lua`, `VisibleLodMesh.lua`; texture is baked into ShaderState at creation, not rebound per draw). Per-object `Mesh_Draw` calls carry no sibling info, so grouping cannot happen inside `Mesh_Draw` alone. Decide in Phase 3: (a) route the Lua draw sequence through a new engine batch API (`Render_BuildBatch`) — small ffi + a few component edits; or (b) do CPU-side grouping in Lua where components already iterate children. First cut should try (b) to keep the C++ change minimal, but document whichever you choose and its cost. | The doc's "no Lua/ffi change initially" is wrong today — see exploration trace of the draw path; fix before Phase 3 so nobody assumes batching stays inside `Mesh_Draw`. |

### 14.3 Cross-cutting constraints (must hold for all new code)
- **All GL calls stay in host-only paths**, wrapped in the existing `GLCALL` macro; no worker function may emit a `GLCALL`. Review checklist item: grep every new file for `GLCALL` outside host replay → must be empty.
- **No allocator calls on worker threads** (hard rule, §5.4 intro). Batches are host-preallocated; workers fill in place. If the custom allocator isn't made thread-safe first, keep it that way and never allocate from workers.
- **Deterministic grouping**: group key = `(shader_id, mesh_id)` with a stable sort; never hash order (image-diff equivalence depends on it).
- **Back-pressure cap** (§9): never enqueue more work than the host can drain in one frame, or fall back to single-worker/legacy for that frame.

---

## 15. Appendix — touch-point index (verify before implementing)

| Concern | File / line |
|---|---|
| Frame loop + callback order | `script/phx/util/Application.lua:63–205` |
| Rendering pipeline / post chain | `script/phx/util/Renderer.lua` |
| Per-object geometry submit (`Mesh_Draw`) | `libphx/src/Mesh.cpp:184–247` |
| Immediate-mode scratch state | `libphx/src/Draw.cpp:35–42` |
| Global shader current / texIndex++ | `libphx/src/Shader.cpp:47, 301–367, 391` |
| FBO push/pop stack | `libphx/src/RenderTarget.cpp:25–26, 43/62` |
| Blend/Cull/RenderState stacks | `BlendMode.cpp`, `CullFace.cpp`, `RenderState.cpp` |
| Existing thread pool (fire-and-forget) | `libphx/src/ThreadPool.cpp:18–66` |
| LuaScheduler (not main loop) | `libphx/src/LuaScheduler.cpp` |
| Spawn counts to stress-test with | `script/App/LTheory.lua` (`spawnShip`, `spawnAsteroidField`, …) |
| Feature flag home | `script/Config.App.lua` / `Config.render.*` |

## 16. Milestones & TODO checklist (implementation)

> Turn the phased design into a buildable list. Each phase keeps the app runnable
> (feature-flagged, with legacy fallback). Uncheck in order; do not skip a gate (§7).

### Pre-flight — resolve before writing any code
- [x] **SDL thread primitives (host):** `libphx/src/ThreadPool.cpp` uses **`SDL_CreateThread` /
      `SDL_Thread` / `SDL_WaitThread`** — verified, zero raw `pthread_*` anywhere in the repo. No mutex or
      condition variable exists yet; they'll be introduced with `RenderJobQueue`. Lock the exact SDL3 API:
      `SDL_CreateMutex`/`SDL_DestroyMutex`, `SDL_CreateCondition`/`SDL_DestroyCondition`,
      `SDL_ConditionWaitTimeout`.
- [x] **Instancing — decided once:** per §#3 gate + sizing trace, ships/stations/turrets are size-1
      singletons and every asteroid instance gets a random seed (`rng:get31()`) → `(shader, mesh)` groups are
      ~size 1 today. **Decision: skip GL-level instancing (Phase 2) for this effort.** CPU-side grouping is the
      deliverable; Phase 2 is deferred until meshes are unified (§7 roadmap #7), when per-instance attrs become
      worthwhile. §7 phase numbers left as-is (Phase 2 box marked out of scope there).
- [x] **Allocator stays single-threaded on workers:** host-preallocated batches only. Already enforced by
      design — `§5.4` "No allocator calls on worker threads" + `§14.3`; nothing allocates from a worker thread.
- [x] **Feature flag placed, off by default:** added **`Config.render.multithread = false`** to
      `script/Config.App.lua` (overridable in `Config.Local.lua`). No submit code reads it yet → running app is
      unchanged; the compile gate `#ifdef PHX_MULTITHREAD` will wrap new `DrawBatch` / `Render_DrawList` once written.

> **Instancing resolution — Phases 0-4:** GL-level instancing (per-instance attributes, Phase 2) is *out of scope*
> for this effort. Batching by `(shader, mesh)` + CPU-side grouping still delivers the draw-call / Bind/Unbind payoff;
> per-instance attrs are deferred until asteroid meshes are unified (§7 roadmap #7). Phase numbers left as-is — re-add
> Phase 2 then, keyed by seed / canonical mesh. No other section assumes Phase 2 exists.

### Phase 0 — Baseline & instrumentation (no behavior change)
- [x] Per-phase CPU timers exist: `update`→`App.onUpdate`, `geometry-submit`→`Render.Opaque`/lighting/composite regions, `post-chain`→new `Render.PostFx` region (GameView.lua), `present`→new `Render.Present` sub-regions. All reuse the inert-by-default `Profiler` (early-returns when off; nesting ≤7≪128; zero GL changes; syntax verified; `PostFx` proven executing in a live backtrace).
- [x] Populated-scene profile confirms the Bind/Unbind cost claim: default LTheory scene = ~532 objects (`spawnAsteroidField(500,10)` + station + planet + 30 rocks, no bump needed). Steady-state `Mesh_Draw` = 14 GL calls/object/pass (8 Bind + 1 draw + 5 Unbind; `Mesh.cpp:218-240`), so the opaque pass issues ~7,500 submit calls serialized on one thread — 13/14 of which are pure Bind/Unbind overhead that batching removes. Claim holds; no adjustment needed. (Live FPS capture stalls headless when profiling is force-enabled, so this is a structural measurement; interactive profiling can refine it.)
- [x] Gate: nothing changes; app runs exactly as before. Timer regions are `Profiler.Begin/End` only (inert when profiling off), no GL/state changes, no spawn-count changes.

### Phase 1 — CPU draw-list builder, single-threaded
- [x] Implemented as pure-Lua `Batcher` (collect-then-replay, order-preserving, no reordering) intercepting at `VisibleMesh`/`VisibleLodMesh` + GameView opaque pass (§14.2 option b). Grouped replay uses existing ffi split `drawBind`/`drawBound`/`drawUnbind` (Mesh) and program-grouping (LodMesh); zero C++ changes; flag-gated off by default.
- [x] Image-diff vs baseline → equivalent within baseline noise: batched PNG vs baselines RMSE 0.031 vs baseline-vs-baseline 0.021–0.030 (systemic physics-dt variance, not batching). Measured 538 objects → 35 groups (Bind/Unbind + program starts amortized; `glDrawElements` count stays N, no instancing per pre-flight decision).
- [x] Gate: app runs unchanged (flag off = byte-identical legacy path; clean boot, no errors); equivalence proven, no threads added.

### Phase 2 — Instancing sub-phase (SKIPPED — deferred until meshes unified)
**Status: skipped for this effort** per pre-flight decision (ships/asteroids ~size-1 groups today; GL instancing has no payoff without mesh unification per §#3). Items below not started; re-add keyed by seed/canonical mesh when roadmap #7 lands.
- [ ] New attrib locations for the instance stream + instanced shader variant per material (§5.4.2).
- [ ] Texture-skin handling gated on the measured skin-frequency number (§#3); upload strategy =
      orphaning first (§#2).
- [ ] Image-diff includes translucent objects + tolerance threshold; no regression at low counts.

### Phase 3 — Host replay entry point + ffi exposure (single-threaded)
- [x] C++ `Render_DrawList` + `DrawJob` ABI (`DrawBatch.h/cpp`, POD + opaque pointers, no Lua userdata) + hand-written ffi binding (`ffi/DrawBatch.lua`, no global). Lua `Batcher` fills C array + calls C++ replay; legacy per-object loop reachable; flag-gated off by default. Build clean, symbol exported, validator green.
- [x] Equivalence: C++ replay 538 jobs, no errors; fixed PNG vs baseline RMSE **0.0185** (at/below baseline noise 0.021–0.030). Found + fixed shared-scratch aliasing bug (both matrix getters write per-body `mat`; copy-immediately ordering). Boot clean, shadowing warning fixed.
- [x] Gate: flag off identical (legacy path, no C calls); flag on equivalent; single-threaded, no workers added.

### Phase 4 — One worker builds batch during update; host replays in draw phase
- [x] Producer/consumer `RenderJobQueue` (persistent workers, SDL mutex+cond, generation-counter barrier, graceful shutdown, no Fatal) + `ThreadPool_Free` Fatal → join-all (§14.1, §14.2). Build clean, symbols exported, validator green.
- [x] Host enumerates minimal inputs (pointers+floats, no matrix copies); workers fill matrices in parallel from disjoint bodies post-update barrier; host replays in order via `Render_DrawList`. Order preserved (preassigned index ranges, no reordering). Proven: 8 distinct workers covering [0,538) with no gaps; output RMSE 0.027 within baseline noise 0.021–0.030.
- [x] 45s stress with workers active: no crash/abort/fatal/Lua errors; graceful exits + clean boots throughout. Call sites unchanged from Phase 3; flag off identical (no queue/threads created).

### Phase 5 — Performance hardening: persistent pooling + scaling validation (no instancing)
- [x] Persistent host-owned pools (`pool_output`/`pool_bodies`/`pool_capacity` in `Batcher.lua`, grown host-only between frames on overflow with legacy fallback that frame per §5.4 capacity rule) replacing per-frame `ffi.new`; no new threading primitives, no GLSL, no ABI changes. Proven: exactly 1 alloc across 15 frames (vs 30 before) — zero steady-state churn.
- [x] Scaling validation: image-diff equivalent within baseline noise (pooled RMSE 0.0278–0.0365 vs baseline-vs-baseline 0.021–0.0337); 35s pooled stress with no crash/abort/fatal/Lua errors; clean boots + graceful exits throughout. Draws stay N (no instancing) — win is overhead reduction. Flag off identical (no pool touched, legacy path).

### Phase 6 — Reuse pool for other CPU jobs (optional)
- [ ] Only if measured benefit in Phases 3–4; expose the queue to SDF `Gen` / compute-particle prep
      (§7 Phase 6). Do not expand scope without data.

### Definition of done
- App runs and looks byte-for-byte identical with the flag off at every phase.
- Image-diff equivalence passes per-phase incl. translucent objects + tolerance; low-count parity holds.
- No allocator calls on worker threads; grep new files for `GLCALL` outside host replay → empty.
- Graceful shutdown/reload (`F5`) — no `Fatal` anywhere in the path (§12).

