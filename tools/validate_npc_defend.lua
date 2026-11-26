#!/usr/bin/env luajit
-- Defensive goal: guard an ally, fight within a leash, and settle directives.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_defend%.lua$', '')
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
function format (f, ...) return string.format(f, ...) end

local Vec = {}; Vec.__index = Vec
local function vec (x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, Vec) end
_G.Vec3f = vec
function Vec.__add (a, b) return vec(a.x+b.x, a.y+b.y, a.z+b.z) end
function Vec.__sub (a, b) return vec(a.x-b.x, a.y-b.y, a.z-b.z) end
function Vec:length () return math.sqrt(self.x*self.x + self.y*self.y + self.z*self.z) end
function Vec:normalize ()
  local n = self:length()
  assert(n > 1e-9, 'zero vector in test fixture')
  return vec(self.x/n, self.y/n, self.z/n)
end
function Vec:scale (s) return vec(self.x*s, self.y*s, self.z*s) end
function Vec:dot (b) return self.x*b.x + self.y*b.y + self.z*b.z end

_G.Config = { game = { npcDefenseLeash = 20000, npcDefenseEngageRange = 4000,
  npcRegroupDistance = 1000 } }
_G.PHX = { Math = { ExpMap1Signed = function (x) return x end } }
_G.max, _G.min = math.max, math.min

local Action = class(function () end)
function Action:flyToward (ship, targetPos, targetForward, targetUp)
  ship.steeredTo = targetPos
  ship.steeredForward = targetForward
  ship.steeredUp = targetUp
end
package.loaded['Game.Action'] = Action
package.loaded['Game.Seed'] = { rng = function ()
  return { managed = function (self) return self end }
end }

local directiveCalls = {}
package.loaded['Game.Directives'] = {
  complete = function (_, id, actor)
    directiveCalls[#directiveCalls + 1] = { 'complete', id, actor }; return true
  end,
  fail = function (_, id)
    directiveCalls[#directiveCalls + 1] = { 'fail', id }; return true
  end,
}
package.loaded['Game.NpcSafety'] = {
  IsCombatant = function (entity) return entity and (tonumber(entity.socketSpeedMax) or 0) > 0 end,
}
local Attack = require('Game.Actions.Attack')

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name)
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end
local defendLoaded, Defend = pcall(dofile, root .. '/script/Game/Actions/Defend.lua')
check('Defend action module loads', defendLoaded)
if not defendLoaded then os.exit(1) end

local function entity (name, position)
  return {
    name = name, pos = position, radius = 20, socketSpeedMax = 1000,
    body = {}, parent = true,
    isAlive = function (self) return self.alive ~= false end,
    getName = function (self) return self.name end,
    getPos = function (self) return self.pos end,
    getVelocity = function () return vec() end,
    getRadius = function (self) return self.radius end,
    getForward = function () return vec(0, 0, 1) end,
    getUp = function () return vec(0, 1, 0) end,
  }
end
local protected = entity('Freighter', vec(0, 0, 0))
local threat = entity('Raider', vec(12000, 0, 0))
local directive = { id = 7, status = 'active', expiresAt = 90 }
local world = { getTime = function () return 10 end,
  directives = {}, }
local owner = { getActorId = function () return 'npc:defender' end }
local ship = entity('Escort', vec(5000, 0, 0))
ship.owner = owner
ship.getOwner = function (self) return self.owner end
ship.getRoot = function () return world end
ship.getThrustController = function () return { clear = function () end } end
ship.actions = {}
function ship:getCurrentAction () return self.actions[#self.actions] end
function ship:pushAction (action)
  self.actions[#self.actions + 1] = action
  if action.onStart then action:onStart(self) end
end
function ship:popAction ()
  local action = table.remove(self.actions)
  if action and action.onStop then action:onStop(self) end
end

local defend = Defend(protected, threat, directive)
ship:pushAction(defend)
defend:onUpdateActive(ship, 0.016)
check('defender moves toward a guard position near its protected ship',
  ship.steeredTo ~= nil and (ship.steeredTo - protected:getPos()):length() <= 1000.1)
check('defense does not chase a threat beyond the protective leash',
  not defend.attack and ship:getCurrentAction() == defend)

ship.pos = vec(900, 0, 0)
threat.pos = vec(2500, 0, 0)
defend:onUpdateActive(ship, 0.016)
local attack = ship:getCurrentAction()
check('defender engages a threat close to the protected ship',
  attack and attack.target == threat and attack.protected == protected
    and attack.leash == Config.game.npcDefenseLeash)

ship:popAction() -- Attack ends; Defend resumes
threat.alive = false
defend:onUpdateActive(ship, 0.016)
check('destroying the threat completes and pops the defense directive',
  #ship.actions == 0 and directiveCalls[#directiveCalls]
    and directiveCalls[#directiveCalls][1] == 'complete')

local escaped = entity('Escaped Raider', vec(30000, 0, 0))
local secondDirective = { id = 8, status = 'active', expiresAt = 90 }
ship.pos, protected.pos = vec(900, 0, 0), vec(0, 0, 0)
ship:pushAction(Defend(protected, escaped, secondDirective))
ship:getCurrentAction():onUpdateActive(ship, 0.016)
check('threat leaving the leash fails and ends the directive',
  #ship.actions == 0 and directiveCalls[#directiveCalls]
    and directiveCalls[#directiveCalls][1] == 'fail')

local attacker = entity('Attack test', vec(0, 0, 0))
local tooFar = entity('Distant threat', vec(30000, 0, 0))
local attackAction = Attack(tooFar)
attackAction.protected, attackAction.leash = protected, 20000
attacker.actions = { attackAction }
function attacker:popAction () self.actions[#self.actions] = nil end
function attacker:setTarget (target) self.target = target end
attackAction:onUpdateActive(attacker, 0.016)
check('Attack aborts pursuit when it leaves its defend leash', #attacker.actions == 0)
protected.alive = false
local nearThreat = entity('Near threat', vec(1000, 0, 0))
local protectedAttack = Attack(nearThreat)
protectedAttack.protected, protectedAttack.leash = protected, 20000
attacker.actions = { protectedAttack }
protectedAttack:onUpdateActive(attacker, 0.016)
check('Attack stops when the ship being defended is destroyed', #attacker.actions == 0)
local disarmed = entity('Disarmed Raider', vec(1000, 0, 0))
disarmed.socketSpeedMax = 0
local disarmedDirective = { id = 9, status = 'active', expiresAt = 90 }
protected.alive = true
ship.actions = { Defend(protected, disarmed, disarmedDirective) }
ship:getCurrentAction():onUpdateActive(ship, 0.016)
check('disarmed ships are not retained as active threats',
  #ship.actions == 0 and directiveCalls[#directiveCalls]
    and directiveCalls[#directiveCalls][1] == 'fail')

local pointBlankTarget = entity('Point-blank target', vec(0, 0, 0))
local duelist = entity('Duelist', vec(0, 0, 0))
duelist.actions = {}
function duelist:popAction () self.actions[#self.actions] = nil end
function duelist:setTarget (target) self.target = target end
function duelist:getSpeed () return 0 end
function duelist:iterSocketsByType () return function () end end
local pointBlankAttack = Attack(pointBlankTarget)
pointBlankAttack.timer, pointBlankAttack.dist = 10, 1000
pointBlankAttack.offset, pointBlankAttack.radius = vec(), 0
duelist.actions = { pointBlankAttack }
local pointBlankOk, pointBlankErr = pcall(function () pointBlankAttack:onUpdateActive(duelist, 0.016) end)
check('point-blank attack steering does not normalize a zero course',
  pointBlankOk and #duelist.actions == 1, pointBlankErr)
local passiveOk, passiveErr = pcall(function () pointBlankAttack:onUpdatePassive(duelist, 0.016) end)
check('point-blank attack alignment does not normalize a zero vector',
  passiveOk, passiveErr)

if failures == 0 then
  print(string.format('npc defend: %d checks passed', checks)); os.exit(0)
else
  print(string.format('npc defend: %d/%d checks failed', failures, checks)); os.exit(1)
end
