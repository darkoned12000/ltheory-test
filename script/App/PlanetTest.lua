-- PlanetTest -- deterministic biome (W7c) look scene.
--
-- Run with: ./run.sh PlanetTest
--
-- A single terrestrial planet, framed large and lit from the side, with the
-- camera pinned so two runs are comparable. Use Debug > Planet > Biomes to
-- cross-fade between the biome blend (1) and the pre-W7c elevation ramp (0),
-- and watch the planet's lowlands change character while its peaks keep the
-- type's own rock/snow.
--
-- WHY A SEPARATE APP: the perf probe's world has a small BARREN planet (a
-- moon-type world, which has a huePick family rather than a palette range)
-- far from the camera, so it is the worst possible test bed for biomes. This
-- scene forces a terrestrial type, a big radius and a fixed framing.
--
-- Audio is muted.

Config.window.fullscreen = false
Config.window.width = 1280
Config.window.height = 800
Config.gpu.asteroidFieldEnabled = false
Config.gen.asteroidField.enable = false
Config.gpu.nebulaEnabled = false
Config.gpu.godraysEnabled = false
Config.gpu.lightningEnable = false
Config.audio.musicVolume = 0
for _, sfx in pairs(Config.audio.sfx) do sfx.volume = 0 end

local Entities = requireAll('Game.Entities')
local DebugControl = require('Game.Controls.DebugControl')

local PlanetTest = Application()
local SUN_DIR = Vec3f(0.4, 0.25, 0.88)

local function setSetting (key, value)
  if Settings.exists(key) then Settings.set(key, value) end
end

function PlanetTest:onInit ()
  -- Applied AFTER the Renderer exists: the Renderer's constructor re-seeds
  -- every panel value from Config.gpu, so applying these earlier is silently
  -- undone.
  setSetting('gen.asteroidField.enable', false)
  setSetting('nebula.enable', false)
  setSetting('postfx.godrays.enable', false)
  setSetting('ssao.enable', false)
  setSetting('render.taa.enable', false)
  setSetting('postfx.bloom.enable', false)
  setSetting('render.sun.enable', true)
  setSetting('render.sun.shadows', false)
  setSetting('render.sun.marker', false)
  setSetting('render.planet.biomes', 1.0)

  self.seed = 424242
  self.system = Entities.System(self.seed)
  self.system.starDir = SUN_DIR
  self.system.nebula.starDir = SUN_DIR

  self.player = Entities.Player()
  local ship = self.system:spawnShip()
  ship:setPos(Vec3f(0, 0, 0))
  ship:setVelocity(Vec3f(0, 0, 0))
  self.player:setControlling(ship)

  -- A terrestrial planet, close enough and big enough to fill a good part of
  -- the frame.
  --
  -- `forceType` is read from Config.render.planet (Planet.lua), so it is set
  -- on the CONFIG TABLE, not through the panel -- and it MUST be set before
  -- the planet is constructed, because the type is picked in the constructor.
  -- Without it the type is a weighted random pick, so 68% of the time this
  -- "terrestrial biome audition scene" was not terrestrial at all -- and a
  -- `barren` world is a gen/moon body, which is the case with no palette
  -- range to spread the biomes across.
  Config.render.planet.forceType = 'terrestrial'
  local planet = Entities.Planet(self.seed, { detail = 5 })
  planet:setPos(Vec3f(0, 0, -9000))
  planet:setRot(Quat.Identity())
  self.system:addChild(planet)
  self.planet = planet

  print(string.format('[planetTest] type=%s radius=%.0f',
                       tostring(planet.typeName or planet.type),
                       planet:getScale()))

  self.gameView = GUI.GameView(self.player)
  self.gameView.ltheory = self
  self.canvas = UI.Canvas()
  self.canvas:add(self.gameView:add(Controls.MasterControl(self.gameView, self.player)))

  -- The camera is pinned by the harness (PHX_FIXED_VIEW / PHX_FIXED_SIZE), so
  -- a capture here is comparable run to run.
end

function PlanetTest:onInput ()
  self.canvas:input()
end

function PlanetTest:onUpdate (dt)
  self.system:update(dt)
  self.canvas:update(dt)
  self.t = (self.t or 0) + dt
end

function PlanetTest:onDraw ()
  self.canvas:draw(self.resX, self.resY)
end

return PlanetTest
