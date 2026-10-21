-- NebulaVolumes -- deterministic per-cell plume records (fog-nebula Phase 2).
-- Bounded, CPU-culled anchor generator with dual-tone color gradients and
-- non-uniform ellipsoid extent stretching.

local NebulaVolumes = {}

local CELL = 12000      -- world lattice pitch (plume spacing)
local ANCHOR_UPDATE = CELL * 0.5 -- re-rank the bounded GPU list within a cell
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

function NebulaVolumes.cellKey (pos, radius)
  -- Refresh the nearest-16 list every half lattice cell, not only when the
  -- 12k-generation cell changes. This keeps the bounded GPU list centered on the
  -- moving camera as it traverses a cell. Coverage/radius changes also rebuild it.
  local cover = 1
  if Settings and Settings.get then cover = Settings.get('nebula.coverage') or 1 end
  if radius == nil then
    radius = (Settings and Settings.get and Settings.get('nebula.radius')) or 12000
  end
  return math.floor(pos.x / ANCHOR_UPDATE) .. '_' .. math.floor(pos.y / ANCHOR_UPDATE) .. '_' .. math.floor(pos.z / ANCHOR_UPDATE) ..
    '_' .. string.format('%.2f_%.0f', cover, radius)
end

-- Accepts an optional sectorHue [0..1] derived from the sector's skybox generator.
-- If provided, local plume hues shift to match and complement the skybox palette.
-- `regions`, when given, is the sector's region list, and the anchors take
-- their DENSITY from the environmental field (13f) at their own position:
-- a "Violet Veil" region has dense gas and a "Silent Deep" has thin gas.
--
-- The density is sampled PER ANCHOR, not per build, and that matters: an
-- anchor's density is then a pure function of where that anchor is, so
-- rebuilding the list (which happens when the camera crosses a cell) gives
-- every anchor the SAME density it had before. Sampling it once per build
-- instead would make the whole visible sky change character in one step as
-- the camera crossed a cell boundary -- a pop, in the one place the player
-- is guaranteed to be looking.
function NebulaVolumes.build (seed, pos, radius, sectorHue, regions)
  local s = foldSeed(seed)
  local cx = math.floor(pos.x / CELL)
  local cy = math.floor(pos.y / CELL)
  local cz = math.floor(pos.z / CELL)
  local cover = 1
  if Settings and Settings.get then cover = Settings.get('nebula.coverage') or 1 end
  cover = math.max(0.25, math.min(2.5, cover))
  -- A plume can contribute even when its centre is outside the ray cap. Search
  -- and cull using its conservative maximum extent, not just centre distance;
  -- otherwise the visible edge of a large ellipsoid gets clipped as Radius moves.
  local maxExtent = 8400 * cover -- max base extent 6000 * max axis factor 1.4
  local anchorRange = radius + maxExtent
  local anchorRange2 = anchorRange * anchorRange
  local recs = {}

  -- Search enough neighboring lattice cells to cover the requested march
  -- radius. A fixed 3x3x3 search silently omitted anchors when Radius was raised
  -- above one cell (12k), so the visible clouds stopped growing with the slider.
  local cellReach = math.ceil(anchorRange / CELL) + 1
  for ox = -cellReach, cellReach do
    local icx = cx + ox
    local ccx = icx * CELL
    for oy = -cellReach, cellReach do
      local icy = cy + oy
      local ccy = icy * CELL
      for oz = -cellReach, cellReach do
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
          local centerD2 = dx * dx + dy * dy + dz * dz
          if centerD2 <= anchorRange2 then
            -- Coverage scales bank extents AND core density together, so 1.6
            -- reads as thick storm banks and 0.5 as thin wisps.
            local baseExtent = (1200 + hash32(icx, icy, icz, s, off + 4) * 4800) * cover
            local extX = baseExtent * (0.6 + hash32(icx, icy, icz, s, off + 10) * 0.8)
            local extY = baseExtent * (0.4 + hash32(icx, icy, icz, s, off + 11) * 0.6)
            local extZ = baseExtent * (0.6 + hash32(icx, icy, icz, s, off + 12) * 0.8)

            local edgeDist = math.max(0, math.sqrt(centerD2) - math.max(extX, extY, extZ))
            if edgeDist <= radius then

            local density = (0.8 + hash32(icx, icy, icz, s, off + 5) * 2.2) * cover
            -- The region's CHARACTER (13f): the gas density comes from the
            -- same field the rocks and the lightning read, so the three
            -- cannot disagree about what kind of place this is.
            if regions and #regions > 0 then
              local Sector = require('Game.Region')
              local f = Sector.Region.field(regions, px, py, pz)
              -- The archetype's `density` runs 0.18..0.85, so this is a
              -- 0.55x..1.5x multiplier on the plume's own density.
              density = density * (0.35 + f.density * 1.3)
            end
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
              -- Prioritize plumes whose bounds approach the ray volume; this
              -- makes the bounded 16-anchor GPU list represent visible volume
              -- rather than just nearest centers.
              d2 = edgeDist * edgeDist
            }
            end
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
