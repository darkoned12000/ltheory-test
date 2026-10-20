--[[ EconomyRegistry -- the set of entities that carry an economic component.

  The economy used to rescan EVERY child of the System every frame looking for
  factory/flow/market/trader/yield components:

      for _, e in self.parent:iterChildren() do
        if e:hasFactory() then ...
        if e:hasFlows()   then ...
        ... five checks per child
      end

  With a streamed asteroid field that is ~10,600 children scanned five times
  each, every frame, to find the handful of stations. Measured cost: 1.06 ms per
  frame -- 7.5% of the frame -- for a scene with exactly one station and no
  trade happening at all.

  The registry keeps the economy-relevant entities directly, so the scan is
  proportional to the number of ECONOMIC entities rather than the number of
  entities in the world. Entities register when they gain an economic component
  and unregister when they are removed from the System.

  This lives in its own file because the component adders (Flows, Market,
  Trader, Factory, Yield) must all reach it, and they are themselves loaded
  into the same namespace as the Economy component -- requiring Economy from
  them would be circular.
]]

local Registry = {}

-- Registry of economy-relevant entities, per owning System.
local registries = setmetatable({}, { __mode = 'k' })

local function registryFor (parent)
  local reg = registries[parent]
  if not reg then
    reg = { entities = {}, index = {} }
    registries[parent] = reg
  end
  return reg
end

-- Register an entity as economy-relevant. Called by the component adders.
-- An entity usually gains its economic components BEFORE it is added to the
-- System (a station is built, then parented), in which case there is no parent
-- yet and registration is deferred to AddedToParent. Both orders are handled.
function Registry.register (entity)
  local parent = entity.parent
  if not parent then
    -- Not parented yet: remember to register on the way in.
    if not entity.economyRegisterPending then
      entity.economyRegisterPending = true
      entity:register(Event.AddedToParent, Registry.onAddedToParent)
    end
    return
  end
  entity.economyRegisterPending = nil
  local reg = registryFor(parent)
  if reg.index[entity] then return end
  reg.entities[#reg.entities + 1] = entity
  reg.index[entity] = #reg.entities
end

-- Called when an entity is added to a parent: register it if it carries an
-- economic component.
function Registry.onAddedToParent (self, event)
  if not (self.hasFactory or self.hasFlows or self.hasMarket
          or self.hasTrader or self.hasYield) then return end
  Registry.register(self)
end

function Registry.unregister (entity)
  local parent = entity.parent
  if not parent then return end
  local reg = registries[parent]
  if not reg then return end
  local i = reg.index[entity]
  if not i then return end
  local last = #reg.entities
  local moved = reg.entities[last]
  reg.entities[i] = moved
  reg.entities[last] = nil
  reg.index[entity] = nil
  if moved ~= entity then reg.index[moved] = i end
end

-- The list of economy-relevant entities under `parent`, in registration order.
function Registry.entitiesFor (parent)
  local reg = registries[parent]
  if not reg then return {} end
  return reg.entities
end

return Registry
