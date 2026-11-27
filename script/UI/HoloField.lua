-- Minor-entity field: deterministic spatial clusters plus zoom-driven point LOD.
-- Pure data module; rendering and hit-testing stay in HoloRenderer/HoloGraph.

local Field = {}

local function clamp (v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function capped (list, maxCount, selectedId)
  if #list <= maxCount then return list end
  if maxCount <= 0 then return {} end
  local out, selected = {}, nil
  local step = #list / maxCount
  for i = 0, maxCount - 1 do
    local index = math.min(#list, math.floor(i * step) + 1)
    out[#out + 1] = list[index]
    if list[index].id == selectedId then selected = list[index] end
  end
  if selectedId and not selected then
    for i = 1, #list do
      if list[i].id == selectedId then selected = list[i]; break end
    end
    if selected then out[#out] = selected end
  end
  return out
end

function Field.Build (nodes, opts)
  opts = opts or {}
  local contextId = opts.contextId or 'field'
  local cellSize = math.max(1, opts.cellSize or 180)
  local scale = opts.scale or 1
  local heightScale = opts.heightScale or 1
  local points, byId = {}, {}
  for i = 1, #nodes do
    local node = nodes[i]
    local point = {
      id = node.id or ('field_' .. i),
      data = node,
      x = (node.x or node.wx or 0) * scale,
      y = (node.y or node.wy or 0) * heightScale,
      z = (node.z or node.wz or 0) * scale,
      radius = node.radius or 2,
      isFieldPoint = true,
    }
    points[#points + 1] = point
    byId[point.id] = point
  end
  table.sort(points, function (a, b) return a.id < b.id end)

  local groups, order = {}, {}
  for i = 1, #points do
    local p = points[i]
    local gx, gz = math.floor(p.x / cellSize), math.floor(p.z / cellSize)
    local key = gx .. ':' .. gz
    local group = groups[key]
    if not group then
      group = { key = key, gx = gx, gz = gz, count = 0, x = 0, y = 0, z = 0,
        radius = 0, members = {} }
      groups[key] = group
      order[#order + 1] = group
    end
    group.count = group.count + 1
    group.x = group.x + p.x
    group.y = group.y + p.y
    group.z = group.z + p.z
    group.radius = math.max(group.radius, p.radius)
    group.members[#group.members + 1] = p
  end

  local clusters, clusterById = {}, {}
  for i = 1, #order do
    local group = order[i]
    local cluster = {
      id = string.format('field-cluster:%s:%d:%d', contextId, group.gx, group.gz),
      x = group.x / group.count,
      y = group.y / group.count,
      z = group.z / group.count,
      count = group.count,
      radius = math.max(7, math.sqrt(group.count) * 1.35),
      members = group.members,
      isFieldCluster = true,
    }
    clusters[#clusters + 1] = cluster
    clusterById[cluster.id] = cluster
  end
  table.sort(clusters, function (a, b) return a.id < b.id end)
  return { points = points, clusters = clusters, byId = byId, clusterById = clusterById }
end

function Field.LOD (field, zoom, selectedId, opts)
  opts = opts or {}
  local maxPoints = math.max(0, opts.maxPoints or 4096)
  local maxClusters = math.max(0, opts.maxClusters or 256)
  local t = clamp((zoom - 0.75) / (1.60 - 0.75), 0, 1)
  local clusterAlpha, pointAlpha = 1 - t, t
  local points, clusters = {}, {}

  local selectedPoint = selectedId and field.byId[selectedId] or nil
  local selectedCluster = selectedId and field.clusterById[selectedId] or nil
  if selectedPoint then points[1] = selectedPoint end

  if t < 1 then
    clusters = capped(field.clusters, maxClusters, selectedId)
    if selectedCluster then
      local found = false
      for i = 1, #clusters do if clusters[i] == selectedCluster then found = true end end
      if not found and #clusters < maxClusters then clusters[#clusters + 1] = selectedCluster end
    end
  end
  if t > 0 then
    local visible = capped(field.points, maxPoints, selectedId)
    for i = 1, #visible do points[#points + 1] = visible[i] end
  end

  -- Avoid duplicating the forced selected point when the regular budget also
  -- included it. Keep deterministic order after the merge.
  local seen, unique = {}, {}
  for i = 1, #points do
    if not seen[points[i].id] then
      seen[points[i].id] = true
      unique[#unique + 1] = points[i]
    end
  end
  points = unique
  if selectedPoint and #points == 0 then points[1] = selectedPoint; pointAlpha = 1 end
  if selectedPoint and t == 0 then pointAlpha = 1 end

  return {
    points = points,
    clusters = clusters,
    pointAlpha = pointAlpha,
    clusterAlpha = clusterAlpha,
    selectedId = selectedId,
    lod = t == 0 and 'clusters' or (t == 1 and 'points' or 'transition'),
  }
end

return Field
