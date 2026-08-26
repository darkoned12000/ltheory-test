local Entities = requireAll('Game.Entities')
local DebugControl = require('Game.Controls.DebugControl')

local LTheory = Application()
local rng = RNG.FromTime()

function LTheory:generate ()
  self.seed = rng:get64()
  if true then
    -- self.seed = 7035008865122330386ULL
    -- self.seed = 15054808765102574876ULL
    -- self.seed = 1777258448479734603ULL
    -- self.seed = 5023726954312599969ULL
  end
  printf('Seed: %s', self.seed)

  if self.system then self.system:delete() end
  self.system = Entities.System(self.seed)

  -- GPU particle pool (compute-simulated sprites). One per system; other
  -- entities just call Entities.GPUParticles.explode(...) / .emit{...}.
  self.system:addChild(Entities.GPUParticles())

  local ship
  do -- Player Ship
    ship = self.system:spawnShip()
    ship:setPos(Config.gen.origin)
    ship:setFriction(0)
    ship:setSleepThreshold(0, 0)
    ship:setOwner(self.player)
    self.system:addChild(ship)
    self.player:setControlling(ship)

    -- player escorts
    local ships = {}
     for i = 1, 0 do
       local escort = self.system:spawnShip()
       local offset = rng:getSphere():scale(100)
       escort:setPos(ship:getPos() + offset)
       escort:setOwner(self.player)
       escort:pushAction(Actions.Escort(ship, offset))
       insert(ships, escort)
     end

    for i = 1, #ships do
      local j = rng:getInt(1, #ships)
      if i ~= j then
        -- ships[i]:pushAction(Actions.Attack(ships[j]))
      end
    end
  end

  for i = 1, 1 do
    local station = self.system:spawnStation()
  end

  for i = 1, 0 do
    self.system:spawnAI(100)
  end

  for i = 1, 1 do
    self.system:spawnAsteroidField(500, 10)
  end

  for i = 1, 1 do
    local planet = self.system:spawnPlanet()
    -- Keep the player's ship clear of the surface so it starts with room to see
    -- and fly around instead of spawning at/at the (huge) planet. If one exists
    -- inside the target viewing distance, push it outward along the line between
    -- them; bearing is preserved so it stays in view.
    local controlling = self.player:getControlling()
    if controlling then
      local center   = planet:getPos()
      local sp       = controlling:getPos()
      local dx, dy, dz = sp.x - center.x, sp.y - center.y, sp.z - center.z
      local dist     = math.sqrt(dx * dx + dy * dy + dz * dz)
      if dist < Config.gen.planetViewDist then
        local nx, ny, nz = dx / dist, dy / dist, dz / dist
        controlling:setPos(Vec3f(
          center.x + nx * Config.gen.planetViewDist,
          center.y + ny * Config.gen.planetViewDist,
          center.z + nz * Config.gen.planetViewDist))
      end
    end
  end
end

function LTheory:onInit ()
  self.player = Entities.Player()
  self:generate()

  DebugControl.ltheory = self
  self.gameView = GUI.GameView(self.player)
  self.canvas = UI.Canvas()
  self.canvas
    :add(self.gameView
      :add(Controls.MasterControl(self.gameView, self.player)))
end

function LTheory:onInput ()
  self.canvas:input()
end

function LTheory:onUpdate (dt)
  self.player:getRoot():update(dt)
  self.canvas:update(dt)
end

function LTheory:onDraw ()
  self.canvas:draw(self.resX, self.resY)
end

return LTheory
