local GameView = {}
GameView.__index  = GameView
setmetatable(GameView, UI.Container)

GameView.name = 'Game View'
local ssTable = { 1, 2, 4 }
local Batcher = require('Game.Batcher')

-- PHX_DEBUG_DUMP=<frame> : save pipeline checkpoints to PNGs once, at that frame.
-- Set PHX_DEBUG_DUMP=120 to snapshot ~2s after boot.
local dumpTargetFrame = tonumber(os.getenv('PHX_DEBUG_DUMP') or '')

-- AO render targets: color-only buffers (no depth attachment), clamped + linear,
-- cleared once so the FBO is complete. Half-res R8/16F for passes 1-2, full-res
-- R8 for the final depth-aware upsample.
local function aoTarget (w, h, format)
  local t = Tex2D.Create(w, h, format)
  t:setMagFilter(TexFilter.Linear)
  t:setMinFilter(TexFilter.Linear)
  t:setWrapMode(TexWrapMode.Clamp)
  t:push()
  Draw.Clear(0, 0, 0, 0)
  t:pop()
  return t
end


-- Point-light shadow maps (item #3). For each light we render the opaque world
-- into a Depth32F texture using an ortho frustum centered on the light and
-- aligned with the light->camera direction, then sample it in point.glsl with a
-- PCF test. Cached per entity so the texture is built once per frame.
local function shadowSize (sx, sy)
  local scale = math.min(1024 / sx, 1024 / sy)
  return math.max(256, math.floor(sx * scale)), math.max(256, math.floor(sy * scale))
end

function GameView:buildShadowFrustum (lightPos, eye, halfSize)
  -- View +Z = light->camera direction so visible geometry lands near +Z and the
  -- stored depth tracks distance-from-light. x/y are any orthonormal complement.
  -- Floor the camera-to-light distance: when you fly right up to the ship (which is
  -- your light) that vector collapses to ~0 and normalize() would assert; fall back
  -- to +Y so shadows still compute instead of crashing.
  local d = (eye - lightPos):length()
  local z = Vec3f(0, math.max(d, 1e-4), 0):normalize()
  local ref = (math.abs(z.y) < 0.999) and Vec3f(0, 1, 0) or Vec3f(1, 0, 0)
  local x = (ref:cross(z)):normalize()
  local y = (z:cross(x)):normalize()
  local view = Matrix.FromBasis(x, y, z):product(Matrix.Translation(-lightPos.x, -lightPos.y, -lightPos.z))

  -- Ortho box [L-h, L+h]^3. Depth encodes distance-from-light along +Z; bias in
  -- point.glsl compensates for off-axis geometry (which has a smaller Z component).
  local proj = Matrix.Ortho(-halfSize, halfSize, -halfSize, halfSize, 0.1, 2 * halfSize)
  return view:product(proj)
end

-- Render per-light shadow maps into Depth32F textures (called before the light passes).
function GameView:renderShadows (world, lights)
  local eye = self.camera.pos
  self.shadowTexts = {}
  self.shadowProjs = {}
  for i, light in ipairs(lights) do
    local tex = self.shadowTexts[light.entity]

    -- Create/cache a Depth32F shadow map at screen-scaled resolution. Cleared to
    -- the far plane (depth 1) right before rendering below.
    if not tex then
      local sw, sh = shadowSize(self.sx, self.sy)
      tex = Tex2D.Create(sw, sh, TexFormat.Depth32F)
      tex:setMinFilter(TexFilter.Linear)
      tex:genMipmap()
      self.shadowTexts[light.entity] = tex
    end

    -- Ortho frustum centered on the light; its combined view-proj is reused by
    -- point.glsl to map each fragment into shadow-map UV space. Using `lp` (the
    -- final lit position, incl. the +5 lift) keeps this identical to the sampling pass.
    local halfSize = math.max((eye - light.lp):length() * 0.5, 100000)
    local proj = self:buildShadowFrustum(light.lp, eye, halfSize)
    self.shadowProjs[light.entity] = proj

    -- Push a fresh FBO and bind only the Depth32F tex as the depth attachment so
    -- world:render() records distance-from-light (set below via `eye`).
    RenderTarget.Push(self.sx, self.sy)
    RenderTarget.BindTex2D(tex)   -- Depth32F is not a color format -> depth only

    ShaderVar.PushMatrix('mView', proj)
    ShaderVar.PushMatrix('mProj', Matrix.Identity())
    -- setDepth() stores length(worldPos - eye); override eye with the light so the
    -- shadow map records distance-from-light (not camera distance).
    ShaderVar.PushFloat3('eye', light.lp.x, light.lp.y, light.lp.z)
    BlendMode.PushDisabled()
    CullFace.Push(CullFace.Back)
    RenderState.PushDepthTest(true)
    RenderState.PushDepthWritable(true)

    Draw.ClearDepth(1)            -- clear depth to far plane (shadow map init)

    world:render(Event.Render(BlendMode.Disabled, eye))

    RenderState.PopDepthWritable()
    RenderState.PopDepthTest()
    CullFace.Pop()
    BlendMode.Pop()
    ShaderVar.Pop('mView')
    ShaderVar.Pop('mProj')
    ShaderVar.Pop('eye')
    RenderTarget.Pop()
  end
end


-- Whole-scene sun shadow map, sampled in light/dir.glsl. One Depth32F render of
-- the opaque world with the ortho box centered on the camera and +Z along
-- -starDir (the scene as the sun sees it). The depth is encoded in the same
-- distance-from-origin style as the point lights, so dir.glsl compares against
-- the camera-centered radial distance; only the direct (non-ambient) sun term
-- is killed. Higher resolution than the point lights since it is shared by ALL
-- pixels rather than one light's neighborhood.
local function sunShadowSize (sx, sy)
  local scale = math.min(2048 / sx, 2048 / sy)
  return math.max(256, math.floor(sx * scale)), math.max(256, math.floor(sy * scale))
end

function GameView:renderSunShadow (world)
  if not self.sunShadowTex then
    local sw, sh = sunShadowSize(self.sx, self.sy)
    self.sunShadowTex = Tex2D.Create(sw, sh, TexFormat.Depth32F)
    self.sunShadowTex:setMinFilter(TexFilter.Linear)
    self.sunShadowTex:genMipmap()
  end

  -- Box half-size covers the visible field; centered on the camera so the
  -- near-ship region (where the player flies) is the map's highest-res heart.
  local range = Settings.get('render.sun.shadowRange') or 8000
  local sd = Vec3f(world.starDir.x, world.starDir.y, world.starDir.z):normalize()
  self.sunShadowCenter = self.camera.pos
  local proj = self:buildShadowFrustum(self.sunShadowCenter, self.sunShadowCenter - sd, range)
  self.sunShadowProj = proj

  RenderTarget.Push(self.sx, self.sy)
  RenderTarget.BindTex2D(self.sunShadowTex)   -- Depth32F -> depth attachment only

  ShaderVar.PushMatrix('mView', proj)
  ShaderVar.PushMatrix('mProj', Matrix.Identity())
  -- setDepth() stores length(worldPos - eye); anchor eye at the box center so the
  -- map records distance-from-center, matching dir.glsl's radial comparison.
  ShaderVar.PushFloat3('eye', self.sunShadowCenter.x, self.sunShadowCenter.y, self.sunShadowCenter.z)
  BlendMode.PushDisabled()
  CullFace.Push(CullFace.Back)
  RenderState.PushDepthTest(true)
  RenderState.PushDepthWritable(true)

  Draw.ClearDepth(1)            -- far plane

  world:render(Event.Render(BlendMode.Disabled, self.sunShadowCenter))

  RenderState.PopDepthWritable()
  RenderState.PopDepthTest()
  CullFace.Pop()
  BlendMode.Pop()
  ShaderVar.Pop('mView')
  ShaderVar.Pop('mProj')
  ShaderVar.Pop('eye')
  RenderTarget.Pop()
end


-- GTAO chain: aoview (half-res view rays + NdotV) -> ao (naive horizon
-- integral, half-res) -> aoblur (full-res depth-aware upsample + denoise).
-- Ambient-only by construction: only light/global.glsl consumes texAO, so the
-- sun and point lights are untouched. See ssao-gtao-implementation.md.
function GameView:renderAO ()
  local r = self.renderer
  local sx, sy = r.sx, r.sy

  local q = Settings.get('ssao.quality') or 2
  local k = (q <= 1) and 1 or ((q == 2) and 2 or 4)
  local aoW = math.max(1, math.floor(sx / k))
  local aoH = math.max(1, math.floor(sy / k))
  local aoMip = math.log(math.max(1, sx / aoW)) / math.log(2)

  -- (Re)create the half-res targets on resolution/quality change.
  if not self.aoView or self.aoView:getSize().x ~= aoW then
    if self.aoView then
      self.aoView:free()
      self.aoRaw:free()
    end
    self.aoView = aoTarget(aoW, aoH, TexFormat.RGBA16F)
    self.aoRaw  = aoTarget(aoW, aoH, TexFormat.R8)
  end
  -- Full-res composite texture (what global.glsl samples).
  if not self.aoFull or self.aoFull:getSize().x ~= sx then
    if self.aoFull then self.aoFull:free() end
    self.aoFull = aoTarget(sx, sy, TexFormat.R8)
  end
  -- 1x1 white fallback bound whenever the AO chain is off.
  if not self.aoWhite then
    self.aoWhite = aoTarget(1, 1, TexFormat.R8)
    self.aoWhite:push()
    Draw.Color(1, 1, 1, 1)
    Draw.Rect(0, 0, 1, 1)
    self.aoWhite:pop()
  end

  Profiler.Begin('Render.AO')

  do -- Pass 1: per-pixel view ray + NdotV (half-res)
    local shader = Cache.Shader('worldray', 'filter/aoview')
    if shader then
      RenderTarget.Push(aoW, aoH)
      RenderTarget.BindTex2D(self.aoView)
      shader:start()
      Shader.SetTex2D('texDepth', r.zBufferL)
      Shader.SetTex2D('texNormalMat', r.buffer1)
      Shader.SetFloat('aoMip', aoMip)
      Draw.Rect(-1, -1, 2, 2)
      shader:stop()
      RenderTarget.Pop()
    end
  end

  do -- Pass 2: horizon integral -> aoRaw (half-res). Fullscreen vertex (ui):
    -- this pass needs only uv + its own mView/mProj uniforms — no world rays.
    local shader = Cache.Shader('ui', 'filter/ao')
    if shader then
      local dirs  = { 2, 4, 6, 8 }
      local steps = { 2, 3, 4, 6 }
      RenderTarget.Push(aoW, aoH)
      RenderTarget.BindTex2D(self.aoRaw)
      shader:start()
      Shader.SetTex2D('texView', self.aoView)
      Shader.SetTex2D('texNormalMat', r.buffer1)
      Shader.SetTex2D('texDepth', r.zBufferL)
      Shader.SetFloat('aoRadius',   Settings.get('ssao.radius') or 500)
      Shader.SetFloat('aoIntensity', Settings.get('ssao.intensity') or 1)
      Shader.SetFloat('aoMip',      aoMip)
      Shader.SetFloat('aoSpacing',  1.0 / 3.0)
      Shader.SetFloat('thickness',  Settings.get('ssao.thickness') or 0.25)
      Shader.SetFloat('timeSeed',   (r.frameSeed or 0) + 1)
      Shader.SetInt  ('dirCount',   dirs[Settings.get('ssao.directions')] or 4)
      Shader.SetInt  ('stepCount',  steps[Settings.get('ssao.steps')] or 3)
      Draw.Rect(0, 0, aoW, aoH)
      shader:stop()
      RenderTarget.Pop()
    end
  end

  do -- Pass 3: full-res depth-aware upsample + denoise -> aoFull
    local shader = Cache.Shader('ui', 'filter/aoblur')
    if shader then
      local rad = Settings.get('ssao.radius') or 500
      RenderTarget.Push(sx, sy)
      RenderTarget.BindTex2D(self.aoFull)
      shader:start()
      Shader.SetTex2D('texAO', self.aoRaw)
      Shader.SetTex2D('texDepth', r.zBufferL)
      Shader.SetFloat('aoMip', aoMip)
      Shader.SetFloat('aoBlurScale', 8.0 / math.max(1e-3, rad * rad))
      Draw.Rect(0, 0, sx, sy)
      shader:stop()
      RenderTarget.Pop()
    end
  end

  Profiler.End()
end

function GameView:draw (focus, active)
  if dumpTargetFrame then
    GameView.__dumpFrame = (GameView.__dumpFrame or 0) + 1
    if GameView.__dumpFrame == dumpTargetFrame then
      local function mkDump (name)
        return function (tex)
          Tex2D.Save(tex, 'dump_' .. name .. '.png')
          print('[DUMP] saved dump_' .. name .. '.png')
        end
      end
      GameView.__dumpGBuffer = function ()
        mkDump('1_gbuffer_albedo')(self.renderer.buffer0)
        mkDump('1b_gbuffer_normalmat')(self.renderer.buffer1)
        mkDump('1c_zbufferL')(self.renderer.zBufferL)
        GameView.__dumpGBuffer = nil
      end
      GameView.__dumpLit = function ()
        mkDump('2_lit')(self.renderer.buffer1)
        GameView.__dumpLit = nil
      end
      GameView.__dump = function ()
        mkDump('3_final')(self.renderer.buffer0)
        GameView.__dump = nil
      end
    end
  end
  self.camera:push()

  local ss = ssTable[Settings.get('render.superSample')]
  local x, y, sx, sy = self:getRectGlobal()
  ClipRect.PushDisabled()
  RenderState.PushAllDefaults()
  self.camera:setViewport(x, y, sx, sy)
  self.camera:beginDraw()

  local world = self.player:getRoot()
  -- If the player died and sweepDestroyed detached it from the system,
  -- getRoot() returns the orphaned player, which has no world methods.
  -- Skip drawing instead of erroring every frame (death handling TODO).
  if world == self.player or not world.beginRender then
    ClipRect.PopDisabled()
    RenderState.PopAllDefaults()
    self.camera:endDraw()
    Profiler.End()
    return
  end
  local eye = self.camera.pos
  world:beginRender()

  -- Sun: warm directional light + ambient fill, driven from render.sun.settings.
  -- Pushed unconditionally so shaders declaring these autovars always find them;
  -- with the sun disabled the color is black (zero contribution) and the
  -- directional pass below is skipped.
  local sUn = Settings.get('render.sun.enable')
  local sunCol, sunFill
  if sUn then
    local si = Settings.get('render.sun.intensity') or 1
    local sw = Settings.get('render.sun.warmth') or 1
    -- Blend white (warmth=0) toward warm starColor orange (1, .6, .2) (warmth=1),
    -- then scale by intensity. Vec3 overloads are componentwise, so do it by hand.
    local mx = 1 * (1 - sw) + 1.0 * sw
    local my = 1 * (1 - sw) + 0.6 * sw
    local mz = 1 * (1 - sw) + 0.2 * sw
    sunCol = Vec3f(mx * si, my * si, mz * si)
    sunFill = Settings.get('render.sun.fill') or 0.12
  else
    sunCol, sunFill = Vec3f(0, 0, 0), 0
  end
  ShaderVar.PushFloat3('sunColor', sunCol.x, sunCol.y, sunCol.z)
  ShaderVar.PushFloat ('sunFill',  sunFill)

  do -- Texture-filter quality (Bilinear/Trilinear/Aniso): re-apply only on change
    local tf = Settings.get('render.textureFilter')
    if tf ~= self.appliedTextureFilter then
      self.appliedTextureFilter = tf
      self.renderer:setTextureFilter(tf)
    end
  end

  -- Live render-pass timings for the debug panel (see DebugWindow Profiling).
  local rtl = self.renderTimes
  rtl.t0 = TimeStamp.Get()

  Profiler.Begin('Render.Submit')
  do -- Opaque Pass
    Profiler.Begin('Render.Opaque')
    self.renderer:start(self.sx, self.sy, ss)
    Batcher.begin()
    RenderState.PushWireframe(Settings.get('render.wireframe'))
    world:render(Event.Render(BlendMode.Disabled, eye))
    Batcher.replay()
    RenderState.PopWireframe()
    self.renderer:stop()
    Profiler.End()
  end
  if GameView.__dumpGBuffer then GameView.__dumpGBuffer() end

  do -- Lighting
    -- Gather light sources (entity, world pos, final lit pos incl. +5 lift, color)
    local lights = {}
    for i, v in world:iterChildren() do
      if v:hasLight() then
        insert(lights, { entity = v, pos = v:getPos(), lp = Vec3f(v:getPos().x, v:getPos().y + 5, v:getPos().z), color = v:getLight() })
      end
    end

    do -- GTAO: screen-space ambient occlusion (ambient-only, before the global pass)
      if Settings.get('ssao.enable') then
        self:renderAO(world)
      end
    end

    do -- Global lighting (environment)
      local shader = Cache.Shader('worldray', 'light/global')
      if shader then
        self.renderer.buffer2:push()
        Draw.Clear(0, 0, 0, 0)
        shader:start()
        Shader.SetTex2D('texDepth', self.renderer.zBufferL)
        Shader.SetTex2D('texNormalMat', self.renderer.buffer1)
        Shader.SetFloat('envScale', Settings.get('lighting.ambientEnv') or 1)
        if self.aoFull then
          Shader.SetTex2D('texAO', self.aoFull)
          Shader.SetFloat('aoStrength', Settings.get('ssao.intensity') or 1)
          Shader.SetFloat('aoShow', Settings.get('ssao.show') and 1 or 0)
        else
          -- AO off: bind the white fallback (or any texture — aoStrength 0 kills it)
          Shader.SetTex2D('texAO', self.aoWhite or self.renderer.zBufferL)
          Shader.SetFloat('aoStrength', 0)
          Shader.SetFloat('aoShow', 0)
        end
        Draw.Rect(-1, -1, 2, 2)
        shader:stop()
        self.renderer.buffer2:pop()
      end
    end

    do -- Direct sunlight (directional, additive over the ambient)
      if sUn then
        local shader = Cache.Shader('worldray', 'light/dir')
        if shader then
          if Settings.get('render.sun.shadows') then
            self:renderSunShadow(world)
          end
          self.renderer.buffer2:push()
          BlendMode.PushAdditive()
          shader:start()
          Shader.SetFloat3('lightColor', sunCol.x, sunCol.y, sunCol.z)
          Shader.SetFloat ('materialSpec', Settings.get('lighting.specular') or 0.35)
          Shader.SetTex2D('texDepth', self.renderer.zBufferL)
          Shader.SetTex2D('texNormalMat', self.renderer.buffer1)
          if self.sunShadowTex then
            Shader.SetTex2D('texShadow', self.sunShadowTex)
            Shader.SetMatrix ('sShadowProj', self.sunShadowProj)
            Shader.SetFloat  ('sShadowBias',   Settings.get('render.shadow.bias') or 0.001)
            Shader.SetFloat  ('sShadowScale',  Settings.get('render.shadow.scale') or 0.0005)
            Shader.SetFloat  ('sShadowRadius', Settings.get('render.shadow.radius') or 2.0)
            Shader.SetFloat3 ('sunShadowCenter', self.sunShadowCenter.x, self.sunShadowCenter.y, self.sunShadowCenter.z)
          end
          Draw.Rect(-1, -1, 2, 2)
          shader:stop()
          BlendMode.Pop()
          self.renderer.buffer2:pop()
        end
      end
    end

    do -- Local lighting (build per-light shadow maps first)
      self:renderShadows(world, lights)
      local shader = Cache.Shader('worldray', 'light/point')
      if shader then
        self.renderer.buffer2:push()
        BlendMode.PushAdditive()
        shader:start()
        for i, v in ipairs(lights) do
          -- TODO : Batching
          local lightPos = v.lp

          -- Cache the per-light shadow map built by renderShadows(); skip a
          -- broken/missing one instead of drawing black.
          local stex = self.shadowTexts[v.entity]
          local sproj = self.shadowProjs[v.entity]

          Shader.SetFloat3('lightColor', v.color.x, v.color.y, v.color.z)
          Shader.SetFloat3('lightPos', lightPos.x, lightPos.y, lightPos.z)
          Shader.SetFloat ('materialSpec', Settings.get('lighting.specular') or 0.35)
          if stex then
            Shader.SetTex2D('texShadow', stex)
            Shader.SetMatrix ('sShadowProj', sproj)
            Shader.SetFloat  ('sShadowBias',   Settings.get('render.shadow.bias') or 0.001)
            Shader.SetFloat  ('sShadowScale',  Settings.get('render.shadow.scale') or 0.0005)
            Shader.SetFloat  ('sShadowRadius', Settings.get('render.shadow.radius') or 2.0)
          end
          Shader.SetTex2D('texDepth', self.renderer.zBufferL)
          Shader.SetTex2D('texNormalMat', self.renderer.buffer1)
          Draw.Rect(-1, -1, 2, 2)
        end
        shader:stop()
      BlendMode.Pop()
      self.renderer.buffer2:pop()
    end
  end

    do -- Composite albedo & accumulated light buffer
      local shader = Cache.Shader('worldray', 'light/composite')
      if shader then
        self.renderer.buffer1:push()
        shader:start()
        Shader.SetTex2D('texAlbedo', self.renderer.buffer0)
        Shader.SetTex2D('texDepth', self.renderer.zBufferL)
        Shader.SetTex2D('texLighting', self.renderer.buffer2)
        Draw.Rect(-1, -1, 2, 2)
        shader:stop()
        self.renderer.buffer1:pop()
      end
      if GameView.__dumpGBuffer then GameView.__dumpLit() end
    end

    self.renderer.buffer0, self.renderer.buffer1 = self.renderer.buffer1, self.renderer.buffer0
  end

  if true then -- Alpha (Additive) Pass
    self.renderer:startAlpha(BlendMode.Additive)
      RenderState.PushWireframe(Settings.get('render.wireframe'))
        world:render(Event.Render(BlendMode.Additive, eye))
      RenderState.PopWireframe()
    self.renderer:stopAlpha()
  end

  if true then -- Alpha Pass
    self.renderer:startAlpha(BlendMode.Alpha)
      RenderState.PushWireframe(Settings.get('render.wireframe'))
        world:render(Event.Render(BlendMode.Alpha, eye))
      RenderState.PopWireframe()

      -- TODO : This should be moved into a render pass
      if Config.debug.physics.drawBoundingBoxesLocal or
         Config.debug.physics.drawBoundingBoxesWorld or
         Config.debug.physics.drawWireframes or
         Config.debug.physics.drawTriggers
      then
        local mat = Material.DebugColorA()
        mat:start()
        if Config.debug.physics.drawBoundingBoxesLocal then
          Shader.SetFloat4('color', 0, 0, 1, 0.5)
          world.physics:drawBoundingBoxesLocal()
        end
        if Config.debug.physics.drawBoundingBoxesWorld then
          Shader.SetMatrix ('mWorld',   Matrix.Identity())
          Shader.SetMatrixT('mWorldIT', Matrix.Identity())
          Shader.SetFloat('scale', 1)
          Shader.SetFloat4('color', 1, 0, 0, 0.5)
          world.physics:drawBoundingBoxesWorld()
        end
        if Config.debug.physics.drawTriggers then
          Shader.SetMatrix ('mWorld',   Matrix.Identity())
          Shader.SetMatrixT('mWorldIT', Matrix.Identity())
          Shader.SetFloat('scale', 1)
          Shader.SetFloat4('color', 1, 0.5, 0, 0.5)
          world.physics:drawTriggers()
        end
        if Config.debug.physics.drawWireframes then
          Shader.SetMatrix ('mWorld',   Matrix.Identity())
          Shader.SetMatrixT('mWorldIT', Matrix.Identity())
          Shader.SetFloat('scale', 1)
          Shader.SetFloat4('color', 0, 1, 0, 0.5)
          world.physics:drawWireframes()
        end
        mat:stop()
      end
    self.renderer:stopAlpha()
  end

  world:endRender()
  ShaderVar.Pop('sunColor')
  ShaderVar.Pop ('sunFill')
  self.camera:endDraw()
  rtl.submit = TimeStamp.GetElapsedMs(rtl.t0)
  Profiler.End() -- Render.Submit

  if true then -- Composited UI Pass (drawn into the dedicated UI buffer, layered
    -- over the post chain at the end so the HUD/debug panel stays crisp and is
    -- not affected by tonemap/exposure/bloom/vignette/sharpen/grain).
    self.renderer:startUI(self.renderer.uiBuffer)
      Viewport.Push(0, 0, ss * self.sx, ss * self.sy, true)
      ClipRect.PushTransform(0, 0, ss, ss)
        -- ui.glsl transforms via mProjUI * mViewUI (not the GLMatrix modelview,
        -- which had no effect here), so the layout's logical-pixel rects must be
        -- ss-scaled through the mViewUI autovar to come out 1:1 after the
        -- ss-buffer present.
        local uiScale = Matrix.Scaling(ss, ss, 1)
        ShaderVar.PushMatrix('mViewUI', uiScale)
          for i = 1, #self.children do self.children[i]:draw(focus, active) end
        ShaderVar.Pop('mViewUI')
        uiScale:free()
      ClipRect.PopTransform()
      Viewport.Pop()
    self.renderer:endUI()
  end

  do -- Post chain + present (UI composite, post-fx passes, buffer swap); timing only
    Profiler.Begin('Render.PostFx')
    rtl.t1 = TimeStamp.Get()
  if false or Settings.get('render.showBuffers') then
    self.renderer:compositeUI()   -- HUD/debug over the (raw) scene, as before
    Profiler.Begin('Render.Present')
    local tPres = TimeStamp.Get()
    self.renderer:presentAll(x, y, sx, sy)
    rtl.present = TimeStamp.GetElapsedMs(tPres)
    Profiler.End()
  else
    self.renderer:startPostEffects()
    if Settings.get('postfx.bloom.enable') then self.renderer:bloom(Settings.get('postfx.bloom.radius')) end
    -- HDR exposure meter: reads the pre-tonemap scene into a 1x1 texel for the
    -- debug-panel readout and auto-exposure. Must run before tonemap's swap.
    self.renderer:meter()
    if Settings.get('postfx.tonemap.enable') then self.renderer:tonemap() end
    if Settings.get('postfx.vignette.enable') then self.renderer:vignette() end
    if Settings.get('postfx.aberration.enable') then
      self.renderer:applyFilter('aberration', function ()
        Shader.SetFloat('strength', Settings.get('postfx.aberration.strength'))
      end)
    end
    if Settings.get('postfx.radialblur.enable') then
      self.renderer:applyFilter('radialblur', function ()
        Shader.SetFloat('strength', Settings.get('postfx.radialblur.strength'))
      end)
    end
    if Settings.get('postfx.sharpen.enable') then
      self.renderer:sharpen(
        Settings.get('postfx.sharpen.radius') or 2,
        (Settings.get('postfx.sharpen.radius') or 2) * 0.5,
        Settings.get('postfx.sharpen.strength') or 1)
    end
    if Settings.get('postfx.grain.enable') then
      self.renderer:grain(Settings.get('postfx.grain.strength') or 1)
    end
    -- HUD/debug panel over the finished (post-tonemap) picture.
    self.renderer:compositeUI(true)
    Profiler.Begin('Render.Present')
    local tPres = TimeStamp.Get()
    self.renderer:present(x, y, sx, sy, ss > 2)
    rtl.present = TimeStamp.GetElapsedMs(tPres)
    Profiler.End()
  end
    rtl.postfx = TimeStamp.GetElapsedMs(rtl.t1) - rtl.present
    Profiler.End() -- Render.PostFx
  end

  if GUI.DrawHmGui then
    GUI.DrawHmGui(self.sx, self.sy)
  end

  if GameView.__dump then GameView.__dump() end
  RenderState.PopAll()
  ClipRect.Pop()
  self.camera:pop()
end

function GameView:onInputChildren (state)
  self.camera:push()
  for i = 1, #self.children do
    local child = self.children[i]
    if not child.removed then child:input(state) end
  end
  self.camera:pop()
end

function GameView:onUpdate (state)
  --[[ TODO : This may be one frame delayed since onUpdateChildren happens later
              and one of them is responsible for updating the camera position.
              Further reason to invert the current Camera-Control relationship. ]]
  self.camera:onUpdate(state.dt)

  do -- Compute Eye Velocity EMA
    local eye = self.camera.pos
    local v = (eye - self.eyeLast):scale(1.0 / max(1e-10, state.dt))
    self.eyeVel:setv(self.player:getControlling():getVelocity())
    self.eyeLast:setv(eye)
  end

  Audio.SetListenerPos(
    self.camera.pos,
    self.eyeVel,
    self.camera.rot:getForward(),
    self.camera.rot:getUp())
  Audio.Update()

  -- M toggles music playback. TODO : move into a proper audio settings UI.
  if Input.GetPressed(Button.Keyboard.M) then
    self.musicMuted = not self.musicMuted
    if self.musicMuted then self.music:pause() else self.music:play() end
  end

  -- F9 toggles the debug panel (independent of which PlayerControl is active).
  -- Debounce: GetPressed also fires on the key-release frame, so a single tap
  -- would toggle twice and instantly cancel. Ignore fires within 200ms of the last.
  if Input.GetPressed(Button.Keyboard.F9) then
    local now = os.clock()
    if not self.__lastDebugToggle or now - self.__lastDebugToggle > 0.2 then
      self.__lastDebugToggle = now
      self.debugWindow:toggleEnabled()
    end
  end

  -- VSync toggle (debug 'Render' section / Config.render.vsync): apply live.
  local vsync = Settings.get('render.vsync')
  if vsync ~= self.appliedVsync and self.ltheory and self.ltheory.window then
    self.appliedVsync = vsync
    self.ltheory.window:setVsync(vsync)
  end

  self.camera:pop()
end

function GameView:onUpdateChildren (state)
  self.camera:push()
  for i = 1, #self.children do
    local child = self.children[i]
    if not child.removed then child:update(state) end
  end
  self.camera:pop()
end

function GameView:onLayoutSizeChildren ()
  self.camera:push()
  for i = 1, #self.children do self.children[i]:layoutSize() end
  self.camera:pop()
end

function GameView:setOrbit (orbit)
  local lastCamera = self.camera

  self.orbit = orbit
  self.camera = self.orbit and self.cameraOrbit or self.cameraChase
  self.camera:setTarget(self.player:getControlling())

  -- NOTE : We're assuming that no one else could have pushed a camera
  local camera = Camera.get()
  if camera and camera == lastCamera then
    lastCamera:pop()
    self.camera:push()
  end
end

function GameView.Create (player)
  -- TODO : Should Audio be handled in App/LTheory??
  Audio.Init()
  Audio.Set3DSettings(0.0, 10, 2);

  local self = setmetatable({
    player      = player,
    renderer    = Renderer(),
    cameraChase = CameraChase(),
    cameraOrbit = CameraOrbit(),
    camera      = nil,
    eyeLast     = nil,
    eyeVel      = nil,
    appliedVsync = nil,
    renderTimes = { submit = 0, postfx = 0, present = 0 },
    children    = List(),
  }, GameView)

  self:setOrbit(false)
  self.eyeLast = self.camera.pos:clone()
  self.eyeVel  = self.player:getControlling():getVelocity():clone()

  -- Ambient music: looping 2D track (2D = unattenuated by distance/position).
  -- Track + volume configurable via Config.audio (see Config.App.lua).
  -- TODO : Playlist rotation + music/SFX volume settings UI.
  self.music = Sound.Load(Config.audio.music, true, false)
  self.music:setVolume(Config.audio.musicVolume)
  self.music:play()
  return self
end

return GameView
