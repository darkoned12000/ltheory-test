#!/usr/bin/env luajit
--[[----------------------------------------------------------------------------
  Offline RenderJobQueue threading validator for the multithreading render submit.

  Exercises the producer/host → persistent workers → host-waits queue behind
  libphx/src/RenderJobQueue.cpp (SDL mutex+cond, generation-counter barrier,
  graceful shutdown). Uses REAL RigidBody objects headlessly (pure Bullet math,
  no GL context) so the full worker path (thread dispatch, matrix fill, barrier,
  order preservation) is tested — not stubs.

  Runs under luajit with NO GL/Engine context: only threads + Bullet math.
  Exit code non-zero on any failure (hang = deadlock = fail; configure.py will
  block, which is intentional for a threading gate). Wired into
  `python3 configure.py test` and `cmake --build` (phx_validate_renderqueue).

  What it covers (mirrors the threading contract in RenderJobQueue.cpp):
    - N bodies with distinct scales → output matrices equal host-read values
      (proves workers correctly read + copied; catches swapped slices/misses)
    - order preservation (output[i] matches body[i], not a neighbor)
    - edge cases: count==0 (immediate return), count==1 and count<workers
      (empty ranges complete barrier, no deadlock)
    - repeated runs (20x) to catch flaky races (missed wakeups, generation bugs)
    - graceful Free (joins cleanly, no Fatal/hang)
----------------------------------------------------------------------------]]--

-- Make `require('ffi.*')` resolve without LD_LIBRARY_PATH.
local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1,1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.')..'/'..src end
local root = src:gsub('/tools/validate_renderqueue%.lua$', '')
if root == src then root = '.' end
package.path = root..'/libphx/script/?.lua;'..root..'/libphx/script/?/init.lua;'..package.path

local ffi = require('ffi')
require('ffi.RigidBody')      -- loads cdef (CreateBox, GetToWorld/LocalMatrix, SetScale, Free)
require('ffi.DrawBatch')      -- loads DrawJob cdef + ABI assert
require('ffi.RenderJobQueue') -- loads queue cdef
local libphx = require('ffi.libphx').lib

local function makeBodies (n)
  local bodies = {}
  for i = 1, n do
    local b = libphx.RigidBody_CreateBox()
    assert(b ~= nil, 'CreateBox returned nil')
    libphx.RigidBody_SetScale(b, 1.0 + i * 0.1)  -- distinct scales → distinct matrices
    bodies[#bodies+1] = b
  end
  return bodies
end

local function freeBodies (bodies)
  for _, b in ipairs(bodies) do libphx.RigidBody_Free(b) end
end

local function matEqual (a, b)
  -- a, b: float[16] (or Matrix.m); exact equality (same code path, deterministic).
  for i = 0, 15 do
    if a[i] ~= b[i] then return false, i, a[i], b[i] end
  end
  return true
end

local function checkBuild (queue, bodies, label)
  local n = #bodies
  local bodyPtrs = ffi.new('void*[?]', math.max(n, 1))
  for i, b in ipairs(bodies) do bodyPtrs[i-1] = b end
  local out = ffi.new('DrawJob[?]', math.max(n, 1))
  libphx.RenderJobQueue_BuildBatch(queue, bodyPtrs, out, n)  -- workers fill; barrier waits
  for i, b in ipairs(bodies) do
    local mw = libphx.RigidBody_GetToWorldMatrix(b)
    local ok, idx, a, c = matEqual(out[i-1].mWorld, mw.m)
    if not ok then
      error(string.format('%s: mWorld[%d][%d] mismatch (%s vs %s)', label, i, idx, tostring(a), tostring(c)))
    end
    local mi = libphx.RigidBody_GetToLocalMatrix(b)
    local ok2, idx2, a2, c2 = matEqual(out[i-1].mWorldIT, mi.m)
    if not ok2 then
      error(string.format('%s: mWorldIT[%d][%d] mismatch', label, i, idx2))
    end
  end
  print(string.format('ok - %s (%d bodies, order + values match)', label, n))
end

local queue = libphx.RenderJobQueue_Create(0)  -- auto worker count
assert(queue ~= nil, 'Create returned nil')

-- Normal + edge cases (empty, singleton, fewer-than-workers).
do
  local bodies = makeBodies(64)
  for iter = 1, 20 do
    checkBuild(queue, bodies, 'build-64 iter'..iter)
  end
  freeBodies(bodies)
end

do
  local bodies = makeBodies(1)
  checkBuild(queue, bodies, 'build-singleton')
  freeBodies(bodies)
end

do
  local bodies = makeBodies(3)  -- fewer than workers (empty ranges must complete barrier)
  checkBuild(queue, bodies, 'build-fewer-than-workers')
  freeBodies(bodies)
end

do
  -- count==0 returns immediately (no hang, no crash).
  local out = ffi.new('DrawJob[?]', 1)
  local bodies = ffi.new('void*[?]', 1)
  libphx.RenderJobQueue_BuildBatch(queue, bodies, out, 0)
  print('ok - build-empty (immediate return)')
end

libphx.RenderJobQueue_Free(queue)  -- graceful join; must return (no Fatal/hang)
print('ok - free (graceful shutdown)')

print('[RenderJobQueue tests] ALL PASS')
