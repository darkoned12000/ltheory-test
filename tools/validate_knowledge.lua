#!/usr/bin/env luajit
-- Durable, fingerprint-aware ship scan knowledge.

local root = (io.popen('pwd'):read('*l') or '.') .. '/'
package.path = root .. 'script/?.lua;' .. package.path
local loaded, Knowledge = pcall(require, 'Game.Knowledge')
if not loaded then print('FAIL - knowledge module is available'); os.exit(1) end

local failures, checks = 0, 0
local function check (name, ok)
  checks = checks + 1
  if ok then print('ok   - ' .. name) else failures = failures + 1; print('FAIL - ' .. name) end
end
local function rock (key, fingerprint, yielded)
  return { stableId = key, depositFingerprint = fingerprint,
    hasYield = function () return yielded end }
end
local state = Knowledge.Create()
local a = rock('rock:1', 'fp1', true)
Knowledge.Record(state, a, true)
check('successful scan is durable by structural key', Knowledge.Scanned(state, a)
  and Knowledge.Known(state, a))
local replacement = rock('rock:1', 'fp1', true)
check('rematerialized rock retains scan knowledge', Knowledge.Scanned(state, replacement)
  and Knowledge.Known(state, replacement))
replacement.hasYield = function () return false end
check('depleted rock stays scanned but is not a known usable yield',
  Knowledge.Scanned(state, replacement) and not Knowledge.Known(state, replacement))
local changed = rock('rock:1', 'fp2', true)
check('fingerprint mismatch rejects old knowledge', not Knowledge.Scanned(state, changed)
  and not Knowledge.Known(state, changed))
local mutated = rock('rock:1', 'fp1', true)
Knowledge.Record(state, mutated, true)
mutated.depositFingerprint = 'changed-in-place'
check('cached objects cannot bypass fingerprint validation',
  not Knowledge.Scanned(state, mutated) and not Knowledge.Known(state, mutated))
Knowledge.Record(state, rock('rock:2', 'fp3', false), false)
check('failed scan is remembered without a known yield',
  Knowledge.Scanned(state, rock('rock:2', 'fp3', false))
  and not Knowledge.Known(state, rock('rock:2', 'fp3', true)))
local snapshot = Knowledge.Capture(state)
local restored = Knowledge.Create()
Knowledge.Restore(restored, snapshot)
check('knowledge survives capture/restore', Knowledge.Scanned(restored, a)
  and Knowledge.Known(restored, a))

local unresolved = Knowledge.Create()
Knowledge.Record(unresolved, rock('asteroidField:7:0:0:0:1', 'fp4', true), true)
local resolved = {}
local remaining = Knowledge.Rebind(unresolved, function () return nil end,
  function () return false end, '7')
check('unloaded knowledge remains inert and retryable', remaining == 1
  and unresolved.scans['asteroidField:7:0:0:0:1'] ~= nil)
check('unloaded knowledge does not block unrelated state', not Knowledge.Known(unresolved, nil))
resolved['asteroidField:7:0:0:0:1'] = rock('asteroidField:7:0:0:0:1', 'fp4', true)
remaining = Knowledge.Rebind(unresolved, function (key) return resolved[key] end,
  function () return false end, '7')
check('materialized knowledge rebinds and compacts', remaining == 0
  and Knowledge.Known(unresolved, resolved['asteroidField:7:0:0:0:1']))

local dropped = Knowledge.Create()
Knowledge.Record(dropped, rock('asteroidField:7:0:0:0:2', 'fp5', true), true)
remaining = Knowledge.Rebind(dropped, function () return nil end,
  function (key) return key == 'asteroidField:7:0:0:0:2' end, '7')
check('tombstoned knowledge is discarded', remaining == 0
  and dropped.scans['asteroidField:7:0:0:0:2'] == nil)
local wrong = Knowledge.Create()
Knowledge.Record(wrong, rock('asteroidField:8:0:0:0:2', 'fp6', true), true)
remaining = Knowledge.Rebind(wrong, function () return nil end,
  function () return false end, '7')
check('wrong-sector knowledge is discarded', remaining == 0
  and wrong.scans['asteroidField:8:0:0:0:2'] == nil)
local unfingerprinted = rock('asteroidField:7:0:0:0:3', nil, true)
local session = Knowledge.Create()
Knowledge.Record(session, unfingerprinted, true)
check('unfingerprinted structural rocks remain session-only', Knowledge.Scanned(session, unfingerprinted)
  and #Knowledge.Capture(session) == 0)
local malformed = Knowledge.Create()
local malformedOk = pcall(function ()
  Knowledge.Restore(malformed, { 42, { key = 'runtime:1', fingerprint = 'fp' },
    { key = 'rock:bad', fingerprint = '' }, { key = 'rock:ok', fingerprint = 'fp7' } })
end)
check('malformed knowledge entries are skipped safely', malformedOk
  and malformed.scans['rock:bad'] == nil and malformed.scans['rock:ok'] ~= nil)

if failures == 0 then
  print(string.format('knowledge: %d checks passed', checks)); os.exit(0)
else
  print(string.format('knowledge: %d/%d checks failed', failures, checks)); os.exit(1)
end
