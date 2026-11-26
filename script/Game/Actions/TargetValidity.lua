-- Shared action-target validity. Actions run before the system's removal
-- sweep, so a target can still look "alive" after its rigid body was detached
-- during docking, sector transit, or streaming removal.
local TargetValidity = {}

function TargetValidity.Usable (entity)
  if not entity or entity.deleted then return false end
  if entity.isAlive and not entity:isAlive() then return false end
  if not entity.body then return false end
  if entity.getParent and not entity:getParent() then return false end
  return true
end

return TargetValidity
