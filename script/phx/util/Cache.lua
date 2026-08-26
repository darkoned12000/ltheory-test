local Cache = {}

local files    = {}
local fonts    = {}
local shaders  = {}
-- First program that compiled successfully for each (vs, fs) / compute key. Used to
-- degrade gracefully: if a later load of the same pass fails (e.g. you edited its .glsl),
-- we keep rendering with this last-known-good version instead of crashing. See item 4.
local goodShaders = {}
local textures = {}

function Cache.Clear ()
  for k, v in pairs(shaders) do if v then v:free() end end
  for k, v in pairs(textures) do v:free() end
  shaders = {}
  goodShaders = {}
  textures = {}
end

function Cache.File (path)
  if not File.Exists(path) then return nil end
  if files[path] then return files[path] end
  local f = io.open(path, 'rb')
  if not f then Log.Error('Failed to open file <%s> for reading', path) end
  local self = f:read('*a')
  f:close()
  files[path] = self
  return self
end

-- TODO AB : Figure out proper way to do UI font caching
function Cache.Font (name, size)
  local key = name .. size
  local self = fonts[key]
  if self then return self end
  self = Font.Load(name, size)
  fonts[key] = self
  return self
end

function Cache.Shader (vs, fs)
  local key = vs .. fs
  local self = shaders[key]
  if self then return self end
  self = Shader.Load('vertex/' .. vs, 'fragment/' .. fs)
  if not self then
    -- C++ returned NULL: the shader failed to compile/link. Fall back to the last-good
    -- version of this pass so a broken .glsl degrades instead of aborting mid-flight;
    -- otherwise surface it (caller skips this draw). See item 4.
    if goodShaders[key] then Log.Warning('Shader <%s> failed to compile/link; using last good version', key) end
    return goodShaders[key]
  end
  shaders[key] = self
  goodShaders[key] = self
  return self
end

function Cache.Compute (cs)
  local key = '@compute/' .. cs
  local self = shaders[key]
  if self then return self end
  self = Shader.LoadCompute('compute/' .. cs)
  if not self then
    if goodShaders[key] then Log.Warning('Compute shader <%s> failed to compile/link; using last good version', key) end
    return goodShaders[key]
  end
  shaders[key] = self
  goodShaders[key] = self
  return self
end

function Cache.Texture (name, filtered)
  local self = textures[name]
  if self then return self end
  self = Tex2D.Load(name)
  textures[name] = self
  if filtered then
    self:setMagFilter(TexFilter.Linear)
    self:setMinFilter(TexFilter.LinearMipLinear)
    self:setWrapMode(TexWrapMode.Clamp)
    self:genMipmap()
  end
  return self
end

return Cache
