-- GPUBuffer --------------------------------------------------------------------
local ffi = require('ffi')
local libphx = require('ffi.libphx').lib
local GPUBuffer

do -- C Definitions
  ffi.cdef [[
    GPUBuffer* GPUBuffer_Create     (uint size);
    void       GPUBuffer_Acquire    (GPUBuffer*);
    void       GPUBuffer_Free       (GPUBuffer*);
    void       GPUBuffer_Upload     (GPUBuffer*, const void* data, uint size);
    void       GPUBuffer_Download   (GPUBuffer*, void* outData, uint size);
    void       GPUBuffer_BindSSBO   (GPUBuffer*, uint binding);
    uint       GPUBuffer_GetHandle  (GPUBuffer*);
    uint       GPUBuffer_GetSize    (GPUBuffer*);
  ]]
end

do -- Global Symbol Table
  GPUBuffer = {
    Create     = libphx.GPUBuffer_Create,
    Acquire    = libphx.GPUBuffer_Acquire,
    Free       = libphx.GPUBuffer_Free,
    Upload     = libphx.GPUBuffer_Upload,
    Download   = libphx.GPUBuffer_Download,
    BindSSBO   = libphx.GPUBuffer_BindSSBO,
    GetHandle  = libphx.GPUBuffer_GetHandle,
    GetSize    = libphx.GPUBuffer_GetSize,
  }

  if onDef_GPUBuffer then onDef_GPUBuffer(GPUBuffer, mt) end
  GPUBuffer = setmetatable(GPUBuffer, mt)
end

do -- Metatype for class instances
  local t  = ffi.typeof('GPUBuffer')
  local mt = {
    __index = {
      managed   = function (self) return ffi.gc(self, libphx.GPUBuffer_Free) end,
      acquire   = libphx.GPUBuffer_Acquire,
      free      = libphx.GPUBuffer_Free,
      upload    = libphx.GPUBuffer_Upload,
      download  = libphx.GPUBuffer_Download,
      bindSSBO  = libphx.GPUBuffer_BindSSBO,
      getHandle = libphx.GPUBuffer_GetHandle,
      getSize   = libphx.GPUBuffer_GetSize,
    },
  }

  if onDef_GPUBuffer_t then onDef_GPUBuffer_t(t, mt) end
  GPUBuffer_t = ffi.metatype(t, mt)
end

return GPUBuffer
