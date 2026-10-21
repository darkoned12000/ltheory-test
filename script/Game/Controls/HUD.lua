local CameraBindings = require('Game.Controls.CameraBindings')
local ShipBindings = require('Game.Controls.ShipBindings')
local Disposition = require('Game.Components.Dispositions')
local Frustum = require('Game.Frustum')
local Sector = require('Game.Region')
local Seed = require('Game.Seed')
local Container = require('UI.Container')

-- Scratch vector for the frustum pre-cull in drawTargets. The target list
-- holds every live, damageable entity in the system -- with a streamed
-- asteroid field that is ~10,600 rocks -- and the loop below runs every
-- frame. Allocating a Vec3f per entity per frame was pure GC pressure.
local scratchPos = Vec3f()

local HUD = {}
HUD.__index = HUD
setmetatable(HUD, UI.Panel)

HUD.name      = 'HUD'
HUD.focusable = true
HUD:setPadUniform(8)

function HUD:onEnable ()
  -- TODO : Wtf does this do? Who wrote this?? WHY.
  local pCamera = self.gameView.camera
  local camera = self.gameView.camera
  camera:warp()
  camera:lerpFrom(pCamera.pos, pCamera.rot)
end

--[[
  drawTargets -- target brackets + pick the lock candidate
  ----------------------------------------------------------------------------
  Iterates `self.targets.tracked` (every live, damageable entity in the system
  -- see Util/TrackingList.lua) and draws a bracket around those on screen. It
  ALSO decides which entity `self.target` is: the alive, friendly-ish tracked
  entity closest to the screen center (within 128px). That candidate is what
  `LockTarget` (key T) locks onto. The bracket drawing itself is gated by
  Config.ui.showTrackers, but the `self.target` selection always runs so
  locking works even with brackets hidden.
]]
function HUD:drawTargets (a)
  local camera = self.gameView.camera

  local cTarget = Color(1.0, 0.5, 0.1, 1.0 * a)
  local cLock = Color(1.0, 0.5, 0.1, 1.0 * a)

  local player = self.player
  local playerShip = player:getControlling()
  local playerTarget = playerShip:getTarget()

  local closest = nil
  local minDist = 128
  local center = Vec2f(self.sx / 2, self.sy / 2)

  -- The tracked list is EVERY live, damageable entity in the system. With a
  -- streamed asteroid field that is ~10,600 rocks, and this loop ran over all
  -- of them every frame: one Vec3f allocation for the position and five more
  -- inside the NDC transform, per rock, per frame. Measured at 1.78 ms -- the
  -- largest item in the frame that was not the scene render itself.
  --
  -- The frustum cull below is what removes that cost. The view cone (built
  -- once per frame by GameView, and still current when the UI pass runs) says
  -- whether an entity can be on screen at all. An entity outside the cone
  -- cannot be the lock candidate -- the candidate test requires it to be
  -- inside the screen rectangle -- so it only contributes the off-screen
  -- hostile indicator, which is drawn solely for HOSTILE entities
  -- (disposition < 0). Everything else can be dropped without projecting it.
  --
  -- The test is a sphere, not a point, and the sphere is the entity's own
  -- bounding radius: a big rock straddling the screen edge still has geometry
  -- on screen, and the bracket is drawn from its bounding box, not its centre.
  local planes = Frustum.getCurrent()
  local showTrackers = Config.ui.showTrackers

  for i = 1, #self.targets.tracked do
    local target = self.targets.tracked[i]
    if target ~= playerShip and target:isAlive() then
      local disp = target:getOwnerDisposition(player)
      local culled = false
      if planes and disp >= 0 then
        local body = target.body
        if body then
          body:getPos(scratchPos)
          local radius = body:getBoundingRadius() * 1.15
          culled = not Frustum.sphereVisible(planes, scratchPos.x, scratchPos.y,
                                             scratchPos.z, radius)
        end
      end
      if not culled then
        local pos = target:getPos()
        local ndc = camera:worldToNDC(pos)
        local ndcMax = max(abs(ndc.x), abs(ndc.y))

        local c = Disposition.GetColor(disp)
        c.a = a * c.a
        if ndcMax <= 1.0 and ndc.z > 0 then
          if showTrackers then
            do -- Draw rounded box corners
              local bx1, by1, bsx, bsy = camera:entityToScreenRect(target)
              local bx2, by2 = bx1 + bsx, by1 + bsy
              UI.DrawEx.Wedge(bx2, by1, 4, 4, 0.125, 0.2, c)
              UI.DrawEx.Wedge(bx1, by1, 4, 4, 0.375, 0.2, c)
              UI.DrawEx.Wedge(bx1, by2, 4, 4, 0.625, 0.2, c)
              UI.DrawEx.Wedge(bx2, by2, 4, 4, 0.875, 0.2, c)
              if playerTarget == target then
                UI.DrawEx.Wedge(bx2, by1, 12, 12, 0.125, 0.3, cLock)
                UI.DrawEx.Wedge(bx1, by1, 12, 12, 0.375, 0.3, cLock)
                UI.DrawEx.Wedge(bx1, by2, 12, 12, 0.625, 0.3, cLock)
                UI.DrawEx.Wedge(bx2, by2, 12, 12, 0.875, 0.3, cLock)
              elseif self.target == target then
                UI.DrawEx.Wedge(bx2, by1, 8, 8, 0.125, 0.2, cTarget)
                UI.DrawEx.Wedge(bx1, by1, 8, 8, 0.375, 0.2, cTarget)
                UI.DrawEx.Wedge(bx1, by2, 8, 8, 0.625, 0.2, cTarget)
                UI.DrawEx.Wedge(bx2, by2, 8, 8, 0.875, 0.2, cTarget)
              end
            end
          end

          local ss = camera:ndcToScreen(ndc)
          local dist = ss:distance(center)
          if disp < 0.5 and dist < minDist then
            closest = target
            minDist = dist
          end
        else
          if showTrackers then
            ndc.x = ndc.x / ((1 + 16/camera.sx) * ndcMax)
            ndc.y = ndc.y / ((1 + 16/camera.sy) * ndcMax)
            local x = ( ndc.x + 1)/2 * camera.sx
            local y = (-ndc.y + 1)/2 * camera.sy
            if disp < 0.0 then
              c.a = c.a * 0.5
              UI.DrawEx.Point(x, y, 64, c)
            end
          end
        end
      end
    end
  end

  -- Stash the best lock candidate for controlTargetLock to consume (see
  -- HUD:onInput -> ShipBindings.LockTarget).
  self.target = closest
end

--[[
  drawLock -- reticle arrow + health bar for the LOCKED target
  ----------------------------------------------------------------------------
  `self.player:getControlling():getTarget()` is the entity the player locked
  with T. We draw a direction arrow toward it and, if it has health, a colored
  health bar with `cur / max` text. If the locked target has been destroyed we
  clear the lock so the HUD stops tracking a corpse.
]]
function HUD:drawLock (a)
  local playerShip = self.player:getControlling()
  local target = self.player:getControlling():getTarget()
  if not target or target:isDestroyed() then
    -- Target died (or was swept from the world): drop the lock.
    if target then playerShip:setTarget(nil) end
    return
  end
  local camera = self.gameView.camera
  local center = Vec2f(self.sx / 2, self.sy / 2)

  -- Health bar for the locked target (only if it is damageable)
  if target.health then
    local ndc = camera:worldToNDC(target:getPos())
    local ndcMax = max(abs(ndc.x), abs(ndc.y))
    if ndcMax <= 1.0 and ndc.z > 0 then
      local ss = camera:ndcToScreen(ndc)
      local bw, bh = 120, 10
      local bx, by = ss.x - bw / 2, ss.y - 40
      local frac = target:getHealthNormalized()
      UI.DrawEx.Rect(bx, by, bw, bh, Color(0.1, 0.1, 0.1, 0.7 * a))
      UI.DrawEx.Rect(bx, by, bw * frac, bh,
        frac > 0.5 and Color(0.2, 0.9, 0.2, a)
        or frac > 0.25 and Color(0.9, 0.8, 0.2, a)
        or Color(0.9, 0.2, 0.2, a))
      UI.DrawEx.TextAdditive('NovaMono',
        string.format('%d / %d', target:getHealth(), target.healthMax),
        14, bx, by - 16, bw, 16, 1, 1, 1, a, 0.0, 0.0)
    end
  end

  do -- Direction indicator
    local r = 96
    local pos = target:getPos()
    local ndc = camera:worldToNDC(pos)
    local ndcMax = max(abs(ndc.x), abs(ndc.y))
    if ndcMax > 1 or ndc.z <= 0 then ndc:idivs(ndcMax) end
    local ss = camera:ndcToScreen(ndc)
    local dir = ss - center
    local dist = dir:length()
    if dist > 1 then
      dir:inormalize()
      ss = center + dir:scale(r)
      local a = a * (1.0 - exp(-max(0.0, dist / (r + 16) - 1.0)))
      UI.DrawEx.Arrow(ss, dir:scale(6), Color(1.0, 0.5, 0.1, a))
    end
  end

  -- Impact point
  if playerShip.socketSpeedMax > 0 then
    local tHit, pHit = Math.Impact(
      playerShip:getPos(),
      target:getPos(),
      playerShip:getVelocity(),
      target:getVelocity(),
      playerShip.socketSpeedMax)

    if tHit then
      local ndc = camera:worldToNDC(pHit)
      local ndcMax = max(abs(ndc.x), abs(ndc.y))
      if ndcMax <= 1 and ndc.z > 0 then
        local ss = camera:ndcToScreen(ndc)
        UI.DrawEx.Cross(ss.x, ss.y, 4, Color(1.0, 0.5, 0.1, a))
      end
    end
  end
end

function HUD:drawReticle (a)
  -- Saved below for the cursor-direction branch.
  local debugWindow = self.gameView.debugWindow
  local overPanel = debugWindow and debugWindow:isEnabled()
                    and debugWindow:containsPoint(
                      Input.GetMousePosition().x, Input.GetMousePosition().y)
  -- Hide the OS cursor during play; the game reticle is the only aim indicator.
  -- When the debug panel is open we keep the OS cursor visible so its widgets are
  -- interactive (the panel's onEnable/onDisable also set the cursor, but HUD draws
  -- every frame so it would otherwise immediately re-hide it).
  if not (debugWindow and debugWindow:isEnabled()) then
    Input.SetMouseVisible(false)
  end

  -- Over the open panel the OS cursor is the pointer; no game reticle needed.
  if overPanel then return end

  local cx, cy = self.sx / 2, self.sy / 2
  local c = Color(0.1, 0.5, 1.0, a)
  local x, y
  -- Design: reticle tracks the aim input. With a mouse the aim point is the
  -- cursor (and turrets fire along camera:mouseToRay, so the ring == impact
  -- point on screen). With a controller (no cursor) it tracks the aim stick
  -- (self.aimX/aimY from the thrust controller).
  if Input.GetActiveDeviceType() == DeviceType.Mouse then
    -- GameView's UI pass now scales the whole subtree through the mViewUI
    -- autovar (ss-scaled), so DrawEx coordinates are 1:1 with the OS-window
    -- pixels Input.GetMousePosition returns; the cursor needs no extra ss scale.
    local w  = self.gameView.camera:windowToScreen(Input.GetMousePosition())
    x, y = w.x, w.y
  else
    x = cx + 0.5 * self.sx * (self.aimX or 0)
    y = cy - 0.5 * self.sy * (self.aimY or 0)
  end
  UI.DrawEx.Ring(x, y, 16, c)
end

-- The name of the key a binding is bound to, if it is a plain key.
--
-- The dock prompt used to say "Press ??? to Dock", which is no use at all:
-- the player cannot act on a prompt that does not say which key, and for a
-- JUMPGATE it did not say where the gate went either.
-- The name of the key a binding is bound to, if it is a plain key.
--
-- Button.ToString returns the raw ENUM NAME -- "Button_Keyboard_F" -- so
-- the prefix is stripped: the prompt should say "Press F to Dock", not
-- "Press Button_Keyboard_F to Dock".
local function bindingKeyName (binding)
  local c = binding and binding.control
  if not c then return nil end
  local raw
  if c.key then
    raw = tostring(Button.ToString(c.key))
  elseif c.controls then
    for _, sub in ipairs(c.controls) do
      if sub.key then raw = tostring(Button.ToString(sub.key)) break end
    end
  end
  if not raw then return nil end
  return raw:match('Button_Keyboard_(.+)$')
      or raw:match('Button_Gamepad_(.+)$')
      or raw
end

function HUD:drawDockPrompt (a)
  local x, y, sx, sy = self:getRectGlobal()
  local text = 'Press ??? to Dock'
  local key = bindingKeyName(ShipBindings.Dock)
  if key then text = 'Press ' .. key .. ' to Dock' end

  -- A jumpgate says where it goes. "Press F to Dock" is fine for a station;
  -- for a gate, where you will END UP is the entire question.
  local d = self.dockable
  if d and d.getPartnerName then
    local dest = d:getPartnerName()
    if dest and dest ~= '' then
      text = text .. '  --  ' .. dest
    end
  end

  UI.DrawEx.TextAdditive(
    'NovaMono',
    text,
    16,
    x, y, sx, sy,
    1, 1, 1, self.dockPromptAlpha * a,
    0.5, 0.99
  )
end

function HUD:drawAtmosphereWarning (a)
  local ship = self.player:getControlling()
  if not (ship and ship.atmoWarning) then return end

  local text  = Config.render.planet.atmoBubbleMsg or 'ATMOSPHERE - PULL UP'
  local bound = Cache.Font('NovaMono', 20):getSize(text)

  -- Blink so it reads as an alert, but never fully vanish.
  local blink = 0.65 + 0.35 * math.sin(Time.GetRaw() * 0.012)

  -- LTheory-styled plate: a dark plate + accent border behind bright text.
  -- (Additive red text over a bright nebula was unreadable.)
  local padX, padY = 28, 14
  local bw, bh = bound.z + padX * 2, bound.w + padY * 2
  local x, y, sx, sy = self:getRectGlobal()
  local bx = x + (sx - bw) / 2
  local by = y + sy * 0.10

  UI.DrawEx.PushAlpha(a * blink)
  UI.DrawEx.Panel(bx, by, bw, bh, Color(0.22, 0.015, 0.03, 0.95), 0.6)
  UI.DrawEx.RectOutline(bx, by, bw, bh, Color(1.0, 0.15, 0.25, 1.0))
  UI.DrawEx.TextAlpha('NovaMono', text, 20,
    bx, by, bw, bh,
    1.0, 0.90, 0.88, 1.0,
    0.5, 0.5)
  UI.DrawEx.PopAlpha()
end

function HUD:controlThrust (e)
  if not e:hasThrustController() then return end
  local c = e:getThrustController()
  c:setThrust(
    ShipBindings.ThrustZ:get(),
    ShipBindings.ThrustX:get(),
    0,
    ShipBindings.Yaw:get(),
   -ShipBindings.Pitch:get(),
    ShipBindings.Roll:get(),
    ShipBindings.Boost:get())
  self.aimX = c.yaw
  self.aimY = c.pitch
end

function HUD:controlTurrets (e)
  local targetPos, targetVel
  local target = e:getTarget()
  if target and target:getOwnerDisposition(self.player) <= 0.0 then
    targetPos = target:getPos()
    targetVel = target:getVelocity()
  end

  local firing   = ShipBindings.Fire:get() > 0 and 1 or 0
  local camera   = self.gameView.camera
  -- Reticle/turret parity: mouse aims via cursor (turrets along mouseToRay),
  -- controller has no cursor so aims via stick NDC (turrets along ndcToRay).
  -- drawReticle() uses the same branch, so the ring == impact point in both
  -- cases. Keep mouse path unchanged to avoid regressing KBM.
  local fallback
  if Input.GetActiveDeviceType() == DeviceType.Mouse then
    fallback = camera:mouseToRay(1):getPoint(e.socketRangeMin)
  else
    local ndc = Vec3f(self.aimX or 0, self.aimY or 0)
    fallback = camera:ndcToRay(ndc, 1):getPoint(e.socketRangeMin)
  end

  -- Compute a firing solution separately for each turret to support
  -- different projectile velocities & ranges
  local SocketType = require('Game.SocketKind')
for turret in e:iterSocketsByType(SocketType.Turret) do
    if Config.game.autoTarget and targetPos then
      turret:aimAtTarget(target, fallback)
    else
      turret:aimAt(fallback)
    end
    turret.firing = firing
  end
end

function HUD:controlTargetLock (e)
  if ShipBindings.LockTarget:get() > 0.5 then e:setTarget(self.target) end
  if ShipBindings.ClearTarget:get() > 0.5 then e:setTarget(nil) end
end

function HUD:onInput (state)
  local camera = self.gameView.camera
  camera:push()

  -- Seamless debug panel interaction: while the cursor is over the open panel,
  -- its widgets are interactive (they hold mouse focus), so don't aim/fire the
  -- ship's turrets or zoom the camera from the same mouse position. Only the
  -- panel scrolls its own content.
  local debugWindow = self.gameView.debugWindow
  local overPanel = debugWindow and debugWindow:isEnabled()
                    and debugWindow:containsPoint(state.mousePosX, state.mousePosY)
  -- Modal map: while the node graph is open it owns the mouse, so the ship
  -- holds thrust/aim/fire and the camera holds zoom. Same discipline, wider
  -- gate (open anywhere, not just hovered).
  local nodeGraph = self.gameView.nodeGraph
  local mapOpen = nodeGraph and nodeGraph:isEnabled() or false
  if not overPanel and not mapOpen then
    camera:modRadius(exp(-0.1 * CameraBindings.Zoom:get()))
  end
  -- camera:modYaw(0.005 * CameraBindings.Yaw:get())
  -- camera:modPitch(0.005 * CameraBindings.Pitch:get())

  local e = self.player:getControlling()
  if not mapOpen then self:controlThrust(e) end

  if not overPanel and not mapOpen then self:controlTurrets(e) end

  self:controlTargetLock(e)
  camera:pop()

  if self.dockable then
    if ShipBindings.Dock:get() > 0 then
      local d = self.dockable
      if d.warpOnDock and d.warp then
        -- A JUMPGATE: the ship warps on the spot. The generic dock action
        -- would fly the ship at a point BELOW the dockable, which is right
        -- for a station you pull up to and wrong for a portal you fly into.
        d:warp(e)
      else
        e:pushAction(Actions.DockAt(d))
      end
      self.dockable = nil
    end
  end
end

function HUD:onUpdate (state)
  self.targets:update()
  self.dockables:update()

  -- V opens the map on the GALAXY level, and swaps between the two levels
  -- when it is already open.
  --
  -- It is handled HERE, and not in the map's own input handler, because that
  -- only runs while the map is open -- so pressing V in the game did nothing.
  -- The map's two levels are the SECTOR level (the bodies, the regions, the
  -- gates) and the GALAXY level (the sectors, and the gates between them),
  -- and they are LEVELS of the one node graph rather than two separate maps.
  if Input.GetPressed(Button.Keyboard.V) then
    local graph = self.gameView and self.gameView.nodeGraph
    if graph then
      if not graph:isEnabled() then
        graph:toggleEnabled()
        graph.galaxyLevel = true
      else
        graph.galaxyLevel = not graph.galaxyLevel
      end
      -- The level changed, so the nodes have to be re-seeded from scratch.
      graph.nodes, graph.edges = {}, {}
      graph.focus, graph.follow = nil, nil
      graph._fitted = false
    end
  end

  local f = 1.0 - exp(-state.dt * 8.0)
  local alphaT = self.dockable and 1 or 0
  self.dockPromptAlpha = Math.Lerp(self.dockPromptAlpha, alphaT, f)

  local pPos    = self.player:getControlling():getPos()
  local pRad    = self.player:getControlling():getRadius()
  local minDist = Config.game.dockRange
  self.dockable = nil
  for i = 1, #self.dockables.tracked do
    local dockable = self.dockables.tracked[i]

    local dPos = dockable:getPos()
    local dRad = dockable:getRadius()
    local dist = pPos:distance(dPos) - pRad - dRad
    if dist < minDist then
      minDist = dist
      self.dockable = dockable
    end
  end

  self:updateSectorInfo(pPos)
end

--[[---------------------------------------------------------------------------
  updateSectorInfo -- work out where you are, once per frame.

  Kept out of onDraw because the panel and the bearing marker both need it and
  it must be the SAME answer: a panel saying one region and an arrow pointing
  at another would be worse than neither.

  The heavy part -- the boundary bearing -- is recomputed only every few
  frames. The boundary does not move quickly (the ship crosses one in
  minutes), and the bearing search samples a ring of directions, so a few
  frames of staleness is invisible.
----------------------------------------------------------------------------]]
local BEARING_INTERVAL = 8   -- frames between bearing recomputes

function HUD:updateSectorInfo (shipPos)
  local app = self.gameView and self.gameView.ltheory
  local system = app and app.system
  if not (system and shipPos) then
    self.sectorInfo = nil
    return
  end

  -- The sector state is computed ONCE per frame, by the app, and shared with
  -- the map -- so the panel and the map can never disagree about which
  -- region you are in. (The HUD computes its own copy only if the app has
  -- not provided one, which keeps the HUD usable on its own.)
  local st = app.sectorState
  if not st then
    st = Sector.state(app.seed or Seed.get(), shipPos.x, shipPos.y, shipPos.z)
  end

  local region = st.region
  if not region then
    self.sectorInfo = nil
    return
  end

  -- The boundary bearing, recomputed on an interval.
  self.bearingTick = (self.bearingTick or 0) + 1
  if not self.bearingDir or self.bearingTick >= BEARING_INTERVAL then
    self.bearingTick = 0
    -- The direction and the distance to the nearest boundary come from the
    -- same call: the boundary is an Apollonius surface, so both fall out of
    -- one closed-form computation (see Game/Region.lua).
    self.bearingDir  = st.boundaryDir
    self.bearingDist = st.boundaryDist
    -- Whether the position is still inside the sector. Past the edge the
    -- marker points BACK, because there is nothing out there yet.
    self.bearingInside = st.boundaryInside
  end

  local boundaryDist = self.bearingDist

  local info = self.sectorInfo or {}
  info.sectorLabel  = st.sectorName
  info.regionLabel  = region.name
  info.archetypeLabel = region.archetype and region.archetype.name or ''
  info.bearingDir   = self.bearingDir
  info.bearingDist  = boundaryDist
  -- The map shows the region the PLAYER is in, so the two always agree.
  info.mapRegion    = region

  -- The bearing readout: how far the nearest boundary is. Always shown when
  -- there IS a boundary -- the arrow points at it, so the number belongs
  -- beside it. The earlier version hid it beyond 12 km, which meant the
  -- line was usually absent exactly when the player was looking for it.
  if boundaryDist then
    if self.bearingInside == false then
      -- Past the sector edge. There is NOTHING out there yet -- no jumpgates
      -- exist -- so the useful thing to say is that you are out of the
      -- sector, and the arrow points back in (the bearing direction is
      -- flipped to face the boundary once you are past it).
      info.bearingLabel = 'outside the sector'
    else
      info.bearingLabel = string.format('%.0f km to boundary', boundaryDist / 1000)
    end
  else
    info.bearingLabel = ''
  end

  -- The nearest gate and where it leads.
  --
  -- This is the "how do I get out of here" line. The panel carries it
  -- ALWAYS, so the player never has to open the map and hunt for a gate,
  -- and never has to guess where a gate leads -- which is the thing the
  -- map could not tell them on its own.
  local ng = st.nearestGate
  if ng and ng.name then
    local what = (ng.kind == 'region') and 'gate to' or 'jumpgate to'
    info.gateLabel = string.format('Nearest %s %s  %.0f km',
                                   what, ng.name, ng.dist / 1000)
  else
    info.gateLabel = ''
  end

  -- The nearest LANE. A lane is the intra-sector transport, and it is hard
  -- to find -- so the panel says where the nearest one is.
  local nl = st.nearestLane
  if nl and nl.name then
    info.laneLabel = string.format('Nearest lane to %s  %.0f km',
                                   nl.name, nl.dist / 1000)
  else
    info.laneLabel = ''
  end

  self.sectorInfo = info
end

--[[---------------------------------------------------------------------------
  The HUD is a Container, so its children (the icon button, and the sector
  panel) need the standard layout and update hooks. The HUD draws its HUD
  elements straight into the UI pass, so it overrides onDraw -- which means it
  has to drive the children's update and layout ITSELF, or they never poll
  their content and never get positioned.
----------------------------------------------------------------------------]]
function HUD:onUpdateChildren (state)
  Container.onUpdateChildren(self, state)
end

function HUD:onLayoutSizeChildren ()
  Container.onLayoutSizeChildren(self)
end

function HUD:onLayoutPosChildren ()
  Container.onLayoutPosChildren(self)
end

function HUD:onDraw (focus, active)
  Profiler.Begin('HUD.DrawTargets') self:drawTargets   (self.enabled) Profiler.End()
  Profiler.Begin('HUD.DrawLock')    self:drawLock      (self.enabled) Profiler.End()
  Profiler.Begin('HUD.DrawReticle') self:drawReticle   (self.enabled) Profiler.End()
  Profiler.Begin('HUD.DrawPrompt')  self:drawDockPrompt(self.enabled) Profiler.End()
  Profiler.Begin('HUD.AtmoWarn')    self:drawAtmosphereWarning(self.enabled) Profiler.End()
  Profiler.Begin('HUD.DrawSector')  self:drawSectorPanel(self.enabled) Profiler.End()
  Profiler.Begin('HUD.DrawRegion')  self:drawRegionBearing(self.enabled) Profiler.End()
  -- The HUD's own widgets (the icon button, and the sector panel added as a
  -- child) are drawn LAST, on top of the world-space overlay. The HUD draws
  -- its HUD elements straight into the UI pass, so the children have to be
  -- drawn explicitly -- Container:onDraw is what does that, and overriding
  -- onDraw without calling it leaves every child invisible.
  Container.onDraw(self, focus, active)
end

--[[---------------------------------------------------------------------------
  drawSectorPanel -- the upper-left readout of where you are.

  Phase A of the region work: name the place you are in. Without it a region
  is a NUMBER in a field, and crossing one changes nothing you can see or
  read.

  The panel itself is a UI.SectorPanel widget (see script/UI/SectorPanel.lua)
  added as a child of the HUD, so it lays itself out and picks up the theme.
  This function only keeps its content up to date.
----------------------------------------------------------------------------]]
function HUD:drawSectorPanel (a)
  local panel = self.sectorPanel
  if not panel then return end
  panel.alpha = a
end

--[[---------------------------------------------------------------------------
  drawRegionBearing -- an arrow toward the nearest region boundary.

  Phase B of the region work, and the answer to "which way do I fly?".

  The idiom is the one the sun marker already established (GameView:drawSunMarker):
  project the direction, and when it falls outside the view rect, CLAMP it to
  the edge so it reads as a bearing rather than disappearing. A marker that
  vanishes exactly when you need it is worse than no marker.

  This works at ANY distance, because the boundary is defined by the FIELD --
  a pure function of position -- and not by geometry. That matters: a region
  is far larger than the visible reach of the medium (the volumetric march
  stops at ~14k units; a region spans far more), so a marker that only
  worked for boundaries you could SEE would be useless most of the time.
----------------------------------------------------------------------------]]
function HUD:drawRegionBearing (a)
  local info = self.sectorInfo
  if not info or not info.bearingDir or a <= 0.01 then return end

  local camera = self.gameView.camera
  local w, h = camera.sx, camera.sy
  if not (w and h and w > 1 and h > 1) then return end

  -- The bearing direction is a WORLD direction. Project it far away so it
  -- lands at the right screen position.
  local dir = info.bearingDir
  local far = camera.pos + Vec3f(dir.x, dir.y, dir.z):normalize():muls(1e5)
  local ndc = camera:worldToNDC(far)
  if not (ndc and ndc.z and ndc.z > 0) then return end
  local s = camera:ndcToScreen(ndc)
  local cx, cy = tonumber(s and s.x), tonumber(s and s.y)
  if not (cx and cy and cx == cx and cy == cy) then return end

  -- Rim clamp, exactly as the sun marker does it: clamp each axis by the
  -- scale that puts it on the edge, and take the SMALLER, so the marker
  -- exits through the nearest edge and keeps its bearing.
  local inset = 40
  local mx, my = w * 0.5, h * 0.5
  local dx, dy = cx - mx, cy - my
  local halfW, halfH = mx - inset, my - inset
  local scaleW = dx ~= 0 and (halfW / math.abs(dx)) or 1e30
  local scaleH = dy ~= 0 and (halfH / math.abs(dy)) or 1e30
  local edge = math.min(scaleW, scaleH)
  local offScreen = edge < 1.0
  if offScreen then
    cx, cy = mx + dx * edge, my + dy * edge
  end

  -- The arrow points the way you would fly to reach the boundary.
  local ang = math.atan2(dy, dx)
  local r = offScreen and 16 or 12
  local alpha = a * (offScreen and 0.85 or 0.6)

  -- A small chevron, drawn in the UI pass (screen space), so it reads as an
  -- instrument rather than as part of the world.
  local nx, ny = -math.sin(ang), math.cos(ang)
  local px, py = math.cos(ang), math.sin(ang)
  UI.DrawEx.PushAlpha(alpha)
  for i = -1, 1 do
    local o = i * 5
    UI.DrawEx.Line(cx + px * r + nx * o, cy + py * r + ny * o,
                   cx + px * (r * 0.45), cy + py * (r * 0.45),
                   Color(0.55, 0.75, 0.95, 1))
  end
  UI.DrawEx.PopAlpha()
end

function HUD:onDrawIcon (iconButton, focus, active)
  local borderColor = iconButton == active
                      and Config.ui.color.controlActive
                      or iconButton == focus
                         and Config.ui.color.controlFocused
                         or Config.ui.color.control
  local contentColor = self:isEnabled()
                       and Config.ui.color.controlFocused
                       or Config.ui.color.control

  local x, y, sx, sy = iconButton:getRectGlobal()
  UI.DrawEx.RectOutline(x, y, sx, sy, borderColor)

  local cx = x + sx/2
  local w1y, w1sx, w1sy = 10, 10, 8
  local w2y, w2sx, w2sy =  0,  5, 4
  local ty, by = y + 8, y + sy - 12
  UI.DrawEx.Line(cx,     ty,       cx,        by,              contentColor)
  UI.DrawEx.Line(cx + 2, ty + w1y, cx + w1sx, ty + w1y + w1sy, contentColor)
  UI.DrawEx.Line(cx - 2, ty + w1y, cx - w1sx, ty + w1y + w1sy, contentColor)
  UI.DrawEx.Line(cx + 2, by,       cx + w2sx, by + w2y + w2sy, contentColor)
  UI.DrawEx.Line(cx - 2, by,       cx - w2sx, by + w2y + w2sy, contentColor)
end

function HUD.Create (gameView, player)
  local self = setmetatable({
    gameView        = gameView,
    player          = player,
    icon            = UI.Icon(),

    target          = nil,
    targets         = TrackingList(player, Entity.isAlive),

    -- TODO Probably want a reusable prompt thing
    dockPromptAlpha = 0,
    dockable        = nil,
    dockables       = TrackingList(player, Entity.hasDockable),
    aimX            = 0,
    aimY            = 0,
    impacts         = 0,

    children  = List(),
  }, HUD)

  -- The sector/region readout, in the upper left. It is a UI widget (not raw
  -- draw calls) so it lays itself out and picks up the theme colours; see
  -- script/UI/SectorPanel.lua.
  self.sectorPanel = UI.SectorPanel()
  -- The panel reads the info through a FUNCTION, not a field: the panel's
  -- labels poll their text during the panel's own update, and the HUD's update
  -- (which computes the info) can land either side of that in the UI tree's
  -- update and draw passes. A function is read when the text is generated, so
  -- the ordering cannot leave the panel a frame stale -- and the very first
  -- frame cannot leave it empty.
  self.sectorPanel.infoFn = function () return self.sectorInfo end
  -- `add`, not `addImmediate`: `add` queues the child with the canvas, and
  -- the canvas flushes that queue (Canvas:DeferredAddRemove) at the top of
  -- every update -- so the panel joins the tree on the next frame. Adding it
  -- directly would bypass the canvas's widget bookkeeping.
  self:add(self.sectorPanel)

  self.icon:setOnDraw(function (ib, focus, active)
    self:onDrawIcon(ib, focus, active)
  end)
  self.targets:update()
  self.dockables:update()
  return self
end

return HUD
