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