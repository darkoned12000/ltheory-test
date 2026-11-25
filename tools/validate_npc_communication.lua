#!/usr/bin/env luajit
-- Addressed, ranged, expiring NPC communication. Pure/offline; no Engine/GL.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_communication%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

local Comms = require('Game.Communication')

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

local Vec = {}
Vec.__index = Vec
local function vec (x, y, z) return setmetatable({ x = x, y = y, z = z }, Vec) end
function Vec.__sub (a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
function Vec:length () return math.sqrt(self.x*self.x + self.y*self.y + self.z*self.z) end

local function actor (id, org, pos)
  return {
    getActorId = function () return id end,
    hasOrganization = function (self, wanted) return org == wanted end,
    getPrimaryShip = function () return { getPos = function () return pos end } end,
  }
end

local alice = actor('npc:a', 'belt-miners', vec(0, 0, 0))
local bob = actor('npc:b', 'belt-miners', vec(100, 0, 0))
local carol = actor('npc:c', 'belt-miners', vec(1000, 0, 0))
local outsider = actor('npc:d', 'traders', vec(100, 0, 0))
local bus = Comms.Create()
for _, a in ipairs({ alice, bob, carol, outsider }) do Comms.register(bus, a) end
check('registration is idempotent', Comms.register(bus, alice) and Comms.count(bus) == 4)

check('direct message is delivered', Comms.send(bus, alice, bob, 'hail', { text = 'hello' }, { now = 1 }))
check('direct message reaches only recipient', #Comms.drain(bus, bob, 10) == 1
  and #Comms.drain(bus, alice, 10) == 0 and #Comms.drain(bus, carol, 10) == 0)

check('organization threat reaches nearby member', Comms.sendToOrganization(bus, alice,
  'belt-miners', 'threat', { targetId = 9 }, { now = 2, range = 500 }))
local bobMail = Comms.drain(bus, bob, 10)
check('sender does not receive own organization broadcast', #Comms.drain(bus, alice, 10) == 0)
check('organization message excludes nonmember', #Comms.drain(bus, outsider, 10) == 0)
check('organization message excludes out-of-range member', #Comms.drain(bus, carol, 10) == 0)
check('recipient can inspect threat payload', #bobMail == 1 and bobMail[1].payload.targetId == 9)

Comms.send(bus, alice, bob, 'hail', { text = 'short' }, { now = 3, expiresAt = 4 })
Comms.update(bus, 5)
check('expired messages are discarded', #Comms.drain(bus, bob, 10) == 0)

for i = 1, 40 do
  Comms.send(bus, alice, bob, 'hail', { index = i }, { now = 10 })
end
local bounded = Comms.drain(bus, bob, 100)
check('inbox history is bounded and drops oldest messages', #bounded == 32
  and bounded[1].payload.index == 9)
check('drain is ordered and exactly once', bounded[#bounded].payload.index == 40
  and #Comms.drain(bus, bob, 100) == 0)

check('unregister removes actor', Comms.unregister(bus, carol) and Comms.count(bus) == 3)
check('unknown unregister is safe', not Comms.unregister(bus, carol))

if failures == 0 then
  print(string.format('npc communication: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('npc communication: %d/%d checks failed', failures, checks))
  os.exit(1)
end
