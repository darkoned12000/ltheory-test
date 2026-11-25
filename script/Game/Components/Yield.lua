local Entity = require('Game.Entity')
local Registry = require('Game.EconomyRegistry')

-- NOTE : The 'size' of an entity's yield serves as a rate limiter. No more
--        than 'size' (energy-normalized) units of item may be extracted per
--        unit time from the entity.
local Yield = class(function (self, item, size, amount)
  self.item = item
  self.size = size
  self.initial = amount
  self.remaining = amount
end)

--------------------------------------------------------------------------------

function Entity:addYield (item, size, amount)
  assert(not self.yield)
  if amount == nil then
    local scale = math.max(0, self.getScale and self:getScale() or 1)
    local cfg = (Config and Config.game) or {}
    local minimum = math.max(0, cfg.depositMin or 120)
    local maximum = math.max(minimum, cfg.depositMax or 5000)
    local reference = math.max(1, cfg.depositSizeReference or 900)
    -- Deterministic per-rock randomness: no shared RNG draws, so streaming
    -- cannot reshuffle the world. Larger rocks bias toward the rich end.
    local seed = math.floor(tonumber(self.seed) or self.id or 0) % 2147483647
    local h = seed * 48271 + (math.floor(scale * 1000) % 1000003) * 12345
    local unit = (h % 1000000) / 999999
    local sizeFactor = 0.25 + 0.75 * math.min(1,
      math.log(1 + scale) / math.log(1 + reference))
    amount = minimum + math.floor((maximum - minimum + 1) * unit * sizeFactor)
  end
  amount = math.max(0, math.floor(amount))
  self.yield = Yield(item, size, amount)
  self:register(Event.Debug, Entity.debugYield)
  Registry.register(self)
end

function Entity:debugYield (state)
  local ctx = state.context
  ctx:text('Yield')
  ctx:indent()
  ctx:text('Item: %s', self.yield.item:getName())
  ctx:text('Size: %.2f', self.yield.size)
  ctx:text('Remaining: %d / %d', self.yield.remaining, self.yield.initial)
  ctx:undent()
end

function Entity:getYield ()
  assert(self.yield)
  return self.yield
end

function Entity:hasYield ()
  return self.yield ~= nil and self.yield.remaining > 0
end

function Entity:getYieldRemaining ()
  return self.yield and self.yield.remaining or 0
end

function Entity:getYieldInitial ()
  return self.yield and self.yield.initial or 0
end

function Entity:setDepositKey (key, fingerprint)
  self.depositKey = key
  self.depositFingerprint = fingerprint
  if not self.yield then return end
  local root = self.getRoot and self:getRoot()
  if not root or not root.depositState or not root.depositFingerprints then return end
  if fingerprint == nil or root.depositFingerprints[key] ~= fingerprint then return end
  local remaining = root.depositState[key]
  if remaining ~= nil then
    self.yield.remaining = math.max(0, math.min(self.yield.initial, math.floor(remaining)))
  end
end

function Entity:consumeYield (count)
  if not self.yield then return 0 end
  count = math.max(0, math.floor(count))
  local taken = math.min(count, self.yield.remaining)
  self.yield.remaining = self.yield.remaining - taken
  local root = self.getRoot and self:getRoot()
  if root and root.depositState and self.depositKey then
    root.depositState[self.depositKey] = self.yield.remaining
    if self.depositFingerprint then
      root.depositFingerprints = root.depositFingerprints or {}
      root.depositFingerprints[self.depositKey] = self.depositFingerprint
    end
  end
  return taken
end

--------------------------------------------------------------------------------
