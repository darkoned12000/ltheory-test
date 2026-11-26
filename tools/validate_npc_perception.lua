#!/usr/bin/env luajit
-- Local NPC contacts are bounded, classified, and relation-aware.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_perception%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

local Vec = {}; Vec.__index = Vec
local function vec (x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, Vec) end
_G.Vec3f = vec
function Vec.__sub (a, b) return vec(a.x-b.x, a.y-b.y, a.z-b.z) end
function Vec:length () return math.sqrt(self.x*self.x + self.y*self.y + self.z*self.z) end

_G.Config = { game = { npcPerceptionInterval = 0.25, npcAvoidance = true } }
local Perception = require('Game.NpcPerception')

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name)
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end

local ownerA, ownerB, ownerC, ownerD = {}, {}, {}, {}
ownerA.getOrganization = function () return 'guild' end
ownerC.getOrganization = function () return 'guild' end
local dispositions = { [ownerB] = -0.8 }
local root = { children = {}, time = 10, getTime = function (self) return self.time end }
local function bodyEntity (pos, radius, fields)
  local entity = fields or {}
  entity.pos = vec(pos[1], pos[2], pos[3])
  entity.parent = root
  entity.body = {
    getPos = function (self, out)
      out.x, out.y, out.z = entity.pos.x, entity.pos.y, entity.pos.z
    end,
    getBoundingRadius = function () return radius end,
  }
  entity.getPos = function (self) return self.pos end
  entity.getRadius = function () return radius end
  entity.getVelocity = function () return vec() end
  return entity
end

local observer = bodyEntity({ 0, 0, 0 }, 10)
observer.stableId = 'npc:observer'
observer.getRoot = function () return root end
observer.getOwner = function () return ownerA end
observer.getOwnerDisposition = function (_, owner) return dispositions[owner] or 0 end
observer.getTopSpeed = function () return 100 end

local asteroid = bodyEntity({ 100, 0, 0 }, 30, { isAsteroid = true })
local gate = {
  isWormhole = true, parent = root,
  pos = vec(200, 0, 0),
  getPos = function (self) return self.pos end,
}
local ally = bodyEntity({ 300, 0, 0 }, 10, {
  hasSockets = function () return true end,
  getOwner = function () return ownerA end,
})
local wingman = bodyEntity({ 350, 0, 0 }, 10, {
  hasSockets = function () return true end,
  getOwner = function () return ownerC end,
})
local threat = bodyEntity({ 400, 0, 0 }, 10, {
  hasSockets = function () return true end,
  getOwner = function () return ownerB end,
})
local aggressor = bodyEntity({ 450, 0, 0 }, 10, {
  hasSockets = function () return true end,
  getOwner = function () return ownerD end,
})
local station = bodyEntity({ 500, 0, 0 }, 100, {
  hasDockable = function () return true end,
})
local planet = bodyEntity({ 600, 0, 0 }, 500, { isPlanet = true })
local far = bodyEntity({ 5000, 0, 0 }, 20, { isAsteroid = true })
root.children = { observer, asteroid, gate, ally, wingman, threat, aggressor, station, planet, far }

local contacts = Perception.Local(observer, 1000)
local byEntity = {}
for _, contact in ipairs(contacts) do byEntity[contact.entity] = contact end
check('local perception finds a nearby resource', byEntity[asteroid] and byEntity[asteroid].kind == 'resource')
check('local perception includes bodyless gates as navigation contacts',
  byEntity[gate] and byEntity[gate].kind == 'gate')
check('local perception recognizes friendly ships', byEntity[ally] and byEntity[ally].relation == 'ally')
check('local perception recognizes organization wingmen',
  byEntity[wingman] and byEntity[wingman].relation == 'ally')
check('local perception recognizes hostile ships', byEntity[threat] and byEntity[threat].relation == 'threat')
check('local perception recognizes stations', byEntity[station] and byEntity[station].kind == 'station')
check('local perception keeps planets distinct from stations',
  byEntity[planet] and byEntity[planet].kind == 'planet')
check('local perception excludes itself and distant contacts',
  not byEntity[observer] and not byEntity[far])
local broad = Perception.Local(observer, 5000)
local broadHasFar = false
for _, contact in ipairs(broad) do if contact.entity == far then broadHasFar = true end end
local narrow = Perception.Local(observer, 1000)
local narrowHasFar = false
for _, contact in ipairs(narrow) do if contact.entity == far then narrowHasFar = true end end
check('narrow perception filters a cached broad scan', broadHasFar and not narrowHasFar)
observer.npcSafety = { source = aggressor, lastDamageAt = 10 }
root.time = 10.3
local recent = Perception.Local(observer, 1000)
local aggressorContact
for _, contact in ipairs(recent) do if contact.entity == aggressor then aggressorContact = contact end end
check('recent aggressor is perceived as a local threat',
  aggressorContact and aggressorContact.relation == 'threat')
local queryCalls = 0
root.queryNpcPerception = function (_, origin, range)
  queryCalls = queryCalls + 1
  return { asteroid }
end
root.time = 11
local indexedContacts = Perception.Local(observer, 1000)
check('perception delegates candidate discovery to the System spatial query',
  queryCalls == 1 and #indexedContacts == 1 and indexedContacts[1].entity == asteroid)

if failures == 0 then
  print(string.format('npc perception: %d checks passed', checks)); os.exit(0)
else
  print(string.format('npc perception: %d/%d checks failed', failures, checks)); os.exit(1)
end
