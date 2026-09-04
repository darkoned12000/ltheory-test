-- RenderJobQueue -----------------------------------------------------------
local ffi = require('ffi')
require('ffi.DrawBatch')  -- loads DrawJob cdef (do not redeclare here)
local libphx = require('ffi.libphx').lib

do -- C Definitions
  ffi.cdef [[
    typedef struct RenderJobQueue RenderJobQueue;
    RenderJobQueue* RenderJobQueue_Create(int workers);
    void RenderJobQueue_BuildBatch(RenderJobQueue* q, void** bodies, DrawJob* out, int count);
    void RenderJobQueue_Free(RenderJobQueue* q);
  ]]
end

-- Returned (no global set to avoid _G shadowing); requirers use the return value.
local M = {
  Create = libphx.RenderJobQueue_Create,
  BuildBatch = libphx.RenderJobQueue_BuildBatch,
  Free = libphx.RenderJobQueue_Free,
}

return M
