# LTheory UI/GUI Systems — a REFERENCE, not a plan

> **STATUS: OPEN DESIGN NOTE (2026-10-22).** This is the map of the UI stack
> and the guide to which system to use — not a record of finished work, and
> not a task list. The work it describes is **ROADMAP item 8 (game screens)**,
> which is still open: there is no main menu, no settings screen, no radar or
> inventory in the game yet, only the debug panel.
>
> **The example app in this document now exists and runs:**
> `script/App/UI_Demo.lua` (`./run.sh UI_Demo`) — a radar, a reticle with
> target brackets, ship status, an inventory and a sector map, built from the
> framework's own widgets. It is the corrected, working version of the sketch
> that used to live in §3, and it is what §3 and §4 now point at.
>
> **What was wrong with the old version of this document** (it is worth
> knowing, because every one of these is a trap the framework actually has):
>
> | it said | the truth |
> |---|---|
> | "the game app does not use any of these GUI systems" | the game **is** a `script/UI` app: `GameView` extends `UI.Container`, and the HUD, the sector readout, the market panel and the map are all framework widgets |
> | `UI.Container.Create()` | **`Container` has no `Create`** — `Container.__call` forwards to `t.Create`, so a plain container cannot be made that way. Use `UI.Panel('')` |
> | `UI.Column()` | there is no `Column` widget. To stack things vertically, use a **Grid with one column** |
> | `UI.Slider(0, 5)` | the signature is `Slider.Create(getFn, setFn, minValue, maxValue)` — the first argument is the *getter* |
> | `UI.Window(…):setTitle(…)` | there is no `setTitle`; `Window` has a `.title` field |
> | `UI.Slider .setFormatter(fmt)` | no such method; `Label` has `setFormat` |
> | `Draw.Circle`, `Draw.CircleOutline` | the engine's `Draw` API is **Line/Rect/Tri only**. The circle helpers are `UI.DrawEx.Ring`, `.Point`, `.Wedge`, `.Cross` |
> | `RenderState.PopAllDefaults()` | no such call |
> | `self:super.onDraw(…)` | `super` is not a pattern here; call the parent's method explicitly: `UI.Window.onDraw(self, focus, active)` |
> | `state.dt` inside `onDraw(focus, active)` | `onDraw` gets no state — `dt` arrives in `onUpdate(state)` |
> | `canvas:input(state)` / `canvas:update({dt = dt})` | `Canvas:input()` takes no arguments and `Canvas:update(dt)` takes a number |
> | the OptionSlider is given a string | it works in **INDICES**: `elems[value]`. A string there is a type error in `onUpdate` — the same trap `Settings.addEnum` fell into |
>
> Sections below are corrected where they were wrong, and left alone where
> they were right.

## Executive Summary

The LTheory engine provides **three distinct GUI/UI systems**:

1. **HmGui** — C++ retained-mode GUI (engine core) used by `TestHmGui.lua`
2. **ImGui** — Homegrown immediate-mode GUI (engine core) used by `TestImGui.lua` and `RenderTest.lua`
3. **script/UI/** — Lua-based retained-mode widget framework (the primary game UI system, used by `DebugWindow.lua`)

The main LTheory game app **does** use the third one. `GameView` extends
`UI.Container`, and the HUD, the sector/region readout, the market panel at
the dock and the sector map are all framework widgets (see
`script/Game/GUI/GameView.lua`, `script/Game/Controls/HUD.lua`,
`script/Game/Controls/DockControl.lua`, `script/UI/SectorPanel.lua`). The
Debug window (F9) is a `UI.Window`. The first two systems are test-only.

---

## 1. HmGui (Hybrid Mode GUI)

### Location
- C++ source: `libphx/src/HmGui.cpp` + `libphx/src/HmGuiInternal.h`
- Lua bindings: `libphx/script/ffi/HmGui.lua`
- Demo app: `script/App/TestHmGui.lua`
- Shader: `res/shader/vertex/ui.glsl`

### Architecture Overview
```
┌─────────────────────────────────────────┐
│  HmGui (C++ retained-mode engine)       │
│  - Deferred layout pass                 │
│  - Widget tree with focus system        │
│  - Clip rects for input clipping        │
│  - Scrollable containers                │
└──────────────┬──────────────────────────┘
               │ FFI bindings (libphx)
┌──────────────▼──────────────────────────┐
│  TestHmGui.lua                           │
│  - Uses HmGui.BeginWindow(), .Text()    │
│  - Layout groups, checkboxes, buttons   │
│  - Scrollable code display               │
└──────────────┬──────────────────────────┘
               │ UIRenderer C++ renderer
┌──────────────▼──────────────────────────┐
│  UIRenderer (C++)                        │
│  - Panel, Rect, Text, Image              │
│  - Layered rendering                     │
│  - Draws into the global VAO pipeline    │
└─────────────────────────────────────────┘
```

### Key HmGui Concepts

#### Widget Types (enum in `HmGui.cpp`)
| Type | Purpose |
|------|---------|
| `Widget_Group` | Layout container (stack, vertical, horizontal) |
| `Widget_Text` | Text rendering with custom font/color |
| `Widget_Rect` | Colored rectangles / buttons |
| `Widget_Image` | Texture sprites |

#### Style System
Colors and fonts are set via a style stack:
```cpp
HmGui_PushStyle();
self.style->font = Font_Load("Rajdhani", 14);
self.style->colorPrimary   = Vec4f_Create(0.1, 0.5, 1.0, 1.0); // blue accent
self.style->colorFrame     = Vec4f_Create(0.1, 0.1, 0.1, 0.5); // dim frame
self.style->colorText      = Vec4f_Create(1, 1, 1, 1);        // white text
```

#### Focus System (3 types)
- `FocusType_Mouse` — mouse hover/activation
- `FocusType_Scroll` — scroll bar handle
- `FocusType_SIZE` — size-grip resize corner

### HmGui API Reference

| Function | Description |
|----------|-------------|
| `HmGui_Begin(sx, sy)` | Begin a new frame (resets state) |
| `HmGui_End()` | End frame: layout + compute focus |
| `HmGui_Draw()` | Render all accumulated widgets |
| `HmGui_BeginGroupX()` / `BeginGroupY()` / `BeginGroupStack()` | Create a group (horizontal / vertical / stack) — there is **no** `BeginGroup(layout)` |
| `HmGui_EndGroup()` | Close the current group |
| `HmGui_Button(label)` | Create a button, returns true if clicked |
| `HmGui_Checkbox(label, value)` | Toggle checkbox |
| `HmGui_Slider(lower, upper, value)` | Slider (currently unused in test) |
| `HmGui_SetStretch(x, y)` | Stretch factor for the next children — a plain call, **not** a method on the widget |
| `HmGui_SetAlign(x, y)` | Alignment for the next children |
| `HmGui_SetPadding(l, r, t, b)` | Padding for the next children |
| `HmGui_PushFont(font)` / `PushTextColor(r,g,b,a)` / `PopStyle(depth)` | Style stack management |
| `HmGui_Image(tex2d*)` | Add a texture image |

### Layout System
- **Layout_None**: Fixed position (absolute)
- **Layout_Stack**: Children share same x,y, sizes are max of children
- **Layout_Vertical**: Children stack vertically with spacing; horizontal stretch applies
- **Layout_Horizontal**: Children stack horizontally with spacing; vertical stretch applies

```lua
HmGui.BeginGroupY()               -- there is no BeginGroup(layout)
  HmGui.SetPadding(8, 4)          -- left/right, top/bottom
  HmGui.Text("Hello")
  HmGui.Button("Click me")
  HmGui.SetStretch(1, 0)          -- stretch the NEXT children, horizontally only
HmGui.EndGroup()
```

### Demo App: `TestHmGui.lua` — Full-featured reference
This is the most complete working example. Key patterns from it:

**Tabbed interface:**
```lua
HmGui.BeginWindow('HmGui Test')
  Hmgui.BeginGroupX()
    HmGui.Button("Tab1") HmGui.SetStretch(0, 1)
    HmGui.Button("Tab2") HmGui.SetStretch(0, 1)
    HmGui.EndGroup()

  -- Tab content (shown in TestHmGui:showSimple())
  HmGui.BeginGroupY()
    for i = 1, 3 do
      HmGui.Button(format("Opt %d", i))
    end
  HmGui.EndGroup()
HmGui.EndWindow()
```

**Scrollable content:**
```lua
HmGui.BeginScroll(200)  -- max scroll size
  for _, line in ipairs(lines) do
    HmGui.Text(line)
  end
HmGui.EndScroll()
```

### Enabling HmGui in a new app

```lua
local Test = Application()

function Test:onInit()
  self.bg = Tex2D.Load('./screenshot/wp2.png') -- optional background
end

function Test:onUpdate(dt)
  -- Clear any previous frame (HmGui resets on Begin)
  HmGui.Begin(self.resX, self.resY)
  
    HmGui.BeginWindow("My Window")
      HmGui.Text("Hello World!")
      if HmGui.Button("Click Me") then
        print("Clicked!")
      end
    HmGui.EndWindow()
  HmGui.End()
end

function Test:onDraw()
  -- Must call UIRenderer via UIRenderer.Draw or through a Renderer instance
  local renderer = Renderer()
  renderer:start(self.resX, self.resY)
  Viewport.Push(0, 0, self.resX, self.resY, true)
  HmGui.Draw()        -- calls UIRenderer.Begin → Draw → End internally
  Viewport.Pop()
  renderer:stop()
  renderer:present(self.resX, self.resY)
end

return Test
```

---

## 2. ImGui (Immediate Mode GUI)

> **This is NOT dear imgui.** `libphx/src/ImGui.cpp` is the engine's own
> ~40-function homegrown immediate-mode mini-GUI — a cursor stack, buttons,
> windows, a style stack. It shares a name with the popular library and
> nothing else. Swapping in dear imgui was assessed and is **not worth it**
> (see §6): the shipped game UI belongs on `script/UI/`, and this one is
> test-only.

### Location
- C++ source: `libphx/src/ImGui.cpp` + `libphx/include/ImGui.h`
- Lua bindings: `libphx/script/ffi/ImGui.lua`
- Demo apps: `script/App/TestImGui.lua`, `script/App/RenderTest.lua`

### Architecture Overview
```
┌─────────────────────────────────────────┐
│  ImGui (C++ immediate-mode engine)      │
│  - Single-pass per-frame                │
│  - No retained state                    │
│  - Cursor-based positioning             │
│  - Widget pool allocator                │
└──────────────┬──────────────────────────┘
               │ FFI bindings (libphx)
┌──────────────▼──────────────────────────┐
│  TestImGui.lua                           │
│  - ImGui.Begin(), ImGui.Text()          │
│  - Drag-and-drop windows                │
│  - Scrollable panels                    │
└─────────────────────────────────────────┘
```

### Key ImGui Concepts

#### Immediate Mode vs Retained Mode
- **Retained (HmGui / script/UI)**: You define the entire UI tree once per frame; layout is computed in a deferred pass before drawing.
- **Immediate (ImGui)**: Widgets are created and destroyed each frame via function calls. No retained state exists between frames.

```lua
-- Immediate mode (ImGui) — everything recreated every frame
function Test:onUpdate(dt)
  ImGui.Begin(self.resX, self.resY)    -- begin frame
    ImGui.Text("This text is redrawn every frame")
    if ImGui.Button("Click Me") then print("Clicked!") end
  ImGui.End()                          -- commit draw
end
```

#### Widget Pool System (C++)
ImGui uses memory pools (`MemPool`) for zero-allocation widget storage:
- `widgetPool` — stores all active widgets
- `layoutPool` — stores layout information per group/panel
- `stylePool` — style stacks
- `cursorPool` — cursor stack for indentation

### ImGui API Reference

| Function | Description |
|----------|-------------|
| `ImGui.Begin(sx, sy)` | Begin a frame |
| `ImGui.End()` | End the frame (commits draw) |
| `ImGui_BeginWindow(title, sx, sy)` | Create a window with title |
| `ImGui_EndWindow()` | Close the current window |
| `ImGui.Text(label)` / `.TextColored(r,g,b,a,label)` | Text output |
| `ImGui.ButtonEx(label, width, height)` | Button, returns true if clicked |
| `ImGui.Checkbox(value)` | Toggle checkbox — returns the NEW value |
| `ImGui.Selectable(label)` | Selectable item (like radio button) — returns true when clicked |
| `ImGui.BeginGroupX(sy)` / `BeginGroupY(sx)` | Begin horizontal/vertical group |
| `ImGui.EndGroup()` | Close current group |
| `ImGui.BeginPanel(sx, sy)` | Panel with beveled border (alternative to window) |
| `ImGui.EndPanel()` | End panel |
| `ImGui.BeginScrollFrame(maxY, scrollOffset)` | Scrollable region |
| `ImGui.EndScrollFrame()` | Close scroll frame |
| `ImGui.Indent()` / `ImGui.Undent()` | Indent text cursor (nested layout) |
| `ImGui.Divider()` | Horizontal/vertical divider line |
| `ImGui_SetCursor(x, y)` | Set absolute cursor position |
| `ImGui.PushStyleFont(font)` | Push a custom font |
| `ImGui.PopStyle(depth)` | Pop N styles from the stack |
| `ImGui.SetFont(font)` | Set the font outright |

**There is no `ImGui.Tex2D`** — the engine's ImGui has no texture widget.
And a button does not take a callback: it **returns** whether it was
clicked, so the pattern is `if ImGui.ButtonEx("Go", 120, 32) then ... end`.

### ImGui Demo: `TestImGui.lua` — Market Table Example
This demonstrates the most useful patterns:

```lua
function Test:showScrollWindow()
  ImGui.BeginWindow("Yes!", 800, 320)
    ImGui.SetFont(Cache.Font("Shentox", 17))
    ImGui.PushStyleFont(Cache.Font("Shentox", 30))
    ImGui.TextColored("Market", 0.5, 0.7, 1.0, 0.2)
    ImGui.PopStyle()

    ImGui.BeginGroupX(0)
      -- Left scrollable column (ships list)
      ImGui.BeginScrollFrame(196, 0)   -- max height = 196
        ImGui.TextColored("SHIPS", 0.1, 0.5, 1.0, 1.0)
          ImGui.Indent()
          for _, v in ipairs(shipList) do
            if ImGui.Selectable(v) then printf(v) end  -- selection handler
          end
          ImGui.Undent()

        ImGui.TextColored("SUBSYSTEMS", 0.1, 0.5, 1.0, 1.0)
          ImGui.Indent()
          for _, subsystem in ipairs(subsystems) do
            ImGui.Selectable(subsystem)
          end
          ImGui.Undent()
      ImGui.EndScrollFrame()

      -- Right panel (static info)
      ImGui.BeginGroupY(0)
        ImGui.SetFont(Cache.Font("Iceland", 16))
        ImGui.Text("price : 13")
        ImGui.Text(" mass : 1")
      ImGui.EndGroup()
    ImGui.EndGroup()

  ImGui.EndWindow()
end
```

**Key patterns:**
- `Indent()` / `Undent()` creates nested indentation for column layouts
- `BeginScrollFrame(maxHeight, offset)` creates a scrollable region; negative offset scrolls up initially
- `.Selectable(label)` returns true when clicked/selected
- `PushStyleFont` / `PopStyle` let you change fonts per-region

### Creating an ImGui Demo App

```lua
local Demo = Application()

function Demo:onInit()
  self.renderer = Renderer()  -- optional, for UIRenderer backend
end

function Demo:onUpdate(dt)
  -- Build the entire UI tree every frame
  ImGui.Begin(self.resX, self.resY)
    ImGui.Text("FPS: " .. string.format("%.1f", 1.0 / dt))

    ImGui.SetCursor(20, 40)
    if ImGui.ButtonEx("Start Game", 150, 30) then
      printf("Button clicked!")
    end

    ImGui.SetSpacing(10, 0)
    ImGui.TextColored("Controls:", 0.9, 0.9, 0.9, 1.0)
    ImGui.Text("  W/A/S/D — Move")
    ImGui.Text("  Space   — Fire")

    -- Modal dialog (simulated with a panel overlay)
    if self.showDialog then
      ImGui.BeginPanel(500, 250)
        ImGui.SetFont(Cache.Font("Exo2Bold", 16))
        ImGui.TextColored("Game Over!", 1.0, 0.3, 0.3, 1.0)
        ImGui.Divider()
        ImGui.Text("You ran out of fuel.")
        ImGui.EndPanel()
    end

  ImGui.End()
end

function Demo:onDraw()
  self.renderer:start(self.resX, self.resY)
  Viewport.Push(0, 0, self.resX, self.resY, true)
  ImGui.Draw()
  Viewport.Pop()
  self.renderer:stop()
  self.renderer:present(self.resX, self.resY)
end

function Demo:SetDialog(show)
  self.showDialog = show
end

return Demo
```

### When to Use Which?

| Scenario | Recommended System | Reason |
|----------|-------------------|--------|
| Game UI (HUDs, menus, settings) | `script/UI/` | Retained-mode is more intuitive for hierarchical layouts; declarative children are easier to manage in Lua |
| Debug / tooling windows | `script/UI/` via `DebugWindow.lua` | Reusable patterns already implemented |
| Simple overlays (crosshair, health bar) | ImGui or HmGui | Both work; ImGui is more concise for simple things |
| High-frequency animated widgets | ImGui | No retained state means less GC pressure |
| Complex nested layouts | `script/UI/` | Deferred layout pass handles complex nesting naturally |

---

## 3. The Lua UI Widget Framework (`script/UI/`)

### Location
- Core: `script/UI/*.lua` (30 modules)
- Main entry: `Namespace.Load('UI')` loads all widgets into a global table
- Used by: `GameView.lua` (which extends `UI.Container`), `HUD.lua`,
  `DockControl.lua`, `DebugWindow.lua`, and the map (`SectorPanel.lua`,
  `NodeGraph.lua`)

### Architecture

```
┌─────────────────────────────────────────────┐
│  UI Framework (21 modules in script/UI/)    │
├──────────────────┬──────────────────────────┤
│  Core            │  Canvas.lua              │
│  └─ State        │  Handles input, focus    │
│  └─ Bindings     │  Maps keys to actions    │
│                   │                          │
│  Layout          │  Grid.lua                │
│  ├── Widget      │  Container base class    │
│  ├── Button      │  Draggable windows       │
│  ├── Window      │  Scrollable containers   │
│  ├── Panel       │  Collapsibles            │
│  ├── ScrollView  │  Accordions              │
│  ├── Grid        │  Stack/Stretch           │
│  ├── Slider      │  Checkbox                │
│  ├── Label       │  Image                   │
│  └── NavGroup    │                          │
├──────────────────▼──────────────────────────┤
│  Game Integration                            │
│  └─ DebugWindow.lua (extends UI.Window)     │
└─────────────────────────────────────────────┘
```

### Core Concepts

#### The Widget Hierarchy
All widgets inherit from `UI.Widget`:

```lua
local Widget = require('UI.Widget')

-- A custom widget inherits from Widget (leaf) or Container (with children)
local MyWidget = {}
MyWidget.__index = MyWidget
setmetatable(MyWidget, Widget)     -- or: setmetatable(MyWidget, UI.Container)

MyWidget.name = 'My Widget'
MyWidget.focusable = false

function MyWidget.Create (data)
  local self = setmetatable({ data = data }, MyWidget)
  self:setStretch(0, 0)           -- size to its content, not to the parent
  self.desiredSX = 128
  self.desiredSY = 64
  return self
end

function MyWidget:onDraw (focus, active)
  local x, y, sx, sy = self:getRectGlobal()
  -- DrawEx, NOT the raw Draw API. A raw `Draw.Rect` needs a shader and a
  -- texture already bound; with none bound it calls Tex2D_GetHandle with a
  -- null texture and takes the whole process down. DrawEx starts its own
  -- shader and is always safe.
  DrawEx.Panel(x, y, sx, sy, Color(1.0, 0.0, 0.0, 0.5), 0.5)
end

return MyWidget
```

**The three layout rules.** These are the ones that actually bite, and the
working demo (`script/App/UI_Demo.lua`) is built on them:

1. **A container does not flow its children.** `Container:onLayoutPosChildren`
   hands every child the *same* rect and lets each child's own `align`
   decide where it lands. Two children that both want the top-left corner
   land on top of each other. To stack things vertically, use a **Grid with
   one column**.
2. **A widget that should size to its content needs `setStretch(0, 0)`.** The
   default stretch is 1, which means "fill the parent" — so a panel added to
   the canvas fills the whole screen and the grid inside it spreads its
   columns across the monitor.
3. **The canvas is a layout parent.** Its children are placed with
   `setAlign(ax, ay)` — a *fraction* of the canvas — so a panel sits in the
   top-right corner at any window size with no pixel positions to maintain.

#### The State Machine (`UI.State`)
Every widget has an internal state machine for enable/disable transitions:

```lua
Container.EState = { Enabling = 1, Enabled = 2, Disabling = 3, Disabled = 4 }

function Container:setEState(eState)
  -- Handles fade-in/fade-out animations between states
end
```

#### Input Flow (simplified from `Canvas.lua`)

```
Frame Update:
  1. Find mouse focus → set state.focus / state.active
  2. If focused widget is draggable → apply drag offset
  3. On button press + release → fire click event
  4. Call :inputFocused(state) on all ancestors of focus
  5. Call :input(state) on all children

Frame Draw:
  1. Compute layout (size/position for every child)
  2. Render in order: parent → children (depth-first, tail-first draw order)
```

### UI Widget API Reference

| Module | Key Properties / Methods |
|--------|-------------------------|
| `UI.Widget` | `.name`, `.focusable`, `.draggable`, `.setPadUniform(x,y)`, `.setStretch(x,y)`, `.setAlign(x,y)`, `.setPos(x,y)`, `.setSize(sx,sy)`, `.setMinWidth(w)`, `.getRectGlobal()` |
| `UI.Container` | `.add(child, enabled)`, `.remove(child)`, `.isEnabled()`. **No `Create`** — use `UI.Panel('')` for a plain container |
| `UI.Panel` | `.Create(name, modal, onCancel)`, `.setModal(bool)`, `.setOnCancel(fn)`. Draws nothing by itself |
| `UI.Window` | `.title` (a FIELD, not `setTitle`), `.closeBtn`, `.setCloseButton(enabled)`, `.setModal(bool)`, draggable |
| `UI.Grid` | `.setCols(n)`, `.setRows(n)`, `.setPadCellX(width)`, `.setPadCellY(height)`. **One column is how you stack things vertically** — a container does not flow its children |
| `UI.ScrollView` | `.setScrollable(h,v)`, `.setSize(sx,sy)` (it needs a fixed size when it scrolls) |
| `UI.Slider` | `Slider.Create(getFn, setFn, minValue, maxValue)` — the first argument is the GETTER |
| `UI.Checkbox` | `Checkbox.Create(getFn, setFn)` |
| `UI.OptionSlider` | `OptionSlider.Create(getFn, setFn, elems, val)` — **the value is an INDEX into `elems`**, never the string |
| `UI.Button` | `Button.Create(text, onClick)` — the callback takes the button |
| `UI.Collapsible` | `Collapsible.Create(title, expanded)` |
| `UI.Graph` | `.setMode('sweep'/'scroll')`, `.addRuler(value, label, color)` |
| `UI.Label` | `Label.Create(text)`, `.setText(text)`, `.setFormat(formatstring)`, `.setPollFn(fn)`, `.setFontColor(color)` |
| `UI.IconButton` | `IconButton.Create(icon, onClick)` |
| `UI.Bindings` | Maps key names to input actions (e.g. "W", "SPACE") |

**The `__call` rule.** `Container`, `Panel`, `Widget` and `Window` define
`__call`, which forwards to that class's own `Create` — so `UI.Label("x")`,
`UI.Button("Go", fn)` and `UI.Grid()` all work. A widget that does **not**
inherit from one of those is not callable: use `UI.Grid.Create()` and
friends. (`Container` inherits `__call` but has no `Create`, so
`UI.Container()` is an error — use `UI.Panel('')`.)

#### Label with Live Updates
```lua
local healthLabel = UI.Label()
  :setMinWidth(60)
  :setFormat("%.1f HP")
  :setPollFn(function () return player.health end)
panel:add(healthLabel)
-- The label auto-updates every frame via the poll function
```

#### Grid Layout
```lua
local grid = UI.Grid():setCols(3):setPadCellX(20)
  :add(UI.Label("Slot 1")):add(UI.Button("Use"))
  :add(UI.Label("Slot 2")):add(UI.Button("Drop"))
  :add(UI.Label("Slot 3")):add(UI.Button("Swap"))

container:add(grid)
```

#### Navigation Group (`NavGroup`)
Manages keyboard/gamepad navigation between focusable widgets:

```lua
local nav = UI.NavGroup()
  :add(UI.Collapsible("System"):
    :add(UI.Grid():setCols(2):setPadCellX(16)
      :add(UI.Label("Speed")):add(UI.Slider(getSpeed, setSpeed))
      :add(UI.Label("Thrust")):add(UI.Slider(getThrust, setThrust)))

container:add(nav)
```

### Creating a Complete Custom UI Widget Example

```lua
local Inventory = {}
Inventory.__index = Inventory
setmetatable(Inventory, UI.Container)

Inventory.name = 'Inventory'
Inventory.focusable = true
Inventory.draggable = false  -- don't allow dragging inventory

-- The "slot" widget (one per item)
local SlotWidget = {}
SlotWidget.__index = SlotWidget
setmetatable(SlotWidget, UI.Widget)

function SlotWidget:onDraw(focus, active)
  local x, y, sx, sy = self:getRectGlobal()
  
  -- Background with focus highlighting
  if focus == self then
    Draw.Color(0.2, 0.6, 1.0, 0.3)   -- focused color from Config.ui.color
  elseif active == self then
    Draw.Color(0.8, 0.4, 0.3, 0.3)   -- selected color
  else
    Draw.Color(Config.ui.color.background.r, Config.ui.color.background.g, 
               Config.ui.color.background.b, 0.2)
  end
  Draw.Rect(x, y, sx, sy)

  -- Icon (if item is equipped)
  if self.equipped then
    local tex = Cache.Texture(self.item.icon)   -- Cache.Texture, not Cache.Tex2D
    Tex2D.Draw(tex, x + 4, y + 4, sx - 8, sy - 8)
  end
end

function SlotWidget:onFindMouseFocus(mx, my, foci)
  if self.focusable and self:containsPoint(mx, my) then
    foci.focus = self
  end
end

function SlotWidget:onClick(state)
  -- Handle item selection / use.
  -- `onClick`, not `click`: Widget:click is the dispatcher that calls
  -- onClick, so overriding `click` quietly bypasses the base class.
  print("Selected " .. tostring(self.item.name))
end

-- Main inventory window
Inventory.slotHeight = 48
Inventory.slotWidth  = 96

local function CreateSlot(item)
  local slot = setmetatable({}, SlotWidget)
  slot.item    = item or { name = "", icon = "" }
  slot.equipped= false
  return slot
end

function Inventory:onLayoutSize()
  -- Calculate total size from all children (slots)
  self.desiredSX = 0
  self.desiredSY = #self.children * self.slotHeight + 16  -- top/bottom padding
end

-- NOTE: there is no `onCreateChild` hook. Initialise a child as you create
-- it, or in the child's own `Create`.

-- Usage: Create a grid of slots with items
local inv = Inventory.Create()

for i = 1, 9 do
  local item = { name = "Blaster x" .. tostring(i), icon = "blaster_icon.png" }
  inv:add(CreateSlot(item))
end

inv:setPadUniform(8)
inv.desiredSX = #inv.children * Inventory.slotWidth + 8

-- Add to a window or canvas
local win = UI.Window("Inventory")
win.title = "My Inventory — 9 slots"
win:add(inv)

-- In your app's GameView:
gameView:add(win)
```

### The Demo App: `script/App/UI_Demo.lua` — this one runs

```bash
./run.sh UI_Demo
```

This is the corrected version of the sketch that used to be in this
document. It shows a **radar**, a **reticle with target brackets**, **ship
status**, a **flight-control panel**, an **inventory** and a **sector map** —
the screens ROADMAP item 8 (game screens) still owes — built out of the
framework's own widgets, with a simulated ship behind them so a screen can
be judged without a live sector.

**How an app drives a canvas.** This is the whole of the boilerplate (the
same shape as `script/App/TestEcon.lua`):

```lua
local Canvas = require('UI.Canvas')

local UIDemo = Application()

function UIDemo:onInit ()
  self.canvas = Canvas()
  self:buildUI()               -- build the tree ONCE; it is retained mode
end

function UIDemo:onInput ()
  self.canvas:input()          -- no arguments
end

function UIDemo:onUpdate (dt)
  self.canvas:update(dt)       -- a number, not a table
end

function UIDemo:onDraw ()
  self.canvas:draw(self.resX, self.resY)
end

return UIDemo
```

**What it demonstrates, and where to look:**

| thing | where |
|---|---|
| a custom widget that draws itself (radar, brackets, map) | `Radar`, `TargetBrackets`, `SectorMap` — all extend `UI.Widget` and implement `onDraw` |
| a custom widget that is FOCUSABLE (inventory slots) | `Slot` — it implements `onFindMouseFocus` and `onClick` |
| labels that poll live state | every readout: `Label():setPollFn(function () return self.ship.hull end)` |
| real controls | `Slider`, `Checkbox`, `OptionSlider` (in INDICES), `Button`, `Collapsible`, `ScrollView` |
| the layout idiom | two one-column Grids (left and right), each placed with `setAlign` |

**The two traps the demo had to be taught by:**

* A custom widget that wants mouse clicks implements **`onClick(state)`**,
  not `click(state)` — `Widget:click` is the dispatcher that calls `onClick`,
  so overriding `click` quietly bypasses the base class.
* An `OptionSlider`'s value is an **index** into its element list. Give it a
  string and `onUpdate` compares a string with a number and throws.

**What it does not do:** there is no main menu, no settings screen and no
in-game inventory yet — those are ROADMAP item 8, and the demo is the
reference they should be built from, not a substitute for them.

## 4. Creating a UI/GUI System for New Features

### Decision Tree: Which System to Use?

```
Need to build a new UI element?
│
├─ Is it a game HUD (health, minimap, radar, ship status)?
│   └─ YES → Use script/UI/ widgets. See DebugWindow.lua pattern.
│
├─ Is it a debug/tooling window or settings screen?
│   └─ YES → Use script/UI/ or HmGui if you prefer C++-based.
│
├─ Is it a simple overlay (crosshair, radial indicator)?
│   └─ YES → ImGui is fastest to prototype.
│
└─ Do you need complex animations / transitions?
    └─ Consider extending script/UI/ with CSS-like transition support.
```

### Pattern: HUD Element (Health Bar)

```lua
-- Add this as a child of GameView or as a separate HUD overlay window
local HealthBar = {}
HealthBar.__index = HealthBar
setmetatable(HealthBar, UI.Widget)

HealthBar.name = 'HealthBar'
HealthBar.focusable = false
HealthBar.draggable = false

function HealthBar:onInit()
  self.maxHealth = Config.game.shipHealth or 100
  self.health    = self.maxHealth
end

-- NOTE: the framework calls `onUpdate(state)` -- the state carries `dt`.
-- There is no `update(dt, state)` and no `onInit`; a custom widget is
-- initialised in its own `Create`.
function HealthBar:onUpdate(state)
  local player = self.player
  if player then
    self.health = Math.Clamp(self.health + (state.dt * Config.game.shipHealthRegen), 0, self.maxHealth)
  end
end

function HealthBar:onDraw(focus, active)
  local x, y, sx, sy = self:getRectGlobal()

  -- Background bar.
  -- DrawEx, not the raw Draw API: a raw `Draw.Rect` needs a shader and a
  -- texture already bound, and with none bound it calls Tex2D_GetHandle
  -- with a null texture and crashes the process.
  DrawEx.Rect(x, y, sx, sy, Color(0.15, 0.15, 0.15, 0.9))

  -- Health fill (gradient from red to green)
  local pct = self.health / self.maxHealth
  if pct >= 0.6 then
    DrawEx.Rect(x + 2, y + 2, sx - 4, sy - 4, Color(0.2 + 0.8 * pct, 1.0 - 0.4 * pct, 0.3, 0.9))
  else
    DrawEx.Rect(x + 2, y + 2, sx - 4, sy - 4, Color(1.0 - pct, 0.2, 0.1, 0.9))
  end

  -- Text label
  local font = Config.ui.font.normal
  local bound = font:getSize(string.format("%.0f / %.0f", self.health, self.maxHealth))
  font:draw(string.format("HP: %d/%d", math.floor(self.health), self.maxHealth),
    x + (sx - bound.z)/2, y + sy - bound.y - 6,
    Config.ui.color.textNormal.r, Config.ui.color.textNormal.g, 
    Config.ui.color.textNormal.b, Config.ui.color.textNormal.a)

  -- Damage flash animation
  if self.flashTimer > 0 then
    local alpha = Math.Lerp(1.0, 0.0, self.flashTimer / self.flashDuration)
    DrawEx.Rect(x + 3, y + 3, sx - 6, sy - 6, Color(1.0, 0.2, 0.1, alpha))
    self.flashTimer = self.flashTimer - state.dt * 30  -- fade in ~5 seconds
  end
end

function HealthBar:takeDamage(amount)
  self.health = Math.Max(0, self.health - amount)
  if self.health <= 0 then
    print("Ship destroyed!")
  else
    self.flashTimer = self.flashDuration or 2.0
  end
end

-- Usage in GameView
function GameView.Create(player)
  -- ... existing code ...

  self.healthBar = HealthBar.Create()
  self.healthBar.player = player
  self:add(self.healthBar)  -- add to canvas as a child
end
```

### Pattern: Radar / Sensor Display

The working version of this is the `Radar` widget in
`script/App/UI_Demo.lua`. It is the whole thing in about forty lines, and it
shows the three shapes a radar needs — **there is no circle in the engine's
`Draw` API**, so all of them come from `UI.DrawEx`:

```lua
local DrawEx = require('UI.DrawEx')

local Radar = {}
Radar.__index = Radar
setmetatable(Radar, Widget)
Radar.name = 'Radar'
Radar.focusable = false

function Radar.Create (app)
  local self = setmetatable({ app = app, sweep = 0 }, Radar)
  self:setStretch(0, 0)
  self.desiredSX = 240
  self.desiredSY = 240
  return self
end

function Radar:onUpdate (state)
  self.sweep = (self.sweep + state.dt * 0.5) % 1.0     -- `state.dt` lives HERE
end

function Radar:onDraw (focus, active)
  local x, y, sx, sy = self:getRectGlobal()
  local cx, cy = x + sx * 0.5, y + sy * 0.5
  local r = math.min(sx, sy) * 0.44

  DrawEx.Panel(x, y, sx, sy, Color(0.02, 0.04, 0.07, 0.78), 0.55)
  DrawEx.RectOutline(x, y, sx, sy, Color(0.30, 0.50, 0.70, 0.45))

  -- The range rings: DrawEx.Ring, not Draw.CircleOutline (which does not exist).
  DrawEx.Ring(cx, cy, r,        Color(0.30, 0.50, 0.70, 0.40))
  DrawEx.Ring(cx, cy, r * 0.66, Color(0.30, 0.50, 0.70, 0.25))
  DrawEx.Ring(cx, cy, r * 0.33, Color(0.30, 0.50, 0.70, 0.18))

  DrawEx.Line(cx - r, cy, cx + r, cy, Color(0.30, 0.50, 0.70, 0.22))
  DrawEx.Line(cx, cy - r, cx, cy + r, Color(0.30, 0.50, 0.70, 0.22))

  -- The sweep. `to` is a FRACTION of a full turn; `tw` is its width.
  DrawEx.Wedge(cx, cy, r * 0.15, r, self.sweep, 0.06, Color(0.35, 1.0, 0.65, 0.30), 1)

  -- The contacts, at their bearing and range.
  local range = self.app.ship.radarRange
  for _, c in ipairs(self.app.contacts) do
    local rr = r * math.min(1, c.dist / range)
    local tx = cx + math.cos(c.angle) * rr
    local ty = cy + math.sin(c.angle) * rr
    local col = CONTACT_COLORS[c.kind] or CONTACT_COLORS.debris
    DrawEx.Point(tx, ty, 3.5, col)                  -- a filled dot
    DrawEx.Line(tx - 4, ty, tx + 4, ty, col)        -- and a tick
  end

  DrawEx.Cross(cx, cy, 6, Color(1, 1, 1, 0.95))     -- the ship, at the centre
end
```

**Where the data comes from.** In the demo it is simulated, so a screen can
be judged without a live sector. In the game it would be the entity system,
and the shape of the query is the same:

```lua
for _, entity in ipairs(self.system:iterChildren()) do
  local pos = entity:getPos()
  local dist = (myPos - pos):length()
  local dirToEntity = (pos - myPos):normalize()
  if dist <= detectionRange and
     dirToEntity:dot(self.ship:getForward()) > math.cos(sensorCone) then
    table.insert(self.targetList, { entity = entity, dist = dist })
  end
end
table.sort(self.targetList, function (a, b) return a.dist < b.dist end)
```

(`table.sort` exists — it is a bare global `sort` that does not. The
market's price walk uses `table.sort` for exactly this reason.)

## 5. Summary of All UI Systems

### Comparison Table

| Feature | HmGui (C++) | ImGui (C++ IM) | script/UI/ (Lua) |
|---------|-------------|----------------|-----------------|
| **Mode** | Retained | Immediate | Retained |
| **Language** | C++ + Lua FFI | C++ + Lua FFI | Pure Lua |
| **Layout** | Deferred pass | Per-frame cursor | Deferred pass |
| **Focus** | 3-way (mouse/scroll/nav) | Mouse only | 4-way system |
| **Draggable Windows** | Yes | Yes | Yes |
| **Scrollable regions** | Yes | Yes | Yes |
| **Grid layout** | Via stretch groups | Manual cursor pos | Grid module |
| **Best for** | Tooling / debug panels | Simple overlays, prototypes | Game HUDs, menus, settings |

### File Organization Summary

```
libphx/
├── src/HmGui.cpp           # Engine C++ GUI (retained)
├── src/HmGuiInternal.h     # HmGui layout engine
├── src/ImGui.cpp           # Engine C++ GUI (immediate mode)
├── include/UIRenderer.h    # UIRenderer FFI bindings
└── script/ffi/
    ├── HmGui.lua          # C API → Lua bindings
    └── ImGui.lua           # C API → Lua bindings

script/UI/                   # Pure Lua widget framework (NO dependencies)
├── Widget.lua              # Base class with layout, input, draw hooks
├── Container.lua           # addChild/remove/addQueue patterns
├── Canvas.lua              # Input routing + state machine
├── State.lua               # Focus / active tracking
├── Bindings.lua            # Key mapping system
├── Window.lua              # Draggable title-bar window
├── Panel.lua               # Non-draggable bordered panel
├── Grid.lua                # 2D grid layout (row/col based)
├── ScrollView.lua          # Scrollable container with scrollbar widget
├── Collapsible.lua         # Accordion-style foldable section
├── NavGroup.lua            # Keyboard/gamepad navigation group
├── Stack.lua               # Vertical stack layout
├── Stretch.lua             # Horizontal/vertical stretch child
├── Button.lua              # Clickable label button
├── IconButton.lua          # Icon-only button
├── Checkbox.lua            # Toggle checkbox
├── Slider.lua              | OptionSlider.lua      # Range inputs
├── Label.lua               # Text label with format strings + polling
├── Image.lua               # Texture sprite widget
├── Icon.lua                # Icon sprite widget
├── Rect.lua                # Colored rectangle (used for panels)
├── Hidden.lua              # A widget that draws nothing
├── Graph.lua               # Real-time data graphing widget
├── GraphProvider.lua       # Feeds a Graph from a live source
├── NodeGraph.lua           # The map: a custom widget with its own editor
├── NodeGraphInspector.lua  # The map's property panel
├── NodeGraphUtil.lua       # The map's shared helpers
├── SectorPanel.lua         # The sector/region readout (a custom widget)
└── DrawEx.lua              # Drawing helpers (rings, points, wedges, arrows)

script/App/
└── UI_Demo.lua             # THE DEMO APP -- radar, brackets, status,
                            # flight controls, inventory, map. Runs.

script/Game/GUI/
├── GameView.lua            # Main game view with UI composite pass
├── DebugWindow.lua         # Full-featured debug panel demo
└── DebugInspector.lua      # Property inspector for entities
```

### Entry Points by Use Case

| Use Case | How to Start |
|----------|-------------|
| **Game HUD elements** (health, radar, minimap) | Extend `UI.Widget` or `UI.Container`; add as child of your game view's canvas |
| **Settings / Main Menu** | Create a `UI.Window`, populate with grids/sliders/checkboxes, add to a top-level canvas |
| **Debug tooling panel** | Follow `DebugWindow.lua` pattern — extends `UI.Window`, uses Grid for sections |
| **Simple overlay (crosshair, health bar)** | Use ImGui via FFI: `ImGui.Begin()...ImGui.End()` in your app's update/draw loop |

---

## 6. Where this goes next

The UI work this document describes is **ROADMAP item 8 (game screens)**, and
it is still open. What exists today:

| done | |
|---|---|
| ✅ | the widget framework itself (`script/UI/`, 30 modules) |
| ✅ | the debug panel (`DebugWindow.lua`) — the richest UI in the game |
| ✅ | the HUD, the sector/region readout, the market panel at the dock, the sector map |
| ✅ | **the demo app** (`script/App/UI_Demo.lua`) — radar, target brackets, ship status, flight controls, inventory, sector map, and it runs |

What is missing, and what the demo is the reference for:

1. **A main menu** — a `UI.Window` over the canvas, with the options a new
   player needs (new game, continue, settings, quit). The demo's flight panel
   is the shape of it.
2. **A settings screen** — the same frame, a column of controls: the sliders,
   the checkbox and the option slider the demo already has, bound to
   `Settings`. Note the index trap: an `OptionSlider` wants an index, and the
   settings panel's enum values ARE indices (`Settings.addEnum` stores the
   position, not the string).
3. **The demo's screens, in the game** — the radar, the target brackets and
   the inventory are currently a demo with a simulated ship behind it. Making
   them real means pointing them at the entity system and the HUD's own state.
4. **A pause screen** — the cheapest of the four, and the first thing a
   player sees.

**The deferred dear-imgui question** is answered here: it is not worth
swapping. The *game* UI should stay on `script/UI/` — it is retained-mode,
it is in Lua, it is themed by `Config.ui`, and the layout engine already
works. dear imgui would buy immediate-mode convenience and cost a rewrite of
the game UI; `HmGui` and the engine's own `ImGui` are both C++ test-only
systems that no shipped screen uses.
