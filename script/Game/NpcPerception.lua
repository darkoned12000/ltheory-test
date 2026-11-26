-- Local, short-lived observations used by NPC steering and later goal scoring.
-- This is deliberately a bounded cache of nearby entities, not a second
-- authoritative world registry.

local Perception = {}
local scratchPos

local function valid (entity, root, observer)
  return entity and entity ~= observer and entity.parent == root
    and not entity.deleted and not (entity.isDestroyed and entity:isDestroyed())
    and (entity.body or entity.isWormhole)
end

local function kindOf (entity)
  if entity.isWormhole then return 'gate' end
  if entity.isAsteroid then return 'resource' end
  if entity.isPlanet then return 'planet' end
  if entity.hasDockable and entity:hasDockable() then return 'station' end
  if entity.hasSockets and entity:hasSockets() then return 'ship' end
  return 'obstacle'
end

local function relationOf (observer, entity, now)
  local safety = observer.npcSafety
  if safety and safety.source == entity and now >= (safety.lastDamageAt or -math.huge)
     and now - (safety.lastDamageAt or -math.huge) <= 8 then
    return 'threat'
  end
  local observerOwner = observer.getOwner and observer:getOwner()
  local otherOwner = entity.getOwner and entity:getOwner()
  if not (observerOwner and otherOwner) then return 'neutral' end
  if observerOwner == otherOwner then return 'ally' end
  local organization = observerOwner.getOrganization and observerOwner:getOrganization()
  local otherOrganization = otherOwner.getOrganization and otherOwner:getOrganization()
  if organization and organization == otherOrganization then return 'ally' end
  local disposition = observer.getOwnerDisposition
    and observer:getOwnerDisposition(otherOwner) or 0
  if disposition <= -0.5 then return 'threat' end
  if disposition >= 0.5 then return 'ally' end
  return 'neutral'
end

function Perception.Range (ship)
  local cfg = Config.game or {}
  local horizon = math.max(0.5, tonumber(cfg.npcAvoidanceHorizon) or 3.0)
  local speed = ship.getTopSpeed and ship:getTopSpeed() or 0
  local velocity = ship.getVelocity and ship:getVelocity()
  if velocity then speed = math.max(speed, velocity:length()) end
  local radius = ship.getRadius and ship:getRadius() or 0
  return math.max(tonumber(cfg.npcPerceptionRange) or 1000,
    speed * horizon + radius * 4 + 500)
end

function Perception.Local (ship, range)
  local root = ship and ship.getRoot and ship:getRoot()
  if not root then return {} end
  range = math.max(0, tonumber(range) or Perception.Range(ship))
  local rangeStep = 250
  local viewKey = math.ceil(range / rangeStep)
  local queryRange = math.max(rangeStep, viewKey * rangeStep)
  local now = root.getTime and root:getTime() or 0
  local interval = math.max(0, tonumber(Config.game and Config.game.npcPerceptionInterval) or 0.25)
  local cache = ship.npcPerception
  if cache and cache.root == root and cache.range >= queryRange
     and now >= cache.at and now - cache.at < interval then
    local view = cache.views[viewKey]
    if not view then
      view = {}
      local range2 = queryRange * queryRange
      for _, contact in ipairs(cache.contacts) do
        if contact.distance2 <= range2 then view[#view + 1] = contact end
      end
      cache.views[viewKey] = view
    end
    return view
  end

  local origin = ship:getPos()
  local range2 = queryRange * queryRange
  scratchPos = scratchPos or Vec3f()
  local contacts = {}
  local candidates = root.queryNpcPerception and root:queryNpcPerception(origin, queryRange)
    or root.children or {}
  for _, entity in ipairs(candidates) do
    if valid(entity, root, ship) then
      local pos
      if entity.body then
        entity.body:getPos(scratchPos)
        pos = scratchPos
      else
        pos = entity:getPos()
      end
      if pos then
        local dx, dy, dz = pos.x - origin.x, pos.y - origin.y, pos.z - origin.z
        local distance2 = dx*dx + dy*dy + dz*dz
        if distance2 <= range2 then
          contacts[#contacts + 1] = {
            entity = entity,
            kind = kindOf(entity),
            relation = relationOf(ship, entity, now),
            distance2 = distance2,
          }
        end
      end
    end
  end
  ship.npcPerception = {
    root = root, at = now, range = queryRange, contacts = contacts,
    views = { [viewKey] = contacts },
  }
  return contacts
end

local function stableSide (ship)
  local id = tostring(ship.stableId or ship.npcId or ship.id or '')
  local parity = 0
  for i = 1, #id do parity = (parity + id:byte(i)) % 2 end
  return parity == 0 and 1 or -1
end

function Perception.AvoidCourse (ship, desired, contacts, ignore)
  local cfg = Config.game or {}
  if not ship then return nil end
  if cfg.npcAvoidance == false then ship.npcAvoidanceState = nil; return nil end
  if not (desired and contacts and #contacts > 0) then
    ship.npcAvoidanceState = nil
    return nil
  end

  local desiredLength = desired:length()
  if desiredLength < 1e-6 then return nil end
  local direction = desired:scale(1 / desiredLength)
  local velocity = ship:getVelocity()
  local speed = math.max(velocity:length(), (ship.getTopSpeed and ship:getTopSpeed() or 0) * 0.65)
  if speed < 1e-3 then return nil end

  local shipPos = ship:getPos()
  local shipRadius = ship.getRadius and ship:getRadius() or 0
  local horizon = math.max(0.5, tonumber(cfg.npcAvoidanceHorizon) or 3.0)
  local radiusScale = math.max(1.0, tonumber(cfg.npcAvoidanceRadiusScale) or 1.25)
  local padding = math.max(0, tonumber(cfg.npcAvoidancePadding) or 20)
  local plannedVelocity = direction:scale(speed)
  local correction = Vec3f(0, 0, 0)
  local strongest, strongestWeight, strongestObstacle, strongestRadius = nil, 0, nil, nil
  local root = ship:getRoot()
  local retained = false
  local state = ship.npcAvoidanceState
  if state and state.obstacle ~= ignore and state.root == root and state.obstacle and state.obstacle.body
     and state.obstacle.parent == root and not state.obstacle.deleted
     and not (state.obstacle.isDestroyed and state.obstacle:isDestroyed()) then
    local relative = state.obstacle:getPos() - shipPos
    local along = relative:dot(direction)
    local lateral = (relative - direction:scale(along)):length()
    if along >= -state.safeRadius and lateral <= state.safeRadius * 1.5 then
      correction = correction + state.side:scale(state.weight * 0.6)
      retained = true
    else
      ship.npcAvoidanceState = nil
    end
  else
    ship.npcAvoidanceState = nil
  end

  for _, contact in ipairs(contacts) do
    local obstacle = contact.entity
    if obstacle and obstacle ~= ship and obstacle ~= ignore
       and obstacle.body and obstacle.parent == root
       and not obstacle.deleted and not (obstacle.isDestroyed and obstacle:isDestroyed()) then
      local obstaclePos = obstacle:getPos()
      local obstacleVelocity = obstacle:getVelocity()
      local relative = obstaclePos - shipPos
      local relativeVelocity = obstacleVelocity - plannedVelocity
      local velocity2 = relativeVelocity:dot(relativeVelocity)
      if velocity2 > 1e-6 then
        local t = -relative:dot(relativeVelocity) / velocity2
        if t >= 0 and t <= horizon then
          local closest = relative + relativeVelocity:scale(t)
          local distance = closest:length()
          local obstacleRadius = obstacle.getRadius and obstacle:getRadius() or 0
          local safeRadius = (shipRadius + obstacleRadius) * radiusScale + padding
          if distance < safeRadius then
            local lateral = closest - direction:scale(closest:dot(direction))
            local lateralLength = lateral:length()
            local side
            if lateralLength > 1e-6 then
              side = lateral:scale(-1 / lateralLength)
            else
              side = ship:getRight():scale(stableSide(ship))
            end
            local urgency = 1 - distance / math.max(safeRadius, 1e-6)
            local weight = 0.6 + urgency * 1.4
            correction = correction + side:scale(weight)
            if weight > strongestWeight then
              strongest, strongestWeight = side, weight
              strongestObstacle, strongestRadius = obstacle, safeRadius
            end
          end
        end
      end
    end
  end

  local correctionLength = correction:length()
  if correctionLength < 1e-6 then
    if not strongest then return nil end
    correction = strongest:scale(strongestWeight)
    correctionLength = correction:length()
  end
  if strongest then
    ship.npcAvoidanceState = {
      root = root, obstacle = strongestObstacle, side = strongest,
      safeRadius = strongestRadius, weight = strongestWeight,
      courseDirection = direction,
    }
  elseif not retained then
    ship.npcAvoidanceState = nil
  end
  if correctionLength > 2.0 then correction = correction:scale(2.0 / correctionLength) end
  return direction + correction
end

return Perception
