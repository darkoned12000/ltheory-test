-- ShadowTest -- deterministic, isolated sunlight-shadow tuning scene.
--
-- Run with: ./run.sh ShadowTest
--
-- The large asteroid is the receiver; the smaller one sits between it and the
-- fixed sun direction and should cast a visible patch onto its camera-facing
-- side. The asteroid at right is an unoccluded control. Use Debug > Rendering
-- to toggle Sun Shadows and vary Shadow Range/Res/Bias/Radius. Audio is muted.

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

local ShadowTest = Application()
local SUN_DIR = Vec3f(0.15, 0, 0.988686)

local function setSetting (key, value)
  if Settings.exists(key) then Settings.set(key, value) end
end

function ShadowTest:onInit ()
  -- Set after Renderer has seeded Settings from Config, so the test starts from
  -- a known state even if a previous session saved different debug values.
  setSetting('gen.asteroidField.enable', false)
  setSetting('render.sun.enable', true)
  setSetting('render.sun.shadows', true)
  setSetting('render.sun.shadowRange', 10000)
  setSetting('render.sun.shadowSize', 3) -- enum index 3 = 1024
  setSetting('render.sun.marker', false)
  setSetting('render.sun.fill', 0.12)
  setSetting('render.shadow.period', 1)
  setSetting('render.shadow.maxLights', 0)
  setSetting('render.shadow.radius', 2)
  setSetting('render.shadow.bias', 0.001)
  setSetting('render.shadow.scale', 0.0005)
  setSetting('nebula.enable', false)
  setSetting('postfx.godrays.enable', false)
  setSetting('ssao.enable', false)
  setSetting('render.taa.enable', false)
  setSetting('postfx.bloom.enable', false)

  self.seed = 177603
  self.system = Entities.System(self.seed)
  self.system.starDir = SUN_DIR
  -- The nebula owns the skybox star direction and loads its cube lazily.
  self.system.nebula.starDir = SUN_DIR

  self.player = Entities.Player()
  local ship = self.system:spawnShip()
  ship:setPos(Vec3f(1400, 0, 0))
  ship:setVelocity(Vec3f(0, 0, 0))
  self.player:setControlling(ship)

  local receiverPos = Vec3f(0, 0, -7000)
  local receiver = Entities.Asteroid(4242, 1800, { static = true })
  receiver:setPos(receiverPos)
  receiver:setRot(Quat.Identity())
  self.system:addChild(receiver)

  local blocker = Entities.Asteroid(1234, 340, { static = true })
  blocker:setPos(receiverPos + Vec3f(
    SUN_DIR.x * 1600, SUN_DIR.y * 1600, SUN_DIR.z * 1600))
  blocker:setRot(Quat.Identity())
  self.system:addChild(blocker)

  local control = Entities.Asteroid(7777, 1400, { static = true })
  control:setPos(Vec3f(2400, 0, -9000))
  self.system:addChild(control)

  self.gameView = GUI.GameView(self.player)
  self.gameView.ltheory = self
  self.canvas = UI.Canvas()
  self.canvas:add(self.gameView:add(Controls.MasterControl(self.gameView, self.player)))

  DebugControl.ltheory = self
  self.debugWindow = GUI.DebugWindow(self)
  self.gameView.debugWindow = self.debugWindow
  self.gameView:add(self.debugWindow:setStretch(0, 1), true)

  printf('[shadowtest] fixed sun=(%.2f,%.2f,%.2f); receiver at (0,0,-7000)',
         SUN_DIR.x, SUN_DIR.y, SUN_DIR.z)
  printf('[shadowtest] Debug > Rendering: toggle Shadows; vary Range/Res/Bias/Radius')
end

function ShadowTest:onInput ()
  self.canvas:input()
end

function ShadowTest:onUpdate (dt)
  self.system:update(dt)
  self.canvas:update(dt)
end

function ShadowTest:onDraw ()
  self.canvas:draw(self.resX, self.resY)
end

return ShadowTest
