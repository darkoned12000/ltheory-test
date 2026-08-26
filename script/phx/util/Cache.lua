local Cache = {}

-- Caches + sticky error flag are real fields on the Cache table (not locals):
-- Application reads Cache.lastError for the shader-failure overlay, so they must
-- be reachable through the module. In LuaJIT a bare assignment lands in _G, not on
-- the returned table, which is exactly why the overlay never drew before this.
Cache.files        = {}   -- raw file contents (Cache.File)
Cache.fonts        = {}   -- loaded fonts (Cache.Font)
Cache.shaders      = {}   -- successfully-compiled programs by key
Cache.goodShaders  = {}   -- last-known-good program per key, used to degrade on failure
Cache.lastError    = nil  -- most recent failed pass with no fallback; drawn as overlay
Cache.textures     = {}   -- loaded textures (Cache.Texture)

function Cache.Clear ()
  for k, v in pairs(Cache.shaders) do if v then v:free() end end
  for k, v in pairs(Cache.textures) do v:free() end
  Cache.shaders = {}
  Cache.goodShaders = {}
  Cache.lastError = nil
  Cache.textures = {}
end

function Cache.File (path)
  if not File.Exists(path) then return nil end
  if Cache.files[path] then return Cache.files[path] end
  local f = io.open(path, 'rb')
  if not f then Log.Error('Failed to open file <%s> for reading', path) end
  local self = f:read('*a')
  f:close()
  Cache.files[path] = self
  return self
end

-- TODO AB : Figure out proper way to do UI font caching
function Cache.Font (name, size)
  local key = name .. size
  local self = Cache.fonts[key]
  if self then return self end
  self = Font.Load(name, size)
  Cache.fonts[key] = self
  return self
end

function Cache.Shader (vs, fs)
  local key = vs .. fs
  local self = Cache.shaders[key]
  if self then return self end
  self = Shader.Load('vertex/' .. vs, 'fragment/' .. fs)
  if not self then
    -- C++ returned NULL: the shader failed to compile/link. Fall back to the last-good
    -- version of this pass so a broken .glsl degrades instead of aborting mid-flight;
    -- otherwise surface it (caller skips this draw). See item 4.
    if Cache.goodShaders[key] then Log.Warning('Shader <%s> failed to compile/link; using last good version', key) end
    if not Cache.goodShaders[key] then Cache.lastError = { key = key, msg = 'failed to compile/link' } end
    return Cache.goodShaders[key]
  end
  Cache.shaders[key] = self
  Cache.goodShaders[key] = self
  Cache.lastError = nil
  return self
end

function Cache.Compute (cs)
  local key = '@compute/' .. cs
  local self = Cache.shaders[key]
  if self then return self end
  self = Shader.LoadCompute('compute/' .. cs)
  if not self then
    if Cache.goodShaders[key] then Log.Warning('Compute shader <%s> failed to compile/link; using last good version', key) end
    if not Cache.goodShaders[key] then Cache.lastError = { key = key, msg = 'failed to compile/link' } end
    return Cache.goodShaders[key]
  end
  Cache.shaders[key] = self
  Cache.goodShaders[key] = self
  Cache.lastError = nil
  return self
end

function Cache.Texture (name, filtered)
  local self = Cache.textures[name]
  if self then return self end
  self = Tex2D.Load(name)
  Cache.textures[name] = self
  if filtered then
    self:setMagFilter(TexFilter.Linear)
    self:setMinFilter(TexFilter.LinearMipLinear)
    self:setWrapMode(TexWrapMode.Clamp)
    self:genMipmap()
  end
  return self
end

return Cache
