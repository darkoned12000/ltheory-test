-- Shared lifecycle helpers for dock services that hold live credit state.

local DockService = {}

function DockService.DelayRetry (ship)
  if not ship then return end
  local root = ship.getRoot and ship:getRoot()
  local now = root and root.getTime and root:getTime() or 0
  local delay = Config and Config.game and tonumber(Config.game.npcServiceRetryDelay) or 120
  ship.npcNextServiceAt = now + math.max(1, delay)
end

function DockService.ClearRetry (ship)
  if ship then ship.npcNextServiceAt = nil end
end

function DockService.SettlePaidRepairs (ship)
  if not ship or type(ship.actions) ~= 'table' then return false end
  local settled = false
  for i = #ship.actions, 1, -1 do
    local action = ship.actions[i]
    local name = action.getName and action:getName() or ''
    if action.isDockService and action.paid and name:sub(1, 6) == 'Repair' then
      action:cancel(ship, 'save')
      table.remove(ship.actions, i)
      settled = true
    end
  end
  return settled
end

return DockService
