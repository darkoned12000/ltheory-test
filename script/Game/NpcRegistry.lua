-- Stable NPC identity registry. Runtime Entity.id is process-local and cannot
-- be used for persistence or social identity; NPCs register by their seeded
-- string id instead.

local Registry = {}

function Registry.Create ()
  return { byId = {}, list = {} }
end

function Registry.register (reg, npc)
  if not (npc and npc.isNpc and npc:isNpc()) then return false end
  local id = npc:getNpcId()
  if not id or id == '' then return false end
  local existing = reg.byId[id]
  if existing then return existing == npc end
  reg.byId[id] = npc
  reg.list[#reg.list + 1] = npc
  return true
end

function Registry.unregister (reg, npc)
  if not (npc and npc.isNpc and npc:isNpc()) then return false end
  local id = npc:getNpcId()
  if not id or reg.byId[id] ~= npc then return false end
  reg.byId[id] = nil
  for i = 1, #reg.list do
    if reg.list[i] == npc then
      reg.list[i] = reg.list[#reg.list]
      reg.list[#reg.list] = nil
      return true
    end
  end
  return false
end

function Registry.get (reg, id)
  return reg.byId[id]
end

function Registry.count (reg)
  return #reg.list
end

return Registry
