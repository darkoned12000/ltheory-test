-- Readable NPC decision/status output. Logging never advances simulation time;
-- ETA is always reported against the ship's normal thrust top speed.

local NpcTravel = require('Game.NpcTravel')
local NpcLog = {}

local function enabled ()
  local env = os.getenv('PHX_NPC_LOG')
  if env == '1' then return true end
  if env == '0' then return false end
  return Config and Config.game and Config.game.npcLog == true
end

local function actorId (asset)
  local owner = asset.getOwner and asset:getOwner()
  local id = owner and owner.getNpcId and owner:getNpcId()
    or asset.stableId or tostring(asset.id or 'unknown')
  local name = asset.getName and asset:getName()
  if name and name ~= id then return tostring(id) .. '/' .. tostring(name) end
  return tostring(id)
end

function NpcLog.Event (asset, message)
  if not enabled() then return end
  printf('[NPC] %s %s', tostring(actorId(asset)), tostring(message))
end

function NpcLog.Status (asset, root, now)
  if not enabled() then return end
  local action = asset.getCurrentAction and asset:getCurrentAction()
  local target = action and action.target
  local pos = asset.getPos and asset:getPos()
  local velocity = asset.getVelocity and asset:getVelocity()
  local speed = velocity and velocity:length() or 0
  local top = asset.getTopSpeed and asset:getTopSpeed() or 0
  local distance, eta
  if target then
    distance = NpcTravel.Distance(asset, target)
    if distance and top > 0 then eta = distance / top end
  end
  local hull = asset.getHealthNormalized and asset:getHealthNormalized() or 1
  local credits = asset.getCredits and asset:getCredits() or 0
  local owner = asset.getOwner and asset:getOwner()
  if owner and owner.getItemCount then
    local Item = require('Game.Item')
    credits = owner:getItemCount(Item.Credit) or credits
  end
  printf('[NPC] %s sector=%s t=%.1f action=%s target=%s pos=(%.0f,%.0f,%.0f) speed=%.1f top=%.1f dist=%s eta=%s hull=%.2f credits=%.0f',
    tostring(actorId(asset)), tostring(root and root.sectorIndex or '?'), now or 0,
    action and action:getName() or 'idle', target and target:getName() or '-',
    pos and pos.x or 0, pos and pos.y or 0, pos and pos.z or 0,
    speed, top, distance and string.format('%.0f', distance) or '-',
    eta and string.format('%.1fs', eta) or '-', hull, credits)
end

return NpcLog
