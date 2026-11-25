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
local RouteKey = require('Game.RouteKey')
local Seed = require('Game.Seed')

local kJobIterations = 100
local nextId = 0

local Think = subclass(Action, function (self)
  self.timer = 0
  self.policies = {}
  self.safety = {}
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
    local Actions = requireAll('Game.Actions')
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
  if not asset.npcSafetyHandler then
    asset.npcSafetyHandler = true
    asset:register(Event.Damaged, function (self, event)
      local root = self:getRoot()
      local now = root and root.getTime and root:getTime() or 0
      local safety = self.npcSafety or state
      NpcSafety.recordDamage(safety, event.amount, event.source, now)
      local owner = self:getOwner()
      local organizationId = owner and owner.getOrganization and owner:getOrganization()
      if root and root.comms and organizationId and event.source
         and event.source.isAlive and event.source:isAlive()
         and now - (safety.lastThreatAt or -math.huge) >= 10 then
        safety.lastThreatAt = now
        local range = (Config.game and Config.game.commRange) or 20000
        Communication.sendToOrganization(root.comms, owner, organizationId, 'threat',
          { target = event.source }, { now = now, range = range })
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
  if NpcSafety.shouldFlee(state, asset:getHealthNormalized(), now) then
    NpcSafety.beginFlee(state, now)
    NpcLog.Event(asset, 'safety retreat started')
    local Actions = requireAll('Game.Actions')
    asset:pushAction(Actions.Flee(state.source, NpcSafety.duration))
  end
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
      if target and target.isAlive and target:isAlive() and organizationId
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
              organizationId = organizationId, capacity = 2, now = now, expiresAt = now + 60,
            })
          else
            Directives.create(root.directives, e, 'defend', target, {
              organizationId = organizationId, capacity = 2, now = now, expiresAt = now + 60,
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
  local Actions = requireAll('Game.Actions')
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
  local Actions = requireAll('Game.Actions')
  local range = (Config.game and Config.game.scanRange) or 2000
  -- Scan sits below MoveTo: it stays hidden while approaching, then becomes
  -- active when the ship reaches scanning range.
  asset:pushAction(Actions.Scan(target))
  asset:pushAction(Actions.MoveTo(target, range))
end

function Think:manageDirective (asset)
  if asset.pendingJob or not asset:isIdle() then return end
  local root = asset:getRoot()
  local manager = root and root.directives
  local owner = asset:getOwner()
  if not manager or not owner then return end

  local directive = Directives.activeFor(manager, owner)
  if not directive then
    directive = Directives.availableFor(manager, owner)
    if directive and not Directives.accept(manager, directive.id, owner) then return end
  end
  if directive and directive.target.isAlive and directive.target:isAlive() then
    local Actions = requireAll('Game.Actions')
    asset:pushAction(Actions.Attack(directive.target))
  end
end

function Think:manageJobValidity (asset)
  local job = asset.job
  if not job then return end
  local invalid = (job.src and job.src.deleted) or (job.dst and job.dst.deleted)
    or (job.src and job.src.getParent and not job.src:getParent())
    or (job.dst and job.dst.getParent and not job.dst:getParent())
  if invalid then
    NpcLog.Event(asset, 'job cancelled: endpoint left the active sector')
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
  if not asset:isAlive() or not asset.afterProgression or not asset:isIdle() then return end
  local parent = parentOf(asset)
  if parent and parent.hasDockable and parent:hasDockable() then
    local Actions = requireAll('Game.Actions')
    asset:pushAction(Actions.Undock())
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

function Think:manageProgression (asset)
  if not asset:isAlive() or asset.pendingJob or not goalSlotAvailable(asset) then return end
  local root = asset:getRoot()
  local available = actorCredits(asset)
  local station = findStation(root, asset, false)
  local Actions
  local function actionSet ()
    Actions = Actions or requireAll('Game.Actions')
    return Actions
  end
  local function start (name, action)
    claimGoalSlot(asset)
    asset.afterProgression = 'undock'
    NpcLog.Event(asset, name .. ' selected at ' .. station:getName())
    asset:pushAction(action)
  end
  if station and NpcProgression.NeedsRepair(asset, available) then
    start('repair', actionSet().Repair(station))
  elseif station and NpcProgression.NeedsRefit(asset, available) then
    start('refit', actionSet().Refit(station, NpcProgression.PreferredModule(NpcProgression.Role(asset))))
  else
    local kind = NpcProgression.UpgradeShipKind(asset)
    local yard = kind and findStation(root, asset, true)
    if yard and NpcProgression.NeedsShip(asset, available) then
      claimGoalSlot(asset)
      asset.afterProgression = 'undock'
      NpcLog.Event(asset, 'ship purchase selected: ' .. kind .. ' at ' .. yard:getName())
      asset:pushAction(actionSet().PurchaseShip(yard, { kind = kind }))
    end
  end
end

function Think:manageTravel (asset)
  if asset.pendingJob or not goalSlotAvailable(asset) then return end
  local root = asset:getRoot()
  if not root or type(root.sectors) ~= 'table' or root.sectorIndex == nil then return end
  local now = root.getTime and root:getTime() or 0
  asset.npcNextTravelAt = asset.npcNextTravelAt
    or now + ((Config.game and Config.game.npcTravelDelay) or 180)
  if now < asset.npcNextTravelAt then return end
  local targetSector = asset.travelTargetSector
  local gate = NpcTravel.SelectGate(root, asset, targetSector)
  if not gate then return end
  asset.npcNextTravelAt = now + ((Config.game and Config.game.npcTravelInterval) or 300)
  local distance, speed, eta = NpcTravel.NormalEta(asset, gate)
  NpcLog.Event(asset, format('travel selected %s -> sector %s dist=%.0f normalSpeed=%.0f eta=%.1fs',
    gate:getName(), tostring(gate:getPartnerSector()), distance, speed, eta))
  local Actions = requireAll('Game.Actions')
  claimGoalSlot(asset)
  asset:pushAction(Actions.TravelTo(gate, targetSector and 'mission' or 'exploration'))
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
