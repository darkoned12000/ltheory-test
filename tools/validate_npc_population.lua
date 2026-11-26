#!/usr/bin/env luajit
-- Deterministic sector NPC population plan and role/job compatibility.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_population%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path
local Population = require('Game.NpcPopulation')

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. detail) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or '')) end
end

local roles = { 'fighter', 'freighter', 'industrial', 'capital' }
for _, role in ipairs(roles) do check('role exists: ' .. role, Population.Roles[role] ~= nil) end
check('NPC roles have class-scale hull and shields',
  Population.Roles.fighter.health >= 2500
    and Population.Roles.fighter.shield >= 2500
    and Population.Roles.freighter.health > Population.Roles.fighter.health
    and Population.Roles.capital.health >= 150000
    and Population.Roles.capital.shield >= 50000)
check('capital hulls mount more turrets than fighters',
  Population.Roles.capital.turrets > Population.Roles.fighter.turrets
    and Population.Roles.capital.turrets >= 3)
local total = 0
for _, count in pairs(Population.DefaultMix) do total = total + count end
check('default population has useful variety', total >= 6 and total <= 16, 'count=' .. total)

local a = Population.Plan(1234)
local b = Population.Plan(1234)
local same = #a == #b
if same then
  for i = 1, #a do
    if a[i].role ~= b[i].role or a[i].variant ~= b[i].variant or a[i].seed ~= b[i].seed then same = false end
  end
end
check('same sector seed gives identical population', same)
local c = Population.Plan(5678)
local different = false
for i = 1, math.min(#a, #c) do
  if a[i].role ~= c[i].role or a[i].variant ~= c[i].variant or a[i].seed ~= c[i].seed then different = true end
end
check('different sector seeds vary population', different)

local counts = {}
for _, entry in ipairs(a) do counts[entry.role] = (counts[entry.role] or 0) + 1 end
for _, role in ipairs(roles) do
  check('default mix includes ' .. role, (counts[role] or 0) >= 1)
end
for role, wanted in pairs(Population.DefaultMix) do
  check('planned count matches mix for ' .. role, counts[role] == wanted)
end

check('fighters can patrol but not haul cargo', Population.CanDoJob('fighter', 'patrol')
  and not Population.CanDoJob('fighter', 'transport'))
check('freighters specialize in transport', Population.CanDoJob('freighter', 'transport')
  and not Population.CanDoJob('freighter', 'mine'))
check('industrials specialize in mining', Population.CanDoJob('industrial', 'mine'))
check('capitals can mine and transport', Population.CanDoJob('capital', 'mine')
  and Population.CanDoJob('capital', 'transport'))
local scaled = Population.ScaleMix(6)
local scaledTotal = 0
for _, count in pairs(scaled) do scaledTotal = scaledTotal + count end
check('scaled mix honors requested total', scaledTotal == 6)
check('scaled mix retains all roles when possible', scaled.fighter >= 1
  and scaled.freighter >= 1 and scaled.industrial >= 1 and scaled.capital >= 1)
local zeroTotal = 0
for _, count in pairs(Population.ScaleMix(0)) do zeroTotal = zeroTotal + count end
check('zero population stays empty', zeroTotal == 0)

if failures == 0 then
  print(string.format('npc population: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('npc population: %d/%d checks failed', failures, checks))
  os.exit(1)
end
