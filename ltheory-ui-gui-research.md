# LTheory UI/GUI Systems Research Document

## Executive Summary

The LTheory engine provides **three distinct GUI/UI systems**:

1. **HmGui** — C++ retained-mode GUI (engine core) used by `TestHmGui.lua`
2. **ImGui** — Homegrown immediate-mode GUI (engine core) used by `TestImGui.lua` and `RenderTest.lua`
3. **script/UI/** — Lua-based retained-mode widget framework (the primary game UI system, used by `DebugWindow.lua`)

The main LTheory game app (`LTheory.lua`) does **NOT** use any of these GUI systems directly — it only uses the camera chase/orbit view. The Debug window is a separate entity opened with F9.

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
| `HmGui_BeginGroup(layout)` | Create a group (stack/vertical/horizontal) |
| `HmGui_EndGroup()` | Close the current group |
| `HmGui_Button(label)` | Create a button, returns true if clicked |
| `HmGui_Checkbox(label, value)` | Toggle checkbox |
| `HmGui_Slider(lower, upper, value)` | Slider (currently unused in test) |
| `HmGui_SetStretch(x, y)` | Stretch factor for children |
| `Hmgui_PushFont(font)` / `PopStyle(depth)` | Style stack management |
| `HmGui_Image(tex2d*)` | Add a texture image |

### Layout System
- **Layout_None**: Fixed position (absolute)
- **Layout_Stack**: Children share same x,y, sizes are max of children
- **Layout_Vertical**: Children stack vertically with spacing; horizontal stretch applies
- **Layout_Horizontal**: Children stack horizontally with spacing; vertical stretch applies

```lua
HmGui.BeginGroup(Layout_Vertical)  -- equivalent to BeginGroupY()
  HmGui.SetPadding(8, 4)           -- left/right, top/bottom
  HmGui.Text("Hello")
  HmGui.Button("Click me")
    :SetStretch(1, 0)              -- stretch horizontally only
Hmgui.EndGroup()
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
| `ImGui.Checkbox(value)` | Toggle checkbox |
| `ImGui.Selectable(label)` | Selectable item (like radio button) |
| `ImGui.Tex2D(tex2d*)` | Draw a texture |
| `ImGui.BeginGroupX(sy)` / `BeginGroupY(sx)` | Begin horizontal/vertical group |
| `ImGui.EndGroup()` | Close current group |
| `ImGui.BeginPanel(sx, sy)` | Panel with beveled border (alternative to window) |
| `ImGui.EndPanel()` | End panel |
| `ImGui.BeginScrollFrame(maxY, scrollOffset)` | Scrollable region |
| `ImGui.EndScrollFrame()` | Close scroll frame |
| `ImGui.Indent()` / `ImGui.Undent()` | Indent text cursor (nested layout) |
| `ImGui.Divider()` | Horizontal/vertical divider line |
| `ImGui_SetCursor(x, y)` | Set absolute cursor position |
| `ImGui.PushStyleFont(font)*` | Push a custom font |
| `ImGui.PopStyle(depth)` | Pop N styles from stack |

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
    ImGui.ButtonEx("Start Game", 150, 30)
      if ImGui.ButtonEx then printf("Button clicked!") end

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
- Core: `script/UI/*.lua` (21 files in `script/UI/`)
- Main entry: `Namespace.Load('UI')` loads all widgets into a global table
- Used by: `DebugWindow.lua`, `GameView.lua` (children)

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

-- Custom widget inherits from Container
local MyWidget = {}
MyWidget.__index = MyWidget
setmetatable(MyWidget, UI.Container)  -- or setmetatable(MyWidget, UI.Widget)

function MyWidget:onDraw(focus, active)
  local x, y, sx, sy = self:getRectGlobal()
  Draw.Color(1.0, 0, 0, 0.5)
  Draw.Rect(x, y, sx, sy)
end

MyWidget.name = 'My Widget'

function MyWidget.Create(data)
  local self = setmetatable({}, MyWidget)
  -- Initialize data here
  return self
end

return MyWidget
```

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
| `UI.Widget` | `.name`, `.focusable`, `.draggable`, `.padUniform(x,y,z)` |
| `UI.Container` | `.add(child, enabled)`, `.remove(child)`, `.isEnabled()` |
| `UI.Window` | `.title`, `.closeBtn`, `.setModal(bool)`, `.setCloseButton(enabled)` |
| `UI.Grid` | `.setCols(n)`, `.setRows(n)`, `.setPad(x,y)`, `.setPadCellX(width)` |
| `UI.ScrollView` | `.setScrollable(h,v)`, `.setPadUniform(padding)` |
| `UI.Slider` | `.setFormatter(fmt)`, `.getMin()`, `.setMax()` |
| `UI.Graph` | `.setMode('sweep'/'scroll')`, `.addRuler(value, label, color)` |
| `UI.Label` | `.setText(text)`, `.setFormat(formatstring)`, `.setPollFn(fn)` |
| `UI.Bindings` | Maps key names to input actions (e.g. "W", "SPACE") |

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
    local tex = Cache.Tex2D(self.item.icon)
    Tex2D.Draw(tex, x + 4, y + 4, sx - 8, sy - 8)
  end
end

function SlotWidget:onFindMouseFocus(mx, my, foci)
  if self.focusable and self:containsPoint(mx, my) then
    foci.focus = self
  end
end

function SlotWidget:click(state)
  -- Handle item selection / use
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

function Inventory.onCreateChild(child, index)
  child.equipped = false  -- default state
end

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

### Full Demo App: `DemoUI.lua` (complete working example)

Create this file at `/home/rhague/Documents/Code_Projects/ltheory-test/script/App/DemoUI.lua`:

```lua
local DemoUI = Application()
local UI = require('UI')  -- Load the full UI framework

-- Simple color picker widget for demonstration
local ColorPicker = {}
ColorPicker.__index = ColorPicker
setmetatable(ColorPicker, UI.Widget)

ColorPicker.name = 'Color Picker'
ColorPicker.focusable = true
ColorPicker.draggable = false

function ColorPicker:onDraw(focus, active)
  local x, y, sx, sy = self:getRectGlobal()

  -- Draw a small preview of the current color
  Draw.Color(self.color.r, self.color.g, self.color.b, 0.6)
  Draw.Rect(x + 4, y + 4, sx - 8, sy - 8)

  -- Color bar (vertical gradient)
  local gradHeight = sy - 12
  for i = 0, gradHeight do
    local t = i / gradHeight
    local r = self.color.r * (1.0 - t)
    local g = self.color.g * (1.0 - t)
    local b = self.color.b * (1.0 - t)
    Draw.Color(r, g, b, 0.5 + 0.5 * t)
    Draw.Rect(x + 4, y + 6 + i, sx - 8, 2)
  end

  -- Label showing RGB values
  local font = Config.ui.font.normal
  local bound = font:getSize(string.format("%.1f %.1f %.1f", self.color.r, self.color.g, self.color.b))
  font:draw(string.format("RGB (%.1f,%.1f,%.1f)", self.color.r, self.color.g, self.color.b),
    x - bound.x + (sx - bound.z) / 2, y + sy - bound.y - 6,
    Config.ui.color.textNormal.r, Config.ui.color.textNormal.g, 
    Config.ui.color.textNormal.b, Config.ui.color.textNormal.a)
end

function ColorPicker:inputFocused(state)
  -- On focus, cycle through predefined colors with keyboard
  if Input.GetPressed('KEY_1') then self.color = {r=1.0,g=0.0,b=0.0} end
  if Input.GetPressed('KEY_2') then self.color = {r=0.0,g=1.0,b=0.0} end
  if Input.GetPressed('KEY_3') then self.color = {r=0.0,g=0.0,b=1.0} end
  if Input.GetPressed('KEY_4') then self.color = {r=1.0,g=1.0,b=0.0} end
end

-- Radar widget (simulated)
local Radar = {}
Radar.__index = Radar
setmetatable(Radar, UI.Container)

Radar.name = 'Radar'
Radar.focusable = true
Radar.draggable = false

function Radar:onDraw(focus, active)
  local x, y, sx, sy = self:getRectGlobal()

  -- Dark background
  Draw.Color(0.1, 0.15, 0.2, 0.95)
  Draw.Rect(x, y, sx, sy)

  -- Radar ring
  Draw.Color(0.3, 0.4, 0.5, 0.6)
  Draw.CircleOutline(x + sx/2, y + sy/2, sx*0.4)

  -- Scan line animation (simulated with a rotating triangle)
  local angle = self.scanAngle or 0
  self.scanAngle = (self.scanAngle or 0) + state.dt * 3.14159 / 60  -- slow rotation
  Draw.Color(0, 1.0, 0.5, 0.7)
  -- You'd draw a rotated triangle/arc here using shader transforms

  -- Sample targets (simulated entities outside radar range)
  local targetColors = { {1,0.2,0.3}, {1,0.8,0.3}, {0.5,1,0.5} }
  for i = 1, #targetColors do
    Draw.Color(unpack(targetColors[i]))
    Draw.Rect(x + sx*0.7 + (i-1)*20, y + sy*0.3, 8, 8)  -- simplified positioning
  end

  -- Label
  local font = Config.ui.font.normal
  local bound = font:getSize("Radar")
  font:draw("Radar", x - bound.x + (sx-bound.z)/2, y+4, 
    Config.ui.color.textNormal.r, Config.ui.color.textNormal.g,
    Config.ui.color.textNormal.b, Config.ui.color.textNormal.a)
end

-- Map widget
local Map = {}
Map.__index = Map
setmetatable(Map, UI.Window)

Map.name = 'Map'

function Map:onDraw(focus, active)
  self:super.onDraw(focus, active)

  -- Simulated map background (a rectangle with grid lines)
  local x, y, sx, sy = self:getRectPadGlobal()
  Draw.Color(0.2, 0.25, 0.3, 1.0)
  Draw.Rect(x, y, sx, sy)

  -- Grid lines (simplified — in practice you'd draw a real map texture or generate it)
  for i = 0, sx-8, 40 do
    Draw.Color(0.25, 0.3, 0.4, 1.0)
    Draw.Rect(x + i - 4, y - 2, 8, sy)
    Draw.Rect(x - 2, y + i - 4, sx, 8)
  end

  -- Ship position indicator (centered for demo)
  local center = x + sx/2, y + sy/2
  Draw.Color(1.0, 1.0, 0.5, 0.9)
  Draw.Circle(center.x, center.y, 6)
end

function Map:onInit() end

-- Main demo app
local Demo = setmetatable({}, DemoUI)

function Demo:onInit()
  -- Load the UI framework namespace
  Namespace.LoadInline('Util')
  Namespace.Load      ('UI')

  self.renderer = Renderer()
  self.canvas   = nil  -- will be created on first draw
end

function Demo:onInput(state)
  if not self.canvas then return end
  self.canvas:input(state)
end

function Demo:onUpdate(dt)
  if not self.canvas then return end
  self.canvas:update({ dt = dt })
end

-- Create the full UI tree
local rootCanvas = nil
local radar, mapWin, colorPicker, inventory

function Demo:createUI()
  -- The main container for all UI elements
  local canvas = UI.Container.Create()
  canvas.name = "Demo UI Root"
  
  -- A Grid layout to organize the demo widgets
  local grid = UI.Grid():setCols(2):setPadCellX(16)

  -- Left column: Windows and Panels
  local leftCol = UI.Column():add(grid:setRows(4))
  
    -- Window with close button (simulates a modal dialog)
    local win = UI.Window("System Alert")
      :setTitle("⚠ System Warning")
      :setCloseButton(true)
    
    win:add(UI.Label():setText("This window can be dragged."))
    win:add(UI.Grid():setCols(2):setPadCellX(12):add(
        UI.Button("Accept"):setOnClick(function() self:hideWindow(win) end)
      ):add(UI.Button("Ignore")))
    
    leftCol:add(win)

    -- Panel (beveled, non-windowed)
    local panel = UI.Panel():setTitle("Settings")
      :setPadUniform(6)
    
    panel:add(UI.Label("Debug Level")):add(UI.Slider(0, 5):setValue(2))
    panel:add(UI.Checkbox(function() return true end, function(v) print("Checkbox:", v) end)
    panel:add(UI.Label("Enable particles", true))

    leftCol:add(panel)

    -- Collapsible section
    local collapsible = UI.Collapsible("Advanced Options")
      :add(UI.Grid():setCols(2):setPadCellX(16):add(
          UI.Label("Max Entities"):add(UI.Slider(0, 1000000):setValue(5000))
        ):add(UI.Label("Max Particles"):add(UI.Slider(0, 100000):setValue(32768)))

    leftCol:add(collapsible)

    -- Color picker demo
    colorPicker = ColorPicker.Create()
    colorPicker.color = {r=0.95, g=0.4, b=0.3}  -- accent red
    leftCol:add(colorPicker)

    -- Radar demo widget (non-Window-based)
    local radarPanel = UI.Panel():setTitle("Radar")
      :setPadUniform(8):setMinSize(256, 192)
    
    radarPanel:add(radar = Radar.Create())
    leftCol:add(radarPanel)

    -- Map window
    mapWin = Map.Create()
    leftCol:add(mapWin)

  -- Right column: Navigation and controls
  local rightCol = UI.Column():add(grid:setCols(1):setPadCellX(0))

    -- Navigation group (keyboard navigation demo)
    local navGroup = UI.NavGroup()
      :add(UI.Collapsible("Navigation Demo")
        :add(UI.Grid():setCols(3):setPadCellX(8)
          :add(UI.Button("Home"):setOnClick(function() print("Home") end))
          :add(UI.Label("Current:")):add(UI.Label("None"))
          :add(UI.Button("About"):setOnClick(function() print("About") end))
        )
      )

    rightCol:add(navGroup)

  grid:add(leftCol):add(rightCol)

  -- Add to canvas
  canvas:add(grid)
  rootCanvas = canvas
end

function Demo:hideWindow(win)
  win:remove()
end

function Demo:onDraw()
  -- Create the UI tree on first frame (retained-mode benefit!)
  if not self.canvas then self:createUI(); end

  -- Push alpha blending for all UI
  BlendMode.Push(BlendMode.Alpha)

  -- Begin draw pass
  local canvas = self.canvas
  Viewport.Push(0, 0, self.resX, self.resY, true)
  ClipRect.PushTransform(0, 0, self.resX / (self.uiScale or 1), self.resY / (self.uiScale or 1))

  -- Apply scale transform for high-DPI support
  local uiScale = self.uiScale or 1.0
  ShaderVar.PushMatrix('mViewUI', Matrix.Scaling(uiScale, uiScale, 1))

  -- Draw the UI tree
  canvas:draw()

  ShaderVar.Pop('mViewUI')
  ClipRect.PopTransform()
  Viewport.Pop()

  RenderState.PopAllDefaults()
  BlendMode.Pop()

  -- Optional: Use HmGui as an overlay (can coexist with script/UI)
  local hmguiRenderer = Renderer()
  hmguiRenderer:start(self.resX, self.resY)
  Viewport.Push(0, 0, self.resX, self.resY, true)
  
  -- Simple HmGui demo overlay (only shown when focused on this app)
  if os.getenv('PHX_DEMO_HMGUI') == '1' then
    local hmgui = require('ffi.HmGui').libphx or nil
    if hmgui and not self.hmGuiInitialized then
      -- Initialize HmGui once
      if hmgui.Begin then
        self.hmGuiInitialized = true
        hmgui.Begin(self.resX, self.resY)
          hmgui.Text("HmGui Overlay Demo")
          hmgui.Button("Click to test!")
            :SetOnClick(function() print("HmGui button clicked!") end)
        hmgui.EndWindow()
      end
    end
    if self.hmGuiInitialized then hmgui.Draw() end
  end

  Viewport.Pop()
  hmguiRenderer:stop()
  hmguiRenderer:present(self.resX, self.resY)

  -- Also draw ImGui (immediate mode runs every frame)
  local imgui = require('ffi.ImGui').libphx or nil
  if imgui then
    ImGui.Begin(self.resX, self.resY)
      ImGui.Text("ImGui Overlay")
      ImGui.ButtonEx("I am immediate-mode!", 160, 32)
        :SetOnClick(function() print("ImGui clicked!") end)

      ImGui.BeginScrollFrame(0, -50)
        for i = 1, 100 do
          ImGui.Text(string.format("Line %d", i))
        end
      ImGui.EndScrollFrame()
    ImGui.End()

    Viewport.Push(0, 0, self.resX, self.resY, true)
    ImGui.Draw()
    Viewport.Pop()
  end
end

function Demo:run()
  -- Set up config override for this demo
  Config.window.width = 1280
  Config.window.height = 720
  Config.debug.windowSection = 'Navigation Demo'  -- open nav group by default

  Application.run(self)
end

return Demo
```

---

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

function HealthBar:update(dt, state)
  local player = self.player or GameView and GameView.player
  if player then
    self.health = Math.Clamp(self.health + (dt * config.game.shipHealthRegen), 0, self.maxHealth)
  end
end

function HealthBar:onDraw(focus, active)
  local x, y, sx, sy = self:getRectGlobal()

  -- Background bar
  Draw.Color(0.15, 0.15, 0.15, 0.9)
  Draw.Rect(x, y, sx, sy)

  -- Health fill (gradient from red to green)
  local pct = self.health / self.maxHealth
  if pct >= 0.6 then
    Draw.Color(0.2 + 0.8 * pct, 1.0 - 0.4 * pct, 0.3, 0.9)
  else
    Draw.Color(1.0 - pct, 0.2, 0.1, 0.9)
  end
  Draw.Rect(x + 2, y + 2, sx - 4, sy - 4)

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
    Draw.Color(1.0, 0.2, 0.1, alpha)
    Draw.Rect(x + 3, y + 3, sx - 6, sy - 6)
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

```lua
local RadarDisplay = {}
RadarDisplay.__index = RadarDisplay
setmetatable(RadarDisplay, UI.Container)

RadarDisplay.name = 'RadarDisplay'
RadarDisplay.focusable = false
RadarDisplay.draggable = true  -- allow dragging around screen

function RadarDisplay:onInit()
  self.scanAngle = 0
  self.targetList = {}  -- entities detected by sensors
end

-- This would hook into a sensor system in your game loop:
function RadarDisplay:update(dt, state)
  -- Query your sensor/sonar subsystem for nearby entities
  local myPos = self.player and self.player:getControlling() and 
                self.player:getControlling():getPos() or Vec3f(0,0,0)

  local detectionRange = Config.game.detectionRange or 5000
  local sensorCone = math.pi / 4.0  -- 90 degree cone in front of ship

  for _, entity in ipairs(self.system and self.system:iterChildren() or {}) do
    if entity ~= self.player then
      local pos = entity:getPos()
      local dist = (myPos - pos):length()
      local dirToEntity = (pos - myPos):normalize()
      
      -- Check if within detection range AND in front of ship
      if dist <= detectionRange and 
         dot(dirToEntity, self.player:controlling:getForward()) > math.cos(sensorCone) then
        
        table.insert(self.targetList, { entity = entity, dist = dist })
      end
    end
  end

  -- Sort by distance
  table.sort(self.targetList, function(a,b) return a.dist < b.dist end)
end

function RadarDisplay:onDraw(focus, active)
  local x, y, sx, sy = self:getRectGlobal()

  -- Background with rounded corners (use DrawEx if available)
  Draw.Color(0.12, 0.18, 0.25, 0.92)
  Draw.Rect(x + 4, y + 4, sx - 8, sy - 8)

  -- Radar ring with sweep animation
  local centerX = x + sx/2
  local centerY = y + sy/2
  local radius = sx * 0.35

  -- Draw the scan arc
  self.scanAngle = (self.scanAngle or 0) + state.dt * math.pi / 180
  for angle = -math.pi, math.pi do
    local progress = ((angle - self.scanAngle + math.pi) % (2*math.pi)) / (2*math.pi)
    if progress <= 0.03 then
      -- Draw scan line segments
      local startAngle = angle - 0.015
      local endAngle   = angle + 0.015
      
      local sx1 = centerX + radius * math.cos(startAngle)
      local sy1 = centerY + radius * math.sin(startAngle)
      local sx2 = centerX + radius * math.cos(endAngle)
      local sy2 = centerY + radius * math.sin(endAngle)

      Draw.Color(0.0, 1.0, 0.5, progress < 0.95 and 0.6 or 0.3)
      Draw.Line(sx1, sy1, sx2, sy2)
    end
  end

  -- Draw detected targets as colored dots
  local targetColors = { {1,0.4,0.3}, {0.9,0.7,0.3}, {0.5,1.0,0.8} }
  for i, target in ipairs(self.targetList) do
    if i <= #targetColors then
      local tColor = targetColors[i]
      Draw.Color(tColor.r, tColor.g, tColor.b, 0.9)
      
      -- Position around the ring based on entity position relative to ship
      local angleToTarget = math.atan2(target.entity:getPos().y - myPos.y, 
                                       target.entity:getPos().x - myPos.x)
      local tx = centerX + radius * math.cos(angleToTarget)
      local ty = centerY + radius * math.sin(angleToTarget)

      Draw.Circle(tx, ty, 4)
      
      -- Distance label
      local font = Config.ui.font.normal
      local bound = font:getSize(string.format("%.0fm", target.dist / 100))
      font:draw(string.format("%.0fkm", target.dist),
        tx - bound.x/2, ty + sy*0.3 + bound.y, 
        0.7, 0.7, 0.7)
    end
  end

  -- Range ring labels
  local distances = { 1000, 2000, 5000 }
  for _, d in ipairs(distances) do
    Draw.Color(0.3, 0.4, 0.6, 0.7)
    Draw.Circle(centerX, centerY, radius * (d / detectionRange))
  end

  -- Labels
  local font = Config.ui.font.normal
  font:draw("RADAR", centerX - font:getSize("RADAR").z/2, y + sy*0.05, 
    Config.ui.color.textNormal.r, Config.ui.color.textNormal.g,
    Config.ui.color.textNormal.b, Config.ui.color.textNormal.a)

  -- Legend
  local legendX = x + sx * 0.15
  local legendY = y + sy * 0.38
  font:draw("Enemy", legendX, legendY, 1.0, 0.4, 0.3)
  Draw.Color(1.0, 0.4, 0.3, 0.7)
  Draw.Circle(legendX + 20, legendY - 8, 5)

  font:draw("Friendly", legendX, legendY + 26, 0.9, 0.7, 0.3)
  Draw.Color(0.9, 0.7, 0.3, 0.7)
  Draw.Circle(legendX + 20, legendY - 8 + 14, 5)

  font:draw("Neutral", legendX, legendY + 52, 0.5, 1.0, 0.8)
  Draw.Color(0.5, 1.0, 0.8, 0.7)
  Draw.Circle(legendX + 20, legendY - 8 + 28, 5)
end
```

---

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
├── Rect.lua                # Colored rectangle (used for panels)
├── Graph.lua               # Real-time data graphing widget
└── DrawEx.lua              # Drawing helpers (triangles, arrows, etc.)

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

## 6. Practical Next Steps

To create a demo with UI/GUI demonstrations showing how radar, sensors, reticle, ship info, inventory, map, and target objects could look:

1. **Create** `/home/rhague/Documents/Code_Projects/ltheory-test/script/App/UI_Demo.lua` (use the full DemoUI.lua example above)
2. **Run** with `./run.sh UI_Demo` to see all widget types
3. **Extend** by adding:
   - A real radar that queries your entity system for nearby ships/asteroids/stations
   - A minimap using a low-res texture + dynamic marker sprites
   - Ship info panel pulling from your ship's component data (mass, fuel, shields)
   - Inventory grid with drag/drop between slots
   - Map widget showing planet surface + detected entities

The `DebugWindow.lua` file is the closest existing example to a full-featured UI panel — study its use of `UI.Grid`, `UI.Collapsible`, and nested containers as a template.
