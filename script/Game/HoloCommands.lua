-- App-level command router for Holo node actions. UI code emits intent only;
-- target validation, range policy, and action-stack changes live here.

local Targeting = require('Game.Targeting')
local TargetValidity = require('Game.Actions.TargetValidity')

local Commands = {}
Commands.__index = Commands
local RANGE_REASON = 'You are not within range to perform action.'
local DOCK_RANGE = 500

function Commands.Create (app)
  return setmetatable({ app = app }, Commands)
end

function Commands:ship ()
  local player = self.app and self.app.player
  if not player then return nil end
  return player.getControlling and player:getControlling() or player
end

function Commands:target (node)
  if type(node) ~= 'table' then return nil end
  return node.entity or (node.body and node) or nil
end

function Commands:range (target, range)
  local ship = self:ship()
  local gap = Targeting.SurfaceGap(target, ship)
  if gap == nil then return false, 'Target has no physical body.' end
  if gap > range then return false, RANGE_REASON end
  return true
end

function Commands:execute (action, node)
  if not action or not action.id then return false, 'Invalid action.' end
  local target = self:target(node)
  local ship = self:ship()
  if not ship then return false, 'No controlling ship.' end
  local id = action.id

  if id == 'goto' then
    if not target or not TargetValidity.Usable(target) then return false, 'Target is not usable.' end
    local MoveTo = require('Game.Actions.MoveTo')
    ship:pushAction(MoveTo(target, action.range or 100))
    if ship.setTarget then ship:setTarget(target) end
    return true, 'Course set.'
  elseif id == 'target' then
    if not target or not Targeting.IsTargetable(target) then return false, 'Target is not targetable.' end
    ship:setTarget(target)
    return true, 'Target locked.'
  elseif id == 'scan' then
    if not target then return false, 'No target.' end
    local range = (Config.game and Config.game.scanRange) or 2000
    local ok, why = self:range(target, range)
    if not ok then return false, why end
    if ship.scanTarget then
      local scanned, status = ship:scanTarget(target)
      return scanned, scanned and 'Scan started.' or tostring(status)
    end
    ship:pushAction(require('Game.Actions.Scan')(target))
    return true, 'Scan started.'
  elseif id == 'mine' then
    if not target or not target.hasYield or not target:hasYield() then return false, 'No minable target.' end
    local range = (Config.game and Config.game.miningRange) or 250
    local ok, why = self:range(target, range)
    if not ok then return false, why end
    if ship.mineTarget then
      local mined, status = ship:mineTarget(target)
      return mined, mined and 'Mining started.' or tostring(status)
    end
    ship:pushAction(require('Game.Actions.MineAt')(target, range))
    ship:pushAction(require('Game.Actions.Stop')())
    return true, 'Mining started.'
  elseif id == 'dock' then
    if not target or not target.hasDockable or not target:hasDockable() then
      return false, 'Target cannot dock ships.'
    end
    if not TargetValidity.Usable(target) then return false, 'Target is not usable.' end
    local ok, why = self:range(target, DOCK_RANGE)
    if not ok then return false, why end
    if ship.getParent and ship:getParent() == target then return false, 'Already docked.' end
    ship:pushAction(require('Game.Actions.DockAt')(target))
    return true, 'Docking approach started.'
  elseif id == 'travel' then
    if not target or not target.isWormhole then return false, 'Target is not a jumpgate.' end
    ship:pushAction(require('Game.Actions.TravelTo')(target))
    return true, 'Jumpgate approach started.'
  elseif id == 'trade' or id:match('^buy:') or id:match('^sell:') then
    if not target or not target.hasMarket or not target:hasMarket() then return false, 'Target has no market.' end
    local ok, why = self:range(target, DOCK_RANGE)
    if not ok then return false, why end
    if not ship.getParent or ship:getParent() ~= target then return false, 'Dock to trade.' end
    local market = target:getMarket()
    if not market or not market:isOpen() then return false, 'The market is closed.' end
    if action.item then
      if id:match('^buy:') then
        local count, total = market:buy(ship, action.item, action.count or 1)
        return count > 0, string.format('Bought %d units for %d credits.', count, total or 0)
      else
        local count, total = market:sell(ship, action.item, action.count or 1)
        return count > 0, string.format('Sold %d units for %d credits.', count, total or 0)
      end
    end
    local screen = self.app and self.app.dockScreen
    if screen then
      if screen.refresh then screen:refresh() end
      if screen.open then screen:open() end
    end
    return true, 'Market opened.'
  elseif id == 'view_inputs' or id == 'view_outputs' then
    if not target or not target.hasFactory or not target:hasFactory() then return false, 'Target has no factory.' end
    local names = {}
    for _, prod in ipairs(target:getFactory().prods or {}) do
      local iter = id == 'view_inputs' and prod.type.iterInputs or prod.type.iterOutputs
      for entry in iter(prod.type) do names[#names + 1] = tostring(entry.item) end
    end
    return true, string.format('%s: %s', id == 'view_inputs' and 'Inputs' or 'Outputs',
      #names > 0 and table.concat(names, ', ') or 'none')
  elseif id == 'hail' then
    return false, 'Communications are not available yet.'
  end
  return false, 'Action unavailable.'
end

return Commands
