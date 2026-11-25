local Action = require('Game.Action')
local Communication = require('Game.Communication')
local Directives = require('Game.Directives')
local NpcPolicy = require('Game.NpcPolicy')
local NpcPopulation = require('Game.NpcPopulation')
local NpcSafety = require('Game.NpcSafety')
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
  policy = NpcPolicy.Create(tostring(ownerId) .. ':' .. tostring(asset.id))
  self.policies[asset] = policy
  asset.npcPolicy = policy
  asset.knownYields = asset.knownYields or {}
  asset.scannedAsteroids = asset.scannedAsteroids or {}
  return policy
end

function Think:getSafety (asset)
  local state = self.safety[asset]
  if state then return state end
  state = NpcSafety.Create()
  self.safety[asset] = state
  asset:register(Event.Damaged, function (self, event)
    local root = self:getRoot()
    local now = root and root.getTime and root:getTime() or 0
    NpcSafety.recordDamage(state, event.amount, event.source, now)
    local owner = self:getOwner()
    local organizationId = owner and owner.getOrganization and owner:getOrganization()
    if root and root.comms and organizationId and event.source
       and event.source.isAlive and event.source:isAlive()
       and now - (state.lastThreatAt or -math.huge) >= 10 then
      state.lastThreatAt = now
      local range = (Config.game and Config.game.commRange) or 20000
      Communication.sendToOrganization(root.comms, owner, organizationId, 'threat',
        { target = event.source }, { now = now, range = range })
    end
  end)
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
  if asset.npcRole ~= 'fighter' or not asset:isIdle() then return end
  local root = asset:getRoot()
  local center = root and root.getPatrolCenter and root:getPatrolCenter()
  if not center then return end
  local Actions = requireAll('Game.Actions')
  local radius = (Config.game and Config.game.patrolRadius) or 5000
  asset:pushAction(Actions.Patrol(center, radius))
end

function Think:hasKnownYield (asset)
  for rock in pairs(asset.knownYields or {}) do
    if not rock.deleted and not (rock.isDestroyed and rock:isDestroyed())
       and (not rock.getParent or rock:getParent()) then
      return true
    end
  end
  return false
end

function Think:manageScan (asset)
  if not NpcPopulation.CanDoJob(asset.npcRole or 'capital', 'mine') then return end
  if not asset:isIdle() then return end
  if self:hasKnownYield(asset) then return end
  local root = asset:getRoot()
  if not root or not root.findScanTarget then return end
  local target = root:findScanTarget(asset)
  if not target then return end
  local Actions = requireAll('Game.Actions')
  local range = (Config.game and Config.game.scanRange) or 2000
  -- Scan sits below MoveTo: it stays hidden while approaching, then becomes
  -- active when the ship reaches scanning range.
  asset:pushAction(Actions.Scan(target))
  asset:pushAction(Actions.MoveTo(target, range))
end

function Think:manageDirective (asset)
  if not asset:isIdle() then return end
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

function Think:manageAsset (asset)
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
    asset:pushAction(assigned)
  end
end

function Think:onUpdateActive (e, dt)
  Profiler.Begin('Action.Think')
  self:drainMessages(e)
  do -- Manage assets
    for asset in e:iterAssets() do
      local root = asset:getRoot()
      self:manageSafety(asset)
      self:managePatrol(asset)
      self:manageScan(asset)
      self:manageDirective(asset)
      if root and root:hasEconomy() and asset:isIdle() then
        self:manageAsset(asset)
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
