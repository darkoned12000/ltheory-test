#!/usr/bin/env luajit
-- NPC identity/registry contract. Runs the real Player class without GL/Engine.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_identity%.lua$', '')
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

function insert (t, v) t[#t + 1] = v end
function remove (t, v)
  for i = 1, #t do
    if t[i] == v then t[i] = t[#t]; t[#t] = nil; return end
  end
end
function format (f, ...) return string.format(f, ...) end

local Event = dofile(root .. '/script/Game/Event.lua')
_G.Event = Event
local Entity = dofile(root .. '/script/Game/Entity.lua')
package.loaded['Game.Entity'] = Entity
dofile(root .. '/script/Game/Components/Actions.lua')
dofile(root .. '/script/Game/Components/Assets.lua')
dofile(root .. '/script/Game/Components/Dispositions.lua')
dofile(root .. '/script/Game/Components/Inventory.lua')
local Player = dofile(root .. '/script/Game/Entities/Player.lua')
local Registry = require('Game.NpcRegistry')

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

local human = Player()
local npc = Player({ isNpc = true, npcId = 'seed:1', profile = { role = 'miner' } })
check('human is not NPC', human:isNpc() == false)
check('NPC reports explicit identity', npc:isNpc() == true)
check('NPC exposes stable id', npc:getNpcId() == 'seed:1')
check('NPC profile is retained', npc:getNpcProfile().role == 'miner')

local reg = Registry.Create()
check('registry rejects human identity', Registry.register(reg, human) == false)
check('registry accepts NPC', Registry.register(reg, npc) == true)
check('lookup by stable id returns NPC', Registry.get(reg, 'seed:1') == npc)
check('registry contains one NPC', Registry.count(reg) == 1)
check('duplicate registration is idempotent', Registry.register(reg, npc) == true and Registry.count(reg) == 1)

local other = Player({ isNpc = true, npcId = 'seed:2' })
check('second NPC registers', Registry.register(reg, other) == true)
check('registry contains two NPCs', Registry.count(reg) == 2)
check('unknown removal is safe', Registry.unregister(reg, Player({ isNpc = true, npcId = 'missing' })) == false)
check('active NPC removal succeeds', Registry.unregister(reg, npc) == true)
check('removed NPC is no longer found', Registry.get(reg, 'seed:1') == nil)
check('removal is idempotent', Registry.unregister(reg, npc) == false)
check('other NPC survives removal', Registry.get(reg, 'seed:2') == other)

if failures == 0 then
  print(string.format('npc identity: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('npc identity: %d/%d checks failed', failures, checks))
  os.exit(1)
end
