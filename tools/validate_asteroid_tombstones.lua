#!/usr/bin/env luajit
-- Streamed chunks suppress tombstoned slots without shifting survivors.

local root = (io.popen('pwd'):read('*l') or '.') .. '/'
package.path = root .. 'script/?.lua;' .. package.path
package.loaded['Game.Entities.Asteroid'] = function () return {} end
package.loaded['Game.Seed'] = {}
local AsteroidField = require('Game.Entities.AsteroidField')

local failures, checks = 0, 0
local function check (name, ok)
  checks = checks + 1
  if ok then print('ok   - ' .. name) else failures = failures + 1; print('FAIL - ' .. name) end
end

local added = {}
local system = {
  seed = 123, sectorSeed = 456, deadFingerprint = 'fp-dead',
  isTombstoned = function (self, key, fingerprint)
    return key == 'asteroidField:456:0:0:0:2' and fingerprint == self.deadFingerprint
  end,
  addChild = function (_, entity) added[#added + 1] = entity end,
}
local field = AsteroidField.new(system)
field.loadedCount = 2
local live = { stableId = 'asteroidField:456:0:0:0:1', generationFingerprint = 'physical-live',
  depositFingerprint = 'fp-live', setDepositKey = function (self, key) self.appliedKey = key end }
local dead = { stableId = 'asteroidField:456:0:0:0:2', generationFingerprint = 'physical-dead',
  depositFingerprint = 'fp-dead', setDepositKey = function () end }
local chunk = { rocks = { { entity = live }, { entity = dead } } }
local count = field:materializeChunk(chunk)
check('materialization omits tombstoned rock', count == 1 and #chunk.rocks == 1)
check('materialization keeps surviving rock identity', chunk.rocks[1].entity == live
  and added[1] == live and live.appliedKey == live.stableId)
check('loaded rock count excludes tombstoned slot', field.loadedCount == 1)
system.deadFingerprint = 'fp-replacement'
field.loadedCount = 2
chunk.rocks = { { entity = live }, { entity = dead } }
check('replacement rock is not suppressed by a stale fingerprint',
  field:materializeChunk(chunk) == 2 and field.loadedCount == 2)

if failures == 0 then
  print(string.format('asteroid tombstones: %d checks passed', checks)); os.exit(0)
else
  print(string.format('asteroid tombstones: %d/%d checks failed', failures, checks)); os.exit(1)
end
