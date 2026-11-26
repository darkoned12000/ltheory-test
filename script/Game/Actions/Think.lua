local Action = require('Game.Action')
local Communication = require('Game.Communication')
local Directives = require('Game.Directives')
local Item = require('Game.Item')
local Knowledge = require('Game.Knowledge')
local NpcLog = require('Game.NpcLog')
local NpcPolicy = require('Game.NpcPolicy')
local NpcPopulation = require('Game.NpcPopulation')
local NpcProgression = require('Game.NpcProgression')
local NpcSafety = require('Game.NpcSafety')
local NpcTravel = require('Game.NpcTravel')
local DockService = require('Game.DockService')
local RouteKey = require('Game.RouteKey')
local Seed = require('Game.Seed')

local kJobIterations = 100
local nextId = 0
local Actions

local function getActions ()
  Actions = Actions or requireAll('Game.Actions')
  return Actions
end

local Think = subclass(Action, function (self)
  self.timer = 0
  self.policies = setmetatable({}, { __mode = 'k' })
  self.safety = setmetatable({}, { __mode = 'k' })
  -- Per-instance stream (was clock-seeded): two NPCs thinking in the same tick
  -- no longer interleave draws from one sequence.
  nextId = nextId + 1
  self.rng = Seed.rng('action.think', nextId):managed()
end)

function Think:clone ()
  return Think()
end

function Think:getName ()
  return 'Think'
end

function Think:getPolicy (asset)
  local policy = self.policies[asset]
  if policy then return policy end
  local owner = asset:getOwner()
  local ownerId = owner and owner.getNpcId and owner:getNpcId() or 'human'
  local shipId = RouteKey.Entity(asset) or ('runtime:' .. tostring(asset.id))
  policy = asset.npcPolicy or NpcPolicy.Create(tostring(ownerId) .. ':' .. tostring(shipId))
  self.policies[asset] = policy
  asset.npcPolicy = policy
  asset.knowledge = asset.knowledge or Knowledge.Create()
  asset.knownYields = asset.knowledge.knownYields
  asset.scannedAsteroids = asset.knowledge.scannedAsteroids
  return policy
end

function Think:restorePendingJob (asset)
  local data = asset.pendingJob
  if not data then return false end
  if type(data) ~= 'table' or type(data.src) ~= 'string' or type(data.dst) ~= 'string'
     or not RouteKey.IsPersistent(data.src) or not RouteKey.IsPersistent(data.dst)
     or (data.kind == 'mine' and (type(data.srcFingerprint) ~= 'string'
       or data.srcFingerprint == ''))
     or (data.actionTarget and (type(data.actionTarget) ~= 'string'
       or not RouteKey.IsPersistent(data.actionTarget))) then
    asset.pendingJob = nil
    return false
  end
  local root = asset:getRoot()
  if not root or not root.resolveStableId then return true end
  if root.isTombstoned and (root:isTombstoned(data.src, data.srcFingerprint)
     or root:isTombstoned(data.dst)) then
    asset.pendingJob = nil
    return false
  end
  if root.depositState and data.src and root.depositState[data.src] == 0
     and (not data.srcFingerprint or root.depositFingerprints
       and root.depositFingerprints[data.src] == data.srcFingerprint) then
    asset.pendingJob = nil
    return false
  end
  if data.src then
    local sourceSector = data.src:match('^asteroidField:(%-?%d+):')
    if sourceSector and tostring(root.sectorSeed or root.seed or '') ~= sourceSector then
      asset.pendingJob = nil
      return false
    end
  end
  local src = root:resolveStableId(data.src)
  local dst = root:resolveStableId(data.dst)
  if not src or not dst then return true end -- waiting for streaming/materialization
  if data.srcFingerprint then
    local fingerprint = src.depositFingerprint or src.generationFingerprint
    if fingerprint ~= data.srcFingerprint then asset.pendingJob = nil; return false end
  end

  local job
  if data.kind == 'mine' then
    if not src.hasYield or not src:hasYield() then asset.pendingJob = nil; return false end
    job = require('Game.Jobs.Mine')(src, dst)
  elseif data.kind == 'transport' then
    local item
    for _, candidate in ipairs(require('Game.Item').All()) do
      if candidate:getName() == data.item then item = candidate; break end
    end
    if not item then asset.pendingJob = nil; return false end
    job = require('Game.Jobs.Transport')(src, dst, item)
  else
    asset.pendingJob = nil
    return false
  end

  asset.job = job
  asset.jobState = math.max(0, (tonumber(data.state) or 1) - 1)
  asset.tradeCount = tonumber(data.tradeCount)
  asset:pushAction(job)
  local actionName = type(data.action) == 'string' and data.action:match('^%S+') or nil
  local jobName = job:getName():match('^%S+')
  if actionName and actionName ~= jobName then
    local Actions = getActions()
    local target = data.actionTarget and root:resolveStableId(data.actionTarget)
    if actionName == 'MoveTo' and target then
      asset:pushAction(Actions.MoveTo(target, 100))
    elseif actionName == 'Stop' then
      asset:pushAction(Actions.Stop())
    elseif actionName == 'MineAt' and target and target:hasYield() then
      asset:pushAction(Actions.MineAt(target))
    elseif actionName == 'DockAt' and target then
      asset:pushAction(Actions.DockAt(target))
    elseif actionName == 'Undock' then
      asset:pushAction(Actions.Undock())
    end
  else
    -- The stage's synchronous work already completed; continue with the next one.
    asset.jobState = tonumber(data.state) or 1
  end
  asset.pendingJob = nil
  return true
end

function Think:getSafety (asset)
  local state = asset.npcSafety or self.safety[asset]
  if not state then
    state = NpcSafety.Create()
    asset.npcSafety = state
  end
  self.safety[asset] = state
  local brain = self
  if not asset.npcSafetyHandler then
    asset.npcSafetyHandler = true
    local function registerAttacker (ship, source, now, safety)
      if not (source and NpcSafety.IsCombatant(source)) then return end
      safety.retaliationTarget = source
      safety.retaliationUntil = now + 60
      local owner = ship:getOwner()
      local sourceOwner = source.getOwner and source:getOwner()
      if owner and sourceOwner and owner ~= sourceOwner and owner.modDisposition then
        owner:modDisposition(sourceOwner, -1)
      end
      local organizationId = owner and owner.getOrganization and owner:getOrganization()
      local root = ship:getRoot()
      if root and root.comms and organizationId
         and now - (safety.lastThreatAt or -math.huge) >= 10 then
        safety.lastThreatAt = now
        local range = (Config.game and Config.game.commRange) or 20000
        Communication.sendToOrganization(root.comms, owner, organizationId, 'threat',
          { target = source, protected = ship }, { now = now, range = range })
      end
    end
    asset:register(Event.ShieldDamaged, function (ship, event)
      local root = ship:getRoot()
      local now = root and root.getTime and root:getTime() or 0
      registerAttacker(ship, event.source, now, ship.npcSafety or state)
    end)
    asset:register(Event.Damaged, function (ship, event)
      local root = ship:getRoot()
      local now = root and root.getTime and root:getTime() or 0
      local safety = ship.npcSafety or state
      NpcSafety.recordDamage(safety, event.amount, event.source, now)
      registerAttacker(ship, event.source, now, safety)

      -- Weapon bursts can land many hits before the next AI tick. Retreat has
      -- to begin on the hit itself; waiting for manageSafety lets a capital
      -- die with a perfectly good Flee decision still unexecuted.
      if not ship.isAlive or not ship:isAlive() then return end
      local current = ship.getCurrentAction and ship:getCurrentAction()
      if current and current.getName and current:getName() == 'Flee' then return end
      local personality = NpcPolicy.Personality(brain:getPolicy(ship))
      local riskTolerance = tonumber(ship.npcRiskTolerance) or personality.riskTolerance
      if NpcSafety.shouldFlee(safety, ship, now,
          NpcSafety.CargoValue(ship), riskTolerance) then
        NpcSafety.beginFlee(safety, now)
        NpcLog.Event(ship, 'safety retreat started on damage')
        ship:pushAction(getActions().Flee(safety.source, NpcSafety.duration))
      end
    end)
  end
  local root = asset:getRoot()
  if not state.source and state.sourceKey and root and root.resolveStableId then
    state.source = root:resolveStableId(state.sourceKey)
  end
  return state
end

function Think:manageSafety (asset)
  if not asset:isAlive() then return end
  local current = asset:getCurrentAction()
  if current and current:getName() == 'Flee' then return end
  local root = asset:getRoot()
  local now = root and root.getTime and root:getTime() or 0
  local state = self:getSafety(asset)
  local personality = NpcPolicy.Personality(self:getPolicy(asset))
  local riskTolerance = tonumber(asset.npcRiskTolerance) or personality.riskTolerance
  local cargoValue = NpcSafety.CargoValue(asset)
  if NpcSafety.shouldFlee(state, asset, now,
      cargoValue, riskTolerance) then
    NpcSafety.beginFlee(state, now)
    NpcLog.Event(asset, 'safety retreat started')
    local Actions = getActions()
    asset:pushAction(Actions.Flee(state.source, NpcSafety.duration))
  end
end

function Think:manageRetaliation (asset)
  if not asset:isAlive() or asset.pendingJob or asset.afterProgression then return end
  local root = asset:getRoot()
  local now = root and root.getTime and root:getTime() or 0
  local state = self:getSafety(asset)
  local target = state.retaliationTarget
  if not target then return end
  if now >= (state.retaliationUntil or -math.huge)
     or (target.isAlive and not target:isAlive()) then
    state.retaliationTarget, state.retaliationUntil = nil, -math.huge
    return
  end
  local current = asset:getCurrentAction()
  local name = current and current.getName and current:getName() or ''
  if name == 'Flee' or name:sub(1, 6) == 'Avoid' or name:sub(1, 6) == 'Repair'
     or name:sub(1, 5) == 'Refit' or name:sub(1, 12) == 'PurchaseShip'
     or name == 'Undock' or name:sub(1, 6) == 'Defend'
     or name:sub(1, 6) == 'Attack' then
    return
  end
  if not NpcSafety.IsCombatant(asset) or NpcSafety.HopelessFight(asset, target, 0) then
    return
  end
  for _, action in ipairs(asset.actions or {}) do
    if action.target == target and action.getName and action:getName():sub(1, 6) == 'Attack' then
      return
    end
  end
  NpcLog.Event(asset, 'retaliating against ' .. tostring(target.getName and target:getName() or 'attacker'))
  state.retaliationTarget, state.retaliationUntil = nil, -math.huge
  asset:pushAction(getActions().Attack(target))
end

function Think:manageRegroup (asset)
  if not asset.npcNeedsRegroup or asset.pendingJob or asset.afterProgression then return end
  local root = asset:getRoot()
  if not root then return end
  local now = root.getTime and root:getTime() or 0
  local untilTime = tonumber(asset.npcRegroupUntil)
    or (now + ((Config.game and Config.game.npcRegroupTimeout) or 45))
  asset.npcRegroupUntil = untilTime
  if now >= untilTime then
    asset.npcNeedsRegroup, asset.npcRegroupUntil = nil, nil
    return
  end

  local current = asset:getCurrentAction()
  local name = current and current.getName and current:getName() or ''
  if name == 'Flee' or name == 'Undock' or name:sub(1, 6) == 'Repair'
     or name:sub(1, 5) == 'Refit' or name:sub(1, 12) == 'PurchaseShip'
     or name:sub(1, 6) == 'Defend' or name:sub(1, 6) == 'Attack'
     or name:sub(1, 7) == 'Regroup' then
    return
  end

  local owner = asset:getOwner()
  local range = (Config.game and Config.game.npcRegroupScanRange) or 12000
  local range2 = range * range
  local best, bestDistance2
  local allies = root.npcTargets and root:npcTargets(asset) or {}
  for _, ally in ipairs(allies) do
    local allyOwner = ally.getOwner and ally:getOwner()
    if owner and allyOwner and owner.sharesOrganization
       and owner:sharesOrganization(allyOwner)
       and (not ally.isAlive or ally:isAlive()) then
      local delta = ally:getPos() - asset:getPos()
      local distance2 = delta:dot(delta)
      if distance2 <= range2 and (not best or distance2 < bestDistance2) then
        best, bestDistance2 = ally, distance2
      end
    end
  end

  if not best then return end
  local joinDistance = (Config.game and Config.game.npcRegroupDistance) or 1000
  if bestDistance2 <= joinDistance * joinDistance then
    asset.npcNeedsRegroup, asset.npcRegroupUntil = nil, nil
    return
  end
  local Actions = getActions()
  NpcLog.Event(asset, 'regrouping with ' .. tostring(best.getName and best:getName() or 'ally'))
  asset:pushAction(Actions.Regroup(best, joinDistance, untilTime - now))
end

function Think:drainMessages (e)
  local root
  for asset in e:iterAssets() do root = asset:getRoot(); break end
  if not root or not root.comms then return end
  local now = root.getTime and root:getTime() or 0
  for _, message in ipairs(Communication.drain(root.comms, e, 32)) do
    if message.kind == 'threat' or message.kind == 'defend.offer' then
      local target = message.payload.target
      local organizationId = e:getOrganization()
      if NpcSafety.IsCombatant(target) and organizationId
         and not Directives.activeFor(root.directives, e) then
        local exists = false
        for _, directive in ipairs(root.directives.list) do
          if directive.target == target and directive.organizationId == organizationId
             and (directive.status == 'open' or directive.status == 'active') then
            exists = true
            break
          end
        end
        if not exists then
          if root.createDefendDirective then
            root:createDefendDirective(e, target, {
              organizationId = organizationId, protected = message.payload.protected,
              capacity = 2, now = now, expiresAt = now + 60,
            })
          else
            Directives.create(root.directives, e, 'defend', target, {
              organizationId = organizationId, protected = message.payload.protected,
              capacity = 2, now = now, expiresAt = now + 60,
            })
          end
        end
      end
    end
  end
end

function Think:managePatrol (asset)
  if asset.pendingJob or asset.npcRole ~= 'fighter' or not asset:isIdle() then return end
  local root = asset:getRoot()
  local center = root and root.getPatrolCenter and root:getPatrolCenter()
  if not center then return end
  local Actions = getActions()
  local radius = (Config.game and Config.game.patrolRadius) or 5000
  asset:pushAction(Actions.Patrol(center, radius))
end

function Think:hasKnownYield (asset)
  asset.knowledge = asset.knowledge or Knowledge.Create()
  asset.knownYields = asset.knowledge.knownYields
  for rock in pairs(asset.knownYields) do
    if Knowledge.Known(asset.knowledge, rock) and not rock.deleted
       and not (rock.isDestroyed and rock:isDestroyed())
       and (not rock.getParent or rock:getParent()) then
      return true
    end
  end
  return false
end

function Think:manageScan (asset)
  if asset.pendingJob or not NpcPopulation.CanDoJob(asset.npcRole or 'capital', 'mine') then return end
  if not asset:isIdle() then return end
  if self:hasKnownYield(asset) then return end
  local root = asset:getRoot()
  if not root or not root.findScanTarget then return end
  local target = root:findScanTarget(asset)
  if not target then return end
  NpcLog.Event(asset, 'scan target ' .. target:getName())
  local Actions = getActions()
  local range = (Config.game and Config.game.scanRange) or 2000
  -- Scan sits below MoveTo: it stays hidden while approaching, then becomes
  -- active when the ship reaches scanning range.
  asset:pushAction(Actions.Scan(target))
  asset:pushAction(Actions.MoveTo(target, range))
end

function Think:manageDirective (asset)
  if asset.pendingJob or asset.afterProgression then return end
  local root = asset:getRoot()
  local manager = root and root.directives
  local owner = asset:getOwner()
  if not manager or not owner then return end
  local current = asset:getCurrentAction()
  local currentName = current and current.getName and current:getName() or ''
  if currentName == 'Flee' or currentName:sub(1, 6) == 'Avoid' then return end

  local directive = Directives.activeFor(manager, owner)
  local alreadyActive = directive ~= nil
  if not directive then
    directive = Directives.availableFor(manager, owner)
  end
  if not directive or not NpcSafety.IsCombatant(directive.target) then return end

  local support = 0
  local supportRange = (Config.game and Config.game.npcDefenseSupportRange) or 12000
  local siblings = root.npcTargets and root:npcTargets(asset) or root.children or {}
  for _, ally in ipairs(siblings) do
    local allyOwner = ally.getOwner and ally:getOwner()
    if ally ~= asset and ally.parent == root and allyOwner
       and NpcSafety.IsCombatant(ally)
       and owner.sharesOrganization and owner:sharesOrganization(allyOwner) then
      local a, b = ally:getPos(), asset:getPos()
      local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
      if dx*dx + dy*dy + dz*dz <= supportRange * supportRange then
        support = support + 1
      end
    end
  end
  if NpcSafety.HopelessFight(asset, directive.target, support) then
    if alreadyActive then Directives.release(manager, directive.id, owner) end
    for _, action in ipairs(asset.actions or {}) do
      if action.directive == directive then
        action.directive = nil
      end
    end
    for index = #asset.actions, 1, -1 do
      local name = asset.actions[index].getName and asset.actions[index]:getName() or ''
      if name:sub(1, 6) == 'Defend' then
        asset:popAction()
        break
      end
    end
    return
  end
  if not alreadyActive and not Directives.accept(manager, directive.id, owner) then return end

  current = asset:getCurrentAction()
  currentName = current and current.getName and current:getName() or ''
  if current and (currentName == 'Flee' or currentName:sub(1, 6) == 'Avoid'
      or currentName:sub(1, 6) == 'Repair'
      or currentName:sub(1, 5) == 'Refit' or currentName:sub(1, 12) == 'PurchaseShip'
      or currentName == 'Undock' or currentName:sub(1, 6) == 'Defend'
      or currentName:sub(1, 6) == 'Attack') then
    return
  end
  for _, action in ipairs(asset.actions or {}) do
    if action.directive == directive then return end
  end
  local Actions = getActions()
  local protected = directive.protected
    or (owner.getPrimaryShip and owner:getPrimaryShip()) or asset
  asset:pushAction(Actions.Defend(protected, directive.target, directive))
end

function Think:manageJobValidity (asset)
  local job = asset.job
  if not job then return end
  local invalid = (job.src and job.src.deleted) or (job.dst and job.dst.deleted)
    or (job.src and job.src.getParent and not job.src:getParent())
    or (job.dst and job.dst.getParent and not job.dst:getParent())
  if invalid then
    NpcLog.Event(asset, 'job cancelled: endpoint left the active sector')
    local root = asset:getRoot()
    local now = root and root.getTime and root:getTime() or 0
    NpcPolicy.recordOutcome(self:getPolicy(asset), job, 'cancelled', now)
    asset:clearActions()
    asset.job, asset.jobState, asset.tradeCount = nil, nil, nil
  end
end

local function parentOf (asset)
  if asset.getParent then return asset:getParent() end
  return asset.parent
end

local function actorCredits (asset)
  local owner = asset:getOwner()
  if not owner or not owner.getItemCount then return 0 end
  return owner:getItemCount(Item.Credit) or 0
end

local function hasGoods (asset)
  if not asset.hasInventory or not asset:hasInventory() then return false end
  for item, count in pairs(asset:getInventory()) do
    if item ~= Item.Credit and count > 0 then return true end
  end
  return false
end

local function goalSlotAvailable (asset)
  if asset:isIdle() then return true end
  local current = asset:getCurrentAction()
  return current and current:getName() == 'Patrol' or false
end

local function claimGoalSlot (asset)
  if asset:isIdle() then return end
  NpcLog.Event(asset, 'patrol yielded to a higher-priority goal')
  asset:popAction()
end

local function findStation (root, asset, shipyardOnly)
  local function usable (station)
    return station and not station.deleted and not station.isWormhole
      and station.hasDockable and station:hasDockable()
      and station.addItem and station.removeItem
      and (station.hasMarket and station:hasMarket() or station.hasTrader and station:hasTrader())
      and (not shipyardOnly or station.shipyard)
  end
  local current = parentOf(asset)
  if usable(current) and (not shipyardOnly or current.shipyard) then return current end
  local best, bestDistance
  local stations = root and type(root.npcStations) == 'table' and root.npcStations or root and root.children or {}
  for _, station in ipairs(stations) do
    if usable(station) then
      local distance = 0
      if asset.getMinDistance then
        distance = asset:getMinDistance(station)
      elseif asset.getPos and station.getPos then
        distance = (station:getPos() - asset:getPos()):length()
      end
      if not best or distance < bestDistance then best, bestDistance = station, distance end
    end
  end
  return best
end

function Think:manageDockExit (asset)
  if not asset:isAlive() or not asset.afterProgression then return end
  for _, action in ipairs(asset.actions or {}) do
    local name = action.getName and action:getName() or ''
    if name:sub(1, 6) == 'Repair' or name:sub(1, 5) == 'Refit'
       or name:sub(1, 12) == 'PurchaseShip' then
      return
    end
  end
  local parent = parentOf(asset)
  if parent and parent.hasDockable and parent:hasDockable() then
    local current = asset:getCurrentAction()
    if not (current and current.getName and current:getName() == 'Undock') then
      local Actions = getActions()
      asset:pushAction(Actions.Undock())
    end
  end
  asset.afterProgression = nil
end

function Think:manageUpkeep (asset, dt)
  if not asset:isAlive() then return end
  local owner = asset:getOwner()
  if not owner or not owner.getItemCount or not owner.hasItem or not owner.removeItem then return end
  local function charge (cost)
    if cost <= 0 then return true end
    if not owner:removeItem(Item.Credit, cost) then return false end
    NpcLog.Event(asset, format('upkeep paid=%d', cost))
    return true
  end
  if (asset.npcUpkeepDebt or 0) > 0 and owner:hasItem(Item.Credit, asset.npcUpkeepDebt) then
    if charge(asset.npcUpkeepDebt) then asset.npcUpkeepDebt = 0 end
  end
  asset.npcUpkeepElapsed = (asset.npcUpkeepElapsed or 0) + math.max(0, tonumber(dt) or 0)
  if asset.npcUpkeepElapsed >= 3600 then
    local elapsed = asset.npcUpkeepElapsed
    asset.npcUpkeepElapsed = 0
    local cost = NpcProgression.Upkeep(asset, elapsed)
    if not charge(cost) then
      asset.npcUpkeepDebt = (asset.npcUpkeepDebt or 0) + cost
      NpcLog.Event(asset, format('upkeep unpaid=%d debt=%d', cost, asset.npcUpkeepDebt))
    end
  end
end

local function serviceLog (asset, message)
  local root = asset:getRoot()
  local now = root and root.getTime and root:getTime() or 0
  local interval = (Config and Config.game and tonumber(Config.game.npcServiceLogInterval)) or 10
  if now - (asset.npcLastServiceLogAt or -math.huge) < interval then return end
  asset.npcLastServiceLogAt = now
  NpcLog.Event(asset, message)
end

function Think:manageProgression (asset)
  if not asset:isAlive() or asset.pendingJob or asset.afterProgression then return end
  local root = asset:getRoot()
  local now = root and root.getTime and root:getTime() or 0
  if now < (asset.npcNextServiceAt or 0) then return end
  local current = asset:getCurrentAction()
  if current and current.getName and current:getName() == 'Flee' then return end
  local canReplaceCurrent = goalSlotAvailable(asset)
  local available = actorCredits(asset)
  local needsRepair = NpcProgression.NeedsRepair(asset, available)
  local needsRefit = canReplaceCurrent and NpcProgression.NeedsRefit(asset, available)
  local kind = canReplaceCurrent and NpcProgression.UpgradeShipKind(asset) or nil
  local needsShip = kind and NpcProgression.NeedsShip(asset, available)
  local needsMarket = canReplaceCurrent and hasGoods(asset)
  if not needsRepair and not needsRefit and not needsShip and not needsMarket then return end
  local shipyardOnly = needsRefit or needsShip
  local station = findStation(root, asset, shipyardOnly)
  if not station then
    local target = NpcTravel.ServiceSector(root, shipyardOnly)
    if target and target ~= root.sectorIndex then
      asset.travelTargetSector = target
      asset.npcServiceNeed = shipyardOnly and 'shipyard' or 'station'
      asset.npcNextTravelAt = now
      serviceLog(asset, format('no local %s; routing to sector %d for service',
        asset.npcServiceNeed, target))
    else
      DockService.DelayRetry(asset)
      serviceLog(asset, 'no reachable sector offers the required station service')
    end
    return
  end
  if asset.npcServiceNeed then
    asset.travelTargetSector, asset.npcServiceNeed = nil, nil
    asset.npcNextTravelAt = now
  end
  local function actionSet ()
    return getActions()
  end
  local function start (name, action, interrupt)
    if not asset:isIdle() then
      local top = asset:getCurrentAction()
      if top and top:getName() == 'Patrol' then
        claimGoalSlot(asset)
      elseif not interrupt then
        return false
      else
        NpcLog.Event(asset, name .. ' preempted ' .. top:getName())
      end
    end
    asset.afterProgression = 'undock'
    DockService.ClearRetry(asset)
    NpcLog.Event(asset, name .. ' selected at ' .. station:getName())
    asset:pushAction(action)
    return true
  end
  if needsRepair then
    start('repair', actionSet().Repair(station), true)
  elseif needsRefit then
    local equipment = NpcProgression.NextEquipment(asset)
    start('refit', actionSet().Refit(station,
      NpcProgression.PreferredModule(NpcProgression.Role(asset)),
      { equipment = equipment, replace = true }))
  elseif needsShip then
    start('ship purchase', actionSet().PurchaseShip(station, { kind = kind }), false)
  end
end

function Think:manageTravel (asset)
  if asset.pendingJob or (not goalSlotAvailable(asset) and not asset.npcServiceNeed) then return end
  local root = asset:getRoot()
  if not root or type(root.sectors) ~= 'table' or root.sectorIndex == nil then return end
  local now = root.getTime and root:getTime() or 0
  if asset.npcServiceNeed then
    local station = findStation(root, asset, asset.npcServiceNeed == 'shipyard')
    if station then
      asset.travelTargetSector, asset.npcServiceNeed = nil, nil
      asset.npcNextTravelAt = now
      return
    end
  end
  asset.npcNextTravelAt = asset.npcNextTravelAt
    or now + ((Config.game and Config.game.npcTravelDelay) or 180)
  if now < asset.npcNextTravelAt then return end
  local targetSector = asset.travelTargetSector
  local gate = NpcTravel.SelectGate(root, asset, targetSector)
  if not gate then
    asset.npcNextTravelAt = now + ((Config.game and Config.game.npcTravelInterval) or 300)
    serviceLog(asset, 'station-service travel has no usable gate; will retry')
    return
  end
  asset.npcNextTravelAt = now + ((Config.game and Config.game.npcTravelInterval) or 300)
  local distance, speed, eta = NpcTravel.NormalEta(asset, gate)
  local reason = asset.npcServiceNeed and 'station-service' or targetSector and 'mission' or 'exploration'
  NpcLog.Event(asset, format('travel selected %s -> sector %s dist=%.0f normalSpeed=%.0f eta=%.1fs',
    gate:getName(), tostring(gate:getPartnerSector()), distance, speed, eta))
  local Actions = getActions()
  claimGoalSlot(asset)
  asset:pushAction(Actions.TravelTo(gate, reason))
end

function Think:manageAsset (asset)
  if asset.pendingJob then return end
  local root = asset:getRoot()
  local economy = root and root.hasEconomy and root:hasEconomy() and root:getEconomy()
  if not economy then return end

  local policy = self:getPolicy(asset)
  local now = root.getTime and root:getTime() or 0
  local bestScore = 0
  local bestJob = nil

  local function consider (job)
    if not job or not NpcPolicy.canAssign(policy, job, now) then return end
    if job.isKnown and not job:isKnown(asset) then return end
    if job.getKind and not NpcPopulation.CanDoJob(asset.npcRole or 'capital', job:getKind()) then return end
    local score = NpcPolicy.score(job, asset, policy, now)
    if score > bestScore then
      bestScore = score
      bestJob = job
    end
  end

  -- The last route remains a candidate, but only after its cooldown expires.
  consider(asset.job)
  for i = 1, kJobIterations do
    -- TODO : KnowsAbout/perception check
    consider(self.rng:choose(economy.jobs))
  end

  if bestJob then
    -- Economy Mine jobs are pooled and retargeted when the registry changes.
    -- Each ship must own a clean action instance for the whole route.
    local assigned = bestJob:clone()
    asset.job = assigned
    local name = assigned.getName and assigned:getName() or assigned:getKey()
    NpcLog.Event(asset, 'job accepted ' .. tostring(name))
    asset:pushAction(assigned)
  end
end

function Think:onUpdateActive (e, dt)
  Profiler.Begin('Action.Think')
  self:drainMessages(e)
  do -- Manage assets
    for asset in e:iterAssets() do
      local root = asset:getRoot()
      if asset.pendingJob then self:restorePendingJob(asset) end
      self:manageSafety(asset)
      self:manageDockExit(asset)
      self:manageUpkeep(asset, dt)
      self:manageJobValidity(asset)
      if not asset.pendingJob then
        self:manageProgression(asset)
        self:manageRetaliation(asset)
        self:manageRegroup(asset)
        self:manageTravel(asset)
        self:managePatrol(asset)
        self:manageScan(asset)
        self:manageDirective(asset)
        if root and root:hasEconomy() and asset:isIdle() then
          self:manageAsset(asset)
        end
      end
      local now = root and root.getTime and root:getTime() or 0
      local interval = (Config.game and Config.game.npcLogInterval) or 5
      if now - (asset.npcLastLogAt or -math.huge) >= interval then
        asset.npcLastLogAt = now
        NpcLog.Status(asset, root, now)
      end
    end
  end

  self.timer = self.timer + dt
  do -- Capital expenditure
    if self.timer > 5 then
      --
    end
  end
  Profiler.End()
end

return Think
