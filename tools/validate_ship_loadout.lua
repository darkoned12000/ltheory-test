#!/usr/bin/env luajit
-- Saved ship module loadouts validate strictly and restore real equipment stats.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_ship_loadout%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

function class (ctor)
  local cls = {}; cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end
function subclass (base, ctor)
  local cls = {}; cls.__index = cls
  return setmetatable(cls, { __index = base, __call = function (T, ...)
    local self = setmetatable({}, T); if ctor then ctor(self, ...) end; return self
  end })
end
function insert (t, value) t[#t + 1] = value end
package.loaded['ffi'] = { new = function () return {} end }
local Entity = class(); package.loaded['Game.Entity'] = Entity
for _, name in ipairs({
  'Game.Entities.Dust', 'Game.Entities.Nebula', 'Game.Frustum', 'Game.Content',
  'Game.Item', 'Game.Production', 'Game.Communication', 'Game.Directives',
  'Game.NpcPopulation', 'Game.NpcRegistry', 'Game.NpcLog', 'Game.Tombstones',
  'Game.GenerationFingerprint', 'Game.Knowledge', 'Game.NameGen',
}) do package.loaded[name] = {} end
_G.Config = { gen = { shipRes = 8 } }
_G.Gen = { Ship = { ShipFighter = function () return {} end } }

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end
local function finish ()
  if failures == 0 then print(string.format('ship loadout: %d checks passed', checks)); os.exit(0) end
  print(string.format('ship loadout: %d/%d checks failed', failures, checks)); os.exit(1)
end

local System = dofile(root .. '/script/Game/Entities/System.lua')
local SocketType = require('Game.SocketKind')
local StableId = require('Game.StableId')
local shipId = 'ship:loadout'
local moduleId = StableId.Module(shipId, SocketType.Turret, 1)

check('legacy module rows remain valid', System.ValidateModuleEntry({ type = 'Turret', index = 1 }))
check('saved equipment id and matching slot id are valid',
  System.ValidateModuleEntry({ id = moduleId, type = 'Turret', index = 1,
    equipmentId = 'turret-mk2' }, shipId))
check('unknown equipment fails closed',
  not System.ValidateModuleEntry({ id = moduleId, type = 'Turret', index = 1,
    equipmentId = 'turret-mk9' }, shipId))
check('equipment for the wrong socket type fails closed',
  not System.ValidateModuleEntry({ id = moduleId, type = 'Turret', index = 1,
    equipmentId = 'thruster-mk2' }, shipId))
check('saved module id must match the destination slot',
  not System.ValidateModuleEntry({ id = 'ship:other:module:Turret:1', type = 'Turret', index = 1,
    equipmentId = 'turret-mk2' }, shipId))

local function module (moduleType)
  local value = { deleted = false }
  function value:getSocketType () return moduleType end
  function value:setScale (scale) self.scale = scale end
  function value:delete () self.deleted = true end
  return value
end
_G.Entities = {
  Thruster = function () return module(SocketType.Thruster) end,
  Turret = function () return module(SocketType.Turret) end,
}
_G.ShipType = function ()
  return { instantiate = function (_, id)
    local ship = { stableId = id, sockets = {
      { type = SocketType.Turret, typeIndex = 1 },
      { type = SocketType.Thruster, typeIndex = 1 },
    } }
    function ship:setInventoryCapacity (capacity) self.capacity = capacity end
    function ship:setPos (pos) self.pos = pos end
    function ship:getScale () return 4 end
    function ship:plug (child, index)
      for _, socket in ipairs(self.sockets) do
        if socket.type == child:getSocketType() and socket.child == nil
           and (index == nil or index == socket.typeIndex) then
          socket.child = child
          child.stableId = StableId.Module(self.stableId, socket.type, socket.typeIndex)
          return true
        end
      end
      return false
    end
    return ship
  end }
end
local system = { rng = { get31 = function () return 1 end } }
function system:addChild (ship) ship.parent = self end
function system:isTombstoned () return false end
local ship = System.spawnShip(system, 'fighter', {
  shipId = shipId, seed = 7, pos = { x = 0, y = 0, z = 0 },
  modules = {
    { id = moduleId, type = 'Turret', index = 1, equipmentId = 'turret-mk2' },
    { id = StableId.Module(shipId, SocketType.Thruster, 1), type = 'Thruster', index = 1,
      equipmentId = 'thruster-mk3' },
  },
})
check('spawn restores saved turret tier and combat stats',
  ship and ship.sockets[1].child.equipmentId == 'turret-mk2'
  and ship.sockets[1].child.projDamage == 60 and ship.sockets[1].child.projRange == 1200)
check('spawn restores saved thruster tier and movement stats',
  ship and ship.sockets[2].child.equipmentId == 'thruster-mk3'
  and ship.sockets[2].child.thrustMultiplier == 1.4
  and ship.sockets[2].child.turnMultiplier == 1.25)

finish()
