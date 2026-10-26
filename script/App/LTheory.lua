local Entities = requireAll('Game.Entities')
local Seed = require('Game.Seed')
local SaveGame = require('Game.SaveGame')
local Tex2D = require('ffi.Tex2D')
local File = require('ffi.File')
-- The engine's F-key table is a MODULE, not a global: Application.lua
-- requires it at the top the same way. Reading it as a global threw
-- GlobalRestrict the frame after CUSTOM GAME closed every screen (the
-- quicksave's first live-play frame).
local Bindings = require('phx.util.ApplicationBindings')
local Toast = require('Game.GUI.Toast')
-- THE RECIPES ARE LOAD-TIME SCOPE (see Game/Entities/System.lua's note):
-- a require inside the app-sandbox returns a fresh module with nothing
-- on it; buildPlace's body runs in the sandbox, so it binds through
-- this upvalue instead.
require('Game.Content')
local Productions = require('Game.Production')
local DebugControl = require('Game.Controls.DebugControl')
local Sector = require('Game.Region')
local SectorGraph = require('Game.SectorGraph')

local LTheory = Application()

-- A seed is a 64-bit number, and it is entered in hex.
--
-- It cannot be parsed with `tonumber(hex, 16)`: that returns a DOUBLE, and
-- a double holds 53 bits, so the low eleven bits of the seed would be
-- rounding noise and the same seed would not always make the same world.
-- It cannot be parsed with `ffi.cast('uint64_t', '0x...')` either -- the
-- FFI's constant parser mangles a 64-bit hex literal. So it is built from
-- two halves, each of which fits in a double exactly.
local function seedFromHex (hex)
  hex = hex:gsub('%s', ''):upper()
  if #hex < 1 or #hex > 16 then return nil end
  if hex:match('[^0-9A-F]') then return nil end
  local hi = #hex > 8 and tonumber(hex:sub(1, #hex - 8), 16) or 0
  local lo = tonumber(hex:sub(-8), 16)
  return ffi.cast('uint64_t', hi) * 0x100000000ULL + lo
end

-- The seed as hex, for showing it.
local function seedToHex (seed)
  if seed == nil then return '' end
  return string.format('%016X', seed)
end

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

  -- THE AI POPULATION: the economy's participants. Each spawnAI is one
  -- capital whose ships pick jobs by PAYOUT (Actions/Think.lua): mining
  -- the belts into the stations' standing bids, riding the flows. The
  -- count is opt-in until play-tested (the asteroid field's rule):
  -- Config.game.aiShips, 0 = no AI.
  if (Config.game.aiShips or 0) > 0 then
    self.system:spawnAI(Config.game.aiShips)
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

  -- THE VERSION IS THE COMMIT COUNT.
  --
  -- The build writes it (tools/gen_version.py); the file is generated, so
  -- a checkout that has not been built falls back to a placeholder rather
  -- than failing to start.
  local okVer, Version = pcall(require, 'Generated.Version')
  self.version = (okVer and Version.version) or 'v0.dev'
  self.commitCount = (okVer and Version.count) or 0

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
  -- Boot and NEW GAME are the same path: the world generates, then the
  -- sector content (planet, belts, markets) regenerates into it -- so the
  -- SAVE page's location line, the HUD and the map all have the same
  -- settled state from frame one.
  self:regenerateSectorContent(0)

  -- THE SYSTEM CURSOR NEVER SHOWS.
  --
  -- The canvas draws the game's own pointer instead (UI.Canvas's
  -- `showCursor`): the old game's `Icon Pointer`, over whatever the mouse
  -- is about to touch. Hiding the hardware cursor once here -- and never
  -- letting anything re-show it -- is what makes the two agree; the HUD
  -- used to hide it every frame, and the debug window and the screens each
  -- flipped it open, which is exactly where the cursor used to get lost.
  Input.SetMouseVisible(false)

  DebugControl.ltheory = self
  self.gameView = GUI.GameView(self.player)
  self.gameView.ltheory = self
  -- The audio engine comes up with the GameView, so the gates' hum can only
  -- start now.
  self.audioReady = true
  self:startGateSounds()


  self.canvas = UI.Canvas()
  -- The custom cursor is drawn by the canvas, over whatever the mouse is
  -- about to touch (see UI/Canvas.lua for why the hardware one is hidden).
  -- WHAT it is over is decided every frame in onUpdate: only UI gets a
  -- pointer, playing does not.
  self.masterControl = Controls.MasterControl(self.gameView, self.player)
  self.canvas
    :add(self.gameView
      :add(self.masterControl))

  self.debugWindow = GUI.DebugWindow(self)
  self.gameView.debugWindow = self.debugWindow
  self.gameView:add(self.debugWindow:setStretch(0, 1), Config.debug.window)

  -- The screens: full-screen UI layers over the world (see
  -- script/Game/GUI/Screen.lua). The main menu is the first one, and it
  -- is the front door -- the old game opened on its splash too.
  --
  -- It is NOT opened in a capture: a capture wants the scene, and the
  -- menu would sit over every captured frame.
  self.screens = {}
  if not os.getenv('PHX_FIXED_VIEW') then
    -- The main menu, and the three popups it opens. They are all screens
    -- in their own right -- separate pages that take the input -- and all
    -- of them are added to the CANVAS, not to the game view: the canvas
    -- draws its children in the order they were added, so a screen added
    -- after the game view draws over it.
    self.menu = GUI.MainMenu.Create({
      version      = self.version,
      onClose      = function () end,
      onNewGame    = function () self:newGame() end,
      onCustomGame = function () self:openPopup(self.customGamePopup) end,
      onLoad       = function () self:openPopup(self.loadPopup) end,
      onSave       = function () self:openPopup(self.savePopup) end,
      onInfo       = function () self:openPopup(self.infoPopup) end,
      onHelp       = function () self:openPopup(self.helpPopup) end,
      onSettings   = function () self:openPopup(self.settingsScreen) end,
      onExit       = function () self:quit() end,
    })
    self.canvas:add(self.menu)
    self.screens[#self.screens + 1] = self.menu

    -- INFO: what the tech is. The engine and the systems -- the player
    -- plays the game, and this popup is for the parts of it that are
    -- built rather than flown.
    self.infoPopup = GUI.MenuPanelScreen.Create({
      title   = 'THE ENGINE',
      onClose = function () self:openMenu() end,
    })
    self.infoPopup:addLine('LIMIT THEORY REBOOT -- how this is built',
      Color(0.62, 0.72, 0.86, 1.0))
    self.infoPopup:addLine('')
    self.infoPopup:addLine('CORE', Color(0.45, 0.80, 1.0, 1.0))
    self.infoPopup:addLine('  C++17 engine core with LuaJIT 2.1 running the game logic')
    self.infoPopup:addLine('  OpenGL 4.6 core: HDR deferred pipeline, tonemapping, GTAO,')
    self.infoPopup:addLine('                 sun and point-light shadows, bloom')
    self.infoPopup:addLine('  Bullet physics; miniaudio sound; SDL3 windowing and input')
    self.infoPopup:addLine('  everything procedural: the meshes, the worlds and the')
    self.infoPopup:addLine('                 textures are all generated at runtime')
    self.infoPopup:addLine('')
    self.infoPopup:addLine('WORLD', Color(0.45, 0.80, 1.0, 1.0))
    self.infoPopup:addLine('  planets, nebulae and asteroid fields, from one 64-bit seed')
    self.infoPopup:addLine('  the same seed always makes the same galaxy')
    self.infoPopup:addLine('  sectors, regions and places: jumpgates between the sectors,')
    self.infoPopup:addLine('                 warp lanes leading to the places')
    self.infoPopup:addLine('  one shared environment field that the gas, the rocks, the')
    self.infoPopup:addLine('                 dust, the lightning and the light shafts all read')
    self.infoPopup:addLine('  one map: galaxy -> sector -> region')
    self.infoPopup:addLine('')
    self.infoPopup:addLine('ECONOMY', Color(0.45, 0.80, 1.0, 1.0))
    self.infoPopup:addLine('  mining, a live market with prices, and haul runs between rigs')
    self.infoPopup:addLine('  no loading screens: the galaxy streams around you as you fly')
    self.infoPopup:addCloseButton()
    self.canvas:add(self.infoPopup, false)
    self.screens[#self.screens + 1] = self.infoPopup

    -- HELP: how to play.
    self.helpPopup = GUI.MenuPanelScreen.Create({
      title   = 'HOW TO PLAY',
      onClose = function () self:openMenu() end,
    })
    self.helpPopup:addLine('W A S D     thrust and steer', Color(0.62, 0.72, 0.86, 1.0))
    self.helpPopup:addLine('SHIFT       boost')
    self.helpPopup:addLine('SPACE+MOUSE aim')
    self.helpPopup:addLine('F           dock at a station')
    self.helpPopup:addLine('R / T       sell / buy at the market')
    self.helpPopup:addLine('T / G       lock / clear a target')
    self.helpPopup:addLine('F10         the map')
    self.helpPopup:addLine('F9          the settings panel')
    self.helpPopup:addLine('ESC         this menu')
    self.helpPopup:addLine('')
    self.helpPopup:addLine('Fly out through a jumpgate, or ride a warp lane to the nearest place.')
    self.helpPopup:addLine('Mine the belts, sell at the rig, and buy what you need. Every rock')
    self.helpPopup:addLine('you break is ore you can sell, and every haul pays for the next tank.')
    self.helpPopup:addCloseButton()
    self.canvas:add(self.helpPopup, false)
    self.screens[#self.screens + 1] = self.helpPopup

    -- CUSTOM GAME: a seed you type, so a world can be shared.
    self.customGamePopup = GUI.MenuPanelScreen.Create({
      title   = 'CUSTOM GAME',
      onClose = function () self:openMenu() end,
    })
    self.customGamePopup:addLine('Type a seed in hex -- sixteen digits, and the same seed',
      Color(0.62, 0.72, 0.86, 1.0))
    self.customGamePopup:addLine('always makes the same galaxy, the same sectors and the')
    self.customGamePopup:addLine('same places.')
    self.seedField = UI.TextInput.Create(16, seedToHex(self.seed))
    self.seedField.onSubmit = function (text)
      self:newGame(text)
    end
    -- The field goes in a centring row, like the buttons under it: added
    -- bare, a Grid row's child sits at the LEFT edge of the column while
    -- the START/CLOSE rows centre themselves, and the field reads as
    -- off-centre whatever the window width.
    local fieldRow = UI.Grid():setCols(1):setAlign(0.5, 0)
    fieldRow:setStretch(0, 0)
    fieldRow:add(self.seedField)
    self.customGamePopup.content:add(fieldRow)
    local startRow = UI.Grid():setCols(1):setAlign(0.5, 0)
    startRow:setStretch(0, 0)
    startRow:add(UI.MenuButton.Create('START', function ()
      self:newGame(self.seedField:getText())
    end))
    self.customGamePopup.content:add(startRow)
    self.customGamePopup:addCloseButton()
    self.canvas:add(self.customGamePopup, false)
    self.screens[#self.screens + 1] = self.customGamePopup

    --[[ SAVE and LOAD pages.

        The rows live in a SWAPPED child grid of the page's content: a
        fresh list is built every time the page opens (via the framework's
        deferred `add`/`remove`, which keep the widget bookkeeping honest)
        and every time a save lands. The SAVE page's CLOSE rides INSIDE
        its swapped grid, so it stays the last thing on that page; the
        LOAD page's CLOSE is a footer under its scroll view, so it never
        needs scrolling to. ]]
    self.savePopup = GUI.MenuPanelScreen.Create({
      title   = 'SAVE GAME',
      onClose = function () self:openMenu() end,
    })
    self.savePopup:addLine('A save records the world seed and your ship:',
      Color(0.62, 0.72, 0.86, 1.0))
    self.savePopup:addLine('the position, heading, hull, credits and cargo.')
    self.savePopup:addLine('The universe itself regenerates from the seed,')
    self.savePopup:addLine('so the same save always makes the same galaxy.')
    self.savePopup:addLine('')
    local saveLoc = UI.Label():setText('')
    saveLoc:setFontColor(Color(0.62, 0.72, 0.86, 1.0))
    local saveStatus = UI.Label():setText('')
    saveStatus:setFontColor(Color(0.62, 0.72, 0.86, 1.0))

    local function refreshSaveList ()
      if self.saveGrid then
        self.savePopup.content:remove(self.saveGrid)
      end
      -- Where you are RIGHT NOW (Sector / Region / credits), read fresh
      -- on every open so the page always describes the live state.
      saveLoc:setText(self:currentLocationText())
      self.saveGrid = UI.Grid():setCols(1):setAlign(0.5, 0)
      self.saveGrid:setStretch(0, 0)
      self.saveGrid:add(saveLoc)
      -- How full the list is -- the LOAD page shows every slot, but the
      -- save side is where the player needs to know the cap is near.
      self.saveGrid:add(UI.Label()
        :setText(string.format('Slots used: %d / %d', SaveGame.Count(), SaveGame.MAX_SLOTS))
        :setFontColor(Color(0.62, 0.72, 0.86, 1.0)))
      self.saveGrid:add(UI.MenuButton.Create('SAVE NEW SLOT', function ()
        local name, why = self:saveGameNow()
        if name then
          saveStatus:setText(string.format("Saved as '%s'.", name))
        else
          saveStatus:setText(string.format('Save failed: %s.', tostring(why or '?')))
        end
        refreshSaveList()
      end))
      self.saveGrid:add(saveStatus)
      self.saveGrid:add(UI.MenuButton.Create('CLOSE', function () self.savePopup:close() end))
      self.savePopup.content:add(self.saveGrid)
    end

    self.canvas:add(self.savePopup, false)
    self.screens[#self.screens + 1] = self.savePopup
    -- The location line is READ on open, not at boot.
    self.savePopup.onOpenUI = refreshSaveList
    refreshSaveList()

    -- LOAD: one row per save slot, read fresh every time the page opens.
    -- Corrupt/foreign files are skipped by SaveGame.ListSlots, so the page
    -- only ever offers what it can actually load.
    self.loadPopup = GUI.MenuPanelScreen.Create({
      title   = 'LOAD GAME',
      onClose = function () self:openMenu() end,
    })
    self.loadPopup:addLine('Loading regenerates the world from the saved seed,',
      Color(0.62, 0.72, 0.86, 1.0))
    self.loadPopup:addLine('then puts your ship back where it was saved.')
    self.loadPopup:addLine('Saves live in ./saves/, one JSON file per slot.')
    self.loadPopup:addLine('')

    self.loadGrid = nil
    self.loadTexs = {}
    self.loadClose = nil
    local function refreshLoadList ()
      if self.loadScroll then
        self.loadPopup.content:remove(self.loadScroll)
      end
      if self.loadClose then
        self.loadPopup.content:remove(self.loadClose)
      end
      -- The row textures (Tex2D_Load decodes a fresh one per refresh) are
      -- ours alone; free the previous list or a session of page-opens
      -- would pile VRAM up. Removing the old grid first (the framework
      -- marks it immediately) so the freed textures are never drawn.
      for i = 1, #self.loadTexs do self.loadTexs[i]:free() end
      self.loadTexs = {}
      self.loadGrid = UI.Grid():setCols(1):setAlign(0, 0)
      self.loadGrid:setStretch(0, 0)
      local slots = SaveGame.ListSlots()
      if #slots == 0 then
        self.loadGrid:add(UI.Label()
          :setText('No saves yet. SAVE GAME first.')
          :setFontColor(Color(0.62, 0.72, 0.86, 1.0)))
      else
        -- Each slot is a row of two: its thumbnail (what the game looked
        -- like when it was saved; old slots without one just omit it) and
        -- the facts, LOAD and DEL buttons under them. The cap is small
        -- (10), so a DELETE is the way out when the list is full.
        for _, info in ipairs(slots) do
          local row = UI.Grid():setCols(2):setStretch(0, 0)
          row:setPadCellX(16)
          if info.thumb then
            local tex = Tex2D.Load(info.thumb)
            self.loadTexs[#self.loadTexs + 1] = tex
            row:add(UI.Image.Create(tex))
          else
            row:add(UI.Label():setText(''))
          end
          local col = UI.Grid():setCols(1):setStretch(0, 0)
          col:add(UI.Label():setText(string.format('%s   ·   %s',
            info.slotName, info.dateCreated)))
          if info.systemName ~= '' then
            col:add(UI.Label():setText(string.format('Sector: %s · Region: %s',
              info.systemName, info.regionName ~= '' and info.regionName or 'Deep space')))
          end
          col:add(UI.Label():setText(string.format('Credits: %d   ·   seed %s',
            info.credits, info.seedHex)))
          local btns = UI.Grid():setCols(2):setStretch(0, 0)
          btns:setPadCellX(8)
          btns:add(UI.MenuButton.Create('LOAD', function ()
            self:loadGame(info.slotName)
          end))
          btns:add(UI.MenuButton.Create('DEL', function ()
            if SaveGame.Delete(info.slotName) then
              printf("[SAVE] deleted '%s'", info.slotName)
            end
            refreshLoadList()
          end))
          col:add(btns)
          row:add(col)
          self.loadGrid:add(row)
        end
      end
      -- The page scrolls when the slots outgrow it; the scroll view is the
      -- swapped child (a fixed-height window onto the rebuilt grid). CLOSE
      -- stays OUTSIDE the scroll (a footer), so it never needs scrolling to.
      self.loadScroll = UI.ScrollView()
        :setPadUniform(2)
        :setScrollable(false, true)
        :setMinSize(0, 500)
        :setStretch(0, 0)
      self.loadScroll:add(self.loadGrid)
      self.loadScroll.vScrollTarget = 0
      self.loadScroll.vScrollValue = 0
      self.loadPopup.content:add(self.loadScroll)
      -- The CLOSE footer is SWAPPED WITH THE LIST, not just appended: an
      -- untracked footer appended on every open stacked a new CLOSE button
      -- per page-open and pushed the rows down out of scroll reach.
      self.loadClose = UI.MenuButton.Create('CLOSE',
        function () self.loadPopup:close() end)
      self.loadPopup.content:add(self.loadClose)
    end

    self.canvas:add(self.loadPopup, false)
    self.screens[#self.screens + 1] = self.loadPopup
    -- The list is READ on open, not at boot: the slots page always shows
    -- what is on disk right now.
    self.loadPopup.onOpenUI = refreshLoadList
    refreshLoadList()

    -- SETTINGS: window mode, resolution and the audio gains. Its gets and
    -- sets are live -- the window is resized in place and the gains are
    -- heard immediately -- and every change is written to the settings
    -- file (script/Config.Settings.lua) that Main.lua applies at boot.
    self.settingsScreen = GUI.SettingsScreen.Create({
      title    = 'SETTINGS',
      onClose  = function () self:openMenu() end,
      window   = self.window,
      gameView = self.gameView,
    })
    self.canvas:add(self.settingsScreen, false)
    self.screens[#self.screens + 1] = self.settingsScreen

    -- DOCK: the market window as a real page. It opens and closes with
    -- the docked state (see the watcher in onUpdate); it is in the
    -- screens list so anyScreenOpen pauses the world and shows the
    -- pointer while it is up.
    self.dockScreen = GUI.DockScreen.Create({ player = self.player })
    self.canvas:add(self.dockScreen, false)
    self.screens[#self.screens + 1] = self.dockScreen

    -- FLUSH THE ADDS, THEN OPEN.
    --
    -- Screen:open needs the canvas state (for the modal focus), and it is
    -- found by walking parent links -- which do not exist until the canvas
    -- has flushed its deferred add queue. The first `canvas:update` does
    -- that; doing it here (dt 0: no fade drift) means the boot menu takes
    -- the modal input from frame one, so ESC closes it from the start.
    self.canvas:update(0)
    self.menu:open()
    -- PHX_POPUP=<field name> (e.g. PHX_POPUP=infoPopup) opens that screen
    -- at boot instead of the menu, for off-hand verification of a screen
    -- with a headless capture. Set nothing: this line does nothing.
    local popupName = os.getenv('PHX_POPUP')
    if popupName and self[popupName] then self:openPopup(self[popupName]) end
    self.screenWasOpen = true
  end

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

  -- QUICK SAVE (F6) / QUICK LOAD (F7) -- the old game's keys.
  --
  -- The quicksave is ONE rolling slot ('quicksave'): one keypress, same
  -- slot every time, no list to manage -- the menu's SAVE/LOAD pages are
  -- for the named, deliberate saves. The thumbnail is captured at the
  -- PRESS, so it banks the live frame exactly as the player sees it --
  -- no menu over it, which is the capture context the menu path cannot
  -- have. Quick load runs the same regenerate-and-restore path a LOAD
  -- row does; the screens-close + camera re-seat make it safe from live
  -- play.
  if not self:anyScreenOpen() then
    if Input.GetPressed(Bindings.QuickSave) then
      SaveGame.CaptureWorkingShot(self.gameView and self.gameView.renderer)
      -- ACCUMULATING quicksaves, like the old game's F6: every press lands
      -- in its own timestamped slot, so flying between saves keeps all of
      -- them (a rolling single slot made "multiple saves" impossible from
      -- the keyboard and read exactly like the save system being broken).
      local name, why = self:saveGameNow(
        SaveGame.UnusedSlotName('quicksave-' .. os.date('%Y%m%d-%H%M%S')))
      if name then
        printf('[QUICKSAVE] %s (%s credits)', name,
          tostring((self.player:getControlling()):getCredits()))
      else
        Log.Warning('QUICKSAVE failed: %s', tostring(why))
      end
    elseif Input.GetPressed(Bindings.QuickLoad) then
      -- Quick load = the NEWEST save of any kind, quicksaves included --
      -- the old game's F7 semantics (SaveGame.ListSlots is newest-first).
      local latest = SaveGame.ReadLatest()
      if latest then
        local ok, why = self:loadGame(latest.slotName)
        if not ok then
          Log.Warning('QUICKLOAD: %s', tostring(why))
          Toast.Show('LOAD FAILED', { tostring(why) })
        end
      else
        Log.Warning('QUICKLOAD: no saves yet')
        Toast.Show('NOTHING TO LOAD', { 'Press F6 in flight to save first.' })
      end
    end
  end

  -- ESC TOGGLES THE MENU.
  --
  -- The canvas routes Cancel (ESC, right-click) to the modal screen, so a
  -- screen that is up closes itself -- that happens in the canvas:input
  -- above, before this line. So the question here is not "is a screen
  -- open?" but "was one open when this frame's ESC arrived?", and the
  -- answer is the state captured at the end of the last frame. Asking now
  -- would always say no (the canvas has just closed it) and the menu
  -- would open on the very key that closed it.
  if Input.GetPressed(Button.Keyboard.Escape) and not self.screenWasOpen
     and not self.masterControl:isPlayerDocked() then
    self:openMenu()
  end
end

-- Open the main menu. The world keeps running behind it -- dimmed and
-- drifting -- so the menu has the game behind it rather than a black
-- frame.
--
-- Opening it from LIVE PLAY also banks a working thumbnail (the last clean
-- gameplay frame, no menu over it): the next SAVE copies it next to the
-- slot's JSON, so the LOAD page can show what the save looks like. Two
-- guards: never before the first draw (the boot frame is garbage), and
-- never when a screen was ALREADY open -- a popup closing re-opens the
-- menu, and that frame shows the dimmed world behind the popup, not the
-- game.
function LTheory:openMenu ()
  if self.masterControl and self.masterControl:isPlayerDocked() then
    -- While docked the menu has no business opening: the dock page is
    -- the only page, and ESC undocks instead. Popups closing while
    -- docked used to call this and flash the menu (and its title band)
    -- under the dock's translucent backdrop -- the "garbled title".
    return
  end
  if self.menu then
    if not self.menu:isOpen() then
      if self.hasDrawn and not self.screenWasOpen then
        SaveGame.CaptureWorkingShot(self.gameView and self.gameView.renderer)
      end
      self.menu:open()
    elseif self.canvas.state and self.canvas.state.modalFocus ~= self.menu then
      -- A POPUP just closed back onto the still-open menu. The popup's
      -- close set the modal focus to nil, and this branch is why the menu
      -- never re-took it: "already open" skipped the whole re-open. The
      -- menu stayed VISIBLE but inputless -- ESC routed Cancel to no
      -- modal at all, and the player was stuck on the menu with only
      -- LOAD/EXIT. Re-assert the input grab.
      self.menu:setModal(true)
    end
  end
end

-- Open one of the menu's popups. It is a screen in its own right, so it
-- takes the input; when it closes, the menu takes it back. A popup may
-- carry an `onOpenUI` field (the LOAD page's slot list is rebuilt fresh
-- every time, because what is on disk is what it has to show).
function LTheory:openPopup (popup)
  if popup and not popup:isOpen() then
    if popup.onOpenUI then popup.onOpenUI() end
    popup:open()
  end
end

--[[ NEW GAME -- a new seed, and a new world from it.

  `generate()` is the world's constructor: it deletes the old system, makes
  a new one, spawns a ship, lays out the galaxy and builds the gates. The
  seed comes from Config.gen.seedGlobal when one is pinned, and from the
  clock otherwise -- so a NEW GAME clears the pinned seed and takes a new
  one, which is the whole point of the entry.

  Everything that was built FROM the old world has to be rebuilt: the
  sector's planet and sky, and the map's reference to the system.
]]
function LTheory:newGame (seedHex)
  -- A new seed. The pinned one is the debug panel's, not the player's --
  -- unless the player typed one, in which case it is theirs and it is
  -- kept: the same seed must always make the same galaxy.
  local seed = seedHex and #seedHex > 0 and seedFromHex(seedHex) or nil
  if seed then
    Config.gen.seedGlobal = seed
  else
    Config.gen.seedGlobal = nil
  end
  self:generate()
  self:regenerateSectorContent(0)
  self:settleAfterGenerate()
end

-- Everything a freshly GENERATED world needs regardless of why: after NEW
-- GAME, after CUSTOM GAME's START, and after LOAD (which regenerates the
-- world from the saved seed and then puts the snapshot back). Kept as one
-- method, because nothing here knows the difference -- the cameras re-seat,
-- the node graph follows the new ship, and the screens all close silently.
function LTheory:settleAfterGenerate ()
  -- The world is being REPLACED: no toast may outlive it (a stale "saved"
  -- must never describe the new universe).
  Toast.Clear()
  if self.nodeGraph then
    self.nodeGraph.system = self.system
    self.nodeGraph.focusEntity = self.player and self.player:getControlling()
  end

  -- The CAMERA IS STILL LOOKING AT THE DELETED SHIP. `generate()` deleted
  -- the whole system -- the chase camera's target with it -- and spawned a
  -- new ship, but the cameras were never told: without this they keep
  -- orbiting the old ship's last position and the new ship is nowhere in
  -- frame, which is exactly what a NEW GAME looked like.
  if self.gameView then self.gameView:onPlayerShipChanged() end

  -- THE GAME STARTS BEHIND A STILL-CLOSED SCREEN. Launching can come from
  -- the menu (NEW GAME) or from a popup (CUSTOM GAME's START), and only
  -- the menu was closed here. A popup left open kept `anyScreenOpen()`
  -- true, which keeps the world PAUSED (`onUpdate` gates `root:update` on
  -- it) — so from CUSTOM GAME the menu behind closed, the world behind the
  -- popup regenerated, and nothing visibly happened: a dead START. Close
  -- every open screen — and close it SILENTLY: a popup's `onClose` says
  -- "hand the input back to the menu", which would pop the menu right
  -- back open over the new game.
  for _, screen in ipairs(self.screens or {}) do
    if screen:isOpen() then
      local onClose = screen.onClose
      screen.onClose = nil
      screen:close()
      screen.onClose = onClose
    end
  end
end

--[[---------------------------------------------------------------------------
  SAVE and LOAD

  The save is a slot file (Game/SaveGame.lua): the world seed as a hex
  string plus the player snapshot. Saving writes; loading regenerates the
  world FROM that seed and puts the snapshot back into the fresh ship --
  the same path a NEW GAME runs, with the saved seed pinned and the same
  settle-after steps after, so one code path, whichever way you got here.
-----------------------------------------------------------------------------]]
-- The SAVE page's "where am I" line: the sector name, the dominant region
-- at the ship (the same rule the HUD uses) and the credits -- the same
-- facts a LOAD row shows, so the two pages cannot disagree about a save.
-- WHERE AM I, in parts: (sectorName, regionName, credits). The dominant
-- region at the ship -- the same rule the HUD uses -- and the ship can be
-- between regions, where there is no name. Shared by the SAVE page's
-- location line, the LOAD rows' facts and the save/load toasts, so no two
-- of them can disagree about a place.
function LTheory:locationParts ()
  local ship = self.player and self.player:getControlling()
  if ship == nil then return nil, nil, 0 end
  local pos = ship:getPos()
  local state = self.sectorState
  if state == nil and self.seed then
    -- Before the first update resolves the sector (e.g. the boot menu),
    -- compute it with the same call the per-frame path uses.
    local sector = self.sectors and self.sectors[(self.sectorIndex or 0) + 1]
    state = Sector.state(self.seed, pos.x, pos.y, pos.z, self.sectorIndex or 0,
                          sector and sector.center)
  end
  local regions = state and state.regions
  local region = regions
    and Sector.Region.containing(regions, pos.x, pos.y, pos.z) or nil
  return (state and state.sectorName) or '?',
         region and region.name or 'Deep space',
         ship:getCredits()
end

function LTheory:currentLocationText ()
  local sector, region, credits = self:locationParts()
  if not sector then return 'No ship.' end
  return string.format('Sector: %s · Region: %s · %d credits', sector, region, credits)
end

-- Capture + write in one call, from the live ship. `slotName` is optional:
-- without one, each save lands in its own timestamped slot (the old
-- quicksave rule). Returns the slot name, or nil, reason.
function LTheory:saveGameNow (slotName)
  local ship = self.player and self.player:getControlling()
  if ship == nil or not ship:isAlive() then
    return nil, 'no ship to save'
  end
  if not self.seed then return nil, 'no world to save' end
  -- WHERE you are: the sector is the generated one (the state carries its
  -- own name); the region is the one that CONTAINS the ship's position --
  -- the same dominant-region rule the HUD uses -- and the ship can be
  -- between regions, where there is no name.
  local state = self.sectorState
  local regions = state and state.regions
  local pos = ship:getPos()
  local region = regions
    and Sector.Region.containing(regions, pos.x, pos.y, pos.z) or nil
  local data = SaveGame.Capture(ship, {
    saveName   = slotName or 'save',
    systemName = (state and state.sectorName)
                 or (self.sectors and self.sectors[1] and self.sectors[1].name) or '',
    regionName = region and region.name or 'Deep space',
    seedHex    = seedToHex(self.seed),
  })
  local name, why = SaveGame.Write(slotName or SaveGame.DefaultSlotName(), data)
  if name then
    SaveGame.SaveThumbnail(name)
    -- THE TOAST: the old game's GAME SAVED plate, with this save's rows.
    -- F6 in flight shows it now; a menu save shows it when they return.
    Toast.Show('GAME SAVED', SaveGame.ToastRows(data,
      'F7 quick-loads your newest save at any time.'))
    printf('[SAVE] wrote %s (seed %s, credits %d)', name,
      tostring(data.seedHex), data.playerCredits or 0)
  else
    Log.Warning('SAVE: %s', tostring(why))
  end
  return name, why
end

-- Read a slot and rebuild the world from it: the seed hex goes through the
-- SAME parser the custom-seed field uses, generate() makes the galaxy,
-- the snapshot goes back into the fresh ship, and the camera/screens/flag
-- state settles exactly as a NEW GAME's does.
function LTheory:loadGame (slotName)
  local data, why = SaveGame.Read(slotName)
  if not data then return false, why end
  local seed = data.seedHex and #data.seedHex > 0 and seedFromHex(data.seedHex) or nil
  if not seed then return false, "save has no usable seed ('" ..
    tostring(data.seedHex) .. "')" end
  -- Pin the seed: the same invariant every path already keeps -- the same
  -- seed always makes the same galaxy, now also for one loaded from disk.
  Config.gen.seedGlobal = seed
  self:generate()
  SaveGame.Restore(self.player and self.player:getControlling(), data)
  self:regenerateSectorContent(0)
  self:settleAfterGenerate()
  -- THE TOAST: the old game's GAME LOADED plate (queued while the menu is
  -- still up; it shows the moment the world returns). settleAfterGenerate
  -- cleared any stale toasts first, so the rows describe THIS world.
  Toast.Show('GAME LOADED', SaveGame.ToastRows(data,
    'The world was replaced; unsaved progress is lost.'))
  printf("[LOAD] '%s': seed %s, ship restored (%d credits)", tostring(slotName),
    tostring(data.seedHex), data.playerCredits or 0)
  return true
end

-- Is a screen up? The ship's controls are read straight from the key
-- bindings (not through the UI input tree), so a screen has to ask for
-- them to be ignored -- and that check lives in one place, the HUD.
function LTheory:anyScreenOpen ()
  for _, screen in ipairs(self.screens or {}) do
    if screen:isOpen() then return true end
  end
  return false
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
      if g.sound then
        g.sound:setVolume(0)
        g.sound:free()
        g.sound = nil
      end
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
  -- THE TRADER: the Jobs.Mine AI drops its ore at ANY market; the Mine
  -- job prices the run with dst:getTrader() — a market without a trader
  -- crashed the brain the first time it priced a job. Every market
  -- carries both books now.
  place:addTrader()
  place.trader.credits = 500000 -- the trader's own escrow bank
  -- THE AI'S DEMAND BOOK: the standing bids the NPC miners price their
  -- jobs against (and get paid from). Same prices the player-facing
  -- market pays, so the two books cannot disagree about what ore is worth.
  for _, item in ipairs(Item.T1) do
    place.trader:addStandingBid(item, Item.Price[item] or 10, 200)
  end
  -- The place's working capital: it has to be able to PAY for what it
  -- buys, or the market's transfer fails on the buyer's side.
  place:addCredits(500000)
  -- STANDING ORDERS, not one-shot stock: the bid is this place's
  -- PERMANENT demand for what a belt yields, and Market:update tops the
  -- book back up whenever trading depletes it (a 200-unit bid sold off
  -- once would otherwise go silent forever -- "the market stopped
  -- wanting my ore"). The RE-ARM PRICE now drifts with the shelf
  -- (PriceCurve): a bare shelf bids 1.5x the anchor, a full one 0.75x.
  for _, item in ipairs(Item.T1) do
    place.market:addStandingBuy(place, item, 200, Item.Price[item] or 10)
  end
  -- THE DISPOSAL SINK: every place takes WASTE off a hold for its near-
  -- junk price. Without a dump, a run through a nuclear plant left the
  -- player carrying radioactive filth with nowhere to put it.
  place.market:addStandingBuy(place, Item.Waste, 200, Item.Price[Item.Waste])
  place.trader:addStandingBid(Item.Waste, Item.Price[Item.Waste], 200)

  -- THE STARTING STOCK: a place opens for business with a modest shelf,
  -- so a player docking in the first minute (before any NPC has mined
  -- or any factory has run) sees something to buy and something to sell
  -- into, instead of two empty tables. The factory's working stock is
  -- reserved so the asks do not strip the inputs. Every raw is seeded so
  -- that whichever industrial recipe the yard runs has its inputs.
  for _, item in ipairs(Item.T1) do
    place:addItem(item, 10)
  end
  place:addItem(Item.Energy, 50)
  place:addItem(Item.Waste, 10)
  -- Gas demand only (no supply yet -- capture equipment is future).
  for _, item in ipairs(Item.Gas) do
    place.market:addStandingBuy(place, item, 100, Item.Price[item] or 15)
    place.trader:addStandingBid(item, Item.Price[item] or 15, 100)
  end

  -- THE PLANT: every place runs a nuclear reactor for the universal
  -- fuel (energy + waste) -- a mining outpost or relay always has
  -- energy to sell, because every ship needs it. A YARD (an industrial
  -- place) additionally runs a SECOND recipe so the sector's markets
  -- do not all sell the same thing: machine parts, electronics, weapon
  -- components or rations, depending on the seed. That is what makes
  -- the BUY tab vary from dock to dock.
  do
    place:addFactory()
    place:addProduction(Productions.EnergyNuclear)
    for _, out in ipairs(Productions.EnergyNuclear.outputs) do
      place.market:addStandingSell(place, out.item, 200,
        Item.Price[out.item] or 20)
    end
    for _, out in ipairs(Productions.EnergyNuclear.outputs) do
      place.trader:addStandingAsk(out.item, Item.Price[out.item] or 20, 40)
    end

    if kind == 'yard' then
      local industrial = { Productions.Refinery, Productions.Electronics,
                           Productions.Weapons, Productions.Hydroponics }
      local placeRng = Seed.rng('ltheory.place', region.index)
      local prod = industrial[1 + (placeRng:get31() % #industrial)]
      place:addProduction(prod)
      for _, out in ipairs(prod.outputs) do
        place.market:addStandingSell(place, out.item, 200,
          Item.Price[out.item] or 20)
      end
      for _, out in ipairs(prod.outputs) do
        place.trader:addStandingAsk(out.item, Item.Price[out.item] or 20, 40)
      end
    end

    -- ...and the raw shelf: place stock of T1 (what miners delivered)
    -- is buyable too -- but only BEYOND the plant's working reserve, so
    -- the ore that feeds the reactor cannot be hauled away from under
    -- it (the caravan books stripped the shelf instantly without this).
    for _, item in ipairs(Item.T1) do
      place.trader:addStandingAsk(item, Item.Price[item] or 10, 40, 100)
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
  -- The state the ESC toggle reads next frame (see LTheory:onInput).
  self.screenWasOpen = self:anyScreenOpen()

  -- THE DOCK SCREEN: opened and closed BY THE DOCKED STATE, not by any
  -- key. One watcher, here, where the docked predicate already lives:
  -- MasterControl's control sets run the world half (the orbit camera),
  -- and this runs the UI half.
  local docked = self.masterControl and self.masterControl:isPlayerDocked()
  if self.dockScreen then
    if docked and not self.dockScreen:isOpen() then
      self.dockScreen:refresh() -- retitle to the dock you pulled into
      self.dockScreen:open()
      -- THE MENU MUST NOT BE UNDER THE DOCK PAGE: its title band and
      -- entry row render through the dock's translucent backdrop -- the
      -- big title's glyphs sit right under the market table and read as
      -- garbage ("the title gets messed up when navigating"). Closing it
      -- silently: no onClose pop-back.
      if self.menu:isOpen() then
        local oc = self.menu.onClose
        self.menu.onClose = nil
        self.menu:close()
        self.menu.onClose = oc
      end
    elseif not docked and self.dockScreen:isOpen() then
      -- Silent close: the screen has no onClose, and none may grow here --
      -- the menu must not pop open over the undocked ship.
      self.dockScreen:close()
    end
  end

  -- THE POINTER ONLY EXISTS ON UI.
  --
  -- While flying, the player aims with the reticle; a cursor next to it is
  -- a second point-of-aim glyph and only confuses the eye. So the pointer
  -- is drawn exactly when the player is interacting with UI: a modal
  -- screen (the menu, a popup, the station screens) always wants it, and
  -- the debug panels want it for as long as they are open. Compute it per
  -- frame here rather than in the widgets: they open and close through
  -- several paths (this menu, ESC, the panel switch), and one rule they
  -- cannot disagree with is what makes the pointer trustworthy.
  self.canvas.showCursor =
    self:anyScreenOpen()
    or (self.debugWindow ~= nil and self.debugWindow:isEnabled() or false)
    -- DOCKED IS UI TOO: the market window is clickable, and without this
    -- the player docked at a station had no pointer at all.
    or (self.masterControl ~= nil and self.masterControl:isPlayerDocked())

  -- TEMP: headless settings snapshot.
  if os.getenv('PHX_DUMP_SETTINGS') and not self.__dumped then
    self.__dumped = true
    require('Game.GUI.DebugWindow').DumpSettings()
  end

  -- [TEST HOOK] PHX_UITEST=1: automated UI smoke test. Drives the main
  -- menu + market flow headlessly and prints [UITEST] PASS/FAIL lines so
  -- regressions in the UI layer are caught without a human eyeballing
  -- screenshots. Assertions are checked at each stage; a single FAIL
  -- aborts the run with a non-zero-ish marker.
  if os.getenv('PHX_UITEST') and not self.__uiDone then
    self.__uiT = (self.__uiT or 0) + dt
    local s = self.player and self.player:getControlling()
    local function fail (msg)
      printf('[UITEST] FAIL: %s', msg)
      self.__uiDone = true
      self.__uiFailed = true
    end
    local function pass (msg)
      printf('[UITEST] PASS: %s', msg)
    end

    if self.__uiStage == nil and self.__uiT >= 2.0 then
      self.__uiStage = 1
      -- 1) Main menu opens and closes.
      self:openMenu()
      if not (self.menu and self.menu:isOpen()) then
        fail('main menu did not open') return
      end
      pass('main menu opens')
      self.menu:close()
      if self.menu:isOpen() then fail('main menu did not close') return end
      pass('main menu closes')
    elseif self.__uiStage == 1 and self.__uiT >= 2.4 then
      self.__uiStage = 2
      -- 2) Dock at a market.
      local target
      for _, e in pairs(self.system.children) do
        if e.hasMarket and e:hasMarket() then target = e break end
      end
      if not target then fail('no market station in system') return end
      s:setPos(target:getPos() + Vec3f(80, 0, 0))
      target:addDocked(s)
      self.__uiPlace = target
      -- Seed the ship so the trade stages actually exercise the
      -- market's buy/sell paths (the player otherwise starts broke).
      s:addCredits(1000)
      s:addItem(require('Game.Item').Isotopes, 5)
    elseif self.__uiStage == 2 and self.__uiT >= 2.8 then
      self.__uiStage = 3
      -- 3) Dock screen opened.
      if not (self.dockScreen and self.dockScreen:isOpen()) then
        fail('dock screen did not open on dock') return
      end
      pass('dock screen opens on dock')
      -- Menu must NOT be open under it (the garbled-title regression).
      if self.menu and self.menu:isOpen() then
        fail('menu open under dock screen (garbled title)') return
      end
      pass('menu closed while docked')
    elseif self.__uiStage == 3 and self.__uiT >= 3.2 then
      self.__uiStage = 4
      local m = self.__uiPlace.market
      -- 4) Market has BUY (asks) and SELL (bids) entries.
      local quotes = m:quotes()
      local hasAsk, hasBid = false, false
      for _, q in ipairs(quotes) do
        if q.ask then hasAsk = true end
        if q.bid then hasBid = true end
      end
      if not hasAsk then fail('BUY tab empty (no asks)') return end
      pass('BUY tab has asks')
      if not hasBid then fail('SELL tab empty (no bids)') return end
      pass('SELL tab has bids')
    elseif self.__uiStage == 4 and self.__uiT >= 3.6 then
      self.__uiStage = 5
      -- 5) Buy one energy cell (if affordable) and check credits moved.
      local m = self.__uiPlace.market
      local Energy = require('Game.Item').Energy
      local before = s:getCredits()
      local n, total = m:buy(s, Energy, 1)
      if n > 0 then
        if s:getCredits() >= before then
          fail('buy did not deduct credits') return
        end
        pass('BUY deducts credits (n=' .. n .. ')')
      else
        pass('BUY: no affordable ask (skipped)')
      end
      self.dockScreen:refresh()
    elseif self.__uiStage == 5 and self.__uiT >= 4.0 then
      self.__uiStage = 6
      -- 6) Sell one isotope (seed stock) and check credits moved.
      local m = self.__uiPlace.market
      local Iso = require('Game.Item').Isotopes
      local before = s:getCredits()
      local n, total = m:sell(s, Iso, 1)
      if n > 0 then
        if s:getCredits() <= before then
          fail('sell did not add credits') return
        end
        pass('SELL adds credits (n=' .. n .. ')')
      else
        pass('SELL: no matching bid (skipped)')
      end
      self.dockScreen:refresh()
    elseif self.__uiStage == 6 and self.__uiT >= 4.4 then
      self.__uiStage = 7
      -- 7) Market still has entries after trading (re-arm works).
      local m = self.__uiPlace.market
      local hasBid = false
      for _, q in ipairs(m:quotes()) do
        if q.bid then hasBid = true end
      end
      if not hasBid then fail('bids vanished after trade (re-arm broken)') return end
      pass('bids re-arm after trade')
      -- 8) Undock closes the dock screen.
      s:pushAction(Actions.Undock())
    elseif self.__uiStage == 7 and self.__uiT >= 5.0 then
      self.__uiStage = 8
      if self.dockScreen and self.dockScreen:isOpen() then
        fail('dock screen did not close on undock') return
      end
      pass('dock screen closes on undock')
      printf('[UITEST] ALL CHECKS PASSED')
      self.__uiDone = true
    end
  end

  -- [TEST HOOK] PHX_SAVENOW=<slot>: at ~2.5 s, save the game, MOVE the ship,
  -- then load the same slot in-process and print both positions. The
  -- roundtrip's proof is the post-load position matching the pre-move one.
  local saveSlot = os.getenv('PHX_SAVENOW')
  if saveSlot and not self.__saveTestDone then
    self.__saveTestT = (self.__saveTestT or 0) + dt
    if self.__saveTestT >= 2.5 then
      self.__saveTestDone = true
      local s = self.player and self.player:getControlling()
      if s then
        local p = s:getPos()
        printf('[SAVE TEST] pre-save pos (%.1f, %.1f, %.1f)', p.x, p.y, p.z)
        -- Give the ship something to prove the WALLET and CARGO rows of the
        -- snapshot, then clean them off the slot afterwards.
        s:addCredits(1234)
        local silver = SaveGame.ItemByName('Silver')
        if silver then s:addItem(silver, 42) end
        -- The menu-open capture, exercised directly: the frame in hand has
        -- the menu over the world, but the machinery is what is under test.
        SaveGame.CaptureWorkingShot(self.gameView and self.gameView.renderer)
        printf('[SAVE TEST] working shot exists = %s',
          tostring(File.Exists('./saves/_latest.png')))
        local name, why = self:saveGameNow(saveSlot)
        printf('[SAVE TEST] wrote %s thumb=%s (%s)', tostring(name),
          tostring(SaveGame.ThumbnailPath(tostring(name))), tostring(why))
        s:setPos(s:getPos() + Vec3f(50000, 0, 0))
        local p2 = s:getPos()
        printf('[SAVE TEST] moved to  (%.1f, %.1f, %.1f)', p2.x, p2.y, p2.z)
        local ok, lwhy = self:loadGame(saveSlot)
        printf('[SAVE TEST] load: %s', tostring(ok or lwhy))
        local s2 = self.player and self.player:getControlling()
        if s2 then
          local p3 = s2:getPos()
          printf('[SAVE TEST] post-load  (%.1f, %.1f, %.1f) credits %d silver %d',
            p3.x, p3.y, p3.z, s2:getCredits(),
            silver and s2:getItemCount(silver) or 0)
          printf('[SAVE TEST] position + credits restored = %s',
            tostring(math.abs(p3.x - p.x) < 1 and math.abs(p3.y - p.y) < 1
              and math.abs(p3.z - p.z) < 1 and s2:getCredits() == 1234))
          printf('[SAVE TEST] location line: %s', self:currentLocationText())
          -- Clean up: the slot, its thumbnail, and the working shot.
          if SaveGame.Delete(saveSlot) then
            print('[SAVE TEST] cleaned up the test slots')
          end
          os.remove('./saves/_latest.png')
        else
          print('[SAVE TEST] NO SHIP after load')
        end
      end
    end
  end

  -- [TEST HOOK] PHX_LOADNOW=<slot>: at ~2.5 s, load the named slot from
  -- disk (the cold path: a different process reading what a previous boot
  -- wrote) and print where the ship ended up.
  local loadSlot = os.getenv('PHX_LOADNOW')
  if loadSlot and not self.__loadTestDone then
    self.__loadTestT = (self.__loadTestT or 0) + dt
    if self.__loadTestT >= 2.5 then
      self.__loadTestDone = true
      local ok, why = self:loadGame(loadSlot)
      printf('[LOAD TEST] load: %s (%s)', tostring(ok), tostring(why))
      local s = self.player and self.player:getControlling()
      if s then
        local p = s:getPos()
        printf('[LOAD TEST] ship pos (%.1f, %.1f, %.1f) credits %d',
          p.x, p.y, p.z, s:getCredits())
      else
        print('[LOAD TEST] NO SHIP after load')
      end
    end
  end
  -- getRoot() is nil with no controlling ship, and a DESTROYED ship detaches
  -- from the tree (no `update`). Guard so a bad spawn can't kill the process.
  -- THE GAME IS PAUSED BEHIND A MENU -- BUT NOT BEHIND THE DOCK.
  --
  -- A menu is its own page: the world does not run while it is up. The
  -- ship does not fly (the HUD feeds it zeros), and nothing else moves
  -- either -- the rocks, the market, the gates. What still runs is the
  -- camera drift, which is the camera's, not the world's: the menu has to
  -- have something alive behind it.
  --
  -- THE DOCK SCREEN IS THE EXCEPTION, and the stuck-at-dock bug is why:
  -- the UNDOCK button, ESC and the F key all push an Undock ACTION onto
  -- the ship, and actions only tick when the ship updates. Pausing the
  -- world behind the dock screen queued the action into a frozen world --
  -- the player was docked forever, Ctrl-C the only exit. The dock is a
  -- station interface over a LIVE hangar (the old game's did the same):
  -- the market's books keep ticking, and every undock path works.
  local paused = self:anyScreenOpen()
  if self.dockScreen and self.dockScreen:isOpen() then
    paused = false
  end
  Toast.Update(paused and 0 or dt)
  local root = self.player and self.player:getRoot()
  if not paused and root and root.update then root:update(dt) end
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
          local v = Entities.Wormhole.droneVolume(gd)
          if v < 0.001 then
            -- Effectively silent: free the sound so it cannot linger as a
            -- faint drone after the player flies away (miniaudio at gain 0
            -- can still produce audible output on some backends).
            nearest.sound:free()
            nearest.sound = nil
          else
            nearest.sound:setVolume(v)
          end
        elseif Entities.Wormhole.droneVolume(gd) >= 0.001 then
          -- Sound was freed (player flew away and came back): restart it.
          nearest:startSound()
          if nearest.sound then
            nearest.sound:setVolume(Entities.Wormhole.droneVolume(gd))
          end
        end
        for _, g in ipairs(self.gates or {}) do
          if g ~= nearest and g.sound then
            g.sound:setVolume(0)
            -- Free silenced (non-nearest) gate sounds too, so they cannot
            -- accumulate across sector changes.
            g.sound:free()
            g.sound = nil
          end
        end
      end
    end
  else
    self.sectorState = nil
  end
  self.canvas:update(dt)
end

function LTheory:onDraw ()
  self.hasDrawn = true
  self.canvas:draw(self.resX, self.resY)
end

return LTheory
