# Save / Load — phase 1 (save slots)

**Date:** 2026-10-23 · branch `startui`
**Inputs:** the old engine's `SaveGame{,JSON}` design (user's
`Load-Save/` folder: `SAVE-LOAD-AND-INVENTORY.md`, `SaveGameJSON.cpp`).

## The one idea

**The world is not saved.** Phoenix worlds regenerate deterministically
from a 64-bit seed — that is what a seed is *for* — so a save carries the
seed and the player, nothing more:

* `seedHex` — the seed as an exact 16-character hex string. It must never
  be a JSON number: a double holds 53 bits and the seed is 64 (`Json.lua`
  documents the trap; `seedFromHex` in `App/LTheory.lua` is the one place
  a hex string becomes a seed).
* the player snapshot — position, velocity, heading quaternion, hull
  (`health/healthMax/healthRate`), credits, and cargo as
  `{item = <Item name>, count}` rows.

LOAD regenerates the galaxy from the seed (the same `generate()` path a
NEW GAME runs), then `SaveGame.Restore` puts the snapshot back into the
fresh ship. Nothing else can drift: station markets, belts, sectors and
gates all come back from generation. The GUI warms up through
`LTheory:settleAfterGenerate` (extracted from `newGame` so both paths keep
the same invariants: camera re-seat, node-graph follow, screens closed
silently so the world is not left paused).

## Files

| file | role |
|---|---|
| `script/Game/Json.lua` | minimal JSON encode/decode; decode errors are **values** (`nil, msg`), so a corrupt save degrades instead of crashing the boot |
| `script/Game/SaveGame.lua` | the slot layer + snapshot capture/restore + thumbnails |
| `script/App/LTheory.lua` | `saveGameNow`/`loadGame`, the SAVE/LOAD popup pages, F6/F7 quicksave/quickload, `settleAfterGenerate` |

## The slot layer (ported from `SaveGameJSON.cpp`)

* Every save is a standalone `./saves/<slot>.json`.
* Slot names are sanitised (no `/ \ : .`, control characters stripped):
  a slot name is a file name the player typed, and `..` must not walk out
  of the directory.
* **10 slots max** (the player asked for 5-10 while the LOAD page is
  young), quicksaves included; a NEW slot beyond the cap is refused,
  overwriting an existing slot never is.
* Each SAVE accumulates into its own timestamped slot
  (`save-YYYYMMDD-HHMMSS`, `-2`/`-3` disambiguation when two land in the
  same second) — the old quicksave rule, kept.
* **QUICK SAVE (F6) / QUICK LOAD (F7)** — the old game's keys. F6 is
  ACCUMULATING: every press lands in its own timestamped
  `quicksave-…` slot (a rolling single slot made "multiple saves"
  impossible from the keyboard). F7 loads the NEWEST save of any kind.
  The map's layer filters moved to F1-F4 to free the keys.
* **DELETE**: every LOAD row has a DEL button (json + thumbnail both);
  with the cap small, that is the way out when the list fills.
* **Scrollbar**: the LOAD list scrolls in a fixed-height ScrollView;
  CLOSE is a footer under it, never inside the scroll.
* **Thumbnails**: the game banks a working shot every time the menu
  opens from live play, and a save copies it next to its JSON
  (`<slot>.png`). The capture reads the post chain's final compose
  (`renderer.buffer0`) — the last completed frame, HUD included — NOT
  the default framebuffer (a `Tex2D.ScreenCapture` outside the draw
  phase aborts on an empty viewport stack, and a default-framebuffer
  readback is exactly what F12's intermittent "vertical lines" come
  from; `Tex2D_ScreenCapture` now pins `glReadBuffer(GL_BACK)` and
  fences with `glFinish`). The 4K compose is box-filtered down to
  ~256 px wide on the CPU (LuaJIT, ~50 ms, one-shot at menu-open).
* `ListSlots` reads every file newest-first and **skips** what it cannot
  read (corrupt or foreign-version); the LOAD page only ever offers what
  it can actually load.
* File access is the engine's `ffi.File` API (same as the SETTINGS
  screen's `Config.Settings.lua` write); listing is `ffi.Directory`
  (`GetNext` yields a raw cstr — `ffi.string` it, the house pattern);
  deletion is `os.remove` (no engine file-delete exists;
  `Directory_Remove` is an rmdir).

## The JSON codec

LuaJIT has none and libphx exposes none. `Json.lua` is the smallest
honest pair:

* tables encode as arrays when they hold a `1..#v` sequence, objects
  otherwise;
* numbers go out as integers when a double holds them exactly, else as
  Lua's `tostring`, which round-trips a double;
* `\uXXXX` decodes to a placeholder beyond the BMP (saves are ASCII;
  LuaJIT is Lua 5.1 with no utf8 library);
* `Decode` returns `nil, message` at the first bad byte with a position.

## The UI

* SAVE page: the live location line (`Sector: … · Region: … · N credits`,
  read fresh on every open), `SAVE NEW SLOT`, a status line ("Saved as
  '…'"), CLOSE.
* LOAD page: one row per slot — the **thumbnail** (the game as it looked
  when saved; old slots without one just omit the image), `slot · date`,
  `Sector: … · Region: …`, `Credits: N · seed HEX`, and a LOAD button.
  The list is rebuilt **on open** (the framework's deferred
  `add`/`remove`); the row textures are owned by the page and freed on
  each rebuild.

## Verification (headless, done)

1. **Roundtrip in one process** (`PHX_SAVENOW` dev hook): capture →
   write slot → teleport ship +50k → load same slot →
   position/credits/cargo back exactly (Silver ×42, 1234 credits).
   The hook cleans up its slot.
2. **Cold load in a second process** (`PHX_LOADNOW`): the second boot
   reads what the first wrote; same seed hex, same position.
3. **Real clicks** (temp SDL click-injection probe, since removed): SAVE
   page button wrote a slot; LOAD page listed it and a click on the row
   reloaded the world and closed the screen (`anyScreenOpen` false).

## Not in (yet)

World state that DEVIATES from the seed — market prices, mine-out
asteroids, missions — needs a universe whose spoken history lives
somewhere before it can be saved. Phase 2 saves a *delta over the seed*.
The old `Load-Save/SAVE-LOAD-AND-INVENTORY.md` roadmap phases (inventory
UI, mining wiring, loot pods) map onto this codebase as separate items —
the snapshot fields (`items`, credits) are already in the schema, waiting.

## The asteroid-field budget (same-day companion fix)

Play-testing hit the FPS wall that motivated this doc's neighbor item:
radius hysteresis cannot bound cost, because a long flight loads a
load-radius TUBE along the whole path and the unload ring only drops what
is well behind the ship (measured in one session: 4370 → 6588 chunks,
8151 → 16887 rocks). The field now carries `maxChunks`
(`gen.asteroidField.maxChunks`, default 4600, tunable live in
Debug > Asteroid Field): past the budget it evicts the FARTHEST chunks
first, never one still inside the load radius, so visible rocks cannot
pop out and regeneration from the seed puts an evicted chunk back
identically on the way back. Verified: one 50k jump → `+8500/-4135 →
4600 chunks`, count clamped, rock count bounded at boot level.
