-- DrawBatch -----------------------------------------------------------------
local ffi = require('ffi')
local libphx = require('ffi.libphx').lib

do -- C Definitions
  ffi.cdef [[
    typedef struct {
      void*  state;
      void*  mesh;
      float  mWorld[16];
      float  mWorldIT[16];
      int    imWorld;
      int    imWorldIT;
      int    iScale;
      float  scale;
      float  lod;
      int    split;
    } DrawJob;
    void Render_DrawList(const DrawJob* jobs, int count);
  ]]
end

-- Returned (no global set to avoid _G shadowing); requirers use the return value.
local M = {
  RenderDrawList = libphx.Render_DrawList,
}

return M
