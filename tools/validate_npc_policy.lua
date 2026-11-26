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

local function assetState (overrides)
  local asset = {
    health = 100, healthMax = 100, charge = 100, chargeMax = 100,
    inventoryCapacity = 100, inventoryFree = 100, owner = nil,
  }
  function asset:getHealthNormalized () return self.health / self.healthMax end
  function asset:hasCharge () return true end
  function asset:getChargeNormalized () return self.charge / self.chargeMax end
  function asset:hasInventory () return true end
  function asset:getInventoryCapacity () return self.inventoryCapacity end
  function asset:getInventoryFree () return self.inventoryFree end
  function asset:getOwner () return self.owner end
  if overrides then for k, v in pairs(overrides) do asset[k] = v end end
  return asset
end

local policy = Policy.Create(123)
local richSlow = job('mine:A:B:ore', 'mine', 1000, 100)
local leanFast = job('transport:C:D:fuel', 'transport', 500, 2)
check('efficient route outscores raw-payout route',
  Policy.score(leanFast, {}, policy, 0) > Policy.score(richSlow, {}, policy, 0))
check('score is finite for zero travel', Policy.score(job('zero', 'mine', 10, 0), {}, policy, 0) > 0)
check('zero-payout jobs have no utility', Policy.score(job('no-pay', 'mine', 0, 1), {}, policy, 0) == 0)

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

local riskPolicy = Policy.Create(765)
local riskyJob = job('mine:risky', 'mine', 100, 10)
riskyJob.risk = 1
local safeJob = job('transport:safe', 'transport', 100, 10)
local damagedShip = assetState({ health = 20 })
check('low hull shifts utility away from high-risk work',
  Policy.score(riskyJob, damagedShip, riskPolicy, 0)
    < Policy.score(safeJob, damagedShip, riskPolicy, 0))

local mineJob = job('mine:cargo', 'mine', 100, 10)
local transportJob = job('transport:cargo', 'transport', 100, 10)
local emptyShip = assetState({ inventoryFree = 100 })
local fullShip = assetState({ inventoryFree = 0 })
check('cargo load lowers utility of further mining',
  Policy.score(mineJob, fullShip, riskPolicy, 0)
    < Policy.score(mineJob, emptyShip, riskPolicy, 0))
check('cargo load raises utility of delivery work',
  Policy.score(transportJob, fullShip, riskPolicy, 0)
    > Policy.score(transportJob, emptyShip, riskPolicy, 0))

local powerJob = job('patrol:power', 'patrol', 100, 10)
powerJob.energyDemand = 1
local lowCharge = assetState({ charge = 10 })
check('low capacitor discounts energy-intensive goals',
  Policy.score(powerJob, lowCharge, riskPolicy, 0)
    < Policy.score(powerJob, emptyShip, riskPolicy, 0))
check('capacitor reserve also nudges normal economic travel utility',
  Policy.score(mineJob, lowCharge, riskPolicy, 0)
    < Policy.score(mineJob, emptyShip, riskPolicy, 0))

local dutyJob = job('patrol:duty', 'patrol', 100, 10)
dutyJob.organizationId = 'belt-miners'
local dutyOwner = { hasOrganization = function (_, id) return id == 'belt-miners' end }
local dutyShip = assetState({ owner = dutyOwner })
local ordinaryShip = assetState()
check('faction duty raises utility of matching work',
  Policy.score(dutyJob, dutyShip, riskPolicy, 0)
    > Policy.score(dutyJob, ordinaryShip, riskPolicy, 0))
local industrialDuty = assetState({ owner = dutyOwner, npcRole = 'industrial' })
local freighterDuty = assetState({ owner = dutyOwner, npcRole = 'freighter' })
local miningDutyJob = job('mine:faction-duty', 'mine', 100, 10)
miningDutyJob.organizationId = 'belt-miners'
check('role duty favors an industrial ship for its faction mining work',
  Policy.score(miningDutyJob, industrialDuty, riskPolicy, 0)
    > Policy.score(miningDutyJob, freighterDuty, riskPolicy, 0))

local protectedOwner, hostileOwner = {}, {}
local friendlyOwner = { getDisposition = function (_, target) return target == protectedOwner and 1 or 0 end }
local hostileRelationOwner = { getDisposition = function (_, target) return target == hostileOwner and -1 or 0 end }
local relationJob = job('transport:relationship', 'transport', 100, 10)
relationJob.dst = { getOwner = function () return protectedOwner end }
local friendShip = assetState({ owner = friendlyOwner })
local waryShip = assetState({ owner = hostileRelationOwner })
check('relationship standing changes goal utility',
  Policy.score(relationJob, friendShip, riskPolicy, 0)
    > Policy.score(relationJob, waryShip, riskPolicy, 0))

local committed = assetState({ job = leanFast })
check('current route commitment receives a continuity bonus',
  Policy.score(leanFast, committed, policy, 0)
    > Policy.score(leanFast, assetState(), policy, 0))
local traitsA = Policy.Personality and Policy.Personality(Policy.Create(123))
local traitsB = Policy.Personality and Policy.Personality(Policy.Create(123))
local traitsOther = Policy.Personality and Policy.Personality(Policy.Create(124))
check('personality traits are deterministic and seeded', traitsA and traitsB and traitsOther
  and traitsA.riskTolerance == traitsB.riskTolerance
  and traitsA.riskTolerance ~= traitsOther.riskTolerance)

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
