-- Real-entity adapter for Holo selected-node info, previews, and actions.
-- Virtual/mock nodes keep their provider-owned descriptors unchanged.

local TargetInfo = require('Game.TargetInfo')
local Targeting = require('Game.Targeting')

local Provider = {}
local RANGE_REASON = 'You are not within range to perform action.'
local DOCK_RANGE = 500

local function controlling (player)
  if not player then return nil end
  if player.getControlling then return player:getControlling() end
  return player
end

local function description (e)
  if e.description then return e.description end
  if e.desc then return e.desc end
  if e.isAsteroid then return 'A resource-bearing asteroid with a deterministic composition and finite deposit.' end
  if e.isPlanet then return 'A planetary body with orbital, surface, and resource points of interest.' end
  if e.isWormhole then return 'A jumpgate connecting this sector to another destination.' end
  if e.hasDockable and e:hasDockable() then return 'A station providing docking, markets, services, and industrial production.' end
  if e.hasSockets and e:hasSockets() then return 'A spacecraft with installed systems, hardpoints, cargo, and technology metadata.' end
  return 'A selectable object in the live sector graph.'
end

local function rangeAction (e, ship, range, extra)
  local gap = Targeting.SurfaceGap(e, ship)
  if gap == nil then return false, 'Target has no physical body.' end
  if gap > range then return false, RANGE_REASON end
  if extra then return extra() end
  return true
end

function Provider.Info (node, player)
  local e = node and node.entity
  if not e then return node and node.info end
  local ship = controlling(player)
  local stats = {}
  local function add (label, getValue, value)
    stats[#stats + 1] = { label = label, getValue = getValue, value = value }
  end
  local gap = Targeting.SurfaceGap(e, ship)
  if gap then
    add('Distance', function ()
      local live = Targeting.SurfaceGap(e, ship)
      return live and string.format('%.0f u', live) or '--'
    end)
  end
  if e.health and e.healthMax then
    add('Health', function () return string.format('%.0f / %.0f', e.health, e.healthMax) end)
  end
  local shield = TargetInfo.Shield(e)
  if shield then add('Shield', nil, shield) end
  if e.isAsteroid then
    add('Composition', nil, TargetInfo.Composition(e))
    local deposit = TargetInfo.Deposit(e)
    if deposit then add('Remaining', nil, deposit) end
  end
  if e.isWormhole then add('Destination', nil, TargetInfo.Destination(e)) end
  add('Class', nil, node.cat or (e.isAsteroid and 'asteroid' or 'object'))
  return {
    title = TargetInfo.Name(e),
    subtitle = node.sublabel or node.cat or 'Live Object',
    description = description(e),
    preview = { kind = 'mesh', entity = e },
    stats = stats,
  }
end

function Provider.Actions (node, player)
  local e = node and node.entity
  if not e then return node and node.actions or {} end
  local ship = controlling(player)
  local actions = {}
  local function add (id, label, enabled, reason, submenu)
    actions[#actions + 1] = { id = id, label = label, enabled = enabled,
      reason = reason, submenu = submenu }
  end

  if node.children and #node.children > 0 then add('drill', 'Inspect') end
  if Targeting.IsTargetable(e) then
    add('goto', 'Goto', true)
    local isStation = (e.hasDockable and e:hasDockable())
      or (e.hasMarket and e:hasMarket()) or (e.hasFactory and e:hasFactory())
    if not isStation then add('target', 'Target', true) end
  end
  if e.isAsteroid or (e.hasYield and e:hasYield()) then
    local scanRange = (Config.game and Config.game.scanRange) or 2000
    local mineRange = (Config.game and Config.game.miningRange) or 250
    local scanOk, scanWhy = rangeAction(e, ship, scanRange)
    local mineOk, mineWhy = rangeAction(e, ship, mineRange)
    add('scan', 'Scan', scanOk, scanWhy)
    add('mine', 'Mine', mineOk, mineWhy)
  end
  if e.hasDockable and e:hasDockable() then
    local dockOk, dockWhy = rangeAction(e, ship, DOCK_RANGE, function ()
      if ship and ship.getParent and ship:getParent() == e then return false, 'Already docked.' end
      return true
    end)
    add('dock', 'Dock', dockOk, dockWhy)
  end
  if e.hasMarket and e:hasMarket() then
    local tradeOk, tradeWhy = rangeAction(e, ship, DOCK_RANGE, function ()
      if ship and ship.getParent and ship:getParent() == e then return true end
      return false, 'Dock to trade.'
    end)
    local submenu
    local market = e.getMarket and e:getMarket()
    if market and market.quotes then
      local menu = { title = 'Commodity Exchange', actions = {} }
      local shown = 0
      for _, quote in ipairs(market:quotes()) do
        if shown >= 2 then break end
        local item = quote.item
        local name
        if item and item.getName then name = item:getName() else name = tostring(item) end
        menu.actions[#menu.actions + 1] = { id = 'buy:' .. name, label = 'Buy ' .. name,
          item = quote.item, enabled = tradeOk, reason = tradeWhy }
        menu.actions[#menu.actions + 1] = { id = 'sell:' .. name, label = 'Sell ' .. name,
          item = quote.item, enabled = tradeOk, reason = tradeWhy }
        shown = shown + 1
      end
      if #menu.actions > 0 then submenu = menu end
    end
    add('trade', 'Trade', tradeOk, tradeWhy, submenu)
  end
  if e.hasFactory and e:hasFactory() then
    add('factory', 'Factory', true, nil, { title = 'Production', actions = {
      { id = 'view_inputs', label = 'View Inputs', enabled = true },
      { id = 'view_outputs', label = 'View Outputs', enabled = true },
      { id = 'start_production', label = 'Start Production', enabled = false,
        reason = 'Factory production is automatic.' },
      { id = 'stop_production', label = 'Stop Production', enabled = false,
        reason = 'Factory production is automatic.' },
    } })
  end
  if e.hasSockets and e:hasSockets() and e ~= ship then
    add('hail', 'Hail', false, 'Communications are not available yet.')
  end
  return actions
end

function Provider.Enrich (node, player)
  if not node or not node.entity then return node end
  node.info = Provider.Info(node, player)
  node.actions = Provider.Actions(node, player)
  return node
end

return Provider
