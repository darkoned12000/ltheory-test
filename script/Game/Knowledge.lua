-- Durable scan knowledge keyed by structural asteroid identity. Entity maps
-- are disposable caches rebuilt after streaming; the scan records are truth.

local StableId = require('Game.StableId')
local Knowledge = {}

function Knowledge.Create ()
  return { scans = {}, knownYields = {}, scannedAsteroids = {} }
end

function Knowledge.FromLegacy (knownYields, scannedAsteroids)
  local state = Knowledge.Create()
  for entity in pairs(scannedAsteroids or {}) do Knowledge.Record(state, entity, false) end
  for entity in pairs(knownYields or {}) do Knowledge.Record(state, entity, true) end
  return state
end

function Knowledge.Key (entity)
  return StableId.For(entity)
end

function Knowledge.Fingerprint (entity)
  return entity and (entity.depositFingerprint or entity.generationFingerprint) or nil
end

local function matches (record, entity)
  if not record or not entity then return false end
  local fingerprint = Knowledge.Fingerprint(entity)
  return fingerprint ~= nil and record.fingerprint == fingerprint
end

function Knowledge.Record (state, entity, yieldIdentified)
  if not state or not entity then return end
  state.scannedAsteroids = state.scannedAsteroids or {}
  state.knownYields = state.knownYields or {}
  state.scannedAsteroids[entity] = true
  if yieldIdentified and entity.hasYield and entity:hasYield() then
    state.knownYields[entity] = true
  else
    state.knownYields[entity] = nil
  end
  local key = Knowledge.Key(entity)
  local fingerprint = Knowledge.Fingerprint(entity)
  if not key or key:sub(1, 8) == 'runtime:' or type(fingerprint) ~= 'string'
     or fingerprint == '' then return end
  state.scans = state.scans or {}
  state.scans[key] = { fingerprint = fingerprint,
    yieldIdentified = yieldIdentified == true }
end

function Knowledge.Scanned (state, entity)
  if not state or not entity then return false end
  local key = Knowledge.Key(entity)
  local record = key and state.scans and state.scans[key]
  if record then return matches(record, entity) end
  if not (state.scannedAsteroids and state.scannedAsteroids[entity]) then return false end
  -- An unfingerprinted object can be remembered for this session only. A
  -- fingerprinted object without a matching durable record must fail closed.
  return Knowledge.Fingerprint(entity) == nil
end

function Knowledge.Known (state, entity)
  if not state or not entity or not entity.hasYield or not entity:hasYield() then return false end
  local key = Knowledge.Key(entity)
  local record = key and state.scans and state.scans[key]
  if record then return matches(record, entity) and record.yieldIdentified == true end
  if not (state.knownYields and state.knownYields[entity]) then return false end
  return Knowledge.Fingerprint(entity) == nil
end

local function wrongSector (key, sector)
  if not key or not sector then return false end
  local sourceSector = key:match('^asteroidField:(%-?%d+):')
  return sourceSector ~= nil and sourceSector ~= tostring(sector)
end

function Knowledge.Rebind (state, resolve, tombstoned, sector)
  if not state then return 0 end
  local previousScanned = state.scannedAsteroids or {}
  local previousKnown = state.knownYields or {}
  state.scannedAsteroids, state.knownYields = {}, {}
  -- Objects without structural identity are session-only caches. Structural
  -- objects are rebuilt exclusively from durable records so unloaded rocks do
  -- not remain strongly referenced by every pilot that scanned them.
  for entity in pairs(previousScanned) do
    if not Knowledge.Key(entity) then
      state.scannedAsteroids[entity] = true
      if previousKnown[entity] and entity.hasYield and entity:hasYield() then
        state.knownYields[entity] = true
      end
    end
  end
  local unresolved = 0
  for key, record in pairs(state.scans or {}) do
    if type(record) ~= 'table' or type(record.fingerprint) ~= 'string'
       or record.fingerprint == '' then
      state.scans[key] = nil
    else
      local entity = resolve and resolve(key)
      if entity and not matches(record, entity) then entity = nil; state.scans[key] = nil
      elseif not entity and ((tombstoned and tombstoned(key, record.fingerprint))
         or wrongSector(key, sector)) then
        state.scans[key] = nil
      end
      if entity then
        state.scannedAsteroids[entity] = true
        if record.yieldIdentified and entity.hasYield and entity:hasYield() then
          state.knownYields[entity] = true
        end
      elseif state.scans[key] then
        unresolved = unresolved + 1
      end
    end
  end
  return unresolved
end

function Knowledge.Capture (state)
  local out = {}
  for key, record in pairs(state and state.scans or {}) do
    if type(key) == 'string' and key ~= '' and key:sub(1, 8) ~= 'runtime:'
       and type(record) == 'table' and type(record.fingerprint) == 'string'
       and record.fingerprint ~= '' then
      out[#out + 1] = { key = key, fingerprint = record.fingerprint,
        yieldIdentified = record.yieldIdentified == true }
    end
  end
  table.sort(out, function (a, b) return a.key < b.key end)
  return out
end

function Knowledge.Restore (state, data)
  state.scans, state.knownYields, state.scannedAsteroids = {}, {}, {}
  if type(data) ~= 'table' then return end
  -- Current saves are a sorted array. Accept an object wrapper as an additive
  -- evolution, but deliberately ignore the old known/scanned key arrays: they
  -- carried no generation fingerprint and cannot be rebound fail-closed.
  local entries = data.scans or data
  if type(entries) ~= 'table' then return end
  for _, entry in ipairs(entries) do
    if type(entry) == 'table' and type(entry.key) == 'string' and entry.key ~= ''
       and entry.key:sub(1, 8) ~= 'runtime:' and type(entry.fingerprint) == 'string'
       and entry.fingerprint ~= '' then
      state.scans[entry.key] = { fingerprint = entry.fingerprint,
        yieldIdentified = entry.yieldIdentified == true }
    end
  end
end

return Knowledge
