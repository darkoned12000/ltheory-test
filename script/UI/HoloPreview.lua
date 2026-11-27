-- CPU-projected live mesh preview shared by Holo detail cards.
-- Meshes are normalized to the preview rect and cached per entity.

local DrawEx = require('UI.DrawEx')
local TargetInfo = require('Game.TargetInfo')
local ffi = require('ffi')

local Preview = {}
local cache = setmetatable({}, { __mode = 'k' })
local WIRE = { r = 0.25, g = 0.72, b = 1.0, a = 0.92 }

function Preview.BuildLines (entity)
  if not entity then return nil end
  local cached = cache[entity]
  if cached ~= nil then return cached ~= false and cached or nil end
  local mesh = TargetInfo.ResolveMesh(entity)
  if not mesh then cache[entity] = false; return nil end
  local okV, count = pcall(function () return mesh:getVertexCount() end)
  if not (okV and count and count > 0) then cache[entity] = false; return nil end
  local getData = mesh.getVertexData
  local data = getData and getData(mesh)
  if not data then cache[entity] = false; return nil end
  local verts = ffi.cast('struct Vertex*', data)
  local radius = 0
  for i = 0, count - 1 do
    local v = verts[i]
    local r = math.sqrt(v.px * v.px + v.py * v.py + v.pz * v.pz)
    if r > radius then radius = r end
  end
  if radius < 1e-6 then cache[entity] = false; return nil end
  local okI, indexCount = pcall(function () return mesh:getIndexCount() end)
  if not (okI and indexCount and indexCount > 0) then cache[entity] = false; return nil end
  local getIndexData = mesh.getIndexData
  local indexData = getIndexData and getIndexData(mesh)
  if not indexData then cache[entity] = false; return nil end
  local indices = ffi.cast('int32_t*', indexData)
  local yaw, pitch = 0.7, 0.4
  local cy, sy = math.cos(yaw), math.sin(yaw)
  local cp, sp = math.cos(pitch), math.sin(pitch)
  local function project (v)
    local x, y, z = v.px / radius, v.py / radius, v.pz / radius
    local rx = x * cy + z * sy
    local rz = -x * sy + z * cy
    return rx, y * cp - rz * sp
  end
  local triangles = math.floor(indexCount / 3)
  local step = math.max(1, math.ceil(triangles / 360))
  local lines, n = {}, 0
  local ti = 0
  while ti * 3 + 2 < indexCount do
    local i0 = ti * 3
    local ax, ay = project(verts[indices[i0]])
    local bx, by = project(verts[indices[i0 + 1]])
    local cx, cy2 = project(verts[indices[i0 + 2]])
    n = n + 1; lines[n * 4 - 3], lines[n * 4 - 2], lines[n * 4 - 1], lines[n * 4] = ax, ay, bx, by
    n = n + 1; lines[n * 4 - 3], lines[n * 4 - 2], lines[n * 4 - 1], lines[n * 4] = bx, by, cx, cy2
    n = n + 1; lines[n * 4 - 3], lines[n * 4 - 2], lines[n * 4 - 1], lines[n * 4] = cx, cy2, ax, ay
    ti = ti + step
  end
  cache[entity] = lines
  return lines
end

function Preview.Draw (x, y, sx, sy, preview)
  local entity = type(preview) == 'table' and preview.entity or preview
  local lines = Preview.BuildLines(entity)
  if not lines then return false end
  local cx, cy = x + sx * 0.5, y + sy * 0.5
  local scale = math.min(sx, sy) * 0.36
  for i = 1, #lines, 4 do
    DrawEx.Line(cx + lines[i] * scale, cy - lines[i + 1] * scale,
      cx + lines[i + 2] * scale, cy - lines[i + 3] * scale, WIRE)
  end
  return true
end

return Preview
