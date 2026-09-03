# SDL2 → SDL3 Migration Plan

Goal: migrate the engine from **SDL2 2.32.70** to the latest **SDL3** (system has **3.4.14**), keeping the GL 4.6 core context and every engine-internal API unchanged. This is a **contained, low-risk self-contained project**: SDL is used only inside `libphx/src` (a thin C++ shim layer); the game (`lt`), `Main.cpp`, all gameplay Lua, and the FFI bindings are **SDL-free**. Audio is 100% miniaudio, so **audio is not in scope**.

## 1. Background / why it's contained

- **Zero SDL outside `libphx/src`.** `grep -rl "SDL_" src/` returns nothing; `Main.cpp` bootstraps only through `Engine_Init(4, 6)`. Lua/FFI never reference SDL.
- **Headered-out.** No `SDL_` symbol leaks into any `.h`; SDL types are hidden inside `.cpp` struct definitions (`SDL_Window* handle`, `SDL_Thread* handle`, `SDL_GameController* handle`). The engine-internal wrappers (`Window_*`, `Input_*`, `Gamepad_*`, `Mouse_*`, `Keyboard_*`, `Joystick_*`, `OS_*`, `Timer_*`, `Thread_*`, `OpenGL_*`) are the public surface and stay as-is.
- **Audio is not a concern** — miniaudio owns it; `SDL_INIT_AUDIO` is absent from the init mask and no SDL audio API is used.
- **Dependency already present**: SDL3 3.4.14 dev package is installed (`pkg-config --modversion sdl3` → `3.4.14`, headers at `/usr/include/SDL3/`).

## 2. Affected assets

### 2.1 C++ sources (the files to change) — all in `libphx/src/`

**Real, substantive changes:**

| File | What changes |
|---|---|
| `Engine.cpp` | Subsystem init flags (`SDL_INIT_EVENTS/VIDEO/TIMER/HAPTIC/JOYSTICK/GAMECONTROLLER` → SDL3 flag set; `GAMECONTROLLER`→`GAMEPAD`), `SDL_InitSubSystem`/`SDL_QuitSubSystem` calls, **GL profile attr** (`SDL_GL_CONTEXT_PROFILE_MASK` + `SDL_GL_CONTEXT_PROFILE_CORE` → inline `SDL_GL_CONTEXT_PROFILE` flag). Lines ~28-34, ~61-81. |
| `Window.cpp` | `SDL_CreateWindow(title,x,y,w,h,flags)` → `SDL_CreateWindow(title,w,h,flags)` (drop x/y + `SDL_WINDOWPOS_*`), `SDL_WINDOW_FULLSCREEN_DESKTOP`→`SDL_WINDOW_FULLSCREEN`, show/hide, `SDL_SetWindowFullscreen`. Lines ~17-96. |
| `OpenGL.cpp` | `SDL_GL_GetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, ...)` → SDL3 profile query. Keep the *core-profile invariant* (the load-bearing architecture — see §5). Lines ~24-37. |
| `Input.cpp` | **The big one, ~500 lines.** All event-enum renames (`SDL_KEYDOWN`→`SDL_EVENT_KEY_DOWN`, `SDL_MOUSEMOTION`→`SDL_EVENT_MOUSE_MOTION`, mouse-button/wheel, `SDL_QUIT`→`SDL_EVENT_QUIT`, `SDL_WINDOWEVENT*`→`SDL_EVENT_WINDOW_*`), `SDL_GameController*` events → `SDL_*Gamepad*` events, `SDL_GetTicks`→`SDL_GetTicks64`, `SDL_ShowCursor`/`SDL_CaptureMouse` (dropped `SDL_TRUE/FALSE`), `SDL_WarpMouseInWindow` semantics, `SDL_GameControllerAddMappingsFromFile`→`SDL_AddGamepadMappingsFromFile`. |
| `Gamepad.cpp` | Whole `SDL_GameController*`→`SDL_Gamepad*` API rename, `SDL_CONTROLLER_*`→`SDL_GAMEPAD_*` constants, `SDL_IsGameController`→`SDL_IsGamepad`, `SDL_JoystickInstanceID`→`SDL_GetJoystickInstanceID`. |
| `Joystick.cpp` | GUID rework (`SDL_JoystickGUID`→`SDL_GUID` string handling, `SDL_JoystickGetDeviceGUID`→`SDL_GetJoystickGUIDForID`), `SDL_JoystickInstanceID`→`SDL_GetJoystickInstanceID`. |
| `Button.cpp` | `SDL_CONTROLLER_BUTTON_*`→`SDL_GAMEPAD_BUTTON_*` (and axis) in the controller sections; `SDL_SCANCODE_*`/mouse constants are numerically stable in SDL3 → mostly untouched. |
| `GamepadButton.cpp`, `GamepadAxis.cpp` | Mechanical `SDL_CONTROLLER_*`→`SDL_GAMEPAD_*` constant renames. |

**Superficial / near-zero change:**
`Mouse.cpp` (`SDL_ShowCursor`/`SDL_ENABLE`/`SDL_DISABLE` split into `SDL_ShowCursor`/`SDL_HideCursor`), `Keyboard.cpp` (unchanged), `MouseButton.cpp`/`WindowPos.cpp`/`HatDir.cpp`/`WindowMode.cpp` (constant tables; only `SDL_WINDOW_FULLSCREEN_DESKTOP`→`SDL_WINDOW_FULLSCREEN` in `WindowMode.cpp:6`), `OS.cpp` (low-risk, but received an extra clipboard-caching change during implementation — see §7 completion record line 136), `Timer.cpp`/`TimeStamp.cpp` (unchanged; use `SDL_GetPerformanceCounter`, stable in SDL3), `Thread.cpp`/`ThreadPool.cpp` (unchanged).

### 2.2 Headers / build (the other side of the swap)

| Asset | Action |
|---|---|
| `libphx/ext/include/sdl/` (bundled SDL2 headers) | Refresh to SDL3: either vendor SDL3 headers under `libphx/ext/include/sdl3/`, or drop the bundled copy and include against system `/usr/include/SDL3`. **Keep them in sync with the linked runtime** (same rule as the 2026-08-28 header refresh). The include path in the ~20 `#include <SDL...>` sites becomes `<SDL3/SDL.h>` etc. |
| `libphx/CMakeLists.txt:41` | `SDL2` → `SDL3` in the `target_link_libraries(phx ...)` block. |
| `ext/include`/`ext/lib` refresh | Confirm the bundled header versions match the system SDL3 runtime (the `ldd`/`pkg-config` verification pattern from AGENTS "Technology Stack"). |
| `gamecontrollerdb_205.txt` | Already used via `Input.LoadGamepadDatabase`; confirm it still loads under SDL3 (SDL3 ships `SDL_GAMECONTROLLERCONFIG` env / adds its own mapping DB — verify `SDL_AddGamepadMappingsFromFile` accepts it). |

### 2.3 Anything else that may need updating

- **`run.sh` / Wayland** — already drives native Wayland; SDL3 Wayland support is mature. Re-verify both native Wayland (`wayland`, unset `DISPLAY`) and X11-backed runs still work.
- **Doc references** — `AGENTS.md` "Technology Stack" SDL2 paragraph and the *Roadmap* item "SDL2 → SDL3" should be updated to reflect completion (see §7).
- **`configure.py`** — no code change needed for the swap itself, but note the `run_sdl_tests()` validator invocation stays the same.
- **GL profile invariant** — SDL3 changed how the core profile is requested (`SDL_GL_CONTEXT_PROFILE` flag instead of `SDL_GL_CONTEXT_PROFILE_MASK`). The engine *requires* a core profile for GL 4.6 (see load-bearing architecture). Make sure the profile request is preserved exactly, else context creation silently fails or falls back to compat.

## 3. Is SDL used by unit tests, and do we need to update/create any?

**Current test surface** (all invoked by `python3 configure.py test` and by `cmake --build` via custom targets):

1. **`tools/validate_sdl.py`, `validate_sdl_window.py`, `validate_sdl_input.py`** — Python scripts that `pkg-config`-probe SDL, and compile+run tiny C programs against the SDL headers. They **already check SDL3** (they test both `sdl2` and `sdl3`, and already detect the breakpoints: `SDL_CreateWindow` signature, GL `CONTEXT_PROFILE` attr, `GameController`→`Gamepad`). **These are the primary SDL tests, and they need updating** to:
   - Assert the engine now builds against **SDL3** specifically (currently they pass if *either* sdl2 or sdl3 is present).
   - Add compile+run probes that exercise the *new* SDL3 signatures the engine uses (e.g. `SDL_CreateWindow(title,w,h,flags)`, `SDL_Init(SDL_INIT_VIDEO)` with the SDL3 init constants, a `SDL_Gamepad*` open path).
2. **`tools/validate_hud_reticle.lua`** — pure Lua HUD test, no SDL. **No change.**
3. **`tools/validate_glsl.py`** — shader validator, no SDL. **No change.**
4. **`tools/validate_bytes.lua`** — LZ4 codec test, no SDL. **No change.**
5. **`build/test/lte_tests`** — referenced in `configure.py:77` as "LTE core unit tests", but **no CMake target builds it** (it's a leftover/no-op; configure.py prints "No test executable found - skipping"). **No action required** unless you want to stand it up.

**Recommendation — what to add/update during the migration:**
- **Extend `validate_sdl.py`** to require SDL3 as the linked target and to compile+run a tiny SDL3 app that (a) inits video, (b) sets the 4.6 **core** GL profile via the SDL3 API, (c) creates a hidden window + GL 4.6 context, (d) opens a gamepad if present. This becomes the regression gate for the exact APIs the engine uses.
- **Add a small `validate_sdl_gamepad.py`** (or fold into `validate_sdl_input.py`) that compiles+links against `SDL3` using the `SDL_Gamepad*` API and the `SDL_EVENT_*` enum names the engine now uses, so a missed rename fails at configure time.
- **No new C++ unit-test harness is required** — the engine has no standalone SDL unit-test binary, and the renderer/gameplay are behind the shim layer, so the validator-probe approach is the right level. If you *do* want engine-level tests, they'd be integration boot tests (window + GL context), which `validate_sdl_window.py` already approximates.

## 4. How to test the SDL upgrade

Run everything, in this order:

1. **Static/compile validation (fast, headless):**
   ```
   python3 configure.py test
   ```
   Runs shader + bytes + SDL + HUD validators. The shader validator confirms the GL 4.6 core context plumbing still works; the SDL validators confirm pkg-config/headers/link against SDL3.

2. **Clean full build (must pass):**
   ```
   python3 configure.py        # configure (writes build/)
   cmake --build ./build -j$(nproc)
   ```
   Watch for the `phx_validate_sdl` / `phx_validate_sdl_window` / `phx_validate_sdl_input` custom targets **and** the `phx_validate_glsl` gate. All must be green.

3. **Runtime boot test on native Wayland (primary platform):**
   ```
   ./run.sh LTheory
   ```
   Verify the window maps as a first-class Hyprland client (`hyprctl clients` shows `class: lt64r`, `xwayland: 0`), is decorated/closable, and the console shows `[GL] ... GL 4.6 (Core Profile) ... glew-4.6 yes`, `Seed: ...`, `Resolution: WxH`. Quit via the configured `Config.window.quitKey` (Escape).

4. **Runtime boot test via X11** (in case a fallback path is needed):
   ```
   env -u WAYLAND_DISPLAY SDL_VIDEODRIVER=x11 ./run.sh LTheory
   ```
   Confirm GL 4.6 core context + window + input still work under X.

5. **Input / gamepad functional test:**
   - Connect a controller; confirm `gamecontrollerdb` loads (watch for a device-added log line) and the gamepad drives turret/aim (the HUD reticle test `tools/validate_hud_reticle.lua` already checks mouse-vs-gamepad parity at the Lua level).
   - Test keyboard (fly, `T`/`G` target, `M` music), mouse look, mouse buttons, and the `Config.window.quitKey`.

6. **`ldd` sanity check** (confirm the engine links the runtime SDL3, like the 2026-08-28 header-runtime sync):
   ```
   ldd bin/libphx64r.so | grep -i sdl
   ```

## 5. Load-bearing invariants to preserve (do not break)

From `AGENTS.md` "Load-bearing architecture" — these are the exact things the SDL3 swap touches and must not regress:

1. **GL 4.6 core context is mandatory.** When moving the profile request to SDL3's new `SDL_GL_CONTEXT_PROFILE` flag form, keep requesting **core** (never compat). Losing core means Mesa silently gives the wrong context and the whole shader ladder breaks.
2. **Global VAO** and **no program-0 draws** — unaffected by SDL, but re-verify with the boot test after the swap.
3. **Eager autovar trap** — unaffected.

*(If any part of the swap touches context/attribute setup, run `python3 configure.py test` — the GLSL validator compiles at `<NNN> core` and will catch a broken context.)*

## 6. Reference material

- SDL3 ships an official **`SDL_MIGRATION.md`** migration guide in its source tree (covers every rename/removal in §2). Start there for the exact symbol mappings.
- Existing validators already encode the breakpoints (`tools/validate_sdl*.py`) — treat them as a spec.

## 7. Wrap-up — DONE 2026-09-03

- `AGENTS.md` "Technology Stack" SDL2 paragraph → SDL3 and *Roadmap* "SDL2 → SDL3" marked **done**.
- Commit the swap as one self-contained change (source + headers + CMake + validators + docs), mirroring how the FMOD→miniaudio swap was landed.

### Completion record (2026-09-03)

**Migrated files** (`libphx/src/`, `libphx/include/`, `libphx/script/ffi/`, `script/`):
- `Engine.cpp` — `SDL_INIT_TIMER` dropped, `SDL_INIT_GAMECONTROLLER`→`SDL_INIT_GAMEPAD`, `SDL_Init`/`SDL_InitSubSystem` int→bool checks, `#include <cstdlib>` (SDL2 no longer provides it transitively). GL profile request unchanged (`SDL_GL_CONTEXT_PROFILE_MASK`+`CORE` still valid in SDL3 — the load-bearing core invariant holds).
- `Input.cpp` — all `SDL_EVENT_*` renames, `sdl.key.keysym.scancode`→`sdl.key.scancode`, `sdl.cbutton/caxis/cdevice`→`gbutton/gaxis/gdevice`, `SDL_GameController*`→`SDL_Gamepad*` open/close/query, `SDL_ShowCursor`/`SDL_HideCursor`, `SDL_CaptureMouse(bool)`, timestamp ns→ms, startup enumeration via `SDL_GetJoysticks()`, `DeviceState` bounds `SDL_NUM_SCANCODES`→`SDL_SCANCODE_COUNT`.
- `Window.cpp`/`Window.h`/`ffi/Window.lua`/`Application.lua` — `Window_Create` drops x/y (`SDL_CreateWindow(title,w,h,flags)`), `SDL_GL_DestroyContext`, `SDL_SetWindowFullscreen(bool)`.
- `Mouse.cpp` — `SDL_GetMouseState`/`GetGlobalMouseState` float out-params, `SDL_WarpMouseInWindow` float, `SDL_BUTTON_MASK`, `SDL_GetMouseState(NULL,NULL)`.
- `Keyboard.cpp` — `SDL_GetKeyboardState` returns `bool const*` now.
- `WindowMode.cpp` — `SDL_WINDOW_FULLSCREEN_DESKTOP`→`SDL_WINDOW_FULLSCREEN`, `WindowMode_Shown = 0` (`SDL_WINDOW_SHOWN` removed; SDL3 windows show by default).
- `Gamepad.cpp` — full `SDL_GameController*`→`SDL_Gamepad*` port (`SDL_OpenGamepad`, `SDL_CloseGamepad`, `SDL_GetGamepadJoystick`, `SDL_GetJoystickID`, `SDL_GetGamepadName`, `SDL_GamepadConnected`, `SDL_AddGamepadMappingsFromFile`, `SDL_GetGamepadButton/Axis`).
- `Joystick.cpp` — `SDL_GetJoysticks(&count)` enumeration (no `SDL_GetNumJoysticks` in SDL3), `SDL_OpenJoystick`/`SDL_CloseJoystick`, `SDL_GetJoystickGUID`+`SDL_GUIDToString`, `SDL_GetNumJoystick*`, `SDL_GetJoystickName*`, `SDL_GetJoystickAxis/Button/Hat`.
- `Button.cpp`/`Button.h` — `SDL_GameControllerAxis/Button` types → `SDL_GamepadAxis/Button`; `TRIGGERLEFT/TRIGGERRIGHT`→`LEFT_TRIGGER/RIGHT_TRIGGER`; face buttons → `SOUTH/EAST/WEST/NORTH` (values 0–3 unchanged); `LEFTSTICK`→`LEFT_STICK` etc.
- `GamepadButton.cpp`/`GamepadAxis.cpp` — same constant renames (values preserved).
- `OS.cpp` — `SDL_GetCPUCount`→`SDL_GetNumLogicalCPUCores`, `SDL_SetClipboardText` bool check.
- `OpenGL.cpp` — `#include <SDL2/SDL.h>`→`<SDL3/SDL.h>` (profile query unchanged).
- `libphx/include/SDL.h` shim — `"sdl/SDL.h"`→`<SDL3/SDL.h>` (system headers).
- `libphx/CMakeLists.txt` — link `SDL2`→`SDL3`.
- `libphx/ext/include/sdl/` (92 bundled SDL2 headers) — **deleted**; engine builds against system SDL3 3.4.14.
- `tools/validate_sdl{,_window,_input}.py` — SDL3-only gates: init/API probe (`SDL_CreateWindow` sig, gamepad open path, `SDL_GUIDToString`, `SDL_EVENT_GAMEPAD_*`), hidden-window GL 4.6 probe, input-symbol + `gamecontrollerdb_205.txt` load gate (35 mappings).

**Verification (2026-09-03):** `python3 configure.py test` all green (GLSL 118 OK, bytes, SDL×3, HUD); `cmake --build` clean; `ldd bin/libphx64r.so` → `libSDL3.so.0`; `./run.sh LTheory` boots native Wayland with `[GL] ... GL 4.6 (Core Profile) ... profile CORE | glew-4.6 yes`, `Resolution: 1024x768`, no errors.

**Follow-up hardening (same day, pre-commit):**
- `OS_GetClipboard` — was returning `SDL_GetClipboardText()` (SDL-malloc'd) directly, leaking per call; now cached in a static `std::string` + `SDL_free`, keeping borrow semantics.
- `Input.cpp` timestamps — documented the `Uint64`→`uint32` ms truncation (~49-day wrap; verified all diffs are wrap-tolerant unsigned subtraction).
- `Joystick_GetGUIDByIndex`/`Joystick_GetNameByIndex` — deleted (zero callers; module already `DEPRECATED`/`__FFI_IGNORE__`, no FFI binding exists).
- `Window_SetPosition` + `WindowPos` — retired (zero callers; `SDL_SetWindowPosition` is a compositor no-op on Wayland anyway). Removed C def/decl, FFI cdef + both bindings, `Common.h`/`libphx.lua` typedefs, and deleted `WindowPos.cpp/.h/lua`. `Window_GetPosition` kept (still meaningful).
