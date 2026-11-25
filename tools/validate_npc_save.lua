#!/usr/bin/env luajit
-- NPC actor-state save/restore by stable id. The world still regenerates from
-- its seed; this validates the additive actor snapshot and JSON round-trip.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_save%.lua$', '')
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
  if v == nil then v = t[#t] end
  for i = 1, #t do
    if t[i] == v then t[i] = t[#t]; t[#t] = nil; return end
  end
end

local Event = dofile(root .. '/script/Game/Event.lua')
_G.Event = Event
local Entity = dofile(root .. '/script/Game/Entity.lua')
package.loaded['Game.Entity'] = Entity
for _, name in ipairs({ 'addActions', 'addDispositions' }) do
  Entity[name] = function () end
end
dofile(root .. '/script/Game/Components/Assets.lua')
dofile(root .. '/script/Game/Components/Inventory.lua')
local Player = dofile(root .. '/script/Game/Entities/Player.lua')
local Registry = require('Game.NpcRegistry')
local Json = dofile(root .. '/script/Game/Json.lua')
package.loaded['Game.Json'] = Json
package.loaded['ffi.File'] = {}
package.loaded['ffi.Directory'] = {}
package.loaded['ffi.Tex2D'] = {}
local Credit = { getMass = function () return 0 end, getName = function () return 'Credit' end }
_G.Item = { Credit = Credit, All = function () return { Credit } end }
package.loaded['Game.Item'] = _G.Item
local SaveGame = dofile(root .. '/script/Game/SaveGame.lua')

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

local function systemWith (npc)
  local registry = Registry.Create()
  Registry.register(registry, npc)
  return { npcs = registry, getNpc = function (self, id) return Registry.get(registry, id) end }
end

local original = Player({ isNpc = true, npcId = 'seed:1', organization = 'belt-miners',
  profile = { role = 'miner', caution = 0.25 } })
original:addItem(Credit, 1234)
original:modOrganizationStanding('belt-miners', 7)
local source = systemWith(original)
source.depositState = { ['rock:1'] = 17, ['rock:2'] = 0 }
local captureOk, data = pcall(function ()
  return SaveGame.Capture(nil, { seedHex = '0011223344556677' }, source)
end)
check('capture includes NPC actor state', captureOk and data.npcs and #data.npcs == 1,
  captureOk and tostring(data) or tostring(data))
check('capture uses stable NPC id', data.npcs and data.npcs[1].id == 'seed:1')
check('capture stores credits as a plain number', data.npcs and data.npcs[1].credits == 1234)
check('capture includes persistent deposit amounts', data.deposits and #data.deposits == 2)

local encoded = Json.Encode(data)
local decoded = Json.Decode(encoded)
check('NPC snapshot survives JSON round-trip', decoded.npcs and decoded.npcs[1].id == 'seed:1'
  and decoded.npcs[1].credits == 1234 and decoded.npcs[1].profile.role == 'miner')

local restored = Player({ isNpc = true, npcId = 'seed:1', organization = 'traders',
  profile = { role = 'trader' } })
restored:addItem(Credit, 9999)
local destination = systemWith(restored)
SaveGame.Restore(nil, decoded, destination)
check('restore matches NPC by stable id', destination:getNpc('seed:1') == restored)
check('restore replaces credits exactly', restored:getItemCount(Credit) == 1234)
check('restore replaces organization', restored:getOrganization() == 'belt-miners')
check('restore replaces standing', restored:getOrganizationStanding('belt-miners') == 7)
check('restore replaces profile', restored:getNpcProfile().role == 'miner'
  and restored:getNpcProfile().caution == 0.25)
check('restore reinstates deposit amounts', destination.depositState
  and destination.depositState['rock:1'] == 17 and destination.depositState['rock:2'] == 0)

if failures == 0 then
  print(string.format('npc save: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('npc save: %d/%d checks failed', failures, checks))
  os.exit(1)
end
