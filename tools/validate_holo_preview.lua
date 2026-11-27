#!/usr/bin/env luajit
-- Live entity mesh preview contracts for the Holo info panel.

local src = debug.getinfo(1, 'S').source:match('^@(.+)$') or '.'
if src:sub(1, 1) ~= '/' then src = (io.popen('pwd'):read('*l') or '.') .. '/' .. src end
local root = src:gsub('/tools/validate_holo_preview%.lua$', '')
if root == src then root = '.' end
package.path = root .. '/script/?.lua;' .. package.path

local ffi = require('ffi')
ffi.cdef[[
  struct Vertex { float px, py, pz, nx, ny, nz, uvx, uvy; };
]]
package.loaded['Game.TargetInfo'] = { ResolveMesh = function (e) return e and e.mesh end }
local drawn = {}
_G.DrawEx = { Line = function (...) drawn[#drawn + 1] = { ... } end }
package.loaded['UI.DrawEx'] = DrawEx
_G.Color = function (r, g, b, a) return { r = r, g = g, b = b, a = a } end

local failures, checks = 0, 0
local function check (name, ok, detail)
  checks = checks + 1
  if ok then print('ok   - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or ''))
  else failures = failures + 1; print('FAIL - ' .. name .. (detail and ('  -- ' .. tostring(detail)) or '')) end
end
local function finish ()
  if failures == 0 then print(string.format('holo preview: %d checks passed', checks)); os.exit(0) end
  print(string.format('holo preview: %d/%d checks failed', failures, checks)); os.exit(1)
end

local loaded, Preview = pcall(require,('UI.HoloPreview'))
check('HoloPreview module loads', loaded, Preview)
if not loaded then finish() end

check('missing entity mesh falls back cleanly', Preview.BuildLines(nil) == nil)
local verts = ffi.new('struct Vertex[4]')
verts[0].px, verts[0].py, verts[0].pz = -1, -1, 0
verts[1].px, verts[1].py, verts[1].pz = 1, -1, 0
verts[2].px, verts[2].py, verts[2].pz = 0, 1, 0
verts[3].px, verts[3].py, verts[3].pz = 0, 0, 1
local indices = ffi.new('int32_t[6]', 0, 1, 2, 0, 2, 3)
local mesh = {
  getVertexCount = function () return 4 end,
  getVertexData = function () return verts end,
  getIndexCount = function () return 6 end,
  getIndexData = function () return indices end,
}
local entity = { mesh = mesh }
local lines = Preview.BuildLines(entity)
check('real entity mesh builds a normalized projected wireframe',
  lines ~= nil and #lines > 0, lines and (#lines / 4) .. ' edges')
check('mesh preview draws into the supplied preview rect',
  Preview.Draw(10, 20, 200, 120, { kind = 'mesh', entity = entity }) == true
    and #drawn > 0)

finish()
