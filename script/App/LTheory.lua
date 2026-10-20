local Entities = requireAll('Game.Entities')
local Seed = require('Game.Seed')
local DebugControl = require('Game.Controls.DebugControl')
local Sector = require('Game.Region')

local LTheory = Application()

function LTheory:generate ()
  -- Resolve the world seed FIRST and publish it: everything created below --
  -- and later, by entities -- derives its randomness from it, so this boot's
  -- "Seed:" line reproduces the whole world, not just the sector (Game.Seed).
  if Config.gen.seedGlobal then
    self.seed = Config.gen.seedGlobal
  else
    self.seed = RNG.FromTime():managed():get64()
  end
  Seed.setWorld(self.seed)
  printf('Seed: %s', self.seed)
  printf('Resolution: %dx%d', self.resX, self.resY)

  local rng = Seed.rng('ltheory.generate'):managed()

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
      -- Stand-off is RELATIVE to the planet's own radius, the same
      -- scale-invariant principle the ring mesh uses: 1.75x the radius puts the
      -- disc about 70 degrees across, filling most of an 80 degree FOV. It was a
      -- FIXED 250000, which was tuned back when planets had radius ~200000 and
      -- left a radius-4000 planet a 1.7-degree speck.
      --
      -- This is applied UNCONDITIONALLY. It used to be `if dist < clear`, which
      -- only pushed the ship OUT when it happened to spawn too close -- and since
      -- the planet's own placement distance is
      -- max(kSystemScale*(1+expDraw), radius*planetClearance) with
      -- kSystemScale = 10000, the ship normally spawns FARTHER out than the
      -- stand-off and was left alone. The consequence was that a planet's
      -- apparent size was an accident of the random draw rather than a setting:
      -- measured 11.6 degrees across on a normal seed versus 54 degrees when the
      -- ship did get pushed out, for the same ship and the same camera.
      --
      -- Always placing makes the apparent size depend only on planetStandoff, which
      -- is what makes that knob meaningful at all. It also means the ship is
      -- never inside the planet, which is the W8 guarantee: `clear` is a multiple
      -- of the radius, so it cannot be swallowed regardless of the seed.
      --
      -- planetViewDist survives as a FLOOR, so a very small body still gets some
      -- stand-off. It is NOT a visual knob: below radius ~2860 the floor wins and
      -- the planet renders small again (a radius-588 body subtends 13.5 degrees).
      -- That is deliberate -- it stops a tiny moon filling the screen.
      --
      -- planetStandoff is a SPAWN-TIME value and is deliberately NOT a debug-panel
      -- slider: the placement has already happened by the time the panel is drawn,
      -- so a panel knob for it would be a slider that visibly does nothing.
      local clear = math.max(planet:getScale() * (Config.gen.planetStandoff or 1.75),
                             Config.gen.planetViewDist or 0)
      -- Bearing from the planet's centre out to the ship is preserved, so the ship
      -- keeps its side of the system and the approach direction does not change.
      local nx, ny, nz = 0, 0, 1
      if dist > 1e-3 then nx, ny, nz = dx / dist, dy / dist, dz / dist end
      controlling:setPos(Vec3f(
        center.x + nx * clear,
        center.y + ny * clear,
        center.z + nz * clear))
    end
  end

  -- Visibility cloud: debug ring of 30 rocks placed around player
  local Entity = require('Game.Entity')
  local Material = require('Game.Material')
  -- The old 30-rock debug ring. It is SUPPRESSED whenever the streamed field is
  -- on: the ring sits at 8000..20000 units in a flat plane, which is inside the
  -- streamed field's own reach, so leaving both on double-loads that band with
  -- ~2000 non-collidable decorative rocks that look identical to the real ones.
  -- That makes it impossible to tell what you are looking at. Its own toggle is
  -- the streamed field's; this ring stays only as a fallback when it is off.
  -- Checked against Config.gpu FIRST as well as the panel: generate() runs
  -- BEFORE Renderer seeds the panel from Config.gpu, so reading only
  -- Settings here sees the pre-seed default (false) and builds the ring even
  -- with the field switched on -- which is exactly what happened, giving 30
  -- decorative rocks inside the real field's own band.
  local fieldOn = (Config.gpu and Config.gpu.asteroidFieldEnabled)
                  or (Settings.exists('gen.asteroidField.enable')
                      and Settings.get('gen.asteroidField.enable'))
                  or (Config.gen.asteroidField and Config.gen.asteroidField.enable)
  if ship and not fieldOn then
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

  -- Node-graph overlay (§13): hidden until F10. Phase 2 seeds live system
  -- data (replaces the old demo scaffold); focusEntity marks the player's
  -- ship as the white node.
  self.nodeGraph = UI.NodeGraph.Create(self.system, {
    focusEntity = self.player and self.player:getControlling(),
    -- The sector state, shared with the HUD's panel.
    getSectorState = function () return self.sectorState end,
  })
  self.gameView.nodeGraph = self.nodeGraph
  -- The map starts hidden (F10 opens it). PHX_MAP=1 opens it at boot, which
  -- is what a headless capture wants: the map is a widget, so it is only in
  -- the UI layer, and a capture of the scene alone cannot see it.
  self.gameView:add(self.nodeGraph:setStretch(1, 1), os.getenv('PHX_MAP') ~= nil)
end

function LTheory:onInput ()
  self.canvas:input()
end

function LTheory:onUpdate (dt)
  -- getRoot() is nil with no controlling ship, and a DESTROYED ship detaches
  -- from the tree (no `update`). Guard so a bad spawn can't kill the process.
  local root = self.player and self.player:getRoot()
  if root and root.update then root:update(dt) end
  -- Atmosphere bubble: push the ship back out of planet atmospheres before it
  -- can grind the surface (see System:handleAtmosphere).
  local ship = self.player and self.player:getControlling()
  if self.system and ship then self.system:handleAtmosphere(ship) end
  -- Asteroid field streaming, driven from the same resolved ship for the same
  -- reason: System has no way to tell the player's ship from a thousand
  -- identical rocks it is itself streaming in.
  if self.system then self.system:streamAsteroidField(ship) end
  -- The sector state: what this place is called, which region you are in,
  -- and which way the next boundary lies.
  --
  -- Computed ONCE, here, and shared -- the HUD's readout and the map's
  -- overlay both read it. Two places computing it independently is how a
  -- panel ends up naming one region while the map highlights another.
  if ship and self.seed then
    local p = ship:getPos()
    self.sectorState = Sector.state(self.seed, p.x, p.y, p.z)
  else
    self.sectorState = nil
  end
  self.canvas:update(dt)
end

function LTheory:onDraw ()
  self.canvas:draw(self.resX, self.resY)
end

return LTheory
