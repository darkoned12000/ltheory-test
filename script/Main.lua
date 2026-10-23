package.path = package.path .. ';./libphx/script/?.lua'
package.path = package.path .. ';./script/?.lua'
package.path = package.path .. ';./script/?.ext.lua'
package.path = package.path .. ';./script/?.ffi.lua'

require('env.env')

Env.Call(function ()
  require('phx.phx')
  local app = __app__ or Config.app or 'ltheory'
  GlobalRestrict.On()

  dofile('./script/Config.App.lua')
  if io.exists ('./script/Config.Local.lua') then dofile('./script/Config.Local.lua') end
  -- THE PLAYER'S SETTINGS SCREEN CHOICES, after the local overrides: the
  -- settings screen (Game/GUI/SettingsScreen.lua) writes this file whenever
  -- a setting on the menu's SETTINGS page changes, so what is on disk is
  -- exactly what the player last picked. Missing file = boot defaults; a
  -- local override the player then changes in-game also lands here.
  if io.exists ('./script/Config.Settings.lua') then dofile('./script/Config.Settings.lua') end

  -- A GLOBAL mute, from the environment.
  --
  -- The engine has no master volume, so muting means zeroing the music and
  -- every SFX gain. Doing it here -- once, after the config is loaded --
  -- means every app is muted, including the main one, and it cannot be
  -- forgotten by a test app that forgets to mute itself.
  --
  -- This matters: the capture harness has always said so in its header
  -- ("mute audio for any headless boot"), because `sfx.engine` is a
  -- continuous loop with a 60-unit full-volume radius and a dev machine
  -- audibly hums. A headless boot should be SILENT unless it says otherwise.
  if os.getenv('PHX_MUTE') then
    Config.audio.musicVolume = 0
    for _, sfx in pairs(Config.audio.sfx) do sfx.volume = 0 end
  end

  Namespace.LoadInline('Util')
  Namespace.Load      ('UI')
  Namespace.Load      ('WIP')
  Namespace.Load      ('Gen')
  Namespace.LoadInline('Game')

  jit.opt.start(
    format('maxtrace=%d',   Config.jit.tune.maxTrace),
    format('maxrecord=%d',  Config.jit.tune.maxRecord),
    format('maxirconst=%d', Config.jit.tune.maxConst),
    format('maxside=%d',    Config.jit.tune.maxSide),
    format('maxsnap=%d',    Config.jit.tune.maxSnap),
    format('hotloop=%d',    Config.jit.tune.hotLoop),
    format('hotexit=%d',    Config.jit.tune.hotExit),
    format('tryside=%d',    Config.jit.tune.trySide),
    format('instunroll=%d', Config.jit.tune.instUnroll),
    format('loopunroll=%d', Config.jit.tune.loopUnroll),
    format('callunroll=%d', Config.jit.tune.callUnroll),
    format('recunroll=%d',  Config.jit.tune.recUnroll),
    format('sizemcode=%d',  Config.jit.tune.sizeMCode),
    format('maxmcode=%d',   Config.jit.tune.maxMCode)
  )

  require('App.' .. app):run()
  GlobalRestrict.Off()
end)
