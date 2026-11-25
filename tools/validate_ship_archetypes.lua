#!/usr/bin/env luajit
-- Ship archetype metadata used by procedural spawning and registry naming.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_ship_archetypes%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path
local Archetypes = require('Game.ShipArchetypes')

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. detail) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. detail) or '')) end
end

for _, kind in ipairs({ 'fighter', 'freighter', 'industrial', 'capital' }) do
  local def = Archetypes.Get(kind)
  check('archetype exists: ' .. kind, def ~= nil)
  check('archetype has generator/scale/cargo: ' .. kind, def and def.generator
    and def.scale > 0 and def.cargo > 0)
end
check('fighter remains small and fast', Archetypes.Get('fighter').scale == 4)
check('freighter is a distinct large cargo hull', Archetypes.Get('freighter').scale > 20
  and Archetypes.Get('freighter').cargo > Archetypes.Get('fighter').cargo)
check('industrial is a distinct mining hull', Archetypes.Get('industrial').model == 'Industrial')
check('capital is strategic registry class', Archetypes.Get('capital').classId == 3)
check('freighter registry name is not fighter', Archetypes.Get('freighter').model == 'Freighter')
check('unknown kind safely falls back to fighter', Archetypes.Get('missing') == Archetypes.Get('fighter'))

if failures == 0 then
  print(string.format('ship archetypes: %d checks passed', checks))
  os.exit(0)
else
  print(string.format('ship archetypes: %d/%d checks failed', failures, checks))
  os.exit(1)
end
