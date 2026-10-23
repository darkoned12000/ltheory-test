-- Displays -- what the monitor can do, asked straight from SDL3.
--
-- The engine's `Window` API speaks window sizes, but nothing in libphx
-- exposes the MONITOR: its native resolution and the modes it supports.
-- The SETTINGS screen needs both (a resolution list to offer, and a
-- sensible default to open at), and this is the thin bridge: a handful of
-- `ffi.load('SDL3')` calls, read-only, with the struct layouts matching the
-- system headers this engine builds against (SDL3 3.4.14).
--
-- STRUCT LAYOUTS: only the head of SDL_DisplayMode is needed -- `format`
-- then two ints, w and h -- and those three fields are first, so the
-- partial cdef below is ABI-exact for reading w/h.

local Displays = {}

local SDL = nil
-- Loaded once, then cached; libphx already links SDL3, so both the library
-- and the symbols exist in every process that runs an app.
local function sdl ()
  if not SDL then
    ffi.cdef [[
      typedef int32_t SDL_DisplayID;
      typedef struct SDL_DisplayMode {
        /* SDL_DisplayID (a Uint32) comes FIRST in SDL3's struct -- without
           it the width reads the pixel-format enum (370546692x2560, seen in
           the wild). */
        uint32_t displayID;
        uint32_t format;
        int32_t  w;
        int32_t  h;
        float    pixel_density;
        float    refresh_rate;
        int32_t  refresh_rate_numerator;
        int32_t  refresh_rate_denominator;
        void*    driverdata;
      } SDL_DisplayMode;
      SDL_DisplayID          SDL_GetPrimaryDisplay        ();
      const SDL_DisplayMode* SDL_GetDesktopDisplayMode    (SDL_DisplayID id);
      SDL_DisplayMode**      SDL_GetFullscreenDisplayModes(SDL_DisplayID id, int* count);
      void                   SDL_free                     (void* p);
    ]]
    SDL = ffi.load('SDL3')
  end
  return SDL
end

-- The desktop's resolution: the monitor's native size, NOT whatever size
-- the game window happens to be. Returns w, h, or nil if SDL has no
-- answer (headless sessions can legitimately not have a display).
function Displays.Desktop ()
  local s = sdl()
  local id = s.SDL_GetPrimaryDisplay()
  if id == 0 then return nil end
  local mode = s.SDL_GetDesktopDisplayMode(id)
  if mode == nil or mode.w <= 0 or mode.h <= 0 then return nil end
  return tonumber(mode.w), tonumber(mode.h)
end

-- Every fullscreen mode the primary display supports, as {w = , h = , hz = }
-- tables sorted by pixel height, tallest last. Duplicate heights are kept
-- (same height, different width happens on odd panels) but exact w/h
-- duplicates are dropped: a resolution menu lists RESOLUTIONS, not modes.
function Displays.Modes ()
  local s = sdl()
  local id = s.SDL_GetPrimaryDisplay()
  if id == 0 then return {} end
  local count = ffi.new('int[1]')
  local modes = s.SDL_GetFullscreenDisplayModes(id, count)
  local out = {}
  if modes ~= nil then
    local seen = {}
    for i = 0, count[0] - 1 do
      local m = modes[i]
      local w, h = tonumber(m.w), tonumber(m.h)
      local key = w .. 'x' .. h
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = {
          w  = w,
          h  = h,
          hz = tonumber(m.refresh_rate) or 0,
        }
      end
    end
    s.SDL_free(modes)
  end
  table.sort(out, function (a, b)
    if a.h ~= b.h then return a.h < b.h end
    if a.w ~= b.w then return a.w < b.w end
    return (a.hz or 0) < (b.hz or 0)
  end)
  return out
end

return Displays
