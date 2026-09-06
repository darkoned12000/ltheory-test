# Debug Panel Update

Status: **Investigation complete — recovery implemented on this branch.**

This doc records how the debug panel works today (the "old way"), what I found
when trying to bring it back, the concrete fix plan, and design notes for the
easily-extensible upgrade (F-key toggle, perf graphs, AI hook-ins).

---

## Objective

Re-activate the in-game debug panel on a graphics surface that has moved on
(forced debug run proved the window renders), remove the obtuse old way it was
called, and rebuild it as an easy-to-extend panel keyed off a single toggle.

---

## 1. Empirical findings (verified 2026-09-05, real GPU)

- Forcing `Config.ui.defaultControl = "Debug"` + running `./run.sh LTheory`
  produced **zero Lua errors** over a 25 s run. The panel constructs, updates,
  and draws without throwing — **it is not broken, only unreachable through the
  normal flow.**
- Instrumented `DebugWindow:onDraw` with `getRectGlobal`:
  `DBGWIN (8,8) 297x779`, near-steady `(8,8) 299x775`. So the window is a
  **narrow (~300 px), full-height column anchored to the top-left** — exactly
  the left-side panel you remembered.
- Note: `Draw.Rect(self:getRectGlobal())` draws in a *different* coordinate
  space than `getRectGlobal` returns (probe produced a spurious wider bbox).
  The true layout rect is the (8,8) 300px column.

### Why it "vanished"
The backtick toggle only exists **inside** the `DebugControl:onInput`, which
only runs while the `Debug` control set is *already the active* PlayerControl.
Default active control is `Ship` (`Config.ui.defaultControl = 'Ship'`). So to
show the debug window you had to: open the Control Selector (some other binding)
→ switch to the Debug control → *then* backtick toggles the window. Two or
three hidden hops, dependent on the icon-driven top bar → effectively gone.

---

## 2. How it works today (the old wiring)

```
LTheory:onInit                     script/App/LTheory.lua:130
  DebugControl.ltheory = self      (:134)
  GameView(player)
    MasterControl(gameView, player)   added as Canvas child
GameView also mounts MasterControl via Controls.MasterControl(...)
```

**MasterControl** (`script/Game/Controls/MasterControl.lua`)
- Owns ordered `ControlSets` (Undocked / Docked). The Undocked set lists
  `Ship`, `Command`, `Debug` control definitions.
- Builds an icon-button dock ("Control Selector") top bar; cycling the
  `activeControlDef` via icon buttons (or `Bindings.Controls[i]`).
- `activateControl(def)` does `def.panel:enable()/disable()`. Running set is
  chosen top-down by predicate in `onUpdate`.

**DebugControl** (`script/Game/Controls/DebugControl.lua`)
- `DebugControl.Create(gameView, player)` builds a `debugWindow =
  GUI.DebugWindow(DebugControl.ltheory)` and adds it as a child at
  `self:add(self.debugWindow:setStretch(0,1), Config.debug.window)`.
- `onInput` reads `Bindings.InspectWidget` (F1 → widget inspector) and
  `Bindings.ToggleDebugWindow` (backtick → `self.debugWindow:toggleEnabled()`).
- This is the **only** link between a key and the debug window, and it only
  fires when the Debug control is active.

**DebugBindings** (`script/Game/Controls/DebugBindings.lua`)
- `ToggleDebugWindow = Button.Keyboard.Backtick`
- `InspectWidget = F1`, `RegenerateSystem = R`.

**DebugWindow** (`script/Game/GUI/DebugWindow.lua`)
- `DebugWindow.Create(ltheory)` → a draftable off `UI.Window('Debug')`, contents =
  Profiling text + Profiling Graphs + Audio + UI sections + Settings sections.
- `onDraw` measures `self.drawTime` via `Timer`.
- Collapsible sections driven by `Config.debug.windowSection`.
- Static placeholder `DebugWindow.SetValue(section, name, value)` for runtime
  value push (single global `instance`).

**Config** (`script/Config.App.lua`)
- `Config.debug = { metrics=true, window=true, windowSection=nil, timeAccelFactor=10, damageLog=false, ... }`
- `Config.ui.defaultControl = 'Ship'` decides the default active control set.

**MasterControl construction** — control panels are added to MasterControl in
`Create`; the debug window is a *child of DebugControl*, so it only mounts when
the Debug panel is enabled. Config default `window=true` is the *panel-factory
argument*, but the panel is still inert unless the Debug control is active.

---

## 3. The problem (cleanup targets)

1. **Reachability**: Debug window hidden behind nested control-set switching +
   a backtick that only works when the Debug control is already active.
2. **Unknown/legacy toggles**: backtick is undiscoverable; F10 is already
   `ProfilerToggle` per ApplicationBindings (claimed free earlier is wrong —
   F9 is genuinely free).
3. **Look & feel** is dated / untuned vs the GL4.6 core pipeline and is the
   manual-tuning blocker for the add-hdr graphics pass (AGENTS.md #1 +
   tech-debt bullet).
4. **No hands-free entry point** for AI/tooling to read panel output
   (perf graphs / values) — needed for troubleshooting sessions.

---

## 4. Fix plan — make it operational again

1. **Single, global, reachable toggle**
   - Move the debug-window toggle OUT of `DebugControl:onInput` and INTO a
     places that's always live.
   - Bind **F9** (verified free: F5 Reload, F10 ProfilerToggle, F11 Fullscreen,
     F12 Screenshot, Tab Wireframe, H TimeAccel).
   - Add the F9 binding at a top level (GameView or the Canvas / a dedicated
     always-on Input handler) so it toggles the debug window regardless of which
     control set is active.
2. **Remove the backtick** binding and its dead path in `DebugBindings`.
3. **Register the debug window independently of the Debug control set** so it
   can mount even when the active control is `Ship`. Options:
   - a) Add the debug window to the shared canvas/gameview directly (not under
     DebugControl), keyed by a boolean.
   - b) Keep DebugControl as the container but add a MasterControl-level toggle
     that enables DebugControl when F9 is pressed (heavier, drags orbit/icon
     machinery).
   - Preferred: (a) — decouple the window lifecycle from the control dock.
4. **Decide default state**: keep `Config.debug.window` behavior but let F9
   create/toggle at runtime. Leave the panel off by default so normal gameplay
   is uncluttered; F9 brings it up instantly.

### Implemented (this branch)

- **F9** now toggles the debug window globally from `GameView:onUpdate`
  (next to the M-music toggle). Works from any PlayerControl (Ship/Debug/Dock).
- **Backtick removed** from `DebugBindings`; the `ToggleDebugWindow` handler and
  the window lifecycle are gone from `DebugControl`.
- **Window mounted on GameView** in `LTheory:onInit` (after `self.canvas`
  exists — `DebugWindow:createUISection` reads `ltheory.canvas`), added via
  `gameView:add(self.debugWindow:setStretch(0,1), Config.debug.window)`.
- **Off by default**: `Config.debug.window = false` (Config.App.lua +
  Config.Local.lua) so the app never launches with the panel showing.
- **Seamless reticle↔panel interaction**:
  - `DebugWindow:onEnable/onDisable` set `Input.SetMouseVisible(true/false)`.
  - `HUD:drawReticle` keeps the OS cursor visible (and skips the game reticle)
    when the cursor is over the open panel.
  - `HUD:onInput` suppresses ship-turret aim/fire while the cursor is over the
    open panel, so left-click drives the panel widgets instead of the guns.
  - Canvas mouse-focus already scans GameView children top-down, so the panel
    (added last) captures focus when hovered.

---

## 5. Upgrade design (extendable, part of the same pass)

- **Perf graphs framework**: `UI.Graph` already has `Mode.Sweep/Scroll` + rulers
  (used for Frame Time + Lua Mem). Add an easy "register a metric" helper so new
  graphs/values are 2–3 lines (label + poll fn + optional ruler + min/max).
- **CPU / mem / FPS**: surfaced today as text labels (Frame Time, Frame Time
  EMA1, FPS, Lua Memory, Allocation Rate, GC Passes, GC Frequency) plus the 2
  graphs. Expose raw profiler regions (`Submit/Opaque/PostFx/Present/BatchBuild`
  per AGENTS.md perf notes) as a third graph group; keep the existing ones.
- **AI hook-states**: add a lightweight protocol to read current panel state,
  so a tool/agent can pull values without a screen reader — i.e.
  `DebugPanel.dump()` returning name→value, logged/assertable. This pairs with
  the DebugWindow refactor and the F-key toggle for scripted sessions.
- **Look & feel**: modernized panel styling aligned with the GL4.6 core render
  (measured: grey panels, collapsible sections, scroll-view) — do visual tuning
  as the add-hdr graphics sign-off proceeds.

---

## 6. Files touched (recovery implementation — this branch)

- `script/App/LTheory.lua` — creates the debug window after the canvas exists
  and mounts it on GameView (`self.gameView.debugWindow = ...`).
- `script/Game/Controls/DebugBindings.lua` — removed the Backtick binding.
- `script/Game/Controls/DebugControl.lua` — removed the ToggleDebugWindow input
  and the owned debug-window lifecycle; keeps InspectWidget (F1) +
  RegenerateSystem (R) + widget inspector.
- `script/Game/GUI/GameView.lua` — F9 toggle in `onUpdate`; `debugWindow` field.
- `script/Game/GUI/DebugWindow.lua` — `onEnable`/`onDisable` cursor control.
- `script/Game/Controls/HUD.lua` — curser-visible + reticle skip over the panel;
  turret aim/fire suppressed while the cursor is over the open panel.
- `script/Config.App.lua` / `Config.Local.lua` — `Config.debug.window = false`
  (off at launch; F9 enables).

---

## 7. Working tree hygiene during this work

Temp changes used for the empirical test were reverted and the tree is clean:
- `script/App/LTheory.lua` forced-seed `self.seed = 7035...` — reverted.
- `script/phx/util/Application.lua` `autoShot` patch — reverted.
- `script/Config.Local.lua` `defaultControl="Debug"` + `autoShot=15` — reverted.

Commit the doc now; apply the code fix as the next change.

---

# SESSION 2 (2026-09-05, later): root cause found — core-profile immediate-mode gap

**Status: F9 wiring verified correct; panel draw path verified reaching the screen;
REAL root cause of "no UI anywhere" identified and fix designed. Work in progress
on the engine-level fix; this section is the handoff record.**

## S2.1 — What was verified empirically (frame-dump runs, real GPU)

Method: `PHX_DEBUG_DUMP=<frame> ./run.sh LTheory` with `Config.debug.window = true`
(temp) + temp dump hooks in `GameView:draw` saving the UI layer (buffer1) and the
composite output (buffer0) right after `Renderer:stopUI()`.

- **The UI composite chain WORKS.** `dump_5_composite.png` (buffer0 post-stopUI)
  contains world + DebugWindow panel bg + the magenta test-tri. The panel reaches
  the presented frame when enabled. The last AI's uncommitted `Renderer:stopUI`
  rewrite (identity vertex shader + clip-space rect) is **NOT needed** — the
  committed `'ui'` composite is functionally correct (buffer2:push() pushes fresh
  viewport matrices via RenderTarget_PushTex2D → Viewport_Push). **Revert those
  uncommitted Renderer.lua/GameView.lua experiments.**
- **`Tex2D_Save` dump artifacts (important for future dump readers):**
  `glGetTexImage(GL_TEXTURE_2D, 0, ...)` always reads **mip 0** and returns rows
  bottom-up, so every dump PNG is a **vertically flipped view** and, under
  supersampling (ss=2 default from `Config.gpu.superSample='2x'`), post-chain
  state lives in **mip 1** — `dump_3_final` was md5-identical to the UI layer
  purely because Save read stale mip0 bytes. Do not trust final-frame dumps'
  orientation or mip content.
- Panel appears at **top-left in real screen space** (flipped dump shows it
  bottom-left). Geometry/layout is correct.
- **The panel renders as an EMPTY grey rectangle: all text is missing.** The
  magenta solid tri (DrawEx.Tri) and solid panel bg (DrawEx.Panel) draw; nothing
  texture- or text-based does.

## S2.2 — Root cause (structural, verified in code)

The GL 4.6 core migration removed fixed-function, but the **legacy immediate-mode
draw paths were never given a program**. In core profile, `glUseProgram(0)` →
Mesa rasterizes **nothing, silently** (AGENTS.md trap #2). Specifically:

1. **ALL TEXT IS INVISIBLE.** `Widget:drawText/drawTextRect/drawTextRectCentered`
   (script/UI/Widget.lua:280-299) → `font:draw` → `Font_Draw` (libphx/src/Font.cpp:142)
   → `Tex2D_DrawEx` → `Imm_Draw` → `Draw_Flush` → `glDrawArrays` under **whatever
   program happens to be bound** — usually none (Shader_Stop → glUseProgram(0)).
   Pre-migration this worked because no-program = fixed-function pipeline, which
   rendered the textured glyph quads. Also `Draw.Color`'s static (Draw.cpp:42,256)
   is **written but never consumed** in core (no autovar feeds it to shaders), so
   even under a bound program the color would be stale. Same bug affects every
   direct `font:draw` site: Button.lua:27, Slider.lua:84, OptionSlider.lua:82,
   Graph.lua:185/200/207, Hidden.lua:97, Application.lua:177-193 (metrics +
   shader-failure overlays — themselves invisible!), BSPTest.lua (test app).
   `DrawEx.drawText`/`TextAdditive` (DrawEx.lua:252-266) already do it right
   (start `ui/text`, set `color` uniform, `font:drawShaded`) — HUD's text worked;
   widget text did not.
2. **~28 raw `Draw.Rect/Tri/Line/Border` sites in script/UI are silent** (Button
   bg, Checkbox, Slider bar/thumb, OptionSlider arrows, Collapsible header/arrow,
   Hidden header, ScrollView scrollbars, Graph border/bars/lines, Grid/Canvas/
   Widget debug rects, Stretch fill, Application metrics bar bg). All drive color
   via `Config.ui.color.X:set()` / `applyColor` → dead `Draw.Color` static, no
   program. (Full inventory greppable: `rg -n "Draw\.(Rect|Tri|Line|Border)\(" script/UI`.)
3. **`GLMatrix` is a dead CPU-side stub** (libphx/src/GLMatrix.cpp:17-19: "Nothing
   in the renderer consumes these matrices anymore"). Graph's plot transform
   (GLMatrix.Translate/Scale Y-flip) is dead → even with a program, Graph plots
   draw untransformed. Graph needs a Lua-side coordinate transform fix.
4. **UIRenderer.cpp:150** also calls `Font_Draw` under its own pipeline (HmGui/
   ImGui test-app renderers) — same gap, minor (test apps only).

**Wayland is ruled out as the cause.** The engine is native Wayland via SDL3
(run.sh:20-22); configure.py's validators are display-agnostic (headless EGL);
the old backtick toggle was the fragile part (hidden control-set + layout-dependent
key), already replaced by F9 (commit a42d3e7). User's F9 report ("nothing shows")
is consistent with: (a) the panel enabling but rendering as an easy-to-miss empty
grey rect, and/or (b) the toggle not firing — needs one live-input verification
with temp logging.

## S2.3 — Fix design (chosen): engine-level default program in Draw_Flush

Restore the pre-migration semantics with ONE engine change instead of ~28
hand-threaded Lua edits:

- Track the active program in Shader.cpp (`Shader_Start`/`Shader_Stop`), expose
  `Shader_GetActive()`.
- In `Draw_Flush` (Draw.cpp): if **no program is active**, start a lazily-loaded
  default program — reuse **`vertex/ui.glsl`** (attribs 0/2 + autovar matrices ✓)
  and **`fragment/ui/text.glsl`** as a generic flat/textured shader
  (`outColor = color * texture(glyph, uv)`; flat rects with a white 1x1 dummy
  texture bound → pure color; glyph quads bind the glyph texture to unit 0 → text).
  Set the `color` uniform from the `Draw_Color` static **× alpha-stack top**
  (restores `Draw.PushAlpha` fade semantics for raw primitives too).
  If a program IS active, draw under it untouched (current behavior preserved:
  composite/post-chain `Draw.Rect` calls keep working as today).
- Mark textured immediate draws (`Tex2D_Draw`/`Tex2D_DrawEx` in Tex2D.cpp) so
  flush knows to keep the unit-0 binding instead of the white dummy.
- Result with ZERO Lua changes: all text renders, buttons/checkboxes/sliders/
  collapsibles/scrollbars get their color-state primitives back, Application
  overlays render.
- Remaining Lua work: **Graph plot transform** (GLMatrix dead — compute the
  translate/Y-flip in Lua coords), optionally rerouting debug-only rects.
- Then: rebuild libphx (`cmake --build build`), re-run dumps to verify text in
  panel, temp-log F9 (`printf` in GameView:onUpdate F9 branch) and have the user
  press F9 live to confirm the toggle fires over Wayland; remove temp bits;
  `./configure.py test`.

## S2.4 — Temp state currently in the tree (clean up before commit)

- `script/Config.Local.lua` — `Config.debug.window = true` (TEMP diagnostic).
- `script/Game/GUI/GameView.lua` — TEMP `__dumpUI` hook (4_uilayer/5_composite
  dumps) + the previous AI's uncommitted `stopUI`-before-Viewport.Pop move (revert).
- `script/phx/util/Renderer.lua` — previous AI's uncommitted identity-composite
  experiment (revert — composite verified fine as committed).
- `script/Game/GUI/DebugWindow.lua` — TEMP magenta tri marker in `onDraw` (remove
  after visual verification).
- Dump PNGs `dump_*.png` in repo root (diagnostic artifacts, delete).
## S2.5 — OUTCOME (implemented + verified in frame dumps, 2026-09-05)

All S2.3 fixes are implemented and verified via PHX_DEBUG_DUMP frame captures.
Temp state is fully cleaned; the tree contains only the intended changes.

**Engine (libphx):**
- `libphx/src/Draw.cpp` — `Draw_Flush` now starts a default program when none
  is bound: lazily loads `vertex/ui` + `fragment/ui/flat` (new file
  `res/shader/fragment/ui/flat.glsl` = `color * tex(unit 0)`), sets
  `color = rgb, a * alphaStackTop` (replicates old `glColor4f(r,g,b,a*alpha)`),
  binds a 1x1 white dummy texture for unmarked draws; textured draws
  (`Tex2D_Draw/DrawEx/Tex1D_Draw`) keep their unit-0 binding. Draws under an
  explicitly-started program are untouched. Skips silently if the flat program
  fails to load or no viewport matrices are pushed (old behavior was silent
  nothing, so no regression).
- `libphx/src/Shader.cpp` + `include/Shader.h` — `Shader_GetActive()` returns
  the tracked current program (null when none).
- `libphx/src/DrawInternal.h` — `Draw_SetTexturedImm(bool)`; set in
  `Tex2D_Draw`/`Tex2D_DrawEx`/`Tex1D_Draw` before `Imm_Draw`.
- `Shader.h` notes: `Shader_Load("vertex/ui", "fragment/ui/flat")` is the C++
  call; validator now passes 122/122 shaders; `cmake --build build` clean.

**Lua:**
- `script/UI/Graph.lua` — plot transform reimplemented in Lua (GLMatrix is a
  dead stub): `baseY = y + sy - padMaxY`, `fy = dydv * (v - vMin)`, draws via
  `DrawEx.Rect/Line` (border → `DrawEx.RectOutline`). Scissor clipping is
  BYPASSED (`ClipRect.PushDisabled`): the engine clip transform stack does not
  line up with the space widgets draw in under the core profile — everything
  inside Graph's `PushCombined` was culled (content renders unclipped in the
  correct places; ScrollView's clip "works" only because its rect is large).
  Geometry is instead clamped to `[0, usableSY]` in Lua (bars/lines/head/
  rulers), which is exact for auto-ranged graphs and edge-clamps fixed-range
  ones. The clip-transform mismatch is a TODO for the engine (affects any
  widget that relies on `ClipRect.PushCombined` for tight clips).
- `script/UI/Graph.lua` requires `UI.DrawEx` locally (sandbox: bare `DrawEx`
  is an undefined global at load; bare `Color` is fine).

**Verified (frame dumps, buffer1 UI layer + buffer0 composite):**
- Launch-enabled panel: full text, sliders, checkboxes, option sliders,
  collapsible sections, scrollbars, Application metrics bar, F9 title.
- Runtime toggle (auto-toggle at frame 40, dump at 120, window=false at
  launch): panel fades in and renders identically → F9 path proven end-to-end.
- Graphs: bars, sweep line, ruler crossings + labels, head highlight, min/max
  labels all render with live data (frame-time + Lua-memory graphs).
- The vertical "faint vs solid" split seen mid-investigation was the window
  panel background gradient, not a double draw.

**Not done / next:**
- Live user verification of F9 on screen (dumps prove the framebuffer content).
- Engine TODO: fix `ClipRect_PushTransform` coordinate-space mismatch (or
  re-space widget clip coords) and restore `ClipRect.PushCombined` in Graph.
- DebugWindow `onLayoutSize` (`desiredSX *= enabledT`) is safe as-is
  (`Container:layoutSize` rebuilds desiredSX from children every layout).
- Note: laser/bolt visuals are governed by `effect/pulsehead|pulsetail` +
  HDR AgX tonemap (branch add-hdr); the debug-panel work does not touch them.
