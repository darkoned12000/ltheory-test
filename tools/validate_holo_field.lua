#!/usr/bin/env luajit
-- Deterministic minor-field clustering and semantic-zoom LOD contracts.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_holo_field%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end
local function finish ()
  if failures == 0 then print(string.format('holo field: %d checks passed', checks)); os.exit(0) end
  print(string.format('holo field: %d/%d checks failed', failures, checks)); os.exit(1)
end

local loaded, Field = pcall(require, 'UI.HoloField')
check('HoloField module loads', loaded, Field)
if not loaded then finish() end

local function makeNodes (count)
  local nodes = {}
  for i = 1, count do
    local a = i * 2.399963229728653
    local r = 120 + (i * 73) % 4200
    nodes[i] = {
      id = 'rock_' .. i, label = 'Asteroid ' .. i, major = false,
      wx = math.cos(a) * r, wy = (i % 17) * 3, wz = math.sin(a) * r,
    }
  end
  return nodes
end

local nodes2000 = makeNodes(2000)
local field2000 = Field.Build(nodes2000, { contextId = 'sys_test', cellSize = 180 })
check('2,000 asteroids build a complete owned field', #field2000.points == 2000)
local clusterCount = 0
for i = 1, #field2000.clusters do clusterCount = clusterCount + field2000.clusters[i].count end
check('cluster member counts conserve every asteroid', clusterCount == 2000,
  tostring(#field2000.clusters) .. ' clusters')
local fieldAgain = Field.Build(nodes2000, { contextId = 'sys_test', cellSize = 180 })
local deterministic = #fieldAgain.clusters == #field2000.clusters
if deterministic then
  for i = 1, #field2000.clusters do
    if fieldAgain.clusters[i].id ~= field2000.clusters[i].id
      or fieldAgain.clusters[i].x ~= field2000.clusters[i].x
      or fieldAgain.clusters[i].z ~= field2000.clusters[i].z then deterministic = false end
  end
end
check('cluster identities and positions are deterministic', deterministic)

local low = Field.LOD(field2000, 0.5)
check('far zoom draws clusters instead of individual asteroids',
  #low.points == 0 and #low.clusters > 0 and low.clusterAlpha == 1 and low.pointAlpha == 0)
local high = Field.LOD(field2000, 2.0, nil, { maxPoints = 4096 })
check('close zoom unpacks individual asteroid points',
  #high.points == 2000 and high.clusterAlpha == 0 and high.pointAlpha == 1)
local mid = Field.LOD(field2000, 1.1)
check('transition zoom crossfades clusters and points',
  #mid.clusters > 0 and #mid.points > 0 and mid.clusterAlpha > 0 and mid.clusterAlpha < 1
    and mid.pointAlpha > 0 and mid.pointAlpha < 1)

local selectedLow = Field.LOD(field2000, 0.5, 'rock_1777')
local selectedVisible = false
for i = 1, #selectedLow.points do
  if selectedLow.points[i].id == 'rock_1777' then selectedVisible = true end
end
check('selected asteroid stays individually visible at far zoom',
  selectedVisible and #selectedLow.points == 1)

local nodes10000 = makeNodes(10000)
local field10000 = Field.Build(nodes10000, { contextId = 'sys_large', cellSize = 180 })
local capped = Field.LOD(field10000, 2.0, 'rock_9999', { maxPoints = 4096 })
local cappedSelected, unique = false, true
local seen = {}
for i = 1, #capped.points do
  local id = capped.points[i].id
  if seen[id] then unique = false end
  seen[id] = true
  if id == 'rock_9999' then cappedSelected = true end
end
check('10,000-asteroid field caps close-up points without losing selection',
  #capped.points == 4096 and cappedSelected and unique,
  tostring(#capped.points) .. ' points / ' .. tostring(#field10000.clusters) .. ' clusters')

local beforeId, beforeX = nodes2000[1].id, nodes2000[1].wx
field2000.points[1].x = -999999
check('field construction does not mutate provider records',
  nodes2000[1].id == beforeId and nodes2000[1].wx == beforeX)

finish()
