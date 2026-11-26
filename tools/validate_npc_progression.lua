#!/usr/bin/env luajit
-- Phase 2 NPC progression contracts. Runs the real policy/action modules with
-- production Entity components and lightweight physics/GPU boundaries.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_progression%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

function class (ctor)
  local cls = {}
  cls.__index = cls
  return setmetatable(cls, { __call = function (T, ...)
    local self = setmetatable({}, T)
    if ctor then ctor(self, ...) end
    return self
  end })
end

function subclass (base, ctor)
  local cls = class()
  return setmetatable(cls, {
    __index = base,
    __call = function (T, ...)
      local self = base()
      setmetatable(self, T)
      if ctor then ctor(self, ...) end
      return self
    end,
  })
end

function insert (t, value) t[#t + 1] = value end
function remove (t, index)
  return table.remove(t, index)
end
function format (f, ...) return string.format(f, ...) end
_G.min, _G.max, _G.floor, _G.ceil = math.min, math.max, math.floor, math.ceil
_G.abs = math.abs
_G.Config = {
  debug = { instantJobs = true, jobSpeed = 10000, damageLog = false },
  game = { aiUsesBoost = false },
}
_G.PHX = { Math = { ExpMap1Signed = function (value) return value end } }
_G.Quat = { Identity = function () return {} end }
_G.EconomyRegistry = { register = function () end, unregister = function () end }
_G.Profiler = { Begin = function () end, End = function () end }
table.clear = table.clear or function (value)
  for key in pairs(value) do value[key] = nil end
end

local logs = {}
_G.printf = function (message, ...)
  logs[#logs + 1] = format(message, ...)
end

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then
    print('ok   - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or ''))
  else
    failures = failures + 1
    print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or ''))
  end
end

local function finish ()
  if failures == 0 then
    print(string.format('npc progression: %d checks passed', checks))
    os.exit(0)
  end
  print(string.format('npc progression: %d/%d checks failed', failures, checks))
  os.exit(1)
end

local policyOk, Progression = pcall(require, 'Game.NpcProgression')
check('NpcProgression module loads', policyOk, Progression)
if not policyOk then finish() end

-- Minimal vector/transform boundary used by the real Action and DockAt modules.
local Vec = {}
Vec.__index = Vec
local function vec (x, y, z)
  return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, Vec)
end
_G.Vec3f = vec
function Vec.__add (a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
function Vec.__sub (a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
function Vec.__unm (a) return vec(-a.x, -a.y, -a.z) end
function Vec:scale (value) return vec(self.x * value, self.y * value, self.z * value) end
function Vec:muls (value) return self:scale(value) end
function Vec:length () return math.sqrt(self.x*self.x + self.y*self.y + self.z*self.z) end
function Vec:distance (other) return (self - other):length() end
function Vec:dot (other) return self.x*other.x + self.y*other.y + self.z*other.z end
function Vec:cross (other)
  return vec(self.y*other.z - self.z*other.y,
             self.z*other.x - self.x*other.z,
             self.x*other.y - self.y*other.x)
end
function Vec:normalize ()
  local length = self:length()
  if length < 1e-9 then return vec() end
  return self:scale(1 / length)
end

local Event = dofile(root .. '/script/Game/Event.lua')
_G.Event = Event
local Entity = dofile(root .. '/script/Game/Entity.lua')
package.loaded['Game.Entity'] = Entity
for _, name in ipairs({
  'Actions', 'Assets', 'Children', 'Credits', 'Dispositions', 'Dockable', 'Health', 'Inventory', 'Name', 'Owner', 'Sockets',
}) do
  dofile(root .. '/script/Game/Components/' .. name .. '.lua')
end

package.loaded['Game.ScannerDB'] = { Create = function (id) return { id = id } end }
local Player = dofile(root .. '/script/Game/Entities/Player.lua')
package.loaded['Game.Entities.Player'] = Player
package.loaded['Game.Material'] = {}
package.loaded['Game.ShipMovement'] = {}
package.loaded['Game.Targeting'] = {}
package.loaded['Game.Knowledge'] = { Create = function () return {} end }
local Ship = dofile(root .. '/script/Game/Entities/Ship.lua')
package.loaded['Game.Entities.Ship'] = Ship

local Item = require('Game.Item')
dofile(root .. '/script/Game/Content.lua') -- real economy anchors
local StableId = require('Game.StableId')
local SocketType = require('Game.SocketKind')
local Archetypes = require('Game.ShipArchetypes')
local ShipEquipment = require('Game.ShipEquipment')
local Credit = Item.Credit

local function makeController ()
  local controller = { forward = 0, right = 0, up = 0, yaw = 0, pitch = 0, roll = 0, boost = 0 }
  function controller:clear ()
    self.forward, self.right, self.up, self.yaw, self.pitch, self.roll, self.boost = 0, 0, 0, 0, 0, 0, 0
  end
  return controller
end

local function addTransform (entity, pos, radius)
  entity.body = {}
  entity.pos, entity.velocity = pos or vec(), vec()
  entity.radius, entity.scaleValue = radius or 10, 1
  entity.thrustController = makeController()
  function entity:getPos () return self.pos end
  function entity:setPos (value) self.pos = value; self.setPosCalls = (self.setPosCalls or 0) + 1 end
  function entity:getVelocity () return self.velocity end
  function entity:setVelocity (value) self.velocity = value end
  function entity:getRadius () return self.radius end
  function entity:getScale () return self.scaleValue end
  function entity:getForward () return vec(0, 0, -1) end
  function entity:getRight () return vec(1, 0, 0) end
  function entity:getUp () return vec(0, 1, 0) end
  function entity:getThrustController () return self.thrustController end
end

local function makeActor (id, role, credits)
  local actor = Player({ isNpc = true, npcId = id, profile = { role = role } })
  actor.stableId = id
  actor:addItem(Credit, credits or 0)
  actor.deleteCalls = 0
  local baseDelete = actor.delete
  actor.delete = function (self)
    self.deleteCalls = self.deleteCalls + 1
    return baseDelete(self)
  end
  return actor
end

local function makeShip (id, kind, capacity, pos)
  local ship = Entity()
  setmetatable(ship, Ship)
  ship.stableId, ship.shipKind = id, kind or 'fighter'
  ship:addActions()
  ship:addChildren()
  ship:addHealth(100, 0)
  ship:addInventory(capacity or 100)
  ship:addSockets()
  addTransform(ship, pos, 10)
  function ship:attach (child, attachmentPos, rot)
    assert(self.body and child.body, 'fixture attachment requires bodies')
    self:addChild(child)
  end
  function ship:detach (child)
    assert(self.body and child.body, 'fixture detach requires bodies')
    self:removeChild(child)
  end
  function ship:hasThrustController () return true end
  function ship:shutdownThrustController () self.thrustShutdown = true end
  return ship
end

local function addSocket (ship, moduleType, index, occupied)
  local socketId = StableId.Module(ship.stableId, moduleType, index)
  ship:addSocket(moduleType, vec(index, 0, 1), true, index, socketId)
  local socket = ship.sockets[#ship.sockets]
  if occupied then
    local child = makeModule(moduleType)
    socket.child = child
    child.stableId, child.moduleType, child.moduleIndex = socketId, moduleType, index
    ship:attach(child, socket.pos, Quat.Identity())
  end
  return socket
end

local moduleFailure = false
function makeModule (moduleType)
  local module = Entity()
  if moduleFailure then module.body = nil else module.body = {} end
  module.moduleType = moduleType
  module.projRange, module.projSpeed = 1000, 600
  function module:getSocketType () return self.moduleType end
  function module:setScale (value) self.scaleValue = value end
  return module
end

package.loaded['Game.Entities.Thruster'] = function () return makeModule(SocketType.Thruster) end
package.loaded['Game.Entities.Turret'] = function () return makeModule(SocketType.Turret) end
_G.requireAll = function (path)
  if path == 'Game.Entities' then
    return {
      Thruster = package.loaded['Game.Entities.Thruster'],
      Turret = package.loaded['Game.Entities.Turret'],
    }
  end
  return {}
end

local function makeStation (id, pos, shipyard)
  local station = Entity()
  station.stableId, station.shipyard = id, shipyard ~= false
  station:addChildren()
  station:addDockable()
  station:addHealth(10000, 0)
  station:addInventory(1000000)
  station:addCredits(500000)
  addTransform(station, pos, 800)
  return station
end

local function makeSystem ()
  local system = Entity()
  system:addChildren()
  system.time, system.stableIndex, system.tombstones = 0, {}, {}
  system.spawnCalls, system.destroyedCalls = 0, 0
  system.failSpawn, system.failDock = nil, false
  function system:getTime () return self.time end
  function system:resolveStableId (id) return self.stableIndex[id] end
  function system:isTombstoned (id) return self.tombstones[id] == true end
  function system:markTombstone (id) self.tombstones[id] = true end
  function system:recordDestroyed () self.destroyedCalls = self.destroyedCalls + 1 end
  function system:registerKnowledgeShip () end
  function system:unregisterKnowledgeShip () end
  function system:spawnShip (kind, opts)
    self.spawnCalls = self.spawnCalls + 1
    self.lastSpawn = { kind = kind, opts = opts }
    if self.failSpawn == 'throw' then error('fixture spawn failure') end
    if self.failSpawn == 'nil' then return nil end
    local ship = makeShip(opts.shipId, kind, Archetypes.Get(kind).cargo, opts.pos)
    self:addChild(ship)
    self.stableIndex[ship.stableId] = ship
    return ship
  end
  return system
end

local function makeFixture (opts)
  opts = opts or {}
  local system = makeSystem()
  local station = makeStation('station:test', vec(0, 0, 0), opts.shipyard)
  local actor = makeActor(opts.actorId or 'npc:test', opts.role or 'industrial', opts.credits or 10000)
  local ship = makeShip(opts.shipId or 'ship:old', opts.kind or 'fighter', opts.capacity or 100, opts.pos)
  ship.npcRole = opts.role or 'industrial'
  system:addChild(actor)
  system:addChild(station)
  system:addChild(ship)
  system.stableIndex[ship.stableId] = ship
  ship:setOwner(actor)
  actor:setControlling(ship)
  if opts.docked ~= false then station:addDocked(ship) end
  return system, station, actor, ship
end

local function step (ship, dt)
  ship:updateActions({ dt = dt })
end

local function liveChildCount (parent)
  local count = 0
  for _, child in ipairs(parent.children or {}) do
    if child.parent == parent then count = count + 1 end
  end
  return count
end

local function hasLog (needle)
  for _, line in ipairs(logs) do
    if line:sub(1, 17) == '[NPC PROGRESSION]' and line:find(needle, 1, true) then return true end
  end
  return false
end

-- Pure policy: hand-derived values use the canonical hull/equipment economy.
local policyShip = makeShip('ship:policy', 'fighter', 25)
policyShip.npcRole = 'industrial'
policyShip.health, policyShip.healthMax = 40, 100
check('repair cost is the missing fraction of the hull repair allowance',
  Progression.RepairCost(policyShip) == 1296, Progression.RepairCost(policyShip))
check('refit cost includes equipment plus one hour of upkeep',
  Progression.RefitCost(policyShip, SocketType.Thruster, 3600) == 904,
  Progression.RefitCost(policyShip, SocketType.Thruster, 3600))
check('ship prices follow the canonical hull catalog',
  Progression.ShipCost(policyShip, 'fighter') == 18000
  and Progression.ShipCost(policyShip, 'freighter') == 55000
  and Progression.ShipCost(policyShip, 'industrial') == 95000
  and Progression.ShipCost(policyShip, 'capital') == 280000)
check('upkeep accrues by simulated hours', Progression.Upkeep(policyShip, 7200) == 8)
check('upkeep rejects negative elapsed time', Progression.Upkeep(policyShip, -1) == 0)
check('affordability includes the requested reserve',
  Progression.CanAfford(100, 60, 40) and not Progression.CanAfford(99, 60, 40))
policyShip.health = 34
check('repair threshold is strictly below 35 percent hull',
  Progression.NeedsRepair(policyShip, 2000) and not Progression.NeedsRepair(policyShip, 1429))
policyShip.health = 35
check('repair threshold boundary does not trigger', not Progression.NeedsRepair(policyShip, 2000))
local refitPolicyShip = makeShip('ship:refit-policy', 'industrial', 180)
refitPolicyShip.npcRole = 'industrial'
refitPolicyShip.health = 40
addSocket(refitPolicyShip, SocketType.Thruster, 1, false)
check('empty role socket is filled with Mk I before an upgrade is requested',
  Progression.NextEquipment(refitPolicyShip, SocketType.Thruster) == 'thruster-mk1'
  and Progression.NeedsRefit(refitPolicyShip, 1000)
  and not Progression.NeedsRefit(refitPolicyShip, 918))
refitPolicyShip.health = 20
check('refit yields to urgent repair', not Progression.NeedsRefit(refitPolicyShip, 5000))
local buyer = makeShip('ship:buyer', 'fighter', 25)
buyer.npcRole = 'freighter'
check('upkeep follows the current hull rather than the desired role', Progression.Upkeep(buyer, 3600) == 4)
check('purchase threshold requires a role upgrade and three times the price',
  Progression.NeedsShip(buyer, 165000) and not Progression.NeedsShip(buyer, 164999))
local matchedBuyer = makeShip('ship:matched-buyer', 'freighter', 300)
matchedBuyer.npcRole = 'freighter'
check('matched-role ships can still progress to a capital hull',
  type(Progression.UpgradeShipKind) == 'function'
  and Progression.UpgradeShipKind(matchedBuyer) == 'capital'
  and Progression.NeedsShip(matchedBuyer, 840000)
  and not Progression.NeedsShip(matchedBuyer, 839999))
local capitalBuyer = makeShip('ship:capital-buyer', 'capital', 400)
capitalBuyer.npcRole = 'freighter'
check('capital is a terminal hull rather than a downgrade loop',
  Progression.UpgradeShipKind(capitalBuyer) == nil
  and not Progression.NeedsShip(capitalBuyer, 1000000))
check('role module and hull choices are deterministic',
  Progression.PreferredModule('fighter') == SocketType.Turret
  and Progression.PreferredModule('industrial') == SocketType.Thruster
  and Progression.PreferredShipKind('freighter') == 'freighter'
  and Progression.PreferredShipKind('unknown') == 'fighter')
local roleActor = makeActor('npc:role', 'capital', 0)
local roleShip = makeShip('ship:role', 'fighter', 25)
roleShip:setOwner(roleActor)
check('role falls back to the actor profile', Progression.Role(roleShip) == 'capital')

-- Load the production chunks under the same no-new-globals rule as the app
-- sandbox. Fixtures above intentionally use globals; gameplay modules must not.
local previousGlobalMT = getmetatable(_G)
local restrictedOk, restrictedErr = pcall(function ()
  setmetatable(_G, {
    __index = function (_, key) error('undefined global read: ' .. tostring(key)) end,
    __newindex = function (_, key) error('accidental global write: ' .. tostring(key)) end,
  })
  for _, path in ipairs({
    '/script/Game/NpcProgression.lua',
    '/script/Game/Actions/Repair.lua',
    '/script/Game/Actions/Refit.lua',
    '/script/Game/Actions/PurchaseShip.lua',
  }) do
    assert(loadfile(root .. path))()
  end
end)
setmetatable(_G, previousGlobalMT)
check('production modules load without sandbox globals', restrictedOk, restrictedErr)
if not restrictedOk then finish() end

local actionOk, Repair = pcall(require, 'Game.Actions.Repair')
check('Repair action module loads', actionOk, Repair)
if not actionOk then finish() end
local refitOk, Refit = pcall(require, 'Game.Actions.Refit')
check('Refit action module loads', refitOk, Refit)
if not refitOk then finish() end
local purchaseOk, PurchaseShip = pcall(require, 'Game.Actions.PurchaseShip')
check('PurchaseShip action module loads', purchaseOk, PurchaseShip)
if not purchaseOk then finish() end

-- Repair: approach uses the real DockAt/steering path and work uses ordinary dt.
local system, station, actor, ship = makeFixture({ docked = false })
ship:setPos(vec(3000, 0, 0))
ship.setPosCalls = nil -- ignore the fixture's deliberate initial placement
ship.health = 40
local repair = Repair(station)
ship:pushAction(repair)
step(ship, 1 / 60)
check('repair approaches through DockAt', ship:getCurrentAction() == repair.dockAction)
step(ship, 1 / 60) -- DockAt becomes active on the following simulation tick.
local approachController = ship:getThrustController()
check('repair approach steers without teleporting', ship.setPosCalls == nil
  and (math.abs(approachController.forward) > 1e-6 or math.abs(approachController.right) > 1e-6
    or math.abs(approachController.up) > 1e-6))
local dockPos = station:getPos() - station:getUp():scale(1.25 * station:getRadius() + ship:getRadius())
ship:setPos(dockPos)
step(ship, 1 / 60)
check('repair waits until docking completes', ship:getParent() == station and ship.health == 40)
step(ship, 1 / 60)
check('repair charges the actor and station once', actor:getItemCount(Credit) == 8704
  and station:getItemCount(Credit) == 1296 and repair.paid)
check('repair does not instantly restore hull', ship.health > 40 and ship.health < 41)

local _, saveRepairStation, saveRepairActor, saveRepairShip = makeFixture()
saveRepairShip.health = 40
local saveRepair = Repair(saveRepairStation)
saveRepairShip:pushAction(saveRepair)
step(saveRepairShip, 1 / 60)
local settledForSave = type(Repair.SettleForSave) == 'function'
  and Repair.SettleForSave(saveRepairShip)
check('saving settles a paid repair and removes its unsaved action',
  settledForSave and saveRepair.result == 'cancelled' and #saveRepairShip.actions == 0
  and saveRepairActor:getItemCount(Credit) == 9999
  and saveRepairStation:getItemCount(Credit) == 1)

local function repairAfter (dt, frames)
  local _, _, _, testShip = makeFixture()
  testShip.health = 40
  local action = Repair(testShip:getParent())
  testShip:pushAction(action)
  for _ = 1, frames do step(testShip, dt) end
  return testShip, action
end
local at60 = repairAfter(1 / 60, 30)
local at30 = repairAfter(1 / 30, 15)
check('repair rate is dt-invariant', math.abs(at60.health - at30.health) < 1e-9,
  string.format('60fps=%.6f 30fps=%.6f', at60.health, at30.health))
local slow, slowAction = repairAfter(1, 1)
check('repair ignores instant-job debug speed', slow.health < 42 and slowAction.elapsed == 1)

logs = {}
local completed, completedAction = repairAfter(1, 40)
check('repair completes over simulation time', completed.health == 100
  and completed:getCurrentAction() == nil and completedAction.result == 'completed')
check('repair logs start, progress, and completion', hasLog('repair start')
  and hasLog('repair progress') and hasLog('repair complete'))

local _, poorStation, poorActor, poorShip = makeFixture({ credits = 1295 })
poorShip.health = 40
local poorRepair = Repair(poorStation)
poorShip:pushAction(poorRepair)
step(poorShip, 1 / 60)
check('insufficient repair funds fail without charge or healing', poorRepair.result == 'failed'
  and poorShip.health == 40 and poorActor:getItemCount(Credit) == 1295
  and poorStation:getItemCount(Credit) == 0 and poorShip:getCurrentAction() == nil)

local _, refundStation, refundActor, refundShip = makeFixture()
refundShip.health = 40
local refundRepair = Repair(refundStation)
refundShip:pushAction(refundRepair)
step(refundShip, 1)
step(refundShip, 5) -- ten hull points repaired: 216 credits earned
refundStation:removeDocked(refundShip)
step(refundShip, 1)
check('undocking cancels and refunds only unperformed repair', refundRepair.result == 'cancelled'
  and math.abs(refundShip.health - 50) < 1e-9 and refundActor:getItemCount(Credit) == 9784
  and refundStation:getItemCount(Credit) == 216 and refundShip:getCurrentAction() == nil)
local refundBalance = refundActor:getItemCount(Credit)
refundRepair:onStop(refundShip)
check('repair cancellation cannot refund twice', refundActor:getItemCount(Credit) == refundBalance)

local _, deadStation, deadActor, deadShip = makeFixture()
deadShip.health = 40
local deadRepair = Repair(deadStation)
deadShip:pushAction(deadRepair)
step(deadShip, 1 / 60)
deadShip:damage(1000, nil)
step(deadShip, 1 / 60)
check('death cancels repair and restores the unused charge', deadRepair.result == 'cancelled'
  and deadActor:getItemCount(Credit) == 10000 and deadStation:getItemCount(Credit) == 0)

-- Refit: real SocketObj/plug identity, replacement, cargo and payment rollback.
local _, refitStation, refitActor, refitShip = makeFixture({ kind = 'industrial', capacity = 100 })
local freeSocket = addSocket(refitShip, SocketType.Thruster, 1, false)
local refit = Refit(refitStation, SocketType.Thruster, { upkeepElapsed = 3600 })
refitShip:pushAction(refit)
step(refitShip, 1 / 60)
check('refit installs into a free durable slot', refit.result == 'completed'
  and freeSocket.child and freeSocket.child.stableId == 'ship:old:module:Thruster:1'
  and freeSocket.child.moduleIndex == 1)
check('refit charges module plus upkeep', refitActor:getItemCount(Credit) == 9081
  and refitStation:getItemCount(Credit) == 919)

local _, occupiedStation, occupiedActor, occupiedShip = makeFixture()
local occupiedSocket = addSocket(occupiedShip, SocketType.Turret, 1, true)
local oldModule = occupiedSocket.child
local occupiedRefit = Refit(occupiedStation, SocketType.Turret, { slot = 1 })
occupiedShip:pushAction(occupiedRefit)
step(occupiedShip, 1 / 60)
check('occupied socket rejects an add refit', occupiedRefit.result == 'failed'
  and occupiedSocket.child == oldModule and not oldModule.deleted
  and occupiedActor:getItemCount(Credit) == 10000 and occupiedShip:getCurrentAction() == nil)

local replace = Refit(occupiedStation, SocketType.Turret, { slot = 1, replace = true })
occupiedShip:pushAction(replace)
step(occupiedShip, 1 / 60)
check('replacement reuses the durable module slot id', replace.result == 'completed'
  and occupiedSocket.child ~= oldModule and oldModule.deleted and oldModule.parent == nil
  and occupiedSocket.child.stableId == oldModule.stableId)

local _, cargoStation, cargoActor, cargoShip = makeFixture({ capacity = 10 })
cargoShip:addItem(Item.Iron, 2) -- eight mass, two free
local cargoSocket = addSocket(cargoShip, SocketType.Thruster, 1, false)
local cargoRefit = Refit(cargoStation, SocketType.Thruster, { cargo = 3 })
cargoShip:pushAction(cargoRefit)
step(cargoShip, 1 / 60)
check('refit respects temporary cargo clearance', cargoRefit.result == 'failed'
  and cargoSocket.child == nil and cargoActor:getItemCount(Credit) == 10000)

local _, noIdStation, noIdActor, noIdShip = makeFixture()
local noIdSocket = addSocket(noIdShip, SocketType.Thruster, 1, false)
noIdSocket.moduleId = nil
local noIdRefit = Refit(noIdStation, SocketType.Thruster)
noIdShip:pushAction(noIdRefit)
step(noIdShip, 1 / 60)
check('refit derives a missing durable slot id', noIdRefit.result == 'completed'
  and noIdSocket.moduleId == 'ship:old:module:Thruster:1'
  and noIdSocket.child.stableId == noIdSocket.moduleId)

local _, failedStation, failedActor, failedShip = makeFixture()
local failedSocket = addSocket(failedShip, SocketType.Turret, 1, true)
local retainedModule = failedSocket.child
moduleFailure = true
local failedRefit = Refit(failedStation, SocketType.Turret, { slot = 1, replace = true })
failedShip:pushAction(failedRefit)
step(failedShip, 1 / 60)
moduleFailure = false
check('failed replacement restores the old module without charging', failedRefit.result == 'failed'
  and failedSocket.child == retainedModule and not retainedModule.deleted
  and failedActor:getItemCount(Credit) == 10000 and failedStation:getItemCount(Credit) == 0)

local _, brokeStation, brokeActor, brokeShip = makeFixture({ credits = 95 })
addSocket(brokeShip, SocketType.Thruster, 1, false)
local brokeRefit = Refit(brokeStation, SocketType.Thruster)
brokeShip:pushAction(brokeRefit)
step(brokeShip, 1 / 60)
check('unaffordable refit leaves socket and credits unchanged', brokeRefit.result == 'failed'
  and brokeShip.sockets[1].child == nil and brokeActor:getItemCount(Credit) == 95)

local _, invalidStation, invalidActor, invalidShip = makeFixture()
local invalidRefit = Refit(invalidStation, 'NotASocket')
invalidShip:pushAction(invalidRefit)
step(invalidShip, 1 / 60)
check('invalid refit type fails safely', invalidRefit.result == 'failed'
  and invalidActor:getItemCount(Credit) == 10000)
check('failed refit schedules a retry cooldown', invalidShip.npcNextServiceAt ~= nil)

local originalRequireAll = _G.requireAll
_G.requireAll = function () return {} end
local _, directStation, directActor, directShip = makeFixture({ credits = 100000 })
local directSocket = addSocket(directShip, SocketType.Turret, 1, false)
local directRefit = Refit(directStation, SocketType.Turret, { equipment = 'turret-mk2' })
directShip:pushAction(directRefit)
step(directShip, 1 / 60)
_G.requireAll = originalRequireAll
check('refit resolves module factories without a dynamic entity-directory scan',
  directRefit.result == 'completed' and directSocket.child
  and directSocket.child.equipmentId == 'turret-mk2'
  and directActor:getItemCount(Credit) == 94600)

local tierSystem, tierStation, tierActor, tierShip = makeFixture({ credits = 100000 })
local tierSocket = addSocket(tierShip, SocketType.Turret, 1, true)
ShipEquipment.Apply(tierSocket.child, 'turret-mk1')
local retainedModuleId = tierSocket.child.stableId
local tierRefit = Refit(tierStation, SocketType.Turret, {
  slot = 1, replace = true, equipment = 'turret-mk2',
})
tierShip:pushAction(tierRefit)
step(tierShip, 1 / 60)
check('selected refit installs real higher-tier weapon stats',
  tierRefit.result == 'completed' and tierSocket.child.equipmentId == 'turret-mk2'
  and tierSocket.child.projDamage == 60 and tierSocket.child.projRange == 1200)
check('selected refit preserves socket identity and charges the tier price',
  tierSocket.child.stableId == retainedModuleId
  and tierActor:getItemCount(Credit) == 94600
  and tierStation:getItemCount(Credit) == 5400)

-- Purchase: cargo preflight, stable identity, ownership and atomic rollback.
local purchaseSystem, purchaseStation, purchaseActor, purchaseShip = makeFixture({
  role = 'industrial', kind = 'fighter', capacity = 100, credits = 100000,
})
purchaseShip:addItem(Item.Iron, 10) -- 40 mass, requires more than a fighter hold
purchaseShip.afterProgression, purchaseShip.npcUpkeepElapsed = 'undock', 10
purchaseShip.npcNextTravelAt = 99
local purchase = PurchaseShip(purchaseStation, { kind = 'freighter' })
purchaseShip:pushAction(purchase)
step(purchaseShip, 1 / 60)
local newShip = purchaseActor:getControlling()
check('purchase spawns the requested role hull with a new stable id',
  purchase.result == 'completed' and newShip and newShip ~= purchaseShip
  and newShip.shipKind == 'freighter' and newShip.stableId == 'ship:npc:test:purchase:1'
  and purchaseSystem.lastSpawn.kind == 'freighter')
check('purchase transfers ownership and control', newShip:getOwner() == purchaseActor
  and purchaseActor:getAssets()[1] == newShip and #purchaseActor:getAssets() == 1)
check('purchase carries progression cooldowns and undock intent to the new hull',
  newShip.afterProgression == 'undock' and newShip.npcUpkeepElapsed == 10
  and newShip.npcNextTravelAt == 99)
check('purchase transfers all cargo', newShip:getItemCount(Item.Iron) == 10
  and purchaseShip:getItemCount(Item.Iron) == 0)
check('purchase pays station and leaves remaining credits with actor',
  purchaseActor:getItemCount(Credit) == 45000 and purchaseStation:getItemCount(Credit) == 55000
  and newShip:getItemCount(Credit) == 0)
check('purchase docks the new ship and retires only the old hull', newShip:getParent() == purchaseStation
  and purchaseShip.deleted and purchaseShip:getParent() == nil and purchaseShip:getOwner() == nil
  and purchaseShip.thrustShutdown)
check('purchase never kills or deletes the actor', not purchaseActor.deleted
  and purchaseActor.deleteCalls == 0 and purchaseActor:getParent() == purchaseSystem
  and purchaseSystem.destroyedCalls == 0)
check('retired ship id is tombstoned', purchaseSystem:isTombstoned(purchaseShip.stableId))

local function failedPurchase (mode, opts)
  local sys, st, act, old = makeFixture(opts)
  sys.failSpawn = mode
  local action = PurchaseShip(st, { kind = 'freighter' })
  old:pushAction(action)
  step(old, 1 / 60)
  return sys, st, act, old, action
end
for _, mode in ipairs({ 'nil', 'throw' }) do
  local sys, st, act, old, action = failedPurchase(mode, { credits = 100000 })
  check('spawn ' .. mode .. ' refunds atomically', action.result == 'failed'
    and act:getItemCount(Credit) == 100000 and st:getItemCount(Credit) == 0
    and act:getControlling() == old and old:getOwner() == act and not old.deleted
    and act.deleteCalls == 0 and old:getCurrentAction() == nil)
end

local overflowSystem, overflowStation, overflowActor, overflowShip = makeFixture({
  capacity = 100, credits = 100000,
})
overflowShip:addItem(Item.Iron, 10)
local overflow = PurchaseShip(overflowStation, { kind = 'fighter' })
overflowShip:pushAction(overflow)
step(overflowShip, 1 / 60)
check('insufficient new cargo space prevents purchase before spawning', overflow.result == 'failed'
  and overflowSystem.spawnCalls == 0 and overflowActor:getItemCount(Credit) == 100000
  and overflowShip:getItemCount(Item.Iron) == 10 and not overflowShip.deleted)

local dockSystem, dockStation, dockActor, dockShip = makeFixture({ credits = 100000 })
dockStation.failDock = true
local baseDock = dockStation.addDocked
dockStation.addDocked = function () error('fixture dock failure') end
local dockFailure = PurchaseShip(dockStation, { kind = 'freighter' })
dockShip:pushAction(dockFailure)
step(dockShip, 1 / 60)
dockStation.addDocked = baseDock
check('new-ship docking failure refunds and removes the spawned hull', dockFailure.result == 'failed'
  and dockActor:getItemCount(Credit) == 100000 and dockStation:getItemCount(Credit) == 0
  and dockActor:getControlling() == dockShip and liveChildCount(dockSystem) == 2
  and dockActor.deleteCalls == 0)

local creditSystem, creditStation, creditActor, creditShip = makeFixture({ credits = 100000 })
creditStation.addItem = function () return false end
local creditFailure = PurchaseShip(creditStation, { kind = 'freighter' })
creditShip:pushAction(creditFailure)
step(creditShip, 1 / 60)
check('station payment failure refunds and preserves the old ship', creditFailure.result == 'failed'
  and creditActor:getItemCount(Credit) == 100000 and creditActor:getControlling() == creditShip
  and liveChildCount(creditSystem) == 2 and not creditShip.deleted)

local poorPurchaseSystem, poorPurchaseStation, poorPurchaseActor, poorPurchaseShip = makeFixture({ credits = 54999 })
local poorPurchase = PurchaseShip(poorPurchaseStation, { kind = 'freighter' })
poorPurchaseShip:pushAction(poorPurchase)
step(poorPurchaseShip, 1 / 60)
check('unaffordable ship purchase does not spawn', poorPurchase.result == 'failed'
  and poorPurchaseSystem.spawnCalls == 0 and poorPurchaseActor:getItemCount(Credit) == 54999)

local noYardSystem, noYard, noYardActor, noYardShip = makeFixture({ shipyard = false, credits = 100000 })
local noYardPurchase = PurchaseShip(noYard, { kind = 'freighter' })
noYardShip:pushAction(noYardPurchase)
step(noYardShip, 1 / 60)
check('purchase requires a shipyard-capable station', noYardPurchase.result == 'failed'
  and noYardSystem.spawnCalls == 0 and noYardActor:getItemCount(Credit) == 100000)

local repeatSystem, repeatStation, repeatActor, repeatShip = makeFixture({ credits = 100000 })
local firstPurchase = PurchaseShip(repeatStation, { kind = 'freighter' })
repeatShip:pushAction(firstPurchase)
step(repeatShip, 1 / 60)
local firstId = repeatActor:getControlling().stableId
local secondPurchase = PurchaseShip(repeatStation, { kind = 'freighter', tradeIn = true })
repeatActor:getControlling():pushAction(secondPurchase)
step(repeatActor:getControlling(), 1 / 60)
check('repeat purchases allocate distinct stable ship ids', secondPurchase.result == 'completed'
  and repeatActor:getControlling().stableId ~= firstId
  and repeatActor:getControlling().stableId == 'ship:npc:test:purchase:2')

local playerSystem, playerStation, playerActor, playerShip = makeFixture({ credits = 0 })
playerShip:addCredits(100000)
local playerPurchase = PurchaseShip(playerStation, { kind = 'freighter' })
playerShip:pushAction(playerPurchase)
step(playerShip, 1 / 60)
check('player purchase preserves remaining ship credits on the new hull',
  playerPurchase.result == 'completed'
  and playerActor:getControlling():getCredits() == 45000)

local tradeSystem, tradeStation, tradeActor, tradeShip = makeFixture({ credits = 0 })
tradeShip:addCredits(100000)
local tradePurchase = PurchaseShip(tradeStation, { kind = 'freighter', tradeIn = true })
tradeShip:pushAction(tradePurchase)
step(tradeShip, 1 / 60)
check('player trade-in discounts the purchase and preserves the balance',
  tradePurchase.result == 'completed'
  and tradeActor:getControlling():getCredits() == 51300)

local downSystem, downStation, downActor, downShip = makeFixture({
  credits = 0, kind = 'capital',
})
downShip:addCredits(100000)
local downPurchase = PurchaseShip(downStation, { kind = 'fighter', tradeIn = true })
downShip:pushAction(downPurchase)
step(downShip, 1 / 60)
check('downgrade trade-in excess is paid instead of silently lost',
  downPurchase.result == 'completed'
  and downActor:getControlling():getCredits() == 180000
  and downStation:getCredits() == 420000)

finish()
