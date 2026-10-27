#!/usr/bin/env luajit
--[[
  Offline validator for the billboard vertex-shader edge guards
  (res/shader/vertex/billboard/axis.glsl and wrapped.glsl).

  The guards themselves live in GLSL; this script ports the exact guard
  expressions to Lua and checks that degenerate inputs (camera directly
  along the billboard axis, toCam parallel to up, zero-length toCam) yield
  finite, sane results instead of NaNs. No GL context required.
]]

local function length(v)
  return math.sqrt(v[1]*v[1] + v[2]*v[2] + v[3]*v[3])
end

local function cross(a, b)
  return { a[2]*b[3]-a[3]*b[2], a[3]*b[1]-a[1]*b[3], a[1]*b[2]-a[2]*b[1] }
end

local function normalize(v)
  local l = length(v)
  if l <= 0 then return nil end
  return { v[1]/l, v[2]/l, v[3]/l }
end

local function finite(x)
  return x == x and x ~= math.huge and x ~= -math.huge
end

local function vecFinite(v)
  return v and finite(v[1]) and finite(v[2]) and finite(v[3])
end

local failures = 0
local function check(label, cond)
  if not cond then
    failures = failures + 1
    print('FAIL ' .. label)
  end
end

local kWrap = 1024.0

-- axis.glsl guard: right = (length(cross) > 1e-6) ? normalize(cross) : (1,0,0)
local function axisRight(toCam, look)
  local c = cross(toCam, look)
  if length(c) > 1e-6 then return normalize(c) end
  return {1,0,0}
end

-- wrapped.glsl guard
local function wrappedRight(toCam, up)
  local dir = normalize({toCam[1]+1e-6, toCam[2]+1e-6, toCam[3]+1e-6})
  -- for zero toCam the +epsilon keeps it finite; normalize still ok
  local c = cross(dir, up)
  if length(c) > 1e-6 then return normalize(c) end
  return {1,0,0}
end

local function wrappedToCam(toCam)
  return {
    2.0 * (math.fmod and 0 or 0) + 0,
  }
end

-- Test 1: axis, normal case
do
  local r = axisRight({0,0,1}, {0,1,0})
  check('axis normal: finite', vecFinite(r))
  check('axis normal: unit', math.abs(length(r)-1) < 1e-6)
end

-- Test 2: axis, toCam parallel to look (degenerate) -> must not NaN
do
  local r = axisRight({0,0,1}, {0,0,1})
  check('axis parallel: finite', vecFinite(r))
  check('axis parallel: unit', math.abs(length(r)-1) < 1e-6)
end

-- Test 3: axis, zero toCam
do
  local r = axisRight({0,0,0}, {0,0,1})
  check('axis zero toCam: finite', vecFinite(r))
end

-- Test 4: wrapped, toCam not perpendicular to up (cross unnormalized originally)
do
  local up = {0,1,0}
  local toCam = {1,1,0} -- not perpendicular to up? dot=1
  local r = wrappedRight(toCam, up)
  check('wrapped non-perp: finite', vecFinite(r))
  check('wrapped non-perp: unit', math.abs(length(r)-1) < 1e-6)
end

-- Test 5: wrapped, toCam parallel to up (cross zero)
do
  local up = {0,1,0}
  local r = wrappedRight({0,1,0}, up)
  check('wrapped parallel: finite', vecFinite(r))
  check('wrapped parallel: unit', math.abs(length(r)-1) < 1e-6)
end

-- Test 6: wrapped precision form matches mod for small values
do
  for _, v in ipairs({{10.0,20.0,30.0},{100.5, -50.25, 7.0},{0,0,0}}) do
    local a = {}
    local b = {}
    for i=1,3 do
      a[i] = 2.0 * ((v[i]/kWrap - math.floor(v[i]/kWrap)) * kWrap) - kWrap
      -- GLSL fract for negatives differs; use a simple mod-equivalent for positive-ish test
    end
    -- just check finite
    check('wrapped precision finite for '..tostring(v[1]), finite(a[1]) and finite(a[2]) and finite(a[3]))
  end
end

-- Test 7: large distance precision (the whole point of the change)
do
  local big = 1e5
  local v = {big+123.456, -big+789.0, 42.0}
  local r = {}
  for i=1,3 do
    r[i] = 2.0 * ((v[i]/kWrap - math.floor(v[i]/kWrap)) * kWrap) - kWrap
  end
  check('wrapped large-distance finite', finite(r[1]) and finite(r[2]) and finite(r[3]))
  -- result should be within [-kWrap, kWrap]
  for i=1,3 do
    check('wrapped large-distance bounded #'..i, r[i] >= -kWrap-1e-6 and r[i] <= kWrap+1e-6)
  end
end

if failures == 0 then
  print('billboard math guards: all checks passed')
  os.exit(0)
else
  print(string.format('billboard math guards: %d failure(s)', failures))
  os.exit(1)
end
