-- NodeGraphUtil -- shared, dependency-free helpers for the node UI.
-- Split out so NodeGraph and NodeGraphInspector cannot drift (they previously
-- each carried their own `kindTag`, with different strings).

local NodeGraphUtil = {}

-- Capability tag(s): what an entity IS.
--   kindTag(e)         -> 'FACTORY ORE'   (space-joined, upper-case; function line)
--   kindTag(e, 'short')-> 'Factory'       (first tag, title-case; labels/captions)
function NodeGraphUtil.kindTag (e, style)
  if not e then return style == 'short' and 'Body' or 'BODY' end
  local tags = {}
  if e.hasFactory and e:hasFactory() then tags[#tags + 1] = 'FACTORY' end
  if e.hasTrader and e:hasTrader() then tags[#tags + 1] = 'TRADER' end
  if e.hasMarket and e:hasMarket() then tags[#tags + 1] = 'MARKET' end
  if e.hasYield and e:hasYield() then tags[#tags + 1] = 'ORE' end
  if #tags == 0 then
    if e.hasActions and e:hasActions() then tags[#tags + 1] = 'SHIP' end
    if e.hasSockets and e:hasSockets() then tags[#tags + 1] = 'SHIP' end
  end
  if #tags == 0 then tags[#tags + 1] = 'BODY' end
  if style == 'short' then
    local t = tags[1]
    return t:sub(1, 1) .. t:sub(2):lower()
  end
  return table.concat(tags, ' ')
end

-- Player-facing label: the entity's own name when it has a real one, else a
-- kind tag plus a short id. Never the raw `Entity @ 0x...` pointer fallback.
function NodeGraphUtil.resolveLabel (e)
  if e.name and e.name ~= '' then
    local ok, name = pcall(e.getName, e)
    if ok and name and name ~= '' then return name end
  end
  return NodeGraphUtil.kindTag(e, 'short') .. ' #' .. tostring((e.id or 0) % 1000)
end

-- Representation kind for an entity that STANDS FOR a group rather than being
-- a single body (a named region/zone such as an asteroid field). Such nodes
-- have no mesh of their own, so the inspector should draw a schematic glyph
-- instead of falling back to the generic box.
--   -> 'field', count   when it aggregates >= 5 positioned, non-ship children
--   -> nil              otherwise (a real body, or a childless marker)
function NodeGraphUtil.repKind (e)
  if not (e and e.name and e.getChildren) then return nil end
  if e.mesh then return nil end          -- a real body draws its own mesh
  local okC, ch = pcall(e.getChildren, e)
  if not (okC and ch) then return nil end
  local n = 0
  for _, c in ipairs(ch) do
    if c and not c.deleted and c.getPos then
      local okP, p = pcall(c.getPos, c)
      if okP and p and not (c.hasActions and c:hasActions()) then n = n + 1 end
    end
  end
  if n >= 5 then return 'field', n end
  return nil
end

-- A stylized cluster of vector rocks (flat segments {x1,y1,x2,y2,...} in
-- roughly [-1,1] units), for an asteroid-field representation. Deterministic
-- from `seed` so a node's glyph never changes frame to frame. `count` biases
-- how many rocks are drawn (the field's real member count, clamped).
function NodeGraphUtil.fieldSchematic (seed, count)
  local n = math.max(5, math.min(13, math.floor(count or 8)))
  local s = math.floor(math.abs(seed or 1)) % 2147483647
  if s <= 0 then s = 1 end
  local function rnd ()
    s = (s * 1103515245 + 12345) % 2147483648
    return s / 2147483648
  end
  local lines, m = {}, 0
  local function seg (ax, ay, bx, by)
    m = m + 1
    lines[m * 4 - 3], lines[m * 4 - 2], lines[m * 4 - 1], lines[m * 4] = ax, ay, bx, by
  end
  for _ = 1, n do
    -- Scatter over a disc (sqrt keeps the area uniform), each rock a small
    -- irregular polygon with a jittered radius.
    local a = rnd() * math.pi * 2
    local rad = 0.12 + 0.74 * math.sqrt(rnd())
    local cx, cy = math.cos(a) * rad, math.sin(a) * rad
    local r = 0.06 + 0.06 * rnd()
    local sides = 5 + math.floor(rnd() * 3)
    local rot = rnd() * math.pi * 2
    local verts = {}
    for k = 1, sides do
      local va = rot + (k - 1) / sides * math.pi * 2
      local vr = r * (0.72 + 0.5 * rnd())
      verts[k] = { cx + math.cos(va) * vr, cy + math.sin(va) * vr }
    end
    for k = 1, sides do
      local p1, p2 = verts[k], verts[k % sides + 1]
      seg(p1[1], p1[2], p2[1], p2[2])
    end
  end
  return lines
end

-- Range between two bodies, for readings RELATIVE to the player (the map's
-- absolute `pos` lines are useless for navigation). Returns:
--   d3    -- true range in space (includes the vertical)
--   plane -- separation in the map plane (X/Z), i.e. the on-screen distance
--   dy    -- signed vertical separation
-- nil when either body has no position.
function NodeGraphUtil.rangeBetween (a, b)
  if not (a and b and a.getPos and b.getPos) then return nil end
  local okA, pa = pcall(a.getPos, a)
  local okB, pb = pcall(b.getPos, b)
  if not (okA and pa and okB and pb) then return nil end
  local dx, dy, dz = pa.x - pb.x, pa.y - pb.y, pa.z - pb.z
  return math.sqrt(dx * dx + dy * dy + dz * dz),
         math.sqrt(dx * dx + dz * dz),
         dy
end

-- Compact number for on-screen stats (163633 -> '163.6k').
function NodeGraphUtil.fmtShort (n)
  if type(n) ~= 'number' or n ~= n then return '?' end
  local a = math.abs(n)
  if a >= 1e9 then return string.format('%.1fG', n / 1e9) end
  if a >= 1e6 then return string.format('%.1fM', n / 1e6) end
  if a >= 1e3 then return string.format('%.1fk', n / 1e3) end
  return tostring(math.floor(n + 0.5))
end

return NodeGraphUtil
