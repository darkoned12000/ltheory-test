-- NebulaVolumes -- deterministic per-cell plume records (fog-nebula Phase 2).
-- Bounded, CPU-culled anchor generator with dual-tone color gradients and
-- non-uniform ellipsoid extent stretching.

local NebulaVolumes = {}

local CELL = 12000      -- world lattice pitch (plume spacing)
local MAXV = 16         -- bounded uniform list (texAnchors height)

-- 32-bit integer hash: deterministic and free from float precision loss.
-- Returns [0,1): LuaJIT bitops are signed, so a raw /2^32 can go negative for
-- half the inputs (plumes clumping at cell corners) — the mod folds it back.
-- Must stay in sync with the copies in LightningStorm.lua / LightningBolt.lua.
local function hash32 (x, y, z, seed, k)
  local h = (x * 374761393 + y * 668265263 + z * 224682251 + seed * 3266489917 + k * 2654435761) & 0xFFFFFFFF
  h = ((h ~ (h >> 13)) * 1274126177) & 0xFFFFFFFF
  h = (h ~ (h >> 16)) & 0xFFFFFFFF
  return (h % 4294967296) / 4294967296.0
end

local function foldSeed (seed)
  -- Sector seeds are 64-bit ULL, but doubles only hold 53-bit integers: the
  -- raw value's low bits are mush and seed*K rounds to a quantum that swallows
  -- every small cell/k term, so hash32 returns ONE constant for all inputs
  -- (identical plumes on a perfect lattice). XOR both 32-bit halves into 32
  -- bits. Must match LightningStorm's fold so stormSeed ≡ plume seed replays.
  local s = math.floor(tonumber(seed) or 0)
  local lo = s % 4294967296
  local hi = math.floor(s / 4294967296) % 4294967296
  return (lo ~ hi) & 0xFFFFFFFF
end

local function hsl2rgb (h, s, l)
  local c = (1 - math.abs(2 * l - 1)) * s
  local hp = (h % 1.0) * 6
  local x = c * (1 - math.abs(hp % 2 - 1))
  local r, g, b
  if hp < 1 then r, g, b = c, x, 0
  elseif hp < 2 then r, g, b = x, c, 0
  elseif hp < 3 then r, g, b = 0, c, x
  elseif hp < 4 then r, g, b = 0, x, c
  elseif hp < 5 then r, g, b = x, 0, c
  else r, g, b = c, 0, x end
  local m = l - c * 0.5
  return r + m, g + m, b + m
end

function NebulaVolumes.cellKey (pos)
  -- Coverage is part of the key so dragging the panel slider rebuilds the
  -- field on the next frame instead of waiting for a cell crossing.
  local cover = 1
  if Settings and Settings.get then cover = Settings.get('nebula.coverage') or 1 end
  return math.floor(pos.x / CELL) .. '_' .. math.floor(pos.y / CELL) .. '_' .. math.floor(pos.z / CELL) ..
    '_' .. string.format('%.2f', cover)
end

-- Accepts an optional sectorHue [0..1] derived from the sector's skybox generator.
-- If provided, local plume hues shift to match and complement the skybox palette.
function NebulaVolumes.build (seed, pos, radius, sectorHue)
  local s = foldSeed(seed)
  local cx = math.floor(pos.x / CELL)
  local cy = math.floor(pos.y / CELL)
  local cz = math.floor(pos.z / CELL)
  local r2 = radius * radius
  local recs = {}

  for ox = -1, 1 do
    local icx = cx + ox
    local ccx = icx * CELL
    for oy = -1, 1 do
      local icy = cy + oy
      local ccy = icy * CELL
      for oz = -1, 1 do
        local icz = cz + oz
        local ccz = icz * CELL

        local h = hash32(icx, icy, icz, s, 0)
        local n = h < 0.55 and 1 or (h < 0.85 and 2 or 0)

        for k = 0, n - 1 do
          local off = k * 16
          local px = ccx + (hash32(icx, icy, icz, s, off + 1) * 2 - 1) * CELL * 0.34
          local py = ccy + (hash32(icx, icy, icz, s, off + 2) * 2 - 1) * CELL * 0.34
          local pz = ccz + (hash32(icx, icy, icz, s, off + 3) * 2 - 1) * CELL * 0.34

          local dx, dy, dz = px - pos.x, py - pos.y, pz - pos.z
          local d2 = dx * dx + dy * dy + dz * dz

          if d2 <= r2 then
            -- Coverage (storm-cloud knob): scales bank extents AND core
            -- density together, so 1.6 reads as thick storm banks and 0.5 as
            -- thin wisps. Defaults to 1.0 = the signed-off Phase 2 field.
            local cover = 1
            if Settings and Settings.get then cover = Settings.get('nebula.coverage') or 1 end
            cover = math.max(0.25, math.min(2.5, cover))
            local baseExtent = (1200 + hash32(icx, icy, icz, s, off + 4) * 4800) * cover
            local extX = baseExtent * (0.6 + hash32(icx, icy, icz, s, off + 10) * 0.8)
            local extY = baseExtent * (0.4 + hash32(icx, icy, icz, s, off + 11) * 0.6)
            local extZ = baseExtent * (0.6 + hash32(icx, icy, icz, s, off + 12) * 0.8)

            local density = (0.8 + hash32(icx, icy, icz, s, off + 5) * 2.2) * cover
            -- Noise frequency: kept coarse enough that the ~290-unit march
            -- step resolves it (finer scales aliased into speckle).
            local scale   = 0.0002 + hash32(icx, icy, icz, s, off + 6) * 0.0006
            local warp    = hash32(icx, icy, icz, s, off + 7) * 450.0

            -- Palette Coupling: If sectorHue is provided, center plume hues around the skybox!
            local baseHue
            if sectorHue then
              -- Small variation (±0.08) around the background skybox hue
              baseHue = (sectorHue + (hash32(icx, icy, icz, s, off + 8) * 0.16 - 0.08)) % 1.0
            else
              baseHue = 0.02 + hash32(icx, icy, icz, s, off + 8) * 0.95
            end

            local rimHue = (baseHue + 0.12 + hash32(icx, icy, icz, s, off + 9) * 0.15) % 1.0

            local cr, cg, cb = hsl2rgb(baseHue, 0.80, 0.60)  -- Core Color
            local rr, rg, rb = hsl2rgb(rimHue,  0.65, 0.35)  -- Rim Color

            recs[#recs + 1] = {
              px, py, pz, extX, extY, extZ, density, scale, warp,
              cr, cg, cb, rr, rg, rb,
              d2 = d2
            }
          end
        end
      end
    end
  end

  table.sort(recs, function (a, b) return a.d2 < b.d2 end)

  local list = {}
  local count = math.min(#recs, MAXV)
  for i = 1, count do
    list[i] = recs[i]
  end

  return list
end

return NebulaVolumes
