local Entities = requireAll('Game.Entities')
local DebugControl = require('Game.Controls.DebugControl')

local LTheory = Application()
local rng = RNG.FromTime()

function LTheory:generate ()
  if Config.gen.seedGlobal then
    self.seed = Config.gen.seedGlobal
  else
    self.seed = rng:get64()
  end
  printf('Seed: %s', self.seed)
  printf('Resolution: %dx%d', self.resX, self.resY)

  if self.system then self.system:delete() end
  self.system = Entities.System(self.seed)

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

    local ships = {}
    for i = 1, 0 do
      local escort = self.system:spawnShip()
      local offset = rng:getSphere():scale(100)
      escort:setPos(ship:getPos() + offset)
      escort:setOwner(self.player)
      escort:pushAction(Actions.Escort(ship, offset))
      insert(ships, escort)
    end
  end

  for i = 1, 1 do
    local station = self.system:spawnStation()
  end

  for i = 1, 0 do
    self.system:spawnAI(100)
  end

  -- Spawn 60 procedural asteroids 3,000 units directly in front of player
  if ship then
    local fieldPos = ship:getPos() + Vec3f(0, 0, -3000)
    self.system:spawnAsteroidField(60, 1000, fieldPos)
  end

  for i = 1, 1 do
    local planet = self.system:spawnPlanet()
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

  -- Visibility cloud: debug ring of 30 rocks placed around player
  local Entity = require('Game.Entity')
  local Material = require('Game.Material')
  if ship then
    local rockPos = {}
    for i = 1, 30 do
      local ang = (i / 30) * 6.2831853
      local r   = rng:getUniform() * 12000 + 8000
      local off = Vec3f(
        math.cos(ang) * r,
        (rng:getSphere():scale(800)).y,
        math.sin(ang) * r)
      insert(rockPos, ship:getPos() + off)

      local seed = rng:get31()
      local lod  = Gen.Asteroid(seed)
      local a    = Entity()
      local big  = lod:get(0):scale(250, 250, 250)
      a:addRigidBody(true, lod:get(0))
      a.body:setCollidable(false)
      a:setPos(ship:getPos() + off)
      a:addVisibleMesh(big, Material.Rock())

      self.system:addChild(a)
    end

    printf('[dbg] visibility-cloud rocks=%d', #rockPos)
  end
end

function LTheory:onInit ()
  self.player = Entities.Player()

  do
    local w = self.window:getSize()
    local fontScale = Math.Clamp(w.y / 900, 0.7, 1.8)
    local normalSize = max(12, Math.Round(Config.ui.font.normalSize * fontScale))
    local titleSize  = max(10, Math.Round(Config.ui.font.titleSize  * fontScale))
    Config.ui.font.normal     = Cache.Font('Share', normalSize)
    Config.ui.font.normalSize = normalSize
    Config.ui.font.title      = Cache.Font('Exo2Bold', titleSize)
    Config.ui.font.titleSize  = titleSize
  end

  self:generate()

  DebugControl.ltheory = self
  self.gameView = GUI.GameView(self.player)
  self.gameView.ltheory = self
  self.canvas = UI.Canvas()
  self.canvas
    :add(self.gameView
      :add(Controls.MasterControl(self.gameView, self.player)))

  self.debugWindow = GUI.DebugWindow(self)
  self.gameView.debugWindow = self.debugWindow
  self.gameView:add(self.debugWindow:setStretch(0, 1), Config.debug.window)
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
