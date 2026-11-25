-- Demo composition: put two capitals where their real hulls are visible, then
-- hold them briefly so instant-job movement cannot erase the placement before
-- the player sees it. Normal AI resumes when the Wait action completes.

local Actions = requireAll('Game.Actions')

local Placement = {}

local layout = {
  { forward = 8,  right = -2.3, up = 0.8 },
  { forward = 10, right = 3.0,  up = -0.6 },
  { forward = 12, right = 2.8,  up = 1.2 },
  { forward = 14, right = -3.5, up = -1.0 },
}
local rolePriority = { capital = 0, industrial = 1, freighter = 2, fighter = 3 }

function Placement.place (brainOrBrains, ship)
  if not brainOrBrains or not ship then return end
  local brains = brainOrBrains.getAssets and { brainOrBrains } or brainOrBrains
  local assets = {}
  for _, brain in ipairs(brains) do
    for _, asset in ipairs(brain:getAssets()) do assets[#assets + 1] = asset end
  end
  table.sort(assets, function (a, b)
    local pa = rolePriority[a.npcRole] or 4
    local pb = rolePriority[b.npcRole] or 4
    return pa < pb
  end)
  local forward = ship:getForward()
  local right = ship:getRight()
  local up = ship:getUp()
  local origin = ship:getPos()
  for i = 1, math.min(#layout, #assets) do
    local asset = assets[i]
    local radius = asset.getRadius and asset:getRadius() or 10
    local slot = layout[i]
    local distance = math.max(800, slot.forward * radius)
    local offset = forward:scale(distance)
               + right:scale(slot.right * radius)
               + up:scale(slot.up * radius)
    asset:setPos(origin + offset)
    asset:pushAction(Actions.Wait(5))
  end
end

return Placement
