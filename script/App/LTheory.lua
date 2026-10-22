local Entities = requireAll('Game.Entities')
local Seed = require('Game.Seed')
local DebugControl = require('Game.Controls.DebugControl')
local Sector = require('Game.Region')
local SectorGraph = require('Game.SectorGraph')

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

  -- The UNIVERSE: the sectors, and the jumpgates between them.
  --
  -- The sectors are laid out deterministically from the world seed, so the
  -- same galaxy always has the same sectors in the same places with the same
  -- names -- which is what makes the player's map of it a map of something
  -- real rather than of a fresh random world every time.
  self.sectors = SectorGraph.layout(self.seed, Config.game.sectorRadius or 60000)
  self.sectorIndex = 0
  self:buildGates()

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
    -- Kept so it can be REPLACED when the player warps to another sector.
    self.sectorPlanet = planet
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
  -- The audio engine comes up with the GameView, so the gates' hum can only
  -- start now.
  self.audioReady = true
  self:startGateSounds()


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
  -- PHX_GALAXY=1 opens the map on the GALAXY LEVEL (the sectors and the
  -- gates between them), for a headless capture.
  if os.getenv('PHX_GALAXY') then self.nodeGraph.galaxyLevel = true end
  self.gameView.nodeGraph = self.nodeGraph
  -- The map starts hidden (F10 opens it). PHX_MAP=1 opens it at boot, which
  -- is what a headless capture wants: the map is a widget, so it is only in
  -- the UI layer, and a capture of the scene alone cannot see it.
  self.gameView:add(self.nodeGraph:setStretch(1, 1), os.getenv('PHX_MAP') ~= nil)
end

function LTheory:onInput ()
  self.canvas:input()
end

--[[---------------------------------------------------------------------------
  buildGates -- (re)create the jumpgates of the current sector.

  A fully-connected mesh, so every other sector has a gate here. The gates
  sit on the sector's rim, spread evenly, so they read as a set of distinct
  places rather than a pile on one side.

  The gates are rebuilt on every sector change: the gates of the sector you
  leave are the gates of the sector you arrive in, and they are different
  gates.
-----------------------------------------------------------------------------]]
-- Whether the warp lanes exist at all. Read live, so the debug window's
-- switch works without a restart.
--
-- (A file-local, not a method: the class table and the app instance share
-- their fields here, so a method with this name and an instance field with
-- this name are the same slot.)
local function railsEnabled ()
  if Settings.exists('universe.rails.enable') then
    return Settings.get('universe.rails.enable') and true or false
  end
  return false
end

function LTheory:buildGates ()
  if not self.sectors then return end

  -- Clear the old ones.
  if self.gates then
    for _, g in ipairs(self.gates) do
      if g:getParent() then g:getParent():removeChild(g) end
      g:delete()
    end
  end
  self.gates = {}

  local here = self.sectors[self.sectorIndex + 1]
  if not here then return end

  -- The sector's own regions -- the lanes are built from them. (The lanes
  -- themselves are built by buildRails, which the debug window's switch can
  -- call on its own.)
  local regions, sectorName = Sector.Region.place(here.seed, here.center, here.radius)

  -- The sector's regions, for the ENVIRONMENTAL FIELD (13f): the asteroid
  -- field, the nebula and the lightning all read the same function of a
  -- position, so they cannot disagree about what kind of place they are in.
  if self.system then self.system:setSectorRegions(regions, here.seed) end

  -- A PLACE in every region.
  --
  -- This is the answer to "what does a warp lane go to?" A lane that ends
  -- in empty space is a lane nobody would use, and the old game's answer
  -- was that its lanes ran between its POINTS OF INTEREST -- a planet, a
  -- field, a station -- not between areas of nothing. So every region gets
  -- one, and the lanes run to them.
  --
  -- What the place IS depends on the region's KIND (which is what the
  -- archetype's kind field says): a belt gets a mining RIG, a yard gets a
  -- YARD with a factory on it, a veil gets a RELAY (a beacon in the gas).
  -- Every one of them has a market, so the ore you mine has somewhere to
  -- go.
  self.sectorPlaces = {}
  for _, r in ipairs(regions) do
    local place = self:buildPlace(r, sectorName)
    if place then self.sectorPlaces[#self.sectorPlaces + 1] = place end
  end

  -- The HUB: the sector's own centre, and the one place every lane starts
  -- from. It is where the player spawns, so the roads all lead back to
  -- where they started, and it is the middle of the star the lanes make.
  --
  -- (This is the old game's own shape: UniverseGen/System.lts linked every
  -- point of interest to the first one, and ran the rail from a's surface
  -- to b's surface.)
  local hub = { x = here.center.x, y = here.center.y, z = here.center.z,
                name = sectorName }
  self.sectorHub = hub

  for _, gate in ipairs(SectorGraph.gates(self.sectors, self.sectorIndex)) do
    -- The gate is named after the sector it LEADS TO, not the one it stands
    -- in -- the old Limit Theory did exactly this:
    --
    --   a->SetName(o2->GetName() + " Wormhole");
    --   b->SetName(o1->GetName() + " Wormhole");
    --
    -- so a gate is named for its far end. That is also what makes the name
    -- useful on the map: "The Tyle Sprawl Wormhole" tells you where you
    -- will be, which the sector you are standing in obviously does not.
    local wormhole = Entities.Wormhole({
      name          = gate.otherName .. ' Wormhole',
      homeSector    = self.sectorIndex,
      partnerSector = gate.partner,
      partnerName   = gate.otherName,
      partnerPos    = Vec3f(gate.other.x, gate.other.y, gate.other.z),
      pos           = Vec3f(gate.self.x, gate.self.y, gate.self.z),
    })
    -- The arrival handler: the sector has changed, so everything that
    -- depends on the sector has to be rebuilt.
    wormhole.onArrive = function (w, e) self:enterSector(w:getPartnerSector(), e) end
    self.system:addChild(wormhole)
    self.gates[#self.gates + 1] = wormhole
    -- The sound waits for the audio engine, which is initialised by the
    -- GameView's constructor -- and generate() runs BEFORE that. Loading a
    -- sound before Audio.Init() crashes the engine, so the hum is started
    -- later (see startGateSounds).
    if self.audioReady then wormhole:startSound() end
  end

  -- The RAILS: the sector's own highways, between its regions.
  --
  -- Josh's words, from the May 2013 development video: "if you want to get
  -- from point A to point B within a system, you use these lanes, warp
  -- lanes, to get around quickly -- assuming you can hit them."
  --
  -- So a rail is a ROAD, not a door. It is a physical tube of energy, and
  -- flying into it CAPTURES the ship and carries it to the far end. That is
  -- what the old WarpNode controller did, with a rail force, a lane-locking
  -- force and a torque (see script/Game/Entities/Rail.lua).
  --
  -- The first version of this made each lane a pair of teleport markers --
  -- wrong twice over: they were wormhole-shaped (so the map was full of
  -- portals), and they teleported instead of carrying you.
  self:buildRails()
end

--[[---------------------------------------------------------------------------
  buildRails -- (re)create the sector's warp lanes.

  The lanes are the intra-sector roads: you fly into one and it carries you
  across the sector.

  They are OFF by default. A road network only earns its keep if there is
  somewhere to go, and the sector's regions are currently areas of space with
  nothing in them -- so a lane ends in empty space, and a lane that ends in
  empty space is a lane nobody would use. The debug window's "Universe >
  Warp Rails" switch builds them when you want to look at them, and takes
  them away again when you do not.
---------------------------------------------------------------------------]]
function LTheory:buildRails ()
  -- Clear the old ones.
  if self.rails then
    for _, l in ipairs(self.rails) do
      if l:getParent() then l:getParent():removeChild(l) end
      l:delete()
    end
  end
  self.rails = {}
  -- The rail connections, for the map: the old game's map drew the region
  -- structure as a graph of nodes joined by lines, and the lines were the
  -- connections. Ours are the rails.
  self.sectorRails = {}

  local on = railsEnabled()
  self.railsEnabled = on
  if not on then return end

  local here = self.sectors and self.sectors[self.sectorIndex + 1]
  if not here then return end
  local regions = select(1, Sector.Region.place(here.seed, here.center, here.radius))
  local hub = self.sectorHub
  if not hub then
    hub = { x = here.center.x, y = here.center.y, z = here.center.z }
    self.sectorHub = hub
  end

  for _, lane in ipairs(Sector.Region.lanes(regions, hub)) do
    -- Each pair is listed ONCE, so the rail is built from both ends here.
    --
    -- (Looking for a reciprocal entry could never work: Region.lanes dedupes
    -- each pair to a single record, so there is no second record to find.)
    local rail = Entities.Rail({
      from = lane.aPos, to = lane.bPos,
      fromName = lane.aName, toName = lane.bName,
      name = 'Rail to ' .. lane.bName,
      -- The frames start clear of the hub, so six lanes do not stack their
      -- first frames on the same spot.
      clearStart = Entities.Rail.HUB_CLEARANCE,
    })
    rail.material = Material.Rail()
    -- The frame's bracket: a solid pale structure, drawn in the forward
    -- pass with a self-shaded material.
    rail.bracketMaterial = Material.Bracket()
    self.system:addChild(rail)
    self.rails[#self.rails + 1] = rail
    self.sectorRails[#self.sectorRails + 1] = {
      a = lane.aName, b = lane.bName,
      aPos = lane.aPos, bPos = lane.bPos,
    }
  end
end


-- Start the hum on every gate. Called once the audio engine is up.
function LTheory:startGateSounds ()
  for _, g in ipairs(self.gates or {}) do g:startSound() end
end

--[[---------------------------------------------------------------------------
  buildPlace -- the PLACE in a region: the thing a warp lane goes to.

  A station, scaled down to an outpost, named after its region, with a
  market (so the ore has somewhere to go) and -- in a yard -- a factory
  (so the place makes things as well as selling them).

  The name is the region's name and a word for what the place is, because
  the lane's destination is announced by name on the HUD and on the map:
  "Nearest lane to Hogatuge Rig" is a place; "Nearest lane to Hogatuge" was
  a direction.
---------------------------------------------------------------------------]]
function LTheory:buildPlace (region, sectorName)
  local kind = region.kind or 'yard'
  local suffix = kind == 'belt' and 'Rig' or kind == 'veil' and 'Relay' or 'Yard'
  local name = format('%s %s', region.name, suffix)

  local place = Entities.Station(Seed.rng('ltheory.place', region.index):managed():get31())
  place:setName(name)
  -- An outpost, not a station: the sector's one real station is the big
  -- one near the planet.
  place:setScale(45)
  place:setPos(Vec3f(region.center.x, region.center.y, region.center.z))

  -- The market.
  --
  -- It BUYS the raw commodities a belt yields -- that demand is what makes a
  -- belt worth the trip -- and it SELLS what its own factory makes, for
  -- more than it paid. So the player's loop is: mine the isotopes here,
  -- sell them there, and buy the energy cells the reactors make.
  local Item = require('Game.Item')
  place:addMarket()
  -- The place's working capital: it has to be able to PAY for what it
  -- buys, or the market's transfer fails on the buyer's side.
  place:addCredits(100000)
  for _, item in ipairs(Item.T1) do
    place.market:addBuy(place, item, 200, Item.Price[item] or 10)
  end

  -- A yard makes things, and sells them.
  if kind == 'yard' then
    local Production = require('Game.Production')
    place:addFactory()
    local prod = Production.All()[1]
    place:addProduction(prod)
    -- iterOutputs() is ipairs over the outputs, so it yields the INDEX
    -- first; the list itself is the public field.
    for _, out in ipairs(prod.outputs) do
      place.market:addSell(place, out.item, 200, Item.Price[out.item] or 20)
    end
  end

  self.system:addChild(place)
  return place
end

--[[---------------------------------------------------------------------------
  regenerateSectorContent -- a new sector has to LOOK new.

  Without this, warping changed the NAME and nothing else: the same planet,
  the same sky, the same rocks. Which is worse than not having the feature at
  all -- the player is told they have travelled, and the world says
  otherwise. (This was exactly the complaint that prompted it: "the sector I
  am brought to looks the same as the last".)

  What changes:

    * the PLANET -- a new one, of a new type, at a new size and a new
      distance, drawn from the SECTOR's seed. It is the thing you look at.
    * the SKY -- a new nebula and a new starfield, from the sector's seed.
      The nebula is most of the screen, so this is most of the difference.
    * the ROCKS -- already different, and not because of this: the asteroid
      field is a pure function of (world seed, chunk coordinate), and the
      sectors are hundreds of thousands of units apart, so a new sector is
      new chunks.

  The nebula costs a hitch (the skybox is generated on the CPU and the
  irradiance map is convolved). That is the right place for one: a jump
  should feel like a jump.
-----------------------------------------------------------------------------]]
function LTheory:regenerateSectorContent (index)
  local sector = self.sectors and self.sectors[index + 1]
  if not sector then return end
  local centre = Vec3f(sector.center.x, sector.center.y, sector.center.z)

  -- The planet.
  if self.sectorPlanet then
    self.sectorPlanet:delete()
    self.sectorPlanet = nil
  end
  local rng = RNG.Create(sector.seed):managed()
  self.sectorPlanet = self.system:spawnPlanet(rng, centre)

  -- The sky.
  local nebula = Entities.Nebula(sector.seed, self.system.starDir)
  nebula:forceLoad()
  self.system.nebula = nebula
end

--[[---------------------------------------------------------------------------
  enterSector -- the player has arrived in another sector.

  The sector's identity changes: its name, its regions, and its gates. The
  REGIONS are what the HUD reads and what the map draws, so they are the
  part that has to be regenerated -- and they are regenerated from the
  DESTINATION sector's seed, so the sector you arrive in is the sector that
  was always there, seen for the first time.
-----------------------------------------------------------------------------]]
function LTheory:enterSector (index, ship)
  if index == nil or index == self.sectorIndex then return end
  self.sectorIndex = index
  self:regenerateSectorContent(index)
  self:buildGates()

  -- The ship is now somewhere else; its sector's state is recomputed from
  -- its new position.
  if ship then
    local p = ship:getPos()
    local sector = self.sectors[index + 1]
    self.sectorState = Sector.state(self.seed, p.x, p.y, p.z, index,
                                    sector and sector.center)
  end
end

function LTheory:onUpdate (dt)
  -- TEMP: headless settings snapshot.
  if os.getenv('PHX_DUMP_SETTINGS') and not self.__dumped then
    self.__dumped = true
    require('Game.GUI.DebugWindow').DumpSettings()
  end
  -- getRoot() is nil with no controlling ship, and a DESTROYED ship detaches
  -- from the tree (no `update`). Guard so a bad spawn can't kill the process.
  local root = self.player and self.player:getRoot()
  if root and root.update then root:update(dt) end
  -- Atmosphere bubble: push the ship back out of planet atmospheres before it
  -- can grind the surface (see System:handleAtmosphere).
  local ship = self.player and self.player:getControlling()
  -- The RAILS carry the ship.
  --
  -- "You flew into it and you started going very fast, and as long as you
  -- kept the ship in the lane you travelled until you reached the end."
  --
  -- So the rail applies its forces to any ship that is in it: a push down
  -- the lane, a force pulling it back onto the line, and -- when it has
  -- arrived at the far end -- a nudge that takes it off the rail.
  --
  -- This runs BEFORE the atmosphere push, because the two disagree: the
  -- atmosphere shell pushes the ship out of the planet, and the rail wants
  -- it to stay on the line. A ship on a rail is not in an atmosphere.
  -- The warp lanes' on/off, live: the debug window's switch builds them and
  -- takes them away again, without a restart.
  if self.sectors and (railsEnabled() ~= self.railsEnabled) then
    self:buildRails()
  end

  if ship and self.rails then
    self.railRiding = nil
    for _, rail in ipairs(self.rails) do
      if rail:ride(ship, dt) then
        self.railRiding = rail
        break
      end
    end
  end

  if self.system and ship and not self.railRiding then
    self.system:handleAtmosphere(ship)
  end
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
    local sector = self.sectors and self.sectors[self.sectorIndex + 1]
    self.sectorState = Sector.state(self.seed, p.x, p.y, p.z,
                                    self.sectorIndex or 0,
                                    sector and sector.center)
    -- The galaxy the sector belongs to, and which one it is -- the map's
    -- GALAXY level needs both: the sectors to draw, and which of them the
    -- player is standing in.
    if self.sectorState then
      self.sectorState.sectors = self.sectors
      self.sectorState.sectorIndex = self.sectorIndex
      -- The rail connections, for the map.
      self.sectorState.rails = self.sectorRails
      -- The hub the lanes all start from.
      self.sectorState.hub = self.sectorHub
      -- The nearest LANE, and where it goes.
      --
      -- A rail is the intra-sector transport, and it is HARD TO FIND: the
      -- lanes run between region centres, which can be tens of thousands of
      -- units apart, and nothing about them announces itself from a
      -- distance. So the panel says where the nearest one is, the way it
      -- says where the nearest jumpgate is.
      local nearestLane, nearestLaneD
      for _, rail in ipairs(self.rails or {}) do
        -- The distance to the nearest WARP NODE, not to the middle of the
        -- rail: the node is the thing you fly into, and the middle of a
        -- thirty-thousand-unit rail can be a long way from either end.
        local t = rail:project(p.x, p.y, p.z)
        local nt = rail:nearestFrame(t)
        if nt then
          local a = rail.from
          local nx = a.x + rail.dir.x * nt
          local ny = a.y + rail.dir.y * nt
          local nz = a.z + rail.dir.z * nt
          local dx, dy, dz = nx - p.x, ny - p.y, nz - p.z
          local d2 = dx * dx + dy * dy + dz * dz
          if not nearestLaneD or d2 < nearestLaneD then
            nearestLane, nearestLaneD = rail, d2
          end
        end
      end
      if nearestLane then
        self.sectorState.nearestLane = {
          name = nearestLane.toName,
          dist = math.sqrt(nearestLaneD),
          node = nearestLane,
        }
      end

      -- The nearest gate, and where it goes.
      --
      -- The player should never have to hunt for their way out, and never
      -- have to open the map to find out where it leads. The panel carries
      -- the answer, always.
      local nearest, nearestD
      for _, g in ipairs(self.gates or {}) do
        local gp = g:getPos()
        local dx, dz = gp.x - p.x, gp.z - p.z
        local d2 = dx * dx + dz * dz
        if not nearestD or d2 < nearestD then
          nearest, nearestD = g, d2
        end
      end
      if nearest then
        local gd = math.sqrt(nearestD)
        self.sectorState.nearestGate = {
          name = nearest:getPartnerName(),
          kind = nearest.kind or 'sector',
          dist = gd,
          node = nearest,
        }
        -- The hum: ONE sound, for the NEAREST gate, with the volume worked
        -- out from the distance. It is not a 3D sound, because the engine's
        -- inverse attenuation (rolloff 2) makes a sound at the far end of a
        -- sector inaudible -- and the hum is exactly the cue that says
        -- "there is a portal over there".
        if nearest.sound then
          nearest.sound:setVolume(Entities.Wormhole.droneVolume(gd))
        end
        for _, g in ipairs(self.gates or {}) do
          if g ~= nearest and g.sound then g.sound:setVolume(0) end
        end
      end
    end
  else
    self.sectorState = nil
  end
  self.canvas:update(dt)
end

function LTheory:onDraw ()
  self.canvas:draw(self.resX, self.resY)
end

return LTheory
