#!/usr/bin/env luajit
-- Generation fingerprints prevent stale asteroid overlays attaching to new rocks.

local root = (io.popen('pwd'):read('*l') or '.') .. '/'
package.path = root .. 'script/?.lua;' .. package.path
local loaded, Fingerprint = pcall(require, 'Game.GenerationFingerprint')
if not loaded then print('FAIL - generation fingerprint helper is available'); os.exit(1) end

local failures, checks = 0, 0
local function check (name, ok)
  checks = checks + 1
  if ok then print('ok   - ' .. name) else failures = failures + 1; print('FAIL - ' .. name) end
end
local fields = {
  generator = 'stream', worldSeed = '0011223344556677', sectorSeed = '123',
  scope = 'asteroidField', cx = 1, cy = -2, cz = 3, slot = 4,
  chunkSize = 2500, perChunk = 2, rockScale = 1.1, oreChance = 0.9,
  seed = 98765, scale = 123.5, x = 10, y = 20, z = 30,
}
local fp = Fingerprint.Physical(fields)
check('same generation inputs have the same fingerprint', Fingerprint.Physical(fields) == fp)
local function changed (key, value)
  local copy = {}; for k, v in pairs(fields) do copy[k] = v end; copy[key] = value
  return Fingerprint.Physical(copy)
end
check('world seed changes physical identity', changed('worldSeed', '0011223344556678') ~= fp)
check('sector seed changes physical identity', changed('sectorSeed', '124') ~= fp)
check('chunk size changes physical identity', changed('chunkSize', 5000) ~= fp)
check('density changes physical identity', changed('perChunk', 3) ~= fp)
check('region density changes physical identity', changed('rockScale', 1.2) ~= fp)
check('region ore chance changes physical identity', changed('oreChance', 0.5) ~= fp)
check('rock seed changes physical identity', changed('seed', 98766) ~= fp)
check('rock scale changes physical identity', changed('scale', 124) ~= fp)
check('generating position changes physical identity', changed('x', 11) ~= fp)
local deposit = Fingerprint.Deposit(fp, 'Iron Ore', 1, 120)
check('deposit fingerprint is deterministic', Fingerprint.Deposit(fp, 'Iron Ore', 1, 120) == deposit)
check('commodity changes deposit identity', Fingerprint.Deposit(fp, 'Copper Ore', 1, 120) ~= deposit)
check('yield size changes deposit identity', Fingerprint.Deposit(fp, 'Iron Ore', 2, 120) ~= deposit)
check('initial amount changes deposit identity', Fingerprint.Deposit(fp, 'Iron Ore', 1, 121) ~= deposit)

if failures == 0 then
  print(string.format('asteroid fingerprints: %d checks passed', checks)); os.exit(0)
else
  print(string.format('asteroid fingerprints: %d/%d checks failed', failures, checks)); os.exit(1)
end
