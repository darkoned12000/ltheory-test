-- Pure Holo camera/layout math. No UI or renderer dependencies.

local HoloLayout = {}

local function clamp (value, low, high)
  return math.max(low, math.min(high, value))
end

function HoloLayout.project (cam, x, y, z, vx, vy, vsx, vsy)
  z = z or 0
  local zoom = cam.zoom or 1
  local dx = (x - (cam.x or 0)) * zoom
  local dy = (y - (cam.y or 0)) * zoom
  local dz = z * zoom

  local cy, sy = math.cos(cam.yaw or 0), math.sin(cam.yaw or 0)
  local rx = dx * cy - dy * sy
  local ry = dx * sy + dy * cy

  local cp, sp = math.cos(cam.pitch or 0), math.sin(cam.pitch or 0)
  local py = ry * cp - dz * sp
  local pz = ry * sp + dz * cp

  local focal = cam.fovDist or 900
  local depth = focal + pz
  if depth < 40 then return nil end
  local scale = focal / depth
  return vx + vsx * 0.5 + rx * scale,
         vy + vsy * 0.5 + py * scale,
         scale, depth
end

local function finite (value)
  return value == value and math.abs(value) < math.huge
end

function HoloLayout.unproject (cam, mx, my, vx, vy, vsx, vsy)
  if not finite(mx) or not finite(my) or not finite(vx) or not finite(vy)
    or not finite(vsx) or not finite(vsy) or not finite(cam.pitch or 0)
    or not finite(cam.yaw or 0) or not finite(cam.fovDist or 900)
    or not finite(cam.zoom or 1) then return nil end

  local nx = mx - (vx + vsx * 0.5)
  local ny = my - (vy + vsy * 0.5)
  local cp, sp = math.cos(cam.pitch or 0), math.sin(cam.pitch or 0)
  local focal = cam.fovDist or 900
  local denom = cp * focal - ny * sp
  -- Near the horizon the z=0 ray is almost parallel to the graph plane;
  -- inversion is mathematically valid but produces world-space camera jumps.
  local horizonEpsilon = math.max(1e-4, math.abs(focal) * 0.01)
  if not finite(denom) or math.abs(denom) < horizonEpsilon then return nil end

  local ry = ny * focal / denom
  local depth = focal + ry * sp
  if not finite(depth) or depth < 40 then return nil end
  local scale = focal / depth
  local rx = nx / scale
  local cy, sy = math.cos(-(cam.yaw or 0)), math.sin(-(cam.yaw or 0))
  local dx = rx * cy - ry * sy
  local dy = rx * sy + ry * cy
  local zoom = cam.zoom or 1
  local wx, wy = (cam.x or 0) + dx / zoom, (cam.y or 0) + dy / zoom
  if not finite(wx) or not finite(wy) then return nil end
  return wx, wy
end

function HoloLayout.pan (cam, fromX, fromY, toX, toY, vx, vy, vsx, vsy)
  local ax, ay = HoloLayout.unproject(cam, fromX, fromY, vx, vy, vsx, vsy)
  local bx, by = HoloLayout.unproject(cam, toX, toY, vx, vy, vsx, vsy)
  if not ax or not bx then return false end
  cam.x = (cam.x or 0) - (bx - ax)
  cam.y = (cam.y or 0) - (by - ay)
  return true
end

function HoloLayout.zoomAt (cam, mx, my, factor, vx, vy, vsx, vsy)
  if not finite(factor) or factor <= 0 then return false end
  local wx, wy = HoloLayout.unproject(cam, mx, my, vx, vy, vsx, vsy)
  if not wx then return false end
  cam.zoom = clamp((cam.zoom or 1) * factor, 0.25, 4.5)
  local nx, ny = HoloLayout.unproject(cam, mx, my, vx, vy, vsx, vsy)
  if not nx then return false end
  cam.x = (cam.x or 0) + (wx - nx)
  cam.y = (cam.y or 0) + (wy - ny)
  return true
end

function HoloLayout.projectRadius (cam, radius, scale)
  return math.max(1.0, (radius or 1) * (cam.zoom or 1) * (scale or 1))
end

function HoloLayout.radial (children)
  local n = #children
  if n == 0 then return end
  local perRing, baseRadius, ringGap = 12, 170, 105
  for i = 1, n do
    local ring = math.floor((i - 1) / perRing)
    local slot = (i - 1) % perRing
    local count = math.min(perRing, n - ring * perRing)
    local angle = -math.pi * 0.5 + math.pi * 2 * slot / count
    local radius = baseRadius + ring * ringGap
    children[i].tx = math.cos(angle) * radius
    children[i].ty = math.sin(angle) * radius
    children[i].tz = 0
  end
end

function HoloLayout.cardinal (children)
  local n = #children
  local angles = { -math.pi * 0.5, 0, math.pi * 0.5, math.pi }
  for i = 1, n do
    local angle
    if n == 2 then
      angle = i == 1 and math.pi or 0
    else
      local layer = math.floor((i - 1) / 4)
      angle = angles[((i - 1) % 4) + 1] + layer * 0.35
    end
    local radius = 190 + math.floor((i - 1) / 4) * 90
    children[i].tx = math.cos(angle) * radius
    children[i].ty = math.sin(angle) * radius
    children[i].tz = 0
  end
end

function HoloLayout.rectilinear (children)
  local n = #children
  if n == 0 then return end
  local cols = math.max(2, math.ceil(math.sqrt(n)))
  local rows = math.ceil(n / cols)
  for i = 1, n do
    local col = (i - 1) % cols
    local row = math.floor((i - 1) / cols)
    children[i].tx = (col - (cols - 1) * 0.5) * 150
    children[i].ty = (row - (rows - 1) * 0.5) * 85
    children[i].tz = 0
  end
end

function HoloLayout.spiral (children)
  local golden = 2.399963229728653
  for i = 1, #children do
    local radius = 48 * math.sqrt(i)
    local angle = i * golden
    children[i].tx = math.cos(angle) * radius
    children[i].ty = math.sin(angle) * radius
    children[i].tz = math.sin(i * 0.5) * 14
  end
end

function HoloLayout.spatial (children)
  local maxRadius, hasSpatial = 1, false
  for i = 1, #children do
    local child = children[i]
    if child.wx or child.wz then
      hasSpatial = true
      local distance = math.sqrt((child.wx or 0)^2 + (child.wz or 0)^2)
      if distance > maxRadius then maxRadius = distance end
    end
  end
  if not hasSpatial then return HoloLayout.radial(children) end
  local norm = 320 / maxRadius
  for i = 1, #children do
    local child = children[i]
    child.tx = (child.wx or child.x or 0) * norm
    child.ty = (child.wz or child.y or 0) * norm
    child.tz = (child.wy or child.z or 0) * norm * 0.35
  end
end

function HoloLayout.apply (mode, children)
  if mode == 'spatial' then HoloLayout.spatial(children)
  elseif mode == 'cardinal' then HoloLayout.cardinal(children)
  elseif mode == 'rectilinear' then HoloLayout.rectilinear(children)
  elseif mode == 'spiral' then HoloLayout.spiral(children)
  else HoloLayout.radial(children) end
end

function HoloLayout.previewOffsets (spec, budget)
  budget = math.min(budget or 16, 32)
  local points = spec.points or {}
  local count = math.min(#points, budget)
  local out = {}
  if spec.layout == 'spatial' then
    local maxRadius = 1
    for i = 1, count do
      local point = points[i]
      local distance = math.sqrt((point.x or 0)^2 + (point.z or 0)^2)
      if distance > maxRadius then maxRadius = distance end
    end
    for i = 1, count do
      local point = points[i]
      out[i] = {
        id = point.id,
        dx = (point.x or 0) / maxRadius * 38,
        dy = (point.z or 0) / maxRadius * 38,
        dz = (point.y or 0) / maxRadius * 12,
      }
    end
  else
    local radius = spec.radius or 26
    for i = 1, count do
      local angle = -math.pi * 0.5 + math.pi * 2 * (i - 1) / count
      out[i] = {
        id = points[i] and points[i].id or tostring(i),
        dx = math.cos(angle) * radius,
        dy = math.sin(angle) * radius,
        dz = 0,
      }
    end
  end
  return out
end

return HoloLayout
