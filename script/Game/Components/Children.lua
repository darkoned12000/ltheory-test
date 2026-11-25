-- TODO : Rename to 'Container' / 'Contained'

local Entity = require('Game.Entity')
local EconomyRegistry = require('Game.EconomyRegistry')

local function broadcast (self, event)
  for i = #self.children, 1, -1 do
    if self.children[i].parent == self then
      self.children[i]:send(event)
    else
      self.children[i] = self.children[#self.children]
      self.children[#self.children] = nil
    end
  end
end

function Entity:addChild (child)
  assert(self.children)
  if child.parent == self then return end
  if child.parent then child.parent:removeChild(child, true) end
  insert(self.children, child)
  child.parent = self
  self:send(Event.ChildAdded(child))
  child:send(Event.AddedToParent(self))
end

function Entity:addChildren ()
  assert(not self.children)
  self.children = {}
  self:register(Event.Broadcast, broadcast)
end

-- Deliver an event to descendants without also unwrapping it back onto self.
-- Entity:send(Event.Broadcast(event)) intentionally does both, which is useful
-- for tree propagation but caused System policy/economy handlers to tick twice.
function Entity:broadcast (event)
  local handlers = self.handlers[Event.Broadcast]
  if not handlers then return end
  local wrapped = Event.Broadcast(event)
  for i = 1, #handlers do handlers[i](self, wrapped) end
end

function Entity:getChildren ()
  assert(self.children)
  return self.children
end

function Entity:getParent ()
  return self.parent
end

function Entity:getRoot ()
  local root = self
  while root:getParent() do
    root = root:getParent()
  end
  return root
end

function Entity:hasChildren ()
  return self.children ~= nil
end

function Entity:iterChildren ()
  assert(self.children)
  return ipairs(self.children)
end

function Entity:removeChild (child, keepOwner)
  assert(self.children)
  assert(child.parent == self)
  -- Actual world removal ends the owner/asset relationship. Reparenting for
  -- docking passes keepOwner=true and must preserve it.
  if not keepOwner and child.getOwner then
    local owner = child:getOwner()
    if owner then owner:removeAsset(child) end
  end
  -- Drop the child from the economy registry BEFORE the parent link is gone --
  -- the registry is keyed by the old parent. Without this a removed station
  -- would stay in the economy's point-of-interest list forever.
  EconomyRegistry.unregister(child)
  child.parent = nil
  self:send(Event.ChildRemoved(child))
  child:send(Event.RemovedFromParent(self))
end
