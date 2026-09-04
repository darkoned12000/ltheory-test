#!/usr/bin/env luajit
--[[----------------------------------------------------------------------------
  Offline DrawBatch grouping validator for the multithreading render submit.

  Exercises the pure C++ DrawBatch_GroupRuns path behind libphx/src/DrawBatch.cpp
  (consecutive same-(state,mesh,split) runs, order-preserving, no reordering).
  Catches regressions where run merging, order preservation, or split handling
  breaks, which would corrupt batched output (wrong grouping → wrong GL state).

  Runs under luajit with NO GL/Engine context: only malloc + integer/pointer
  compares (grouping never dereferences state/mesh, so fake pointers are safe).
  Exit code non-zero on any failure. Wired into `python3 configure.py test`
  and `cmake --build` (phx_validate_drawbatch).

  What it covers (mirrors the grouping contract in DrawBatch.cpp):
    - empty (count=0) and singleton edge cases
    - all-same (one group) and all-different (N groups)
    - alternating A,B,A (no merge across gap — order preservation)
    - split-mismatch and state-mismatch break runs
    - 100-job patterned run (off-by-one / boundary stress)
    - capacity truncation (returns true count, writes only capacity entries)
----------------------------------------------------------------------------]]--

-- Make `require('ffi.DrawBatch')` resolve without LD_LIBRARY_PATH.
local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1,1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.')..'/'..src end
local root = src:gsub('/tools/validate_drawbatch%.lua$', '')
if root == src then root = '.' end
package.path = root..'/libphx/script/?.lua;'..root..'/libphx/script/?/init.lua;'..package.path

local ffi = require('ffi')
local DrawBatch = require('ffi.DrawBatch')  -- loads cdef + ABI assert (validates layout at load)

local function ptr (id) return ffi.cast('void*', id) end

local function makeJobs (specs)
  -- specs: array of {state=id, mesh=id, split=0/1}; returns DrawJob cdata array.
  local n = #specs
  local jobs = ffi.new('DrawJob[?]', math.max(n, 1))
  for i, s in ipairs(specs) do
    local j = jobs[i-1]
    j.state = ptr(s.state)
    j.mesh = ptr(s.mesh)
    j.split = s.split
  end
  return jobs, n
end

local function checkGroups (name, specs, wantCount, wantStarts, capacity)
  local jobs, n = makeJobs(specs)
  local cap = capacity or math.max(n, 1)
  local starts = ffi.new('int[?]', cap)
  local got = DrawBatch.GroupRuns(jobs, n, starts, cap)
  assert(got == wantCount, string.format('%s: want %d groups, got %d', name, wantCount, got))
  local check = math.min(wantCount, cap)
  for i = 0, check - 1 do
    assert(starts[i] == wantStarts[i+1],
      string.format('%s: starts[%d] want %d, got %d', name, i, wantStarts[i+1], starts[i]))
  end
  print(string.format('ok - %s (%d groups)', name, got))
end

-- 1. empty and singleton edges
checkGroups('empty', {}, 0, {})
checkGroups('singleton', {{state=1, mesh=1, split=1}}, 1, {0})

-- 2. all-same collapses to one group
checkGroups('all-same', {
  {state=1, mesh=1, split=1}, {state=1, mesh=1, split=1}, {state=1, mesh=1, split=1},
  {state=1, mesh=1, split=1}, {state=1, mesh=1, split=1},
}, 1, {0})

-- 3. all-different yields N groups
checkGroups('all-different', {
  {state=1, mesh=1, split=1}, {state=1, mesh=2, split=1}, {state=1, mesh=3, split=1},
  {state=1, mesh=4, split=1}, {state=1, mesh=5, split=1},
}, 5, {0, 1, 2, 3, 4})

-- 4. alternating A,B,A does NOT merge across the gap (order preservation)
checkGroups('alternating-no-merge', {
  {state=1, mesh=1, split=1}, {state=1, mesh=2, split=1}, {state=1, mesh=1, split=1},
}, 3, {0, 1, 2})

-- 5. split-mismatch breaks the run
checkGroups('split-mismatch', {
  {state=1, mesh=1, split=1}, {state=1, mesh=1, split=1},
  {state=1, mesh=1, split=0}, {state=1, mesh=1, split=0},
}, 2, {0, 2})

-- 6. state-mismatch breaks the run (same mesh, different program)
checkGroups('state-mismatch', {
  {state=1, mesh=1, split=1}, {state=2, mesh=1, split=1},
}, 2, {0, 1})

-- 7. 100-job patterned run (run lengths 3,1,4,1,5,...); verifies boundaries + count
do
  local specs, wantStarts, wantCount = {}, {}, 0
  local runs = {3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9, 3, 2, 3, 8, 4}
  local idx, meshId = 0, 0
  for _, len in ipairs(runs) do
    meshId = meshId + 1
    wantCount = wantCount + 1
    wantStarts[#wantStarts+1] = idx
    for k = 1, len do
      specs[#specs+1] = {state=1, mesh=meshId, split=1}
      idx = idx + 1
    end
    if idx >= 100 then break end
  end
  -- trim to exactly 100 jobs (last run may overshoot); recompute want from trimmed specs
  while #specs > 100 do specs[#specs] = nil end
  -- rebuild wantStarts/wantCount from trimmed specs by scanning (same logic, Lua side)
  wantStarts, wantCount = {}, 0
  local i = 1
  while i <= #specs do
    wantCount = wantCount + 1
    wantStarts[#wantStarts+1] = i - 1
    local j = i
    while j + 1 <= #specs
      and specs[j+1].state == specs[i].state
      and specs[j+1].mesh == specs[i].mesh
      and specs[j+1].split == specs[i].split do
      j = j + 1
    end
    i = j + 1
  end
  checkGroups('patterned-100', specs, wantCount, wantStarts)
end

-- 8. capacity truncation: returns true count, writes only capacity entries, no crash
do
  local specs = {}
  for i = 1, 5 do specs[#specs+1] = {state=1, mesh=i, split=1} end
  checkGroups('capacity-truncation', specs, 5, {0, 1}, 2)
end

print('[DrawBatch tests] ALL PASS')
