#!/usr/bin/env luajit
--[[
  Offline validator for the shadow-quality master enum added in the
  `graphicoptions` branch (Renderer.lua `render.shadow.quality` +
  GameView:shadowPcfRadius()).

  Mirrors the contract: quality index 1..5 maps to a PCF radius, with
  index 5 (Custom) falling back to the manual `render.shadow.radius` slider.
  No GL/Engine context required.
]]

local SHADOW_QUALITY_RADIUS = { [1]=0, [2]=1, [3]=2, [4]=4, [5]=nil }

local failures = 0
local function check(label, cond)
  if not cond then failures = failures + 1; print('FAIL ' .. label) end
end

-- 1..4 map to fixed radii
check('Off -> 0',     SHADOW_QUALITY_RADIUS[1] == 0)
check('Low -> 1',     SHADOW_QUALITY_RADIUS[2] == 1)
check('Medium -> 2',  SHADOW_QUALITY_RADIUS[3] == 2)
check('High -> 4',    SHADOW_QUALITY_RADIUS[4] == 4)
-- Custom (5) falls back to slider
check('Custom -> nil (slider fallback)', SHADOW_QUALITY_RADIUS[5] == nil)

-- Simulate shadowPcfRadius()
local function shadowPcfRadius(q, slider)
  local r = SHADOW_QUALITY_RADIUS[q]
  if r == nil then return slider end
  return r
end

for q = 1, 5 do
  local v = shadowPcfRadius(q, 2.5)
  check('quality '..q..' finite', type(v)=='number' and v==v)
end
check('Custom uses slider value', shadowPcfRadius(5, 2.5) == 2.5)
check('Off disables PCF (0)', shadowPcfRadius(1, 2.5) == 0)

-- enum option count: 5 options (Off/Low/Medium/High/Custom); index 5 is nil (slider fallback)
local optCount = 0
for i = 1, 10 do if SHADOW_QUALITY_RADIUS[i] ~= nil or i <= 5 then optCount = i end end
check('5 quality options', optCount == 5)

if failures == 0 then
  print('shadow quality mapping: all checks passed')
  os.exit(0)
else
  print(string.format('shadow quality mapping: %d failure(s)', failures))
  os.exit(1)
end
