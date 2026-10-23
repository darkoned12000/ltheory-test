--[[ SaveGame -- save slots: the player snapshot plus the world seed.

  PORTED AS A DESIGN from ltheory-old's Game/SaveGame{,JSON} (the user's
  saved Lua-/C++ sources in /Load-Save). The shape of a save is the same
  insight that made the old one small: THE WORLD IS NOT SAVED. This
  engine's worlds regenerate deterministically from a 64-bit seed -- that
  is what a seed is FOR (App/LTheory.lua's generate()) -- so a save
  carries the seed and the PLAYER: position, velocity, heading, hull,
  credits and cargo. The station markets, the sectors and the belts all
  come back from generation exactly as they were; nothing else is
  tracked, and nothing else can drift.

  THE SLOT LAYER mirrors the old C++ (SaveGameJSON.cpp) closely:
    * every slot is a standalone JSON file at ./saves/<slot>.json;
    * slot names are sanitized (no separators, no dots) so a name cannot
      escape the saves dir;
    * 10 slots max (the player asked for 5-10 while the LOAD page is
      young), quicksaves included; a NEW slot beyond the cap is refused,
      overwriting an existing slot never is;
    * each SAVE accumulates into its own timestamped slot rather than
      overwriting the previous one ("save-YYYYMMDD-HHMMSS");
    * slot listing reads each file (foreign/corrupt files are skipped,
      not fatal) so the LOAD page can show what is actually there.

  THE SEED IS A HEX STRING (`seedHex`), never a JSON number: a double
  holds 53 bits, and the seed is 64 -- see Json.lua and seedFromHex in
  LTheory.lua. The LOAD path feeds that hex string back through the very
  same parser the CUSTOM GAME field uses, so there is exactly one place
  where a seed hex becomes a seed.

  FILE ACCESS is the engine's File API (like the SETTINGS screen's
  Config.Settings.lua write): runtime code cannot count on io.* beyond
  what Main.lua's boot uses, and File.ReadCstr/WriteStr round-trip text
  cleanly. Deletion has no engine call (Directory_Remove is an rmdir),
  so it uses os.remove -- os is global in the app env (DebugWindow
  already uses os.date the same way).
]]

local File = require('ffi.File')
local Directory = require('ffi.Directory')
local Tex2D = require('ffi.Tex2D')
local Json = require('Game.Json')
local Item = require('Game.Item')

local SaveGame = {}

local SAVE_VERSION = 2
local SLOTS_DIR    = './saves/'
local SAVE_EXT     = '.json'
-- The player's ask: "5-10 saves for now" -- 10 it is. Raise when the
-- LOAD page grows pagination or a delete affordance.
local MAX_SLOTS    = 10

-- The THUMBNAIL: the game captures a working shot of the last CLEAN
-- gameplay frame (no menu over it) every time the menu opens from live
-- play, and a save copies that file next to its JSON. The LOAD page then
-- shows what the save actually looks like.
local THUMB_W      = 256
local WORK_SHOT    = './saves/_latest.png'

-- ---------------------------------------------------------------------------
-- Items: the cargo is keyed by Item instances at runtime, but a save file
-- can only hold NAMES. Item.All() is the item database: every Item ever
-- constructed (Content.lua builds the game's set at boot), and a name is
-- the natural ID for one.
-- ---------------------------------------------------------------------------

local function itemByName (name)
  for _, item in ipairs(Item.All()) do
    if item:getName() == name then return item end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Capture / restore: the snapshot lives in plain Lua tables with plain
-- numbers, so JSON is just a format for it and nothing FFI leaks through.
-- ---------------------------------------------------------------------------

local function vec3 (v)
  if not v then return nil end
  return {x = tonumber(v.x), y = tonumber(v.y), z = tonumber(v.z)}
end

-- The state a save carries about the player's ship. `ship` may be nil
-- (saved from the menu before the ship exists... it cannot: the world is
-- live behind the menu, but a dead ship's save must be refused by the
-- caller, not silently dropped here).
function SaveGame.Capture (ship, meta)
  local data = {
    saveVersion   = SAVE_VERSION,
    dateCreated   = false, -- stamped by SaveGame.Write
    saveName      = meta and meta.saveName or '',
    description   = meta and meta.description or '',
    playerName    = meta and meta.playerName or 'Player',
    systemName    = meta and meta.systemName or '',
    regionName    = meta and meta.regionName or '',
    seedHex       = meta and meta.seedHex or '',
  }
  if ship ~= nil then
    data.playerPos  = vec3(ship:getPos())
    data.playerVel  = vec3(ship:getVelocity())
    local rot = ship:getRot()
    data.playerRot = {x = tonumber(rot.x), y = tonumber(rot.y),
                      z = tonumber(rot.z), w = tonumber(rot.w)}
    if ship:hasHealth() then
      data.shipHealth    = tonumber(ship.health)
      data.shipHealthMax = tonumber(ship.healthMax)
      data.shipHealthRate = tonumber(ship.healthRate)
    end
    data.playerCredits = ship:getCredits()
    if ship:hasInventory() then
      local items = {}
      for item, count in pairs(ship:getInventory()) do
        items[#items + 1] = {item = item:getName(), count = count}
      end
      -- A save dumps its cargo named and ordered, so loading one puts the
      -- SAME rows back the same way every time.
      table.sort(items, function (a, b) return a.item < b.item end)
      data.items = items
    end
  end
  return data
end

-- Put the snapshot INTO a freshly generated ship: pos, velocity, heading,
-- hull, credits, cargo. Setters only (the fresh ship's other components --
-- thrusters, turrets, mass -- are regenerated identical to the saved
-- one's, being proto + seed driven).
function SaveGame.Restore (ship, data)
  if ship == nil or data == nil then return end
  if data.playerPos then
    ship:setPos(Vec3f(data.playerPos.x, data.playerPos.y, data.playerPos.z))
  end
  if data.playerVel then
    ship:setVelocity(Vec3f(data.playerVel.x, data.playerVel.y, data.playerVel.z))
  end
  -- A zero quaternion is a corrupt save, not a heading: leave the fresh
  -- spawn's identity rotation rather than setting a degenerate one.
  local r = data.playerRot
  if r and (r.x ~= 0 or r.y ~= 0 or r.z ~= 0 or r.w ~= 0) then
    ship:setRot(Quat(r.x, r.y, r.z, r.w))
  end
  -- Inside the fountain: hull first (a dead-ship save refuses at the
  -- caller), then credits and cargo.
  if ship:hasHealth() and data.shipHealth then
    ship:setHealth(data.shipHealth, data.shipHealthMax or ship.healthMax,
                   data.shipHealthRate or ship.healthRate)
  end
  if data.playerCredits and data.playerCredits > 0 then
    ship:addCredits(data.playerCredits)
  end
  if data.items then
    for _, entry in ipairs(data.items) do
      local item = itemByName(entry.item)
      if item and entry.count and entry.count > 0 then
        ship:addItem(item, entry.count)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Slot paths and names
-- ---------------------------------------------------------------------------

-- Strip path separators, dots and control characters: a slot name is a
-- FILE NAME the player chose with a keyboard, and '.' would let "." or
-- ".." walk out of the saves dir.
local function sanitize (name)
  local clean = (name or ''):gsub('[%.%c/\\:]', '')
  if #clean == 0 then clean = 'save' end
  return clean:sub(1, 80)
end

local function slotPath (name)
  return SLOTS_DIR .. sanitize(name) .. SAVE_EXT
end

-- The slot's thumbnail rides next to its JSON with the same sanitized
-- name. `sanitize` is local to the slot naming, so the path builder is
-- here and exported below alongside the slot functions.
local function thumbPath (name)
  return SLOTS_DIR .. sanitize(name) .. '.png'
end

local function ensureDir ()
  Directory.Create(SLOTS_DIR)
end

-- ---------------------------------------------------------------------------
-- The thumbnail.
--
-- `Tex2D.ScreenCapture` grabs the whole framebuffer (window-sized), and a
-- save wants a SMALL image the LOAD page can show per row -- a 4K window's
-- full PNG is ~15 MB, so the capture is downscaled to ~256 px wide before
-- it is written. The engine has no GPU-downscale-on-demand helper exposed
-- to the app, but it HAS pixel readback (`getDataBytes`), and a LuaJIT box
-- filter over the readback is a one-shot ~50 ms at menu-open time: nobody
-- is flying during it.
-- ---------------------------------------------------------------------------

-- Average the source image down to dw x dh, FLIPPING while it goes: a GL
-- texture's data rows run bottom-up (FBO origin), so passing the readback
-- straight through produced upside-down thumbnails (the user's report:
-- the HUD's top-left sector readout appeared bottom-left). With flip on,
-- output row y is built from source row sh-1-y, so the output runs
-- top-down like the image it represents.
local function downscaleRGBA (src, sw, sh, dw, dh, flip)
  local out = ffi.new('uint8_t[?]', dw * dh * 4)
  local fx, fy = sw / dw, sh / dh
  local floor = math.floor
  for oy = 0, dh - 1 do
    local y0 = floor(oy * fy)
    local y1 = math.max(y0 + 1, floor((oy + 1) * fy))
    for ox = 0, dw - 1 do
      local x0 = floor(ox * fx)
      local x1 = math.max(x0 + 1, floor((ox + 1) * fx))
      local r, g, b, a, n = 0, 0, 0, 0, 0
      for y = y0, y1 - 1 do
        local row = (flip and (sh - 1 - y) or y) * sw
        for x = x0, x1 - 1 do
          local i = (row + x) * 4
          r, g, b, a, n = r + src[i], g + src[i + 1], b + src[i + 2], a + src[i + 3], n + 1
        end
      end
      local o = (oy * dw + ox) * 4
      out[o], out[o + 1], out[o + 2], out[o + 3] = r / n, g / n, b / n, a / n
    end
  end
  return out
end

-- A working shot of the last fully RENDERED frame: the post chain's final
-- compose (`renderer.buffer0` after a frame -- scene, HUD and UI overlay
-- already over it). Saving the TEXTURE needs no viewport stack (the default
-- framebuffer readback aborts on an empty one, which is exactly where
-- captures outside the draw phase land), and it races nothing: glGetTexImage
-- reads whatever the last completed frame wrote. The app calls this when
-- the menu opens from live play; the next SAVE copies the file next to the
-- slot's JSON.
function SaveGame.CaptureWorkingShot (renderer)
  local ok, err = pcall(function ()
    ensureDir()
    local big = renderer.buffer0
    local size = big:getSize() -- NOTE : returns a Vec2i (see ffiext/Tex2D.lua).
    -- Keep the window's aspect; fix only the width.
    local dw = THUMB_W
    local dh = math.max(1, math.floor(size.y * dw / size.x + 0.5))
    local src = big:getDataBytes(PixelFormat.RGBA, DataFormat.U8)
    -- getData() is a void*; the filter needs byte-sized indexing. The
    -- readback runs bottom-up, so the filter flips (see downscaleRGBA).
    local small = downscaleRGBA(ffi.cast('uint8_t*', src:getData()),
      size.x, size.y, dw, dh, true)
    src:free()
    local tex = Tex2D.Create(dw, dh, TexFormat.RGBA8)
    local bytes = Bytes.Create(dw * dh * 4)
    ffi.copy(bytes:getData(), small, dw * dh * 4)
    tex:setDataBytes(bytes, PixelFormat.RGBA, DataFormat.U8)
    tex:save(WORK_SHOT)
    tex:free()
    bytes:free()
  end)
  if not ok then
    Log.Warning('SAVE: thumbnail capture failed (%s)', tostring(err))
  end
end

-- Copy the working shot next to a saved slot's JSON.
function SaveGame.SaveThumbnail (slotName)
  if not File.Exists(WORK_SHOT) then return false end
  local src = File.ReadBytes(WORK_SHOT)
  if not src then return false end
  local ok = pcall(function ()
    ensureDir()
    local f = File.Create(thumbPath(slotName))
    f:write(src:getData(), src:getSize())
    f:close()
  end)
  src:free()
  return ok
end

function SaveGame.ThumbnailPath (slotName)
  local path = thumbPath(slotName)
  return File.Exists(path) and path or nil
end

-- THE TOAST ROWS for a slot's data: the old game's quicksave
-- notification fields (the user's mock: date, player, position,
-- credits, inventory, seed) plus the sector/region line. Shared by the
-- save and load toasts, so the two sides of a slot say the same things.
function SaveGame.ToastRows (data, note)
  local rows = {
    { label = 'Date',   value = data.dateCreated or '?' },
    { label = 'Player', value = data.playerName or 'Player' },
  }
  local pos = data.playerPos
  if pos then
    rows[#rows + 1] = { label = 'Position',
      value = string.format('%.0f, %.0f, %.0f', pos.x, pos.y, pos.z) }
  end
  rows[#rows + 1] = { label = 'Credits', value = tostring(data.playerCredits or 0) }
  local inv = {}
  if data.items then
    for _, it in ipairs(data.items) do
      inv[#inv + 1] = string.format('%s x%d', it.item, it.count)
    end
  end
  rows[#rows + 1] = { label = 'Inventory',
    value = #inv > 0 and table.concat(inv, ', ') or '(empty)' }
  rows[#rows + 1] = { label = 'Seed', value = data.seedHex or '?' }
  if (data.systemName or '') ~= '' then
    rows[#rows + 1] = { label = 'Place',
      value = data.systemName ..
        ((data.regionName or '') ~= '' and (' · ' .. data.regionName) or '') }
  end
  if note then rows[#rows + 1] = { note = note } end
  return rows
end

-- ---------------------------------------------------------------------------
-- Reading and writing
-- ---------------------------------------------------------------------------

-- Reads one slot. Returns data or nil, reason -- a MISSING file, a corrupt
-- file and a foreign-version file all degrade to "no such save", because
-- from the player's chair they are the same situation.
function SaveGame.Read (slotName)
  local path = slotPath(slotName)
  if not File.Exists(path) then return nil, 'no such save' end
  local okFile, contents = pcall(File.Read, path)
  if not okFile or contents == nil then return nil, tostring(contents) end
  local ok, data = pcall(Json.Decode, contents)
  if not ok then return nil, 'unreadable save: ' .. tostring(data) end
  if type(data) ~= 'table' or data.saveVersion ~= SAVE_VERSION then
    return nil, 'unsupported save version'
  end
  return data
end

-- Writes one slot; returns the sanitized slot name, or nil, reason.
function SaveGame.Write (slotName, data)
  local clean = sanitize(slotName)
  -- The cap applies to NEW slots only; overwriting an existing one is
  -- always allowed (a full list must not make a RE-save of a row fail).
  local exists = File.Exists(slotPath(clean))
  if not exists and SaveGame.Count() >= MAX_SLOTS then
    return nil, string.format('all %d save slots are used', MAX_SLOTS)
  end
  if not data.dateCreated then
    -- os.date is the same call DumpSettings uses; saves want the local
    -- wall clock, human-readable, and nothing depends on its format.
    data.dateCreated = os.date('%Y-%m-%d %H:%M:%S')
  end
  data.saveVersion = SAVE_VERSION
  local ok, err = pcall(function ()
    ensureDir()
    local f = File.Create(slotPath(clean))
    f:writeStr(Json.Encode(data))
    f:close()
  end)
  if not ok then return nil, 'write failed: ' .. tostring(err) end
  return clean
end

-- THE QUICKSAVE RULE, kept from the old layer: every save accumulates
-- into its own timestamped slot instead of overwriting the previous one.
-- TWO SAVES IN THE SAME SECOND would have collided on the same name and
-- silently overwritten (a fast double-click on SAVE NEW SLOT looked
-- exactly like "the game only keeps one save"): -2, -3, ... disambiguate.
-- `base` is the name prefix; the scan is shared by the menu's save (save-…)
-- and the F6 quicksave (quicksave-…).
function SaveGame.UnusedSlotName (base)
  local name = base
  local n = 2
  while File.Exists(slotPath(name)) and n < 100 do
    name = base .. '-' .. n
    n = n + 1
  end
  return name
end

function SaveGame.DefaultSlotName ()
  return SaveGame.UnusedSlotName('save-' .. os.date('%Y%m%d-%H%M%S'))
end

-- ---------------------------------------------------------------------------
-- The slot list
-- ---------------------------------------------------------------------------

local function listSlotNames ()
  ensureDir()
  local dir = Directory.Open(SLOTS_DIR)
  if not dir then return {} end
  local names = {}
  while true do
    -- Directory:GetNext yields a raw cstr (see ffiext/Directory.lua's
    -- walkDirectory for the house pattern): nil at the end, ffi.string
    -- to bring the names across.
    local entry = dir:getNext()
    if entry == nil then break end
    local name = ffi.string(entry)
    if #name > #SAVE_EXT and name:sub(-#SAVE_EXT) == SAVE_EXT then
      names[#names + 1] = name:sub(1, #name - #SAVE_EXT)
    end
  end
  dir:close()
  table.sort(names, function (a, b) return a > b end) -- newest first
  return names
end

-- The LOAD page's data: every valid slot, newest first. Skips (does not
-- hard-fail on) files it cannot read -- a crashed save should not take
-- the menu with it.
function SaveGame.ListSlots ()
  local slots = {}
  for _, name in ipairs(listSlotNames()) do
    local data, why = SaveGame.Read(name)
    if data then
      slots[#slots + 1] = {
        slotName    = name,
        dateCreated = data.dateCreated or '?',
        saveName    = data.saveName or name,
        playerName  = data.playerName or '?',
        systemName  = data.systemName or '',
        regionName  = data.regionName or '',
        credits     = data.playerCredits or 0,
        seedHex     = data.seedHex or '',
        pos         = data.playerPos,
        thumb       = SaveGame.ThumbnailPath(name),
      }
    else
      Log.Warning('SAVE: skipping unreadable slot %s (%s)', name, tostring(why))
    end
  end
  return slots
end

-- The newest slot by dateCreated (the string format sorts lexically).
function SaveGame.ReadLatest ()
  local latest = nil
  for _, info in ipairs(SaveGame.ListSlots()) do
    if latest == nil or info.dateCreated > latest.dateCreated then
      latest = info
    end
  end
  return latest
end

function SaveGame.Count ()
  return #listSlotNames()
end

function SaveGame.Exists (slotName)
  return File.Exists(slotPath(slotName))
end

function SaveGame.Delete (slotName)
  local path = slotPath(slotName)
  if not File.Exists(path) then return false end
  local thumb = thumbPath(slotName)
  if File.Exists(thumb) then os.remove(thumb) end
  return os.remove(path) ~= nil
end

-- The name of the UI-level file, for the docs and the HELP page.
SaveGame.SLOTS_DIR = SLOTS_DIR
SaveGame.MAX_SLOTS = MAX_SLOTS

-- The item resolver, exported for the LOAD-side tests.
SaveGame.ItemByName = itemByName
SaveGame.Sanitize   = sanitize

return SaveGame
