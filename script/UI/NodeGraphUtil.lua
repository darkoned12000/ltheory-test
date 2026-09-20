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
