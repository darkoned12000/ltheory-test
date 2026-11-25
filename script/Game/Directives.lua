-- Shared, system-local NPC objectives. A directive is immutable assignment
-- data; each member executes its own Action instance on its own ship.

local Directives = {}

function Directives.Create ()
  return { nextId = 1, list = {}, byId = {} }
end

function Directives.create (manager, issuer, kind, target, opts)
  opts = opts or {}
  if kind ~= 'defend' or not target then return nil end
  local id = manager.nextId
  manager.nextId = id + 1
  local directive = {
    id = id,
    kind = kind,
    issuerId = issuer:getActorId(),
    organizationId = opts.organizationId,
    target = target,
    capacity = math.max(1, opts.capacity or 2),
    members = {},
    memberCount = 0,
    status = 'open',
    createdAt = opts.now or 0,
    expiresAt = opts.expiresAt or ((opts.now or 0) + 60),
    rewardStanding = opts.rewardStanding or 1,
  }
  manager.list[#manager.list + 1] = directive
  manager.byId[id] = directive
  return directive
end

function Directives.accept (manager, id, actor)
  local directive = manager.byId[id]
  if not directive or (directive.status ~= 'open' and directive.status ~= 'active') then
    return false
  end
  if directive.organizationId and not actor:hasOrganization(directive.organizationId) then
    return false
  end
  local actorId = actor:getActorId()
  if directive.members[actorId] == actor then return true end
  if directive.memberCount >= directive.capacity then return false end
  directive.members[actorId] = actor
  directive.memberCount = directive.memberCount + 1
  directive.status = 'active'
  return true
end

function Directives.activeFor (manager, actor)
  local actorId = actor:getActorId()
  for i = #manager.list, 1, -1 do
    local directive = manager.list[i]
    if directive.status == 'active' and directive.members[actorId] == actor then
      return directive
    end
  end
  return nil
end

function Directives.availableFor (manager, actor)
  for i = #manager.list, 1, -1 do
    local directive = manager.list[i]
    if (directive.status == 'open' or directive.status == 'active')
       and directive.memberCount < directive.capacity
       and (not directive.organizationId or actor:hasOrganization(directive.organizationId)) then
      return directive
    end
  end
  return nil
end

function Directives.complete (manager, id, actor)
  local directive = manager.byId[id]
  if not directive or (directive.status ~= 'active' and directive.status ~= 'open') then
    return false
  end
  directive.status = 'completed'
  if directive.organizationId then
    for _, member in pairs(directive.members) do
      member:modOrganizationStanding(directive.organizationId, directive.rewardStanding)
    end
  end
  return true
end

function Directives.fail (manager, id)
  local directive = manager.byId[id]
  if not directive or (directive.status ~= 'active' and directive.status ~= 'open') then
    return false
  end
  directive.status = 'failed'
  return true
end

function Directives.update (manager, now)
  for i = #manager.list, 1, -1 do
    local directive = manager.list[i]
    if directive.status == 'open' or directive.status == 'active' then
      local target = directive.target
      if now >= directive.expiresAt or (target.isAlive and not target:isAlive()) then
        Directives.fail(manager, directive.id)
      end
    end
  end
end

return Directives
