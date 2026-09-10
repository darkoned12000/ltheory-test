local Entities = requireAll('Game.Entities')
local DebugControl = require('Game.Controls.DebugControl')

local LTheory = Application()
local rng = RNG.FromTime()

function LTheory:generate ()
  if Config.gen.seedGlobal then
    -- Reproducible world for A/B testing (ao_off / ao_on pairs). Grab the
    -- "Seed: <n>" line from a boot log and paste it here as <n>ULL.
    self.seed = Config.gen.seedGlobal
  else
    self.seed = rng:get64()
  end
  printf('Seed: %s', self.seed)
  printf('Resolution: %dx%d', self.resX, self.resY)

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

  -- Visibility cloud: the planet is so large it hides asteroids spawned near it,
  -- and spawnAsteroidField places rocks ~100k+ units out (tiny/pebbles at that
  -- range), so spawn a dense ring of ship-comparable rocks around the player for
  -- testing shadows. We build each rock from a visibly-scaled copy of its high-detail
  -- level and use `addVisibleMesh` (always draws the finest LOD level, unlike the
  -- distance-gated addVisibleLodMesh) so they render regardless of how far they are.
  local Entity = require('Game.Entity')
  local Material = require('Game.Material')
  if ship then
    local rockPos = {}
    for i = 1, 30 do
      local ang = (i / 30) * 6.2831853
      -- Spread over a wide arc so some rocks stay in view even near the planet edge.
      local r   = rng:getUniform() * 12000 + 8000
      local off = Vec3f(
        math.cos(ang) * r,
        (rng:getSphere():scale(800)).y,
        math.sin(ang) * r)
      insert(rockPos, ship:getPos() + off)

      local seed = rng:get31()
      -- Baked-scale (12x) the highest-detail level so each rock is ship-sized;
      -- draw it unconditionally via addVisibleMesh (same pattern ships use). The
      -- fine SDF geometry makes every rock look distinct.
      local lod  = Gen.Asteroid(seed)          -- multi-level SDF LodMesh (cached per seed)
      local a    = Entity()
      local big  = lod:get(0):scale(250, 250, 250)   -- highest-detail level as a standalone Mesh (250x ~ 20x ship-sized)
      a:addRigidBody(true, lod:get(0))         -- body required so the Rock material renders
      a.body:setCollidable(false)              -- collision OFF: no momentum transfer to ship
      a:setPos(ship:getPos() + off)            -- place the rock around the ship (was never applied -> spawned at origin)
      a:addVisibleMesh(big, Material.Rock())

      self.system:addChild(a)
    end

    -- NOTE : if this reads 0 the block above broke (e.g. an API change); the rocks
    -- are otherwise invisible only if addVisibleMesh isn't drawing them at distance.
    printf('[dbg] visibility-cloud rocks=%d', #rockPos)
  end
end


function LTheory:onInit ()
  self.player = Entities.Player()

  -- Scale UI fonts to the actual window height (the compositor may force a
  -- different size than Config.window, e.g. fullscreen). The engine draws UI
  -- in window-pixel space, so a fixed pixel font would be disproportionately
  -- large/small on other monitors; derive it from the real size instead.
  -- Baseline sizes live in Config.ui.font (tuned at a 900px-tall window).
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
  self.gameView.ltheory = self -- window access (vsync), mirrors DebugWindow
  self.canvas = UI.Canvas()
  self.canvas
    :add(self.gameView
      :add(Controls.MasterControl(self.gameView, self.player)))

  -- Debug window: mounted directly on GameView so it is always reachable via F9,
  -- independent of which PlayerControl (Ship / Debug / Dock) is active. Created
  -- after self.canvas exists (DebugWindow:createUISection reads ltheory.canvas).
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
