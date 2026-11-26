#!/usr/bin/env luajit
-- Damage-driven retreat policy and the Flee action that temporarily preempts a
-- job, then resumes it underneath.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_safety%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

function class (ctor)
  local cls = {}
  cls.__index = cls
  setmetatable(cls, { __call = function (T, ...)
    local self = {}
    setmetatable(self, cls)
    if ctor then ctor(self, ...) end
    return self
  end })
  return cls
end

function subclass (base, ctor)
  local cls = {}
  cls.__index = cls
  setmetatable(cls, {
    __call = function (T, ...)
      local self = base()
      setmetatable(self, cls)
      if ctor then ctor(self, ...) end
      return self
    end,
    __index = base,
  })
  return cls
end
function format (f, ...) return string.format(f, ...) end

local Action = class(function () end)
function Action:onStart () end
function Action:onStop () end
function Action:onUpdateActive () end
function Action:onUpdatePassive () end
function Action:flyToward (e, pos, forward, up)
  e.steeredTo = pos
  e.steeredForward = forward
  e.steeredUp = up
end
package.loaded['Game.Action'] = Action
package.loaded['Game.Seed'] = { rng = function ()
  return { managed = function (self) return self end }
end }
package.loaded['Game.SocketKind'] = { Turret = 1 }
_G.Config = { game = { aiFire = function () return true end } }
local Attack = dofile(root .. '/script/Game/Actions/Attack.lua')

local Credit, Iron = {}, {}
package.loaded['Game.Item'] = { Credit = Credit, Price = { [Iron] = 20 } }
local Safety = require('Game.NpcSafety')
local Flee = dofile(root .. '/script/Game/Actions/Flee.lua')

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then
    print('ok   - ' .. name .. (detail and ('  -- ' .. detail) or ''))
  else
    failures = failures + 1
    print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or ''))
  end
end

local state = Safety.Create()
check('healthy undamaged ship does not retreat', not Safety.shouldFlee(state, 1.0, 0))
Safety.recordDamage(state, 5, nil, 0)
check('light damage does not trigger retreat', not Safety.shouldFlee(state, 1.0, 0))
Safety.recordDamage(state, 30, nil, 0)
check('heavy recent damage triggers retreat', Safety.shouldFlee(state, 0.8, 0))
check('retreat starts once and enters cooldown', Safety.beginFlee(state, 0)
  and not Safety.shouldFlee(state, 0.2, 1))
check('critical hull can override the retreat cooldown',
  Safety.shouldFlee(state, 0.1, 1))
local repeatedThreat = Safety.Create()
Safety.recordDamage(repeatedThreat, 30, source, 0)
Safety.beginFlee(repeatedThreat, 0)
check('retreat cooldown suppresses the same damage event',
  not Safety.shouldFlee(repeatedThreat, 0.7, 1))
Safety.recordDamage(repeatedThreat, 10, source, 2)
check('new heavy damage can retrigger retreat during cooldown',
  Safety.shouldFlee(repeatedThreat, 0.7, 2))
check('old damage expires', not Safety.shouldFlee(state, 1.0, 100))
check('low hull triggers retreat without new damage', Safety.shouldFlee(Safety.Create(), 0.2, 0))
local cargoThreat = Safety.Create()
Safety.recordDamage(cargoThreat, 16, source, 0)
check('valuable cargo makes moderate damage trigger retreat',
  not Safety.shouldFlee(cargoThreat, 0.7, 0)
    and Safety.shouldFlee(cargoThreat, 0.7, 0, 20000, 0.1))
check('risk-tolerant pilot accepts more damage before retreat',
  not Safety.shouldFlee(cargoThreat, 0.7, 0, 20000, 0.95))
local cargoShip = {
  hasInventory = function () return true end,
  getInventory = function () return { [Credit] = 100000, [Iron] = 25 } end,
}
check('cargo risk values goods but excludes operating credits',
  Safety.CargoValue and Safety.CargoValue(cargoShip) == 500)

local lightFighter = {
  healthMax = 100, socketSpeedMax = 1000,
  getHealthNormalized = function () return 1 end,
  hasSockets = function () return true end,
}
local capitalThreat = {
  healthMax = 1000, socketSpeedMax = 1000,
  getHealthNormalized = function () return 1 end,
  hasSockets = function () return true end,
}
local rock = { healthMax = 10000, hasSockets = function () return false end }
local hopelessFight = Safety.HopelessFight
check('NPC avoids a hopeless solo fight',
  hopelessFight and hopelessFight(lightFighter, capitalThreat, 0))
check('nearby allies can turn a hopeless fight into a viable defense',
  hopelessFight and not hopelessFight(lightFighter, capitalThreat, 4))
check('non-combat objects are not classified as fights',
  hopelessFight and not hopelessFight(lightFighter, rock, 0))

local powerFn = Safety.CombatPower
local manyGuns = { healthMax = 800, socketSpeedMax = 1000, turretCount = 6,
  hasSockets = function () return true end,
  getHealthNormalized = function () return 1 end }
local fewGuns = { healthMax = 800, socketSpeedMax = 1000, turretCount = 2,
  hasSockets = function () return true end,
  getHealthNormalized = function () return 1 end }
check('combat power accounts for gun count', powerFn
  and powerFn(manyGuns) > powerFn(fewGuns) * 2)
local strongGuns = { healthMax = 800, socketSpeedMax = 900, turretCount = 2,
  hasSockets = function () return true end,
  getHealthNormalized = function () return 1 end,
  getSockets = function () return {
    { type = 1, child = { projDamage = 90, rateOfFire = 10 } },
    { type = 1, child = { projDamage = 90, rateOfFire = 10 } },
  } end }
check('combat power accounts for real weapon damage, not count alone',
  powerFn and powerFn(strongGuns) > powerFn(fewGuns))

local fighterState = Safety.Create()
Safety.recordDamage(fighterState, 40, fewGuns, 0)
local npcFighter = { npcRole = 'fighter', healthMax = 250,
  getHealthNormalized = function () return 210 / 250 end,
  hasSockets = function () return true end, socketSpeedMax = 1000, turretCount = 2 }
check('an NPC fighter does not flee after one pulse hit',
  not Safety.shouldFlee(fighterState, npcFighter, 0))
Safety.recordDamage(fighterState, 80, fewGuns, 0.5)
check('an NPC fighter flees after sustained heavy fire',
  Safety.shouldFlee(fighterState, npcFighter, 0.5))

local capitalState = Safety.Create()
Safety.recordDamage(capitalState, 120, fewGuns, 0)
local npcCapital = { npcRole = 'capital', healthMax = 1600,
  getHealthNormalized = function () return 1480 / 1600 end,
  hasSockets = function () return true end, socketSpeedMax = 1000, turretCount = 6 }
check('a capital ignores fighter fire while its hull is intact',
  not Safety.shouldFlee(capitalState, npcCapital, 0))
local hurtCapital = { npcRole = 'capital', healthMax = 1600,
  getHealthNormalized = function () return 0.2 end,
  hasSockets = function () return true end, socketSpeedMax = 1000, turretCount = 6 }
check('a capital still retreats at critical hull',
  Safety.shouldFlee(Safety.Create(), hurtCapital, 0))
check('a capital is not hopeless against a fighter',
  hopelessFight and not hopelessFight(npcCapital, npcFighter, 0))

local Vec = {}
Vec.__index = Vec
local function vec (x, y, z) return setmetatable({ x = x, y = y, z = z }, Vec) end
function Vec.__sub (a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
function Vec.__add (a, b) return vec(a.x + b.x, a.y + b.y, a.z + b.z) end
function Vec:length () return math.sqrt(self.x*self.x + self.y*self.y + self.z*self.z) end
function Vec:normalize ()
  local len = self:length()
  if len < 1e-6 then return vec(0, 0, 0) end
  return vec(self.x / len, self.y / len, self.z / len)
end
function Vec:scale (s) return vec(self.x * s, self.y * s, self.z * s) end
function Vec:dot (b) return self.x*b.x + self.y*b.y + self.z*b.z end

local source = {
  stableId = 'ship:threat',
  isAlive = function () return true end,
  getPos = function () return vec(10, 0, 0) end,
}
Safety.recordDamage(state, 10, source, 5)
state.lastThreatAt = 4
local safetyOk, safetySnapshot = pcall(function () return Safety.Capture(state) end)
check('safety memory is serializable', safetyOk and safetySnapshot.damage == 45
  and safetySnapshot.sourceKey == 'ship:threat' and safetySnapshot.lastThreatAt == 4)
local restoredSafety = Safety.Create()
local safetyRestoreOk = pcall(function () Safety.Restore(restoredSafety, safetySnapshot) end)
check('safety memory restores damage and cooldown', safetyRestoreOk
  and restoredSafety.damage == 45 and restoredSafety.lastDamageAt == 5
  and restoredSafety.cooldownUntil == state.cooldownUntil
  and restoredSafety.lastThreatAt == 4)
check('unresolved safety source survives recapture', Safety.Capture(restoredSafety).sourceKey == 'ship:threat')
Safety.recordDamage(restoredSafety, 1, { id = 123 }, 6)
check('runtime-only damage source clears stale durable source',
  Safety.Capture(restoredSafety).sourceKey == nil)
Safety.Restore(restoredSafety, { lastDamageAt = math.huge, damage = -5,
  cooldownUntil = -math.huge, sourceKey = 'runtime:1' })
check('malformed safety values fail closed', restoredSafety.lastDamageAt == -math.huge
  and restoredSafety.damage == 0 and restoredSafety.cooldownUntil == -math.huge
  and restoredSafety.sourceKey == nil)
local controller = { forward = 1, right = 1, up = 1, yaw = 1, pitch = 1, roll = 1, boost = 1 }
function controller:clear ()
  self.forward, self.right, self.up = 0, 0, 0
  self.yaw, self.pitch, self.roll, self.boost = 0, 0, 0, 0
end
local e = {
  controller = controller,
  popped = false,
  getPos = function () return vec(0, 0, 0) end,
  getForward = function () return vec(0, 0, -1) end,
  getUp = function () return vec(0, 1, 0) end,
  getThrustController = function (self) return self.controller end,
  popAction = function (self) self.popped = true; self.current:onStop(self) end,
}
local flee = Flee(source, 6)
e.current = flee
flee:onUpdateActive(e, 2)
check('flee steers away from damage source', e.steeredTo.x < 0)
check('flee remains active for its duration', not e.popped)
flee:onUpdateActive(e, 5)
check('flee pops when duration expires', e.popped)
check('completing a retreat requests regrouping', e.npcNeedsRegroup == true)
check('flee clears residual thrust', e.controller.forward == 0 and e.controller.boost == 0)
check('flee clone is independent', flee:clone() ~= flee and flee:clone().duration == 6)

source.isAlive = function () return false end
local e2 = {
  getPos = function () return vec(0, 0, 0) end,
  getForward = function () return vec(0, 0, -1) end,
  getUp = function () return vec(0, 1, 0) end,
  getThrustController = function () return nil end,
}
Flee(source, 6):onUpdateActive(e2, 1)
check('dead damage source is handled safely', e2.steeredTo.z < 0)

local shots = 0
local turret = {
  aimAtTarget = function () end,
  fire = function () shots = shots + 1 end,
}
local combatTarget = {
  body = {},
  isAlive = function () return true end,
  getPos = function () return vec(10, 0, 0) end,
}
local combatShip = {
  current = Flee(nil, 6),
  getPos = function () return vec(0, 0, 0) end,
  getForward = function () return vec(1, 0, 0) end,
  getCurrentAction = function (self) return self.current end,
  iterSocketsByType = function ()
    local done = false
    return function ()
      if done then return nil end
      done = true
      return turret
    end
  end,
}
local attack = Attack(combatTarget)
attack:onUpdatePassive(combatShip, 1)
check('fleeing suppresses lower stacked Attack fire', shots == 0)
combatShip.current = attack
combatTarget.isAlive = function () return true end
turret.aimAtTarget = function () return false end
shots = 0
attack:onUpdatePassive(combatShip, 1)
check('out-of-range turret solution suppresses fire', shots == 0)
turret.aimAtTarget = function () return true end
attack:onUpdatePassive(combatShip, 1)
check('in-range turret solution permits fire', shots == 1)
combatTarget.isAlive = function () return false end
attack:onUpdatePassive(combatShip, 1)
check('dead target suppresses passive fire', shots == 1)
combatShip.lockedTarget = combatTarget
function combatShip:getTarget () return self.lockedTarget end
function combatShip:setTarget (target) self.lockedTarget = target end
attack:onStop(combatShip)
check('cancelled Attack clears its target lock', combatShip.lockedTarget == nil)

if failures == 0 then
  print(string.format('npc safety: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('npc safety: %d/%d checks failed', failures, checks))
  os.exit(1)
end
