#!/usr/bin/env luajit
-- Equipment tiers must affect live turrets, projectiles, and ship thrust.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_equipment_runtime%.lua$', '')
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
_G.min, _G.max, _G.abs, _G.exp = math.min, math.max, math.abs, math.exp

local Vec = {}; Vec.__index = Vec
local function vec (x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, Vec) end
function Vec.__add (a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
function Vec:scale (value) return vec(self.x * value, self.y * value, self.z * value) end
function Vec:length () return math.sqrt(self.x*self.x + self.y*self.y + self.z*self.z) end
function Vec:normalize ()
  local length = self:length()
  return length > 0 and self:scale(1 / length) or vec()
end
_G.Vec3f = vec
_G.Event = { Update = 'update', Render = 'render', Destroyed = 'destroyed' }
_G.Quat = { Identity = function () return {} end }

local nextId = 0
local Entity = class()
function Entity:addRigidBody () self.body = {} end
function Entity:addVisibleMesh () end
function Entity:register () end
function Entity:getId () return self.id end
package.loaded['Game.Entity'] = Entity
_G.requireAll = function () return {} end
local rng = {}
function rng:managed () return self end
function rng:getUniformRange () return 1 end
function rng:getDir3 () return vec(0, 0, -1) end
function rng:getExp () return 1 end
package.loaded['Game.Seed'] = { rng = function () return rng end }
local mesh = {}
function mesh:computeNormals () end
function mesh:computeAO () end
_G.Gen = {
  ShipFighter = { TurretSingle = function () return mesh end, EngineSingle = function () return mesh end },
  Primitive = { Billboard = function () return {} end },
}
_G.Cache = { Texture = function () return {} end, Shader = function () return {} end }
_G.ShaderVarCache = function () return {} end
_G.Material = { Create = function () return {} end, Debug = function () return {} end }
local sound = { freed = false }
function sound:set3DPos () end
function sound:set3DMinMaxDistance () end
function sound:setVolume () end
function sound:setFreeOnFinish () end
function sound:play () end
function sound:setPitch () end
function sound:free () self.freed = true end
_G.Sound = { Load = function () return sound end }
_G.Config = {
  game = { pulseRange = 1000, pulseSpeed = 600, pulseSpread = 0.01,
    pulseDamage = 40, pulseSize = 64, rateOfFire = 10, boostCost = 0 },
  audio = { sfxVolume = 1, sfx = {
    blaster = { sound = 'blaster', minDist = 10, volume = 1 },
    engine = { sound = 'engine', minDist = 10, maxDist = 1000, volume = 1 },
  } },
}

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end
local function finish ()
  if failures == 0 then print(string.format('equipment runtime: %d checks passed', checks)); os.exit(0) end
  print(string.format('equipment runtime: %d/%d checks failed', failures, checks)); os.exit(1)
end

local ShipEquipment = require('Game.ShipEquipment')
local SocketType = require('Game.SocketKind')
local Turret = dofile(root .. '/script/Game/Entities/Turret.lua')
local Thruster = dofile(root .. '/script/Game/Entities/Thruster.lua')
local turret = Turret()
check('new turret receives canonical Mk I equipment',
  turret.equipmentId == 'turret-mk1' and turret.projDamage == 40 and turret.rateOfFire == 10)
check('turret exposes real damage per second',
  type(turret.getDps) == 'function' and turret:getDps() == 400)
ShipEquipment.Apply(turret, 'turret-mk3')
check('upgraded turret exposes upgraded damage per second',
  type(turret.getDps) == 'function' and turret:getDps() == 900)
local thruster = Thruster()
check('new thruster receives canonical Mk I equipment',
  thruster.equipmentId == 'thruster-mk1'
  and thruster.thrustMultiplier == 1 and thruster.turnMultiplier == 1)

local projectile
function turret:getRoot () return { addProjectile = function () projectile = {}; return projectile end } end
function turret:getParent () return { getVelocity = function () return vec() end } end
function turret:getForward () return vec(0, 0, -1) end
function turret:toWorld () return vec() end
turret.cooldown = 0
turret:fire()
check('firing snapshots the equipped damage onto the projectile',
  projectile and projectile.damage == 90)

-- Pulse collision uses the projectile snapshot, not the old global damage.
local pulseFields = {}
_G.CType = {
  Int32 = {}, Float32 = {}, Vec3f = {}, Matrix = {},
  Pointer = function () return {} end,
  Struct = function ()
    local cls = { fields = pulseFields }
    function cls:add (kind, name) self.fields[name] = kind end
    function cls:setInitializer (fn) self.initializer = fn end
    function cls:addOnDestruct (fn) self.destruct = fn end
    function cls:define () end
    return cls
  end,
}
_G.Preload = { Add = function () end }
_G.Profiler = { Begin = function () end, End = function () end }
_G.Ray = function () return {} end
_G.Deref = function (value) return value end
local Pulse = dofile(root .. '/script/Game/Entities/Pulse.lua')
check('pulse projectiles carry a damage field', pulseFields.damage ~= nil)
local hit = { health = 100 }
function hit:damage (amount) self.damageTaken = amount end
local body = { getParentBody = function () return nil end }
function Entity.fromRigidBody () return hit end
local physics = { rayCast = function () return { body = body } end }
local pulse = { pos = vec(), vel = vec(1, 0, 0), life = 1, damage = 90,
  source = {}, delete = function (self) self.deleted = true end }
Pulse.UpdatePostPhysics({ physics = physics }, { pulse }, 0.1)
check('pulse impact deals its snapshotted equipped damage',
  hit.damageTaken == 90 and pulse.deleted)

-- Real ThrustController force/torque must consume the installed loadout.
local Movement = require('Game.ShipMovement')
package.loaded['Game.ShipMovement'] = Movement
dofile(root .. '/script/Game/Components/ThrustController.lua')
local engine = setmetatable({ sockets = {
  { type = SocketType.Thruster, child = thruster },
} }, Entity)
function engine:getParent () return nil end
function engine:discharge () return true end
function engine:getMass () return 50000 end
function engine:getRadius () return 10 end
function engine:hasInventory () return true end
function engine:getInventoryCapacity () return 100 end
function engine:getInventoryFree () return 100 end
function engine:getForward () return vec(0, 0, -1) end
function engine:getRight () return vec(1, 0, 0) end
function engine:getUp () return vec(0, 1, 0) end
function engine:getPos () return vec() end
function engine:getVelocity () return vec() end
function engine:setDrag () end
function engine:applyForce (force) self.lastForce = force end
function engine:applyTorqueLocal (torque) self.lastTorque = torque end
function engine:iterSocketsByType ()
  local done = false
  return function ()
    if done then return nil end
    done = true
    return thruster
  end
end
engine:addThrustController()
ShipEquipment.Apply(thruster, 'thruster-mk3')
engine.thrustController.forward = 1
engine.thrustController:update(engine, 0.016)
check('equipped thruster multiplies real forward force',
  engine.lastForce and math.abs(engine.lastForce.z + 1.9e7 * 1.4) < 1)
engine.thrustController.forward, engine.thrustController.pitch = 0, 1
engine.thrustController:update(engine, 0.016)
check('equipped thruster multiplies real turning torque',
  engine.lastTorque and math.abs(engine.lastTorque.x - 2.46e7 * 1.25) < 1)
check('ship shutdown frees the looping engine voice',
  type(engine.shutdownThrustController) == 'function'
  and engine:shutdownThrustController() and sound.freed
  and engine.thrustController.engineSound == nil)

finish()
