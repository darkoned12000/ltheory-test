-- TODO : Split materials in subdir + flesh them out more as a first-class
--        asset (maybe we can even put the glsl inline in the material files?)
-- TODO : Separate the concept of 'shading model' from 'material'
--        Metal shader is a specific shading model. Metal shader + metal/01_*
--        is a specific 'type' of metal
--           NOTE : Really they're just nested ShaderStates.

local Material = class(function (self) end)

local allMaterials = {}

OnEvent ('Engine.Reload', function ()
  for i = 1, #allMaterials do
    allMaterials[i]:reload()
  end
end)

local function setTextureState (tex)
  tex:genMipmap()
  local m = Cache.filterMode or { min = TexFilter.LinearMipLinear, aniso = 16 }
  tex:setMagFilter(TexFilter.Linear)
  tex:setMinFilter(m.min)
  if m.aniso and m.aniso > 1 then tex:setAnisotropy(m.aniso) end
  tex:setWrapMode(TexWrapMode.Repeat)
end

function Material.applyFilterMode ()
  for _, mat in ipairs(allMaterials) do
    if mat.texDiffuse then setTextureState(mat.texDiffuse) end
    if mat.texNormal  then setTextureState(mat.texNormal) end
    if mat.texSpec    then setTextureState(mat.texSpec) end
  end
end

function Material.Create (name, diffuse, normal, spec, vertex)
  local self = Material()
  self.name = name
  self.vertex = vertex
  -- Frustum-cull opt-in. A mesh may only be culled by its collision sphere if
  -- the visible geometry is bounded by that sphere -- see VisibleMesh.lua. The
  -- asteroid archetypes qualify (their collision sphere is built from the same
  -- mesh that is drawn); a ship or station with fins and greebles does not.
  self.cullable = false
  self.texDiffuse = diffuse
  self.texNormal = normal
  self.texSpec = spec
  self.state = nil

  if diffuse then
    self.texDiffuse:acquire()
    setTextureState(diffuse)
  end

  if normal then
    self.texNormal:acquire()
    setTextureState(normal)
  end

  if spec then
    self.texSpec:acquire()
    setTextureState(spec)
  end

  self:reload()
  table.insert(allMaterials, self)
  return self
end

function Material:free ()
  if self.texDiffuse then self.texDiffuse:free() end
  if self.texNormal then self.texNormal:free() end
  if self.texSpec then self.texSpec:free() end
  self.state:free()
  remove(allMaterials, self)
end

function Material:reload ()
  if self.state then self.state:free() end
  local shader = Cache.Shader(self.vertex or 'wvp', self.name)
  if not shader then return end   -- item 4: skip this material (broken wvp pass) instead of crashing ShaderState.Create(nil)
  self.state = ShaderState.Create(shader)

  if self.texDiffuse and shader:hasVariable('texDiffuse') then
    self.state:setTex2D('texDiffuse', self.texDiffuse)
  end

  if self.texNormal and shader:hasVariable('texNormal') then
    self.state:setTex2D('texNormal', self.texNormal)
  end

  if self.texSpec and shader:hasVariable('texSpec') then
    self.state:setTex2D('texSpec', self.texSpec)
  end

  self.imWorld   = shader:hasVariable('mWorld')   and shader:getVariable('mWorld')
  self.imWorldIT = shader:hasVariable('mWorldIT') and shader:getVariable('mWorldIT')
  self.iScale    = shader:hasVariable('scale')    and shader:getVariable('scale')
end

function Material:setState (e)
  if self.imWorld   then Shader.ISetMatrix(self.imWorld, e:getToWorldMatrix()) end
  if self.imWorldIT then Shader.ISetMatrixT(self.imWorldIT, e:getToLocalMatrix()) end
  if self.iScale    then Shader.ISetFloat(self.iScale, e:getScale()) end
end

function Material:start ()
  self.state:start()
  if self.onStart then self.onStart() end
end

function Material:stop ()
  self.state:stop()
  if self.onStop then self.onStop() end
end

local cache = {}

-- Depth-only material for the directional/point shadow passes. Unlike the
-- regular wvp vertex path, this uses conventional projected depth (not the
-- camera's logarithmic depth or TAA jitter) and avoids running the expensive
-- G-buffer material fragment shaders while filling a depth texture.
function Material.Shadow ()
  if not cache.shadow then
    cache.shadow = Material.Create('depth', nil, nil, nil, 'shadow')
  end
  return cache.shadow
end

function Material.Debug ()
  if not cache.debug then
    cache.debug = Material.Create('material/devmat')
  end
  return cache.debug
end

function Material.DebugColor ()
  if not cache.debugColor then
    cache.debugColor = Material.Create('material/solidcolor')
  end
  return cache.debugColor
end

function Material.DebugColorA ()
  if not cache.debugColorA then
    cache.debugColorA = Material.Create('material/alphacolor')
  end
  return cache.debugColorA
end

function Material.Metal ()
  if not cache.metal then
    cache.metal = Material.Create(
      'material/metal',
      Cache.Texture('metal/01_d'),
      Cache.Texture('metal/01_n'),
      Cache.Texture('metal/01_s'))
  end
  return cache.metal
end

function Material.Rock ()
  if not cache.rock then
    cache.rock = Material.Create(
      'material/asteroid',
      Cache.Texture('rock'))
    -- The asteroid archetype's collision sphere is created from the SAME mesh
    -- that is drawn (CollisionShape_CreateSphereFromMesh), so the sphere bounds
    -- the visible geometry and the entity scale is applied to both. That makes
    -- the sphere a valid frustum-cull radius for this material.
    cache.rock.cullable = true
  end
  return cache.rock
end

-- The JUMPGATE material: the wormhole's fractal glow.
--
-- Ported from the original Limit Theory's Warping/wormhole.jsl, which
-- raymarched a Mandelbulb-style fractal toward the eye and drew the result
-- ADDITIVELY on an INVERTED sphere -- you are meant to be looking at the
-- inside of the portal.
--
-- So this material needs culling OFF (the camera is inside the sphere, and
-- the visible surface is the far wall) and an additive blend.
function Material.Wormhole ()
  if not cache.wormhole then
    cache.wormhole = Material.Create('effect/wormhole')
    cache.wormhole.onStart = function ()
      -- Culling off: the gate is a sphere you are INSIDE of, so the surface
      -- you see is the far side, which is back-facing.
      RenderState.PushCullFace(CullFace.None)
      BlendMode.PushAdditive()
    end
    cache.wormhole.onStop = function ()
      BlendMode.Pop()
      RenderState.PopCullFace()
    end
  end
  return cache.wormhole
end

return Material
