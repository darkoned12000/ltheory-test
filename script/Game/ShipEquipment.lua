-- Canonical equipment definitions. Hulls ship with Mk I modules; shipyard
-- refits replace a socket with a higher tier and persist the equipment id.

local SocketType = require('Game.SocketKind')

local Equipment = {}

Equipment.Defs = {
  ['thruster-mk1'] = {
    id = 'thruster-mk1', name = 'Thruster Mk I', type = SocketType.Thruster,
    tier = 1, cost = 900, thrust = 1.0, turn = 1.0,
  },
  ['thruster-mk2'] = {
    id = 'thruster-mk2', name = 'Thruster Mk II', type = SocketType.Thruster,
    tier = 2, cost = 2700, thrust = 1.18, turn = 1.10,
  },
  ['thruster-mk3'] = {
    id = 'thruster-mk3', name = 'Thruster Mk III', type = SocketType.Thruster,
    tier = 3, cost = 7200, thrust = 1.40, turn = 1.25,
  },
  ['turret-mk1'] = {
    id = 'turret-mk1', name = 'Pulse Turret Mk I', type = SocketType.Turret,
    tier = 1, cost = 1800, damage = 40, range = 1000, speed = 600, rate = 10,
  },
  ['turret-mk2'] = {
    id = 'turret-mk2', name = 'Pulse Turret Mk II', type = SocketType.Turret,
    tier = 2, cost = 5400, damage = 60, range = 1200, speed = 750, rate = 10,
  },
  ['turret-mk3'] = {
    id = 'turret-mk3', name = 'Pulse Turret Mk III', type = SocketType.Turret,
    tier = 3, cost = 12000, damage = 90, range = 1500, speed = 900, rate = 10,
  },
}

Equipment.Order = {
  'thruster-mk1', 'thruster-mk2', 'thruster-mk3',
  'turret-mk1', 'turret-mk2', 'turret-mk3',
}

function Equipment.Get (id)
  return type(id) == 'string' and Equipment.Defs[id] or nil
end

function Equipment.DefaultId (moduleType)
  if moduleType == SocketType.Thruster then return 'thruster-mk1' end
  if moduleType == SocketType.Turret then return 'turret-mk1' end
  return nil
end

function Equipment.NextId (id)
  local def = Equipment.Get(id)
  if not def or def.tier >= 3 then return nil end
  local nextId = string.lower(def.type) .. '-mk' .. tostring(def.tier + 1)
  return Equipment.Get(nextId) and nextId or nil
end

function Equipment.Label (id)
  local def = Equipment.Get(id)
  return def and def.name or tostring(id or 'Unknown module')
end

function Equipment.TierOf (module)
  local def = module and Equipment.Get(module.equipmentId)
  return def and def.tier or 1
end

function Equipment.Apply (module, id)
  local def = Equipment.Get(id)
  if not def or type(module) ~= 'table' then return false end
  module.equipmentId, module.equipmentTier = def.id, def.tier
  if def.type == SocketType.Thruster then
    module.thrustMultiplier = def.thrust
    module.turnMultiplier = def.turn
  elseif def.type == SocketType.Turret then
    module.projDamage = def.damage
    module.projRange = def.range
    module.projSpeed = def.speed
    module.projLife = def.range / def.speed
    module.projSpread = 0.01
    module.rateOfFire = def.rate
  end
  return true
end

function Equipment.Ensure (module, moduleType)
  if type(module) ~= 'table' then return false end
  if module.equipmentId ~= nil then
    local def = Equipment.Get(module.equipmentId)
    return def ~= nil and def.type == moduleType
  end
  return Equipment.Apply(module, Equipment.DefaultId(moduleType))
end

function Equipment.ThrustFactors (ship)
  local sockets = ship and (ship.getSockets and ship:getSockets() or ship.sockets)
  if type(sockets) ~= 'table' then return { thrust = 0, turn = 0 } end
  local count, thrust, turn = 0, 0, 0
  for _, socket in ipairs(sockets) do
    if socket.type == SocketType.Thruster then
      count = count + 1
      local child = socket.child
      local def = child and not child.deleted and Equipment.Get(child.equipmentId) or nil
      if def then thrust, turn = thrust + def.thrust, turn + def.turn end
    end
  end
  if count == 0 then return { thrust = 0, turn = 0 } end
  return { thrust = thrust / count, turn = turn / count }
end

function Equipment.WeaponDps (ship)
  local sockets = ship and (ship.getSockets and ship:getSockets() or ship.sockets)
  if type(sockets) ~= 'table' then return 0 end
  local dps = 0
  for _, socket in ipairs(sockets) do
    local child = socket.child
    if socket.type == SocketType.Turret and child and not child.deleted then
      dps = dps + math.max(0, tonumber(child.projDamage) or 0)
        * math.max(0, tonumber(child.rateOfFire) or 0)
    end
  end
  return dps
end

return Equipment
