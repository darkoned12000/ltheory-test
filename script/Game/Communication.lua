-- System-local addressed communication. Payloads are opaque to the bus; the
-- current local threat message carries a runtime target reference and is not
-- part of the save format.

local Communication = {}

local INBOX_LIMIT = 32
local DEFAULT_TTL = 30.0

function Communication.Create ()
  return {
    time = 0,
    nextId = 1,
    actors = {},
    order = {},
    inboxes = {},
  }
end

function Communication.register (bus, actor)
  local id = actor:getActorId()
  if not id then return false end
  if bus.actors[id] then return bus.actors[id] == actor end
  bus.actors[id] = actor
  bus.order[#bus.order + 1] = actor
  bus.inboxes[id] = {}
  return true
end

function Communication.unregister (bus, actor)
  local id = actor:getActorId()
  if not id or bus.actors[id] ~= actor then return false end
  bus.actors[id] = nil
  bus.inboxes[id] = nil
  for i = 1, #bus.order do
    if bus.order[i] == actor then
      bus.order[i] = bus.order[#bus.order]
      bus.order[#bus.order] = nil
      break
    end
  end
  return true
end

function Communication.count (bus)
  return #bus.order
end

local function inRange (bus, sender, recipient, range)
  if not range then return true end
  local a = sender:getPrimaryShip()
  local b = recipient:getPrimaryShip()
  if not a or not b then return false end
  return (a:getPos() - b:getPos()):length() <= range
end

local function deliver (bus, sender, recipient, kind, payload, opts)
  local recipientId = recipient:getActorId()
  if not bus.actors[recipientId] then return false end
  if not inRange(bus, sender, recipient, opts.range) then return false end
  local now = opts.now or bus.time
  local message = {
    id = bus.nextId,
    kind = kind,
    senderId = sender:getActorId(),
    recipientId = recipientId,
    payload = payload or {},
    sentAt = now,
    expiresAt = opts.expiresAt or (now + (opts.ttl or DEFAULT_TTL)),
    replyTo = opts.replyTo,
  }
  bus.nextId = bus.nextId + 1
  local inbox = bus.inboxes[recipientId]
  inbox[#inbox + 1] = message
  if #inbox > INBOX_LIMIT then table.remove(inbox, 1) end
  return true
end

function Communication.send (bus, sender, recipient, kind, payload, opts)
  opts = opts or {}
  if not bus.actors[sender:getActorId()] or not bus.actors[recipient:getActorId()] then
    return false
  end
  if opts.now then bus.time = math.max(bus.time, opts.now) end
  return deliver(bus, sender, recipient, kind, payload, opts)
end

function Communication.sendToOrganization (bus, sender, organizationId, kind, payload, opts)
  opts = opts or {}
  if not sender:hasOrganization(organizationId) then return false end
  if opts.now then bus.time = math.max(bus.time, opts.now) end
  local delivered = 0
  for _, actor in ipairs(bus.order) do
    if actor ~= sender and actor:hasOrganization(organizationId)
       and deliver(bus, sender, actor, kind, payload, opts) then
      delivered = delivered + 1
    end
  end
  return delivered
end

local function prune (bus, id)
  local inbox = bus.inboxes[id]
  if not inbox then return end
  local write = 1
  for read = 1, #inbox do
    local message = inbox[read]
    if message.expiresAt > bus.time then
      inbox[write] = message
      write = write + 1
    end
  end
  for i = #inbox, write, -1 do inbox[i] = nil end
end

function Communication.update (bus, now)
  bus.time = now or bus.time
  for id in pairs(bus.inboxes) do prune(bus, id) end
end

function Communication.drain (bus, actor, limit)
  local id = actor:getActorId()
  prune(bus, id)
  local inbox = bus.inboxes[id]
  if not inbox then return {} end
  local count = math.min(limit or INBOX_LIMIT, #inbox)
  local out = {}
  for i = 1, count do out[i] = inbox[i] end
  for i = 1, count do table.remove(inbox, 1) end
  return out
end

return Communication
