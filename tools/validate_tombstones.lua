#!/usr/bin/env luajit
-- Bounded persistent tombstones prevent deterministic world respawns.

local root = (io.popen('pwd'):read('*l') or '.') .. '/'
package.path = root .. 'script/?.lua;' .. package.path
local loaded, Tombstones = pcall(require, 'Game.Tombstones')
if not loaded then
  print('FAIL - tombstone store is available')
  os.exit(1)
end

local failures, checks = 0, 0
local function check (name, ok)
  checks = checks + 1
  if ok then print('ok   - ' .. name) else failures = failures + 1; print('FAIL - ' .. name) end
end

local store = Tombstones.Create(3)
store:Mark('rock:1')
store:Mark('rock:1')
check('tombstone marks are idempotent', store:Has('rock:1') and store:Count() == 1)
store:Mark('rock:2'); store:Mark('rock:3'); store:Mark('rock:4')
check('tombstone store is bounded', store:Count() == 3)
check('oldest tombstone is evicted', not store:Has('rock:1') and store:Has('rock:4'))
local data = store:Capture()
local restored = Tombstones.Create()
restored:Restore(data)
check('tombstones survive capture/restore', restored:Has('rock:2')
  and restored:Has('rock:3') and restored:Has('rock:4'))
restored:Restore({ { key = 42, remaining = 1 }, { key = 'rock:5' } })
check('restore ignores malformed entries', restored:Has('rock:5') and restored:Count() == 1)
local function matchesFingerprint (store, key, fingerprint)
  local ok, value = pcall(function () return store:Matches(key, fingerprint) end)
  return ok and value
end
local fingerprinted = Tombstones.Create(2)
fingerprinted:Mark('rock:1', 'fp1')
local matchesOk, matches = pcall(function () return matchesFingerprint(fingerprinted, 'rock:1', 'fp1') end)
check('fingerprinted tombstone matches the same rock', matchesOk and matches)
check('fingerprinted tombstone rejects a different rock', not matchesFingerprint(fingerprinted, 'rock:1', 'fp2'))
fingerprinted:Mark('rock:1', 'fp2')
check('remarking a key updates its fingerprint without growing the store',
  fingerprinted:Count() == 1 and matchesFingerprint(fingerprinted, 'rock:1', 'fp2'))
local fpRestored = Tombstones.Create()
fpRestored:Restore(fingerprinted:Capture())
check('tombstone fingerprints survive capture/restore', matchesFingerprint(fpRestored, 'rock:1', 'fp2'))
fingerprinted:Mark('rock:2', 'fp3'); fingerprinted:Mark('rock:3', 'fp4')
check('eviction clears fingerprint metadata', not matchesFingerprint(fingerprinted, 'rock:1', 'fp2'))

if failures == 0 then
  print(string.format('tombstones: %d checks passed', checks)); os.exit(0)
else
  print(string.format('tombstones: %d/%d checks failed', failures, checks)); os.exit(1)
end
