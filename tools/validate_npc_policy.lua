#!/usr/bin/env luajit
-- NPC policy contract: utility scoring, route memory, cooldowns, and cloned
-- job assignment. Pure/offline; no Engine or GL required.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_npc_policy%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

local Policy = require('Game.NpcPolicy')

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

local function job (key, kind, payout, travel)
  return {
    getKey = function () return key end,
    getKind = function () return kind end,
    getPayout = function () return payout end,
    getTravelTime = function () return travel end,
  }
end

local policy = Policy.Create(123)
local richSlow = job('mine:A:B:ore', 'mine', 1000, 100)
local leanFast = job('transport:C:D:fuel', 'transport', 500, 2)
check('efficient route outscores raw-payout route',
  Policy.score(leanFast, {}, policy, 0) > Policy.score(richSlow, {}, policy, 0))
check('score is finite for zero travel', Policy.score(job('zero', 'mine', 10, 0), {}, policy, 0) > 0)

check('new route is eligible', Policy.canAssign(policy, leanFast, 0))
Policy.recordOutcome(policy, leanFast, 'completed', 10)
check('completed route enters cooldown', not Policy.canAssign(policy, leanFast, 10))
check('other route remains eligible', Policy.canAssign(policy, richSlow, 10))
check('cooldown expires', Policy.canAssign(policy, leanFast, 10 + 1000))
check('repeat penalty lowers score', Policy.score(leanFast, {}, policy, 10) < Policy.score(leanFast, {}, Policy.Create(123), 10))

local p1, p2 = Policy.Create(123), Policy.Create(123)
Policy.recordOutcome(p1, richSlow, 'completed', 5)
Policy.recordOutcome(p2, richSlow, 'completed', 5)
check('policy state is deterministic for a seed', Policy.canAssign(p1, richSlow, 5) == Policy.canAssign(p2, richSlow, 5))
check('different seeds can prefer different job kinds',
  Policy.preference(p1, 'mine') ~= Policy.preference(Policy.Create(124), 'mine'))

local routes = {
  job('mine:1:10:Iron', 'mine', 1000, 10),
  job('mine:2:10:Copper', 'mine', 1000, 10),
  job('mine:3:10:Titanium', 'mine', 1000, 10),
  job('transport:10:20:Energy', 'transport', 1000, 10),
  job('transport:11:20:MachineParts', 'transport', 1000, 10),
  job('transport:12:20:Electronics', 'transport', 1000, 10),
}
local chosen, distinct = {}, 0
for seed = 1, 6 do
  local p = Policy.Create(seed)
  local best, bestScore = nil, -1
  for _, candidate in ipairs(routes) do
    local score = Policy.score(candidate, {}, p, 0)
    if score > bestScore then best, bestScore = candidate, score end
  end
  local key = best:getKey()
  if not chosen[key] then chosen[key] = true; distinct = distinct + 1 end
end
check('equal-value routes diversify across six NPC seeds', distinct >= 3,
  string.format('distinct=%d', distinct))

Policy.recordOutcome(p1, leanFast, 'cancelled', 100)
local captureOk, snapshot = pcall(function () return Policy.Capture(p1) end)
check('policy memory is serializable', captureOk and snapshot and snapshot.seed == 123)
local runtimeRoute = job('runtime:999', 'mine', 1, 1)
Policy.recordOutcome(p1, runtimeRoute, 'completed', 101)
local captureOk2, snapshot2 = pcall(function () return Policy.Capture(p1) end)
snapshot = captureOk2 and snapshot2 or { routes = {} }
local hasRuntime = false
for _, route in ipairs(snapshot.routes) do
  if route.key == 'runtime:999' then hasRuntime = true end
end
check('runtime-only routes are excluded from persistence', not hasRuntime)
local restoredPolicy = Policy.Create(0)
local restoreOk = pcall(function () Policy.Restore(restoredPolicy, snapshot) end)
check('policy restore retains seed and cooldown memory', restoreOk and restoredPolicy.seed == 123
  and not Policy.canAssign(restoredPolicy, leanFast, 100)
  and Policy.canAssign(restoredPolicy, leanFast, 1000))
local stringSeed = 'npc:123:ship:123:1'
local stringPolicy = Policy.Create(stringSeed)
local stringRestored = Policy.Create(0)
Policy.Restore(stringRestored, Policy.Capture(stringPolicy))
check('string policy seeds survive restore', stringRestored.seed == stringSeed
  and Policy.preference(stringRestored, 'mine') == Policy.preference(stringPolicy, 'mine'))
local malformedPolicy = Policy.Create(7)
local malformedOk = pcall(function ()
  Policy.Restore(malformedPolicy, { seed = {}, routes = 42 })
  Policy.Restore(malformedPolicy, { seed = 'ok', routes = { 42, { key = 'mine:ok' } } })
end)
check('malformed policy payloads fail closed', malformedOk and malformedPolicy.seed == 'ok'
  and malformedPolicy.routes['mine:ok'] ~= nil)

if failures == 0 then
  print(string.format('npc policy: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('npc policy: %d/%d checks failed', failures, checks))
  os.exit(1)
end
