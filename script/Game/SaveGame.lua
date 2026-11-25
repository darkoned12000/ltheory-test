--[[ SaveGame -- save slots: the player snapshot plus the world seed.

  PORTED AS A DESIGN from ltheory-old's Game/SaveGame{,JSON} (the user's
  saved Lua-/C++ sources in /Load-Save). The shape of a save is the same
  insight that made the old one small: THE WORLD IS NOT SAVED. This
  engine's worlds regenerate deterministically from a 64-bit seed -- that
  is what a seed is FOR (App/LTheory.lua's generate()) -- so a save
  carries the seed and the PLAYER: position, velocity, heading, hull,
  credits and cargo. The station markets, the sectors and the belts all
  come back from generation exactly as they were; nothing else is
  tracked, and nothing else can drift.

  THE SLOT LAYER mirrors the old C++ (SaveGameJSON.cpp) closely:
    * every slot is a standalone JSON file at ./saves/<slot>.json;
    * slot names are sanitized (no separators, no dots) so a name cannot
      escape the saves dir;
    * 10 slots max (the player asked for 5-10 while the LOAD page is
      young), quicksaves included; a NEW slot beyond the cap is refused,
      overwriting an existing slot never is;
    * each SAVE accumulates into its own timestamped slot rather than
      overwriting the previous one ("save-YYYYMMDD-HHMMSS");
    * slot listing reads each file (foreign/corrupt files are skipped,
      not fatal) so the LOAD page can show what is actually there.

  THE SEED IS A HEX STRING (`seedHex`), never a JSON number: a double
  holds 53 bits, and the seed is 64 -- see Json.lua and seedFromHex in
  LTheory.lua. The LOAD path feeds that hex string back through the very
  same parser the CUSTOM GAME field uses, so there is exactly one place
  where a seed hex becomes a seed.

  FILE ACCESS is the engine's File API (like the SETTINGS screen's
  Config.Settings.lua write): runtime code cannot count on io.* beyond
  what Main.lua's boot uses, and File.ReadCstr/WriteStr round-trip text
  cleanly. Deletion has no engine call (Directory_Remove is an rmdir),
  so it uses os.remove -- os is global in the app env (DebugWindow
  already uses os.date the same way).
]]

local File = require('ffi.File')
local Directory = require('ffi.Directory')
local Tex2D = require('ffi.Tex2D')
local Json = require('Game.Json')
local Item = require('Game.Item')
local NpcPolicy = require('Game.NpcPolicy')
local RouteKey = require('Game.RouteKey')
local ScannerDB = require('Game.ScannerDB')
local NpcSafety = require('Game.NpcSafety')
local Knowledge = require('Game.Knowledge')

local SaveGame = {}

local SAVE_VERSION = 2
local SLOTS_DIR    = './saves/'
local SAVE_EXT     = '.json'
-- The player's ask: "5-10 saves for now" -- 10 it is. Raise when the
-- LOAD page grows pagination or a delete affordance.
local MAX_SLOTS    = 10

-- The THUMBNAIL: the game captures a working shot of the last CLEAN
-- gameplay frame (no menu over it) every time the menu opens from live
-- play, and a save copies that file next to its JSON. The LOAD page then
-- shows what the save actually looks like.
local THUMB_W      = 256
local WORK_SHOT    = './saves/_latest.png'

-- ---------------------------------------------------------------------------
-- Items: the cargo is keyed by Item instances at runtime, but a save file
-- can only hold NAMES. Item.All() is the item database: every Item ever
-- constructed (Content.lua builds the game's set at boot), and a name is
-- the natural ID for one.
-- ---------------------------------------------------------------------------

local function itemByName (name)
  for _, item in ipairs(Item.All()) do
    if item:getName() == name then return item end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Capture / restore: the snapshot lives in plain Lua tables with plain
-- numbers, so JSON is just a format for it and nothing FFI leaks through.
-- ---------------------------------------------------------------------------

local function vec3 (v)
  if not v then return nil end
  return {x = tonumber(v.x), y = tonumber(v.y), z = tonumber(v.z)}
end

local function finite (value, fallback)
  value = tonumber(value)
  if value and value == value and value ~= math.huge and value ~= -math.huge then
    return value
  end
  return fallback
end

local function restoreVec (value)
  if type(value) ~= 'table' then return nil end
  local x, y, z = finite(value.x), finite(value.y), finite(value.z)
  if not x or not y or not z then return nil end
  return Vec3f(x, y, z)
end

local function restoreQuat (value)
  if type(value) ~= 'table' then return nil end
  local x, y, z, w = finite(value.x), finite(value.y), finite(value.z), finite(value.w)
  if not x or not y or not z or not w then return nil end
  return Quat(x, y, z, w)
end

local function captureItems (entity)
  local items = {}
  if entity.hasInventory and entity:hasInventory() then
    for item, count in pairs(entity:getInventory()) do
      if count > 0 then items[#items + 1] = { item = item:getName(), count = count } end
    end
    table.sort(items, function (a, b) return a.item < b.item end)
  end
  return items
end

local function captureModules (ship)
  local modules = {}
  for _, socket in ipairs(ship.sockets or {}) do
    if socket.child then
      modules[#modules + 1] = { id = socket.moduleId, type = socket.type,
        index = socket.typeIndex }
    end
  end
  table.sort(modules, function (a, b)
    if a.type ~= b.type then return a.type < b.type end
    return (a.index or 0) < (b.index or 0)
  end)
  return modules
end

function SaveGame.CaptureJob (ship)
  local job = ship.job
  if not job then return nil end
  local active = false
  for _, action in ipairs(ship.actions or {}) do
    if action == job then active = true; break end
  end
  if not active then return nil end
  local kind = job.getKind and job:getKind()
  local src = job.src and RouteKey.Entity(job.src)
  local dst = job.dst and RouteKey.Entity(job.dst)
  if not kind or (job.src and not RouteKey.IsPersistent(src))
     or (job.dst and not RouteKey.IsPersistent(dst)) then return nil end
  local current = ship.getCurrentAction and ship:getCurrentAction()
  local actionTarget = current and current.target and RouteKey.Entity(current.target) or nil
  if current and current.target and not RouteKey.IsPersistent(actionTarget) then return nil end
  local srcFingerprint = job.src and (job.src.depositFingerprint or job.src.generationFingerprint) or nil
  if kind == 'mine' and (type(srcFingerprint) ~= 'string' or srcFingerprint == '') then
    return nil
  end
  return {
    kind = kind,
    src = src,
    srcFingerprint = srcFingerprint,
    dst = dst,
    item = job.itemName or (job.item and job.item:getName())
      or (job.src and job.src.getYield and job.src:getYield().item:getName()) or nil,
    state = ship.jobState or 0,
    tradeCount = ship.tradeCount,
    action = current and current.getName and current:getName():match('^%S+') or nil,
    actionTarget = actionTarget,
  }
end

local function captureKnowledge (ship)
  local state = ship.knowledge or Knowledge.FromLegacy(ship.knownYields, ship.scannedAsteroids)
  return Knowledge.Capture(state)
end

function SaveGame.CaptureShip (ship)
  if not ship then return nil end
  local id = ship.stableId or (ship.getRegistryId and ship:getRegistryId())
  if not id or id == '' then return nil end
  local rot = ship.getRot and ship:getRot()
  local dockedAt = ship.getParent and ship:getParent()
  return {
    id = id,
    kind = ship.shipKind or ship.npcRole,
    role = ship.npcRole,
    variant = ship.shipVariant,
    seed = ship.prototypeSeed,
    scale = ship.getScale and ship:getScale() or nil,
    capacity = ship.hasInventory and ship:hasInventory() and ship:getInventoryCapacity() or nil,
    name = ship.getName and ship:getName() or nil,
    pos = ship.getPos and vec3(ship:getPos()) or nil,
    vel = ship.getVelocity and vec3(ship:getVelocity()) or nil,
    rot = rot and { x = tonumber(rot.x), y = tonumber(rot.y),
      z = tonumber(rot.z), w = tonumber(rot.w) } or nil,
    health = ship.hasHealth and ship:hasHealth() and {
      value = ship:getHealth(), max = ship.healthMax, rate = ship.healthRate } or nil,
    charge = ship.hasCharge and ship:hasCharge() and {
      value = ship:getCharge(), max = ship:getChargeMax(), rate = ship.chargeRate } or nil,
    items = captureItems(ship),
    modules = captureModules(ship),
    dockedAt = dockedAt and RouteKey.Entity(dockedAt) or nil,
    policy = ship.npcPolicy and NpcPolicy.Capture(ship.npcPolicy) or nil,
    safety = ship.npcSafety and NpcSafety.Capture(ship.npcSafety) or nil,
    knowledge = captureKnowledge(ship),
    job = SaveGame.CaptureJob(ship) or ship.pendingJob,
  }
end

function SaveGame.RestoreShip (ship, data)
  if not ship or type(data) ~= 'table' then return end
  if type(data.kind) == 'string' then ship.shipKind = data.kind end
  if type(data.role) == 'string' then
    ship.npcRole = data.role
  elseif type(data.kind) == 'string' then
    ship.npcRole = data.kind -- legacy snapshots only stored the hull kind
  end
  if type(data.variant) == 'number' then ship.shipVariant = data.variant end
  if type(data.seed) == 'number' or type(data.seed) == 'string' then
    ship.prototypeSeed = data.seed
  end
  local pos, vel, rot = restoreVec(data.pos), restoreVec(data.vel), restoreQuat(data.rot)
  if pos then ship:setPos(pos) end
  if vel then ship:setVelocity(vel) end
  if rot and (rot.x ~= 0 or rot.y ~= 0 or rot.z ~= 0 or rot.w ~= 0) then ship:setRot(rot) end
  if type(data.health) == 'table' and ship.hasHealth and ship:hasHealth() then
    local value = finite(data.health.value)
    local max = finite(data.health.max, ship.healthMax)
    local rate = finite(data.health.rate, ship.healthRate)
    if value and max and max > 0 and rate then ship:setHealth(value, max, rate) end
  end
  if type(data.charge) == 'table' and ship.hasCharge and ship:hasCharge() then
    local value = finite(data.charge.value)
    local max = finite(data.charge.max, ship:getChargeMax())
    local rate = finite(data.charge.rate, ship.chargeRate)
    if value and max and max > 0 and rate then ship:setCharge(value, max, rate) end
  end
  local capacity = finite(data.capacity)
  if capacity and capacity > 0 and ship.hasInventory and ship:hasInventory() then
    ship:setInventoryCapacity(capacity)
    for item in pairs(ship:getInventory()) do ship:getInventory()[item] = nil end
    ship:refreshInventory()
    for _, entry in ipairs(type(data.items) == 'table' and data.items or {}) do
      if type(entry) == 'table' and type(entry.item) == 'string' then
        local item = itemByName(entry.item)
        local count = finite(entry.count)
        if item and count and count > 0 then ship:addItem(item, count) end
      end
    end
  end
  if type(data.policy) == 'table' then
    ship.npcPolicy = NpcPolicy.Create(0)
    NpcPolicy.Restore(ship.npcPolicy, data.policy)
  end
  if data.safety then
    ship.npcSafety = ship.npcSafety or NpcSafety.Create()
    NpcSafety.Restore(ship.npcSafety, data.safety)
  end
  ship.knowledge = Knowledge.Create()
  Knowledge.Restore(ship.knowledge, data.knowledge)
  ship.knownYields = ship.knowledge.knownYields
  ship.scannedAsteroids = ship.knowledge.scannedAsteroids
  local root = ship.getRoot and ship:getRoot()
  if root and root.registerKnowledgeShip then root:registerKnowledgeShip(ship) end
  if type(data.job) == 'table' then ship.pendingJob = data.job end
end

local function restoreScannerDB (owner, data)
  if not owner or not owner.getScannerDB or type(data) ~= 'table' then return end
  local ownerId = owner.getActorId and owner:getActorId() or 'player'
  local db = ScannerDB.Create(ownerId)
  ScannerDB.Restore(db, data)
  owner.scannerDB = db
end

local function captureTransit (transit)
  if type(transit) ~= 'table' then return nil end
  local arrival, pos = transit.arrivalPos, nil
  if type(arrival) == 'table' then
    local x, y, z = finite(arrival.x), finite(arrival.y), finite(arrival.z)
    if x and y and z then pos = { x = x, y = y, z = z } end
  end
  return {
    destination = tonumber(transit.destination), fromSector = tonumber(transit.fromSector),
    reason = type(transit.reason) == 'string' and transit.reason or 'travel',
    departedAt = tonumber(transit.departedAt) or 0,
    arrivalPos = pos,
  }
end

local function copyProfile (profile)
  local out = {}
  for key, value in pairs(profile or {}) do
    if type(value) == 'string' or type(value) == 'number' or type(value) == 'boolean' then
      out[key] = value
    end
  end
  return out
end

-- Actor state is additive to the deterministic world snapshot. Ships and the
-- economy regenerate from the seed; stable NPC ids let us put persistent
-- identity, wealth, affiliation, and profile back onto those fresh actors.
function SaveGame.CaptureNpcs (system)
  local out = {}
  if not system then return out end
  local actors, seen = {}, {}
  for _, npc in ipairs(system.npcs and system.npcs.list or {}) do
    if not seen[npc] then seen[npc] = true; actors[#actors + 1] = npc end
  end
  for _, entry in ipairs(system.npcTransit or {}) do
    local npc = entry.npc
    if npc and not seen[npc] then seen[npc] = true; actors[#actors + 1] = npc end
  end
  for _, npc in ipairs(actors) do
    local organizationId = npc:getOrganization()
    local ships = {}
    for _, ship in ipairs(npc:getAssets()) do
      local snapshot = SaveGame.CaptureShip(ship)
      if snapshot then ships[#ships + 1] = snapshot end
    end
    table.sort(ships, function (a, b) return a.id < b.id end)
    local standings = {}
    for id, value in pairs(npc.organizationStanding or {}) do
      standings[#standings + 1] = { id = id, value = value }
    end
    table.sort(standings, function (a, b) return a.id < b.id end)
    out[#out + 1] = {
      id = npc:getNpcId(),
      profile = copyProfile(npc:getNpcProfile()),
      organization = organizationId,
      standing = organizationId and npc:getOrganizationStanding(organizationId) or 0,
      standings = standings,
      credits = npc:getItemCount(Item.Credit),
      assetCount = #npc:getAssets(),
      primaryShip = npc.controlling and RouteKey.Entity(npc.controlling) or nil,
      ships = ships,
      scannerDB = npc.scannerDB and ScannerDB.Capture(npc.scannerDB) or nil,
      progression = npc.npcProgression and {
        purchaseSerial = math.max(0, math.floor(tonumber(npc.npcProgression.purchaseSerial) or 0)),
      } or nil,
      transit = captureTransit(npc.transit),
    }
  end
  table.sort(out, function (a, b) return a.id < b.id end)
  return out
end

function SaveGame.RestoreNpcs (system, data)
  if not system or type(data) ~= 'table' or type(data.npcs) ~= 'table' then return end
  local authoritative = system.despawnNPCPopulation and system.spawnAI
  local actors = {}
  if authoritative then system:despawnNPCPopulation() end
  for _, entry in ipairs(data.npcs) do
    if type(entry) == 'table' and type(entry.id) == 'string' and entry.id ~= '' then
      local profile = type(entry.profile) == 'table' and entry.profile or {}
      local organization = type(entry.organization) == 'string' and entry.organization or nil
      local npc = system:getNpc(entry.id)
      if not npc and system.spawnAI and not system:isTombstoned(entry.id) then
        npc = system:spawnAI(0, {
          npcId = entry.id,
          role = profile.role or 'capital',
          profile = profile,
          organization = organization,
        })
        system.npcPopulationActors = system.npcPopulationActors or {}
        system.npcPopulationActors[#system.npcPopulationActors + 1] = npc
      end
      if npc then
        npc:setNpcProfile(profile)
        if type(entry.progression) == 'table' then
          npc.npcProgression = {
            purchaseSerial = math.max(0, math.floor(tonumber(entry.progression.purchaseSerial) or 0)),
          }
        end
        if entry.scannerDB then restoreScannerDB(npc, entry.scannerDB) end
        npc:setOrganization(organization)
        if organization then
          npc:setOrganizationStanding(organization, tonumber(entry.standing) or 0)
        end
        for _, standing in ipairs(type(entry.standings) == 'table' and entry.standings or {}) do
          if type(standing) == 'table' and type(standing.id) == 'string' then
            npc:setOrganizationStanding(standing.id, tonumber(standing.value) or 0)
          end
        end
        local credits = math.max(0, math.floor(tonumber(entry.credits) or 0))
        local current = npc:getItemCount(Item.Credit)
        if current > credits then npc:removeItem(Item.Credit, current - credits) end
        if credits > current then npc:addItem(Item.Credit, credits - current) end

        local restoredShips = {}
        for _, snapshot in ipairs(type(entry.ships) == 'table' and entry.ships or {}) do
          if type(snapshot) == 'table' and type(snapshot.id) == 'string' then
            local ship = system.resolveStableId and system:resolveStableId(snapshot.id)
            local retired = system.isTombstoned and system:isTombstoned(snapshot.id)
            if not ship and not retired and system.spawnShip then
              ship = system:spawnShip(snapshot.kind or 'fighter', {
                shipId = snapshot.id, seed = snapshot.seed, variant = snapshot.variant,
                scale = snapshot.scale, cargo = snapshot.capacity,
                modules = type(snapshot.modules) == 'table' and snapshot.modules or nil,
              })
              if ship then ship:setOwner(npc) end
            end
            if ship then
              ship:clearActions()
              if type(snapshot.dockedAt) == 'string' then
                local parent = system:resolveStableId(snapshot.dockedAt)
                if parent and parent.hasDockable and parent:hasDockable() then parent:addDocked(ship) end
              end
              SaveGame.RestoreShip(ship, snapshot)
              restoredShips[snapshot.id] = ship
              if type(snapshot.name) == 'string' then ship:setName(snapshot.name) end
            end
          end
        end
        local assetCount = math.max(0, math.floor(tonumber(entry.assetCount) or 0))
        if (type(entry.ships) ~= 'table' or #entry.ships == 0) and assetCount > 0
           and #npc:getAssets() == 0 and system.spawnShip then
          local role = profile.role or 'capital'
          local shipId = 'ship:' .. entry.id:gsub('^npc:', '')
          local ship = system:spawnShip(role, { shipId = shipId })
          if ship then ship:setOwner(npc); npc:setControlling(ship) end
        end
        if type(entry.primaryShip) == 'string' then
          local primary = restoredShips[entry.primaryShip]
            or (system.resolveStableId and system:resolveStableId(entry.primaryShip))
          if primary then npc:setControlling(primary) end
        end
        if type(entry.transit) == 'table' and tonumber(entry.transit.destination) then
          local destination = math.floor(tonumber(entry.transit.destination))
          local primary = npc:getControlling() or restoredShips[entry.primaryShip or '']
          if primary then
            if destination ~= system.sectorIndex and system.beginNpcTransit then
              local arrival = entry.transit.arrivalPos
              local gate = {
                getPartnerSector = function () return destination end,
                getPartnerPos = function () return arrival end,
                getName = function () return 'saved transit gate' end,
              }
              if system:beginNpcTransit(npc, primary, gate, entry.transit.reason) then
                npc.transit.departedAt = tonumber(entry.transit.departedAt) or 0
              end
            elseif destination == system.sectorIndex and type(entry.transit.arrivalPos) == 'table' then
              local p = entry.transit.arrivalPos
              primary:setPos(Vec3f(p.x, p.y, p.z))
              npc.transit = nil
            end
          end
        end
        if authoritative and not npc.transit then actors[#actors + 1] = npc end
      end
    end
  end
  if authoritative then system.npcPopulationActors = actors end
end

-- Asteroid deposits are the mutable part of an otherwise deterministic world.
-- Keys identify a generated rock; values are remaining units. The map is small
-- (only mined rocks acquire entries) and survives stream unload/reload.
function SaveGame.CaptureDeposits (system)
  local out = {}
  for key, remaining in pairs(system and system.depositState or {}) do
    out[#out + 1] = { key = key, remaining = remaining,
      fingerprint = system.depositFingerprints and system.depositFingerprints[key] or nil }
  end
  table.sort(out, function (a, b) return a.key < b.key end)
  return out
end

function SaveGame.RestoreTombstones (system, data)
  if system and system.restoreTombstones then system:restoreTombstones(data) end
end

function SaveGame.RestoreWorld (system, data)
  if not system or not data then return end
  SaveGame.RestoreDeposits(system, data.deposits)
  SaveGame.RestoreTombstones(system, data.tombstones)
  local simTime = tonumber(data.simTime)
  if not simTime or simTime ~= simTime or simTime == math.huge or simTime == -math.huge then
    simTime = 0
  end
  system.time = math.max(0, simTime)
end

function SaveGame.RestoreDeposits (system, data)
  if not system or type(data) ~= 'table' then return end
  system.depositState = {}
  system.depositFingerprints = {}
  for _, entry in ipairs(data) do
    if type(entry) == 'table' and type(entry.key) == 'string'
       and type(entry.fingerprint) == 'string' and tonumber(entry.remaining) then
      system.depositState[entry.key] = math.max(0, math.floor(entry.remaining))
      system.depositFingerprints[entry.key] = entry.fingerprint
    end
  end
  -- Usually restore runs before streaming creates the field, but applying to
  -- already-loaded rocks makes the function safe for in-place restores too.
  for _, child in ipairs(system.children or {}) do
    local key = child.depositKey
    local fingerprint = key and system.depositFingerprints[key]
    if key and fingerprint and child.depositFingerprint == fingerprint and child.setDepositKey then
      child:setDepositKey(key, fingerprint)
    end
  end
end

-- The state a save carries about the player's ship. `ship` may be nil
-- (saved from the menu before the ship exists... it cannot: the world is
-- live behind the menu, but a dead ship's save must be refused by the
-- caller, not silently dropped here).
function SaveGame.Capture (ship, meta, system)
  local data = {
    saveVersion   = SAVE_VERSION,
    dateCreated   = false, -- stamped by SaveGame.Write
    saveName      = meta and meta.saveName or '',
    description   = meta and meta.description or '',
    playerName    = meta and meta.playerName or 'Player',
    systemName    = meta and meta.systemName or '',
    regionName    = meta and meta.regionName or '',
    sectorIndex   = meta and meta.sectorIndex or 0,
    seedHex       = meta and meta.seedHex or '',
  }
  if ship ~= nil then
    data.playerShip = SaveGame.CaptureShip(ship)
    local owner = ship.getOwner and ship:getOwner()
    if owner and owner.getScannerDB then
      data.playerScannerDB = ScannerDB.Capture(owner:getScannerDB())
    end
    data.playerPos  = vec3(ship:getPos())
    data.playerVel  = vec3(ship:getVelocity())
    local rot = ship:getRot()
    data.playerRot = {x = tonumber(rot.x), y = tonumber(rot.y),
                      z = tonumber(rot.z), w = tonumber(rot.w)}
    if ship:hasHealth() then
      data.shipHealth    = tonumber(ship.health)
      data.shipHealthMax = tonumber(ship.healthMax)
      data.shipHealthRate = tonumber(ship.healthRate)
    end
    data.playerCredits = ship:getCredits()
    if ship:hasInventory() then
      local items = {}
      for item, count in pairs(ship:getInventory()) do
        items[#items + 1] = {item = item:getName(), count = count}
      end
      -- A save dumps its cargo named and ordered, so loading one puts the
      -- SAME rows back the same way every time.
      table.sort(items, function (a, b) return a.item < b.item end)
      data.items = items
    end
  end
  if system then
    data.npcs = SaveGame.CaptureNpcs(system)
    data.deposits = SaveGame.CaptureDeposits(system)
    data.tombstones = system.captureTombstones and system:captureTombstones() or {}
    data.simTime = system.getTime and system:getTime() or 0
  end
  return data
end

-- Put the snapshot INTO a freshly generated ship: pos, velocity, heading,
-- hull, credits, cargo. Setters only (the fresh ship's other components --
-- thrusters, turrets, mass -- are regenerated identical to the saved
-- one's, being proto + seed driven).
function SaveGame.Restore (ship, data, system)
  if data == nil then return end
  if system then
    SaveGame.RestoreWorld(system, data)
    SaveGame.RestoreNpcs(system, data)
  end
  if ship == nil then
    if system and system.rebindKnowledge then system:rebindKnowledge() end
    return
  end
  if type(data.playerShip) == 'table' then SaveGame.RestoreShip(ship, data.playerShip) end
  local owner = ship.getOwner and ship:getOwner()
  if type(data.playerScannerDB) == 'table' then restoreScannerDB(owner, data.playerScannerDB) end
  local playerPos, playerVel = restoreVec(data.playerPos), restoreVec(data.playerVel)
  if playerPos then ship:setPos(playerPos) end
  if playerVel then ship:setVelocity(playerVel) end
  -- A zero quaternion is a corrupt save, not a heading: leave the fresh
  -- spawn's identity rotation rather than setting a degenerate one.
  local r = restoreQuat(data.playerRot)
  if r and (r.x ~= 0 or r.y ~= 0 or r.z ~= 0 or r.w ~= 0) then ship:setRot(r) end
  -- Inside the fountain: hull first (a dead-ship save refuses at the
  -- caller), then credits and cargo.
  if ship:hasHealth() then
    local value = finite(data.shipHealth)
    local max = finite(data.shipHealthMax, ship.healthMax)
    local rate = finite(data.shipHealthRate, ship.healthRate)
    if value and max and max > 0 and rate then ship:setHealth(value, max, rate) end
  end
  local credits = finite(data.playerCredits)
  if credits and credits > 0 then ship:addCredits(credits) end
  -- `playerShip.items` is the authoritative cargo snapshot. The top-level
  -- `items` array is the legacy mirror; applying both duplicates small stacks.
  if type(data.items) == 'table' and not data.playerShip then
    for _, entry in ipairs(data.items) do
      if type(entry) == 'table' and type(entry.item) == 'string' then
        local item = itemByName(entry.item)
        local count = finite(entry.count)
        if item and count and count > 0 then ship:addItem(item, count) end
      end
    end
  end
  if system and type(data.playerShip) == 'table' and type(data.playerShip.dockedAt) == 'string' then
    local parent = system.resolveStableId and system:resolveStableId(data.playerShip.dockedAt)
    if parent and parent.hasDockable and parent:hasDockable() then parent:addDocked(ship) end
  end
  if system and system.rebindKnowledge then system:rebindKnowledge() end
end

-- ---------------------------------------------------------------------------
-- Slot paths and names
-- ---------------------------------------------------------------------------

-- Strip path separators, dots and control characters: a slot name is a
-- FILE NAME the player chose with a keyboard, and '.' would let "." or
-- ".." walk out of the saves dir.
local function sanitize (name)
  local clean = (name or ''):gsub('[%.%c/\\:]', '')
  if #clean == 0 then clean = 'save' end
  return clean:sub(1, 80)
end

local function slotPath (name)
  return SLOTS_DIR .. sanitize(name) .. SAVE_EXT
end

-- The slot's thumbnail rides next to its JSON with the same sanitized
-- name. `sanitize` is local to the slot naming, so the path builder is
-- here and exported below alongside the slot functions.
local function thumbPath (name)
  return SLOTS_DIR .. sanitize(name) .. '.png'
end

local function ensureDir ()
  Directory.Create(SLOTS_DIR)
end

-- ---------------------------------------------------------------------------
-- The thumbnail.
--
-- `Tex2D.ScreenCapture` grabs the whole framebuffer (window-sized), and a
-- save wants a SMALL image the LOAD page can show per row -- a 4K window's
-- full PNG is ~15 MB, so the capture is downscaled to ~256 px wide before
-- it is written. The engine has no GPU-downscale-on-demand helper exposed
-- to the app, but it HAS pixel readback (`getDataBytes`), and a LuaJIT box
-- filter over the readback is a one-shot ~50 ms at menu-open time: nobody
-- is flying during it.
-- ---------------------------------------------------------------------------

-- Average the source image down to dw x dh, FLIPPING while it goes: a GL
-- texture's data rows run bottom-up (FBO origin), so passing the readback
-- straight through produced upside-down thumbnails (the user's report:
-- the HUD's top-left sector readout appeared bottom-left). With flip on,
-- output row y is built from source row sh-1-y, so the output runs
-- top-down like the image it represents.
local function downscaleRGBA (src, sw, sh, dw, dh, flip)
  local out = ffi.new('uint8_t[?]', dw * dh * 4)
  local fx, fy = sw / dw, sh / dh
  local floor = math.floor
  for oy = 0, dh - 1 do
    local y0 = floor(oy * fy)
    local y1 = math.max(y0 + 1, floor((oy + 1) * fy))
    for ox = 0, dw - 1 do
      local x0 = floor(ox * fx)
      local x1 = math.max(x0 + 1, floor((ox + 1) * fx))
      local r, g, b, a, n = 0, 0, 0, 0, 0
      for y = y0, y1 - 1 do
        local row = (flip and (sh - 1 - y) or y) * sw
        for x = x0, x1 - 1 do
          local i = (row + x) * 4
          r, g, b, a, n = r + src[i], g + src[i + 1], b + src[i + 2], a + src[i + 3], n + 1
        end
      end
      local o = (oy * dw + ox) * 4
      out[o], out[o + 1], out[o + 2], out[o + 3] = r / n, g / n, b / n, a / n
    end
  end
  return out
end

-- A working shot of the last fully RENDERED frame: the post chain's final
-- compose (`renderer.buffer0` after a frame -- scene, HUD and UI overlay
-- already over it). Saving the TEXTURE needs no viewport stack (the default
-- framebuffer readback aborts on an empty one, which is exactly where
-- captures outside the draw phase land), and it races nothing: glGetTexImage
-- reads whatever the last completed frame wrote. The app calls this when
-- the menu opens from live play; the next SAVE copies the file next to the
-- slot's JSON.
function SaveGame.CaptureWorkingShot (renderer)
  local ok, err = pcall(function ()
    ensureDir()
    local big = renderer.buffer0
    local size = big:getSize() -- NOTE : returns a Vec2i (see ffiext/Tex2D.lua).
    -- Keep the window's aspect; fix only the width.
    local dw = THUMB_W
    local dh = math.max(1, math.floor(size.y * dw / size.x + 0.5))
    local src = big:getDataBytes(PixelFormat.RGBA, DataFormat.U8)
    -- getData() is a void*; the filter needs byte-sized indexing. The
    -- readback runs bottom-up, so the filter flips (see downscaleRGBA).
    local small = downscaleRGBA(ffi.cast('uint8_t*', src:getData()),
      size.x, size.y, dw, dh, true)
    src:free()
    local tex = Tex2D.Create(dw, dh, TexFormat.RGBA8)
    local bytes = Bytes.Create(dw * dh * 4)
    ffi.copy(bytes:getData(), small, dw * dh * 4)
    tex:setDataBytes(bytes, PixelFormat.RGBA, DataFormat.U8)
    tex:save(WORK_SHOT)
    tex:free()
    bytes:free()
  end)
  if not ok then
    Log.Warning('SAVE: thumbnail capture failed (%s)', tostring(err))
  end
end

-- Copy the working shot next to a saved slot's JSON.
function SaveGame.SaveThumbnail (slotName)
  if not File.Exists(WORK_SHOT) then return false end
  local src = File.ReadBytes(WORK_SHOT)
  if not src then return false end
  local ok = pcall(function ()
    ensureDir()
    local f = File.Create(thumbPath(slotName))
    f:write(src:getData(), src:getSize())
    f:close()
  end)
  src:free()
  return ok
end

function SaveGame.ThumbnailPath (slotName)
  local path = thumbPath(slotName)
  return File.Exists(path) and path or nil
end

-- THE TOAST ROWS for a slot's data: the old game's quicksave
-- notification fields (the user's mock: date, player, position,
-- credits, inventory, seed) plus the sector/region line. Shared by the
-- save and load toasts, so the two sides of a slot say the same things.
function SaveGame.ToastRows (data, note)
  local rows = {
    { label = 'Date',   value = data.dateCreated or '?' },
    { label = 'Player', value = data.playerName or 'Player' },
  }
  local pos = data.playerPos
  if pos then
    rows[#rows + 1] = { label = 'Position',
      value = string.format('%.0f, %.0f, %.0f', pos.x, pos.y, pos.z) }
  end
  rows[#rows + 1] = { label = 'Credits', value = tostring(data.playerCredits or 0) }
  local inv = {}
  if data.items then
    for _, it in ipairs(data.items) do
      inv[#inv + 1] = string.format('%s x%d', it.item, it.count)
    end
  end
  rows[#rows + 1] = { label = 'Inventory',
    value = #inv > 0 and table.concat(inv, ', ') or '(empty)' }
  rows[#rows + 1] = { label = 'Seed', value = data.seedHex or '?' }
  if (data.systemName or '') ~= '' then
    rows[#rows + 1] = { label = 'Place',
      value = data.systemName ..
        ((data.regionName or '') ~= '' and (' · ' .. data.regionName) or '') }
  end
  if note then rows[#rows + 1] = { note = note } end
  return rows
end

-- ---------------------------------------------------------------------------
-- Reading and writing
-- ---------------------------------------------------------------------------

-- Reads one slot. Returns data or nil, reason -- a MISSING file, a corrupt
-- file and a foreign-version file all degrade to "no such save", because
-- from the player's chair they are the same situation.
function SaveGame.Read (slotName)
  local path = slotPath(slotName)
  if not File.Exists(path) then return nil, 'no such save' end
  local okFile, contents = pcall(File.Read, path)
  if not okFile or contents == nil then return nil, tostring(contents) end
  local ok, data = pcall(Json.Decode, contents)
  if not ok then return nil, 'unreadable save: ' .. tostring(data) end
  if type(data) ~= 'table' or data.saveVersion ~= SAVE_VERSION then
    return nil, 'unsupported save version'
  end
  return data
end

-- Writes one slot; returns the sanitized slot name, or nil, reason.
function SaveGame.Write (slotName, data)
  local clean = sanitize(slotName)
  -- The cap applies to NEW slots only; overwriting an existing one is
  -- always allowed (a full list must not make a RE-save of a row fail).
  local exists = File.Exists(slotPath(clean))
  if not exists and SaveGame.Count() >= MAX_SLOTS then
    return nil, string.format('all %d save slots are used', MAX_SLOTS)
  end
  if not data.dateCreated then
    -- os.date is the same call DumpSettings uses; saves want the local
    -- wall clock, human-readable, and nothing depends on its format.
    data.dateCreated = os.date('%Y-%m-%d %H:%M:%S')
  end
  data.saveVersion = SAVE_VERSION
  local ok, err = pcall(function ()
    ensureDir()
    local f = File.Create(slotPath(clean))
    f:writeStr(Json.Encode(data))
    f:close()
  end)
  if not ok then return nil, 'write failed: ' .. tostring(err) end
  return clean
end

-- THE QUICKSAVE RULE, kept from the old layer: every save accumulates
-- into its own timestamped slot instead of overwriting the previous one.
-- TWO SAVES IN THE SAME SECOND would have collided on the same name and
-- silently overwritten (a fast double-click on SAVE NEW SLOT looked
-- exactly like "the game only keeps one save"): -2, -3, ... disambiguate.
-- `base` is the name prefix; the scan is shared by the menu's save (save-…)
-- and the F6 quicksave (quicksave-…).
function SaveGame.UnusedSlotName (base)
  local name = base
  local n = 2
  while File.Exists(slotPath(name)) and n < 100 do
    name = base .. '-' .. n
    n = n + 1
  end
  return name
end

function SaveGame.DefaultSlotName ()
  return SaveGame.UnusedSlotName('save-' .. os.date('%Y%m%d-%H%M%S'))
end

-- ---------------------------------------------------------------------------
-- The slot list
-- ---------------------------------------------------------------------------

local function listSlotNames ()
  ensureDir()
  local dir = Directory.Open(SLOTS_DIR)
  if not dir then return {} end
  local names = {}
  while true do
    -- Directory:GetNext yields a raw cstr (see ffiext/Directory.lua's
    -- walkDirectory for the house pattern): nil at the end, ffi.string
    -- to bring the names across.
    local entry = dir:getNext()
    if entry == nil then break end
    local name = ffi.string(entry)
    if #name > #SAVE_EXT and name:sub(-#SAVE_EXT) == SAVE_EXT then
      names[#names + 1] = name:sub(1, #name - #SAVE_EXT)
    end
  end
  dir:close()
  table.sort(names, function (a, b) return a > b end) -- newest first
  return names
end

-- The LOAD page's data: every valid slot, newest first. Skips (does not
-- hard-fail on) files it cannot read -- a crashed save should not take
-- the menu with it.
function SaveGame.ListSlots ()
  local slots = {}
  for _, name in ipairs(listSlotNames()) do
    local data, why = SaveGame.Read(name)
    if data then
      slots[#slots + 1] = {
        slotName    = name,
        dateCreated = data.dateCreated or '?',
        saveName    = data.saveName or name,
        playerName  = data.playerName or '?',
        systemName  = data.systemName or '',
        regionName  = data.regionName or '',
        credits     = data.playerCredits or 0,
        seedHex     = data.seedHex or '',
        pos         = data.playerPos,
        thumb       = SaveGame.ThumbnailPath(name),
      }
    else
      Log.Warning('SAVE: skipping unreadable slot %s (%s)', name, tostring(why))
    end
  end
  return slots
end

-- The newest slot by dateCreated (the string format sorts lexically).
function SaveGame.ReadLatest ()
  local latest = nil
  for _, info in ipairs(SaveGame.ListSlots()) do
    if latest == nil or info.dateCreated > latest.dateCreated then
      latest = info
    end
  end
  return latest
end

function SaveGame.Count ()
  return #listSlotNames()
end

function SaveGame.Exists (slotName)
  return File.Exists(slotPath(slotName))
end

function SaveGame.Delete (slotName)
  local path = slotPath(slotName)
  if not File.Exists(path) then return false end
  local thumb = thumbPath(slotName)
  if File.Exists(thumb) then os.remove(thumb) end
  return os.remove(path) ~= nil
end

-- The name of the UI-level file, for the docs and the HELP page.
SaveGame.SLOTS_DIR = SLOTS_DIR
SaveGame.MAX_SLOTS = MAX_SLOTS

-- The item resolver, exported for the LOAD-side tests.
SaveGame.ItemByName = itemByName
SaveGame.Sanitize   = sanitize

return SaveGame
