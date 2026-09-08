#!/usr/bin/env luajit
--[[----------------------------------------------------------------------------
  Offline immediate-draw run-signature validator.

  Exercises the merge contract behind libphx/src/Draw.cpp's deferred flat
  immediate-draw batching (roadmap #15) via the exported pure helper
  ImmBatch_KeyMatch — the SAME function Draw_Enqueue calls to decide whether a
  primitive continues the current batch run or commits first.

  Contract under test (see Draw.h):
    - exact identity wins: same primitive mode + bit-identical color key
      (r,g,b,alpha-after-baking) continues the run in one draw call
    - ANY channel difference fails the match -> run must commit -> separate
      draw call (order preserved)
    - mismatch is deliberately exact-float (no epsilon): a near-miss only
      fails to merge (safe: more, smaller draws), never merges wrong colors

  Runs under luajit with NO GL/Engine context: the helper is pure arithmetic
  on scalars. Exit code non-zero on any failure. Wired into
  `python3 configure.py test` and `cmake --build` (phx_validate_immdraw).
----------------------------------------------------------------------------]]--

-- Make `require('ffi.Draw')` resolve without LD_LIBRARY_PATH.
local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1,1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.')..'/'..src end
local root = src:gsub('/tools/validate_immdraw%.lua$', '')
if root == src then root = '.' end
package.path = root..'/libphx/script/?.lua;'..root..'/libphx/script/?/init.lua;'..package.path

local ffi = require('ffi')
local Draw = require('ffi.Draw')  -- loads the cdef; KeyMatch exported by libphx

local KeyMatch = Draw.ImmBatch_KeyMatch

-- GL_QUADS == GL_POLYGON == 5-style expansion aside, modes are opaque ints here.
local GL_QUADS  = 0x0007  -- 7
local GL_LINES  = 0x0001  -- 1
local GL_TRIANG = 0x0004  -- 4

local failures = 0

local function check (label, got, expected)
  if got ~= expected then
    failures = failures + 1
    print(string.format('FAIL %-52s got=%d expected=%d', label, got, expected))
  end
end

local key = { GL_QUADS, 1.0, 0.5, 0.25, 0.9 }  -- canonical run signature

-- 1) Identity: the same key must self-match.
check('identical key self-matches', KeyMatch(key[1],key[2],key[3],key[4],key[5],
                                             key[1],key[2],key[3],key[4],key[5]), 1)

-- 2) Mode is part of the signature.
check('mode mismatch breaks the run',
      KeyMatch(key[1],key[2],key[3],key[4],key[5],
               GL_LINES,key[2],key[3],key[4],key[5]), 0)
check('mode transitions both ways',
      KeyMatch(GL_TRIANG,key[2],key[3],key[4],key[5],
               key[1],key[2],key[3],key[4],key[5]), 0)

-- 3) Every color channel is part of the signature.
for i, delta in ipairs({ {r=1.01}, {g=1.01}, {b=1.01}, {a=0.89} }) do
  local r = delta.r or key[2]
  local g = delta.g or key[3]
  local b = delta.b or key[4]
  local a = delta.a or key[5]
  check('single-channel drift breaks the run ('..i..')',
        KeyMatch(key[1],key[2],key[3],key[4],key[5],
                 key[1],r,g,b,a), 0)
end

-- 4) Near-miss is still a miss (exact-float contract): no epsilon tolerance.
check('near-equal floats do NOT merge (epsilon is unsafe)',
      KeyMatch(key[1],key[2],key[3],key[4],key[5],
               key[1],key[2],key[3]+1e-5,key[4],key[5]), 0)

-- 5) Baked alpha dominates raw draw alpha: same color, different alpha -> split.
check('alpha stack bake splits the run',
      KeyMatch(key[1],key[2],key[3],key[4],0.7,
               key[1],key[2],key[3],key[4],0.9), 0)

-- 6) Full recompose after a split must re-anchor exactly (commit+continue).
check('re-anchored signature self-matches after split',
      KeyMatch(key[1],key[2],key[3],key[4],0.7,
               key[1],key[2],key[3],key[4],0.7), 1)

-- 7) Same color, all-zero alpha is still a valid key (invisible but mergable).
check('zero-alpha key still matches itself',
      KeyMatch(key[1],key[2],key[3],key[4],0.0,
               key[1],key[2],key[3],key[4],0.0), 1)

-- 8) Channel order matters: permuted values never match (no normalization).
check('permuted channels do not merge',
      KeyMatch(key[1],key[2],key[3],key[4],key[5],
               key[1],key[3],key[2],key[4],key[5]), 0)

if failures == 0 then
  print('validate_immdraw: all 13 cases passed')
else
  print(string.format('validate_immdraw: %d case(s) FAILED', failures))
  os.exit(1)
end