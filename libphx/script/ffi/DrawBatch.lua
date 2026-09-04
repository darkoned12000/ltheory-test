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
    int DrawBatch_GroupRuns(const DrawJob* jobs, int count, int* out_starts, int capacity);
  ]]
end

assert(ffi.sizeof('DrawJob') == 168, 'DrawJob ABI mismatch: Lua cdef and C++ struct must match exactly')

-- Returned (no global set to avoid _G shadowing); requirers use the return value.
local M = {
  RenderDrawList = libphx.Render_DrawList,
  GroupRuns = libphx.DrawBatch_GroupRuns,
}

return M
