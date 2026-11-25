-- NpcInfoPanel -- themed target readout for the player's locked/clicked NPC.
--
-- Matches the sector panel's dark instrument styling and uses the UI widget
-- stack for layout. The left cell is a live 3D hologram of the target's actual
-- generated mesh; the right cell carries the compact target description.

local Container = require('UI.Container')
local Grid     = require('UI.Grid')
local Label    = require('UI.Label')
local Widget   = require('UI.Widget')
local DrawEx   = require('UI.DrawEx')
local ScannerDB = require('Game.ScannerDB')
local Targeting = require('Game.Targeting')
local TargetInfo = require('Game.TargetInfo')
local ffi      = require('ffi')

local NpcInfoPanel = {}
NpcInfoPanel.__index = NpcInfoPanel
setmetatable(NpcInfoPanel, Container)

NpcInfoPanel.name = 'Target Info'

local Preview = {}
Preview.__index = Preview
setmetatable(Preview, Widget)
Preview.name = 'NPC ship preview'
Preview:setStretch(0, 0)

function Preview:onLayoutSize ()
  self.desiredSX = 148
  self.desiredSY = 112
end

-- Cache a normalized, projected wireframe for the selected mesh. This is the
-- same CPU projection used by NodeGraphInspector; the old GPU hologram path
-- could escape its viewport because UI scissor state and its 3D transform did
-- not compose reliably.
function Preview:_buildLines (mesh)
  local okV, cnt = pcall(function () return mesh:getVertexCount() end)
  if not (okV and cnt and cnt > 0) then return nil end
  local vd = mesh:getVertexData()
  if not vd then return nil end
  local verts = ffi.cast('struct Vertex*', vd)
  local rmax = 0
  for i = 0, cnt - 1 do
    local v = verts[i]
    local r = math.sqrt(v.px*v.px + v.py*v.py + v.pz*v.pz)
    if r > rmax then rmax = r end
  end
  if rmax < 1e-6 then return nil end

  local okI, icnt = pcall(function () return mesh:getIndexCount() end)
  if not (okI and icnt and icnt > 0) then return nil end
  local idx = mesh:getIndexData()
  if not idx then return nil end
  local i32 = ffi.cast('int32_t*', idx)
  local yaw, pitch = 0.7, 0.4
  local cy, sy = math.cos(yaw), math.sin(yaw)
  local cp, sp = math.cos(pitch), math.sin(pitch)
  local function project (v)
    local x, y, z = v.px / rmax, v.py / rmax, v.pz / rmax
    local rx = x * cy + z * sy
    local rz = -x * sy + z * cy
    return rx, y * cp - rz * sp
  end

  local ntri = math.floor(icnt / 3)
  local step = math.max(1, math.ceil(ntri / 360))
  local lines, n = {}, 0
  local ti = 0
  while ti * 3 + 2 < icnt do
    local i0 = ti * 3
    local ax, ay = project(verts[i32[i0]])
    local bx, by = project(verts[i32[i0 + 1]])
    local cx, cy2 = project(verts[i32[i0 + 2]])
    n = n + 1; lines[n*4-3], lines[n*4-2], lines[n*4-1], lines[n*4] = ax, ay, bx, by
    n = n + 1; lines[n*4-3], lines[n*4-2], lines[n*4-1], lines[n*4] = bx, by, cx, cy2
    n = n + 1; lines[n*4-3], lines[n*4-2], lines[n*4-1], lines[n*4] = cx, cy2, ax, ay
    ti = ti + step
  end
  return lines
end

function Preview:onDraw (focus, active)
  local x, y, sx, sy = self:getRectGlobal()
  DrawEx.RectOutline(x, y, sx, sy, Color(0.20, 0.35, 0.50, 0.55))
  local e = self.panel and self.panel.subject
  if e and e.isWormhole then
    -- Gates intentionally have no body or mesh. Show a compact portal
    -- schematic rather than leaving their target preview blank.
    local cx, cy = x + sx * 0.5, y + sy * 0.5
    local rx = math.min(sx, sy) * 0.36
    Draw.Color(0.20, 0.60, 1.00, 0.90)
    for ring = 1, 3 do
      local radius = rx * (1.0 - (ring - 1) * 0.24)
      local ry = radius * 0.68
      local segments = 32
      local px, py
      for i = 0, segments do
        local angle = 2.0 * math.pi * i / segments
        local nx, ny = cx + math.cos(angle) * radius,
                       cy + math.sin(angle) * ry
        if px then Draw.Line(px, py, nx, ny) end
        px, py = nx, ny
      end
    end
    Draw.Color(1, 1, 1, 1)
    return
  end
  if not (e and e.body and e.mesh) then return end
  local mesh = TargetInfo.ResolveMesh(e)
  if self.mesh ~= mesh then
    self.mesh = mesh
    self.lines = self:_buildLines(mesh)
  end
  local cxs, cys = x + sx * 0.5, y + sy * 0.5
  local scale = math.min(sx, sy) * 0.36
  Draw.Color(0.20, 0.60, 1.00, 0.90)
  if self.lines then
    for i = 1, #self.lines, 4 do
      Draw.Line(cxs + self.lines[i] * scale,     cys - self.lines[i+1] * scale,
                cxs + self.lines[i+2] * scale,   cys - self.lines[i+3] * scale)
    end
  else
    -- Schematic fallback for an entity without usable mesh data.
    local r = math.min(sx, sy) * 0.25
    Draw.Line(cxs-r, cys-r, cxs+r, cys-r)
    Draw.Line(cxs+r, cys-r, cxs+r, cys+r)
    Draw.Line(cxs+r, cys+r, cxs-r, cys+r)
    Draw.Line(cxs-r, cys+r, cxs-r, cys-r)
  end
  Draw.Color(1, 1, 1, 1)
end

function NpcInfoPanel:onLayoutPos (px, py, psx, psy)
  Widget.onLayoutPos(self, px, py, psx, psy)
  -- Match SectorPanel's 10px widget inset. Together with the HUD's 8px pad,
  -- both corner panels sit 18px from their screen edges.
  self.x = self.x - 10
  self.y = self.y + 10
end

function NpcInfoPanel:onDraw (focus, active)
  local x, y, sx, sy = self:getRectGlobal()
  -- Same plate and outline as UI.SectorPanel.
  DrawEx.Panel(x, y, sx, sy, Color(0.02, 0.03, 0.06, 0.78), 0.5)
  DrawEx.RectOutline(x, y, sx, sy, Color(0.35, 0.55, 0.75, 0.55))
end

function NpcInfoPanel:setSubject (e)
  self.subject = e
end

local function shorten (s, n)
  s = tostring(s or '')
  if #s <= n then return s end
  return s:sub(1, n - 3) .. '...'
end

function NpcInfoPanel.Create (ltheory)
  local self = setmetatable({
    ltheory  = ltheory,
    subject  = nil,
    children = List(),
  }, NpcInfoPanel)
  self:setAlign(1.0, 0.0):setStretch(0, 0):setPadUniform(12)

  local function liveSubject ()
    local e = self.subject
    if e and Targeting.IsTargetable(e) then return e end
    return nil
  end

  local title = Label('Target Info')
  title:setFontColor(Config.ui.color.accent)

  local preview = setmetatable({ panel = self }, Preview)

  local details = Grid():setCols(2):setPadCellX(12):setPadCellY(3)
  local function row (name, poll)
    local key = Label(type(name) == 'function' and '' or name)
      :setFontColor(Config.ui.color.textTitle)
    if type(name) == 'function' then key:setPollFn(name) end
    local val = Label(''):setFontColor(Config.ui.color.textNormal):setPollFn(poll)
    details:add(key):add(val)
  end
  local function contactFor (e)
    local player = self.ltheory and self.ltheory.player
    if not (e and player) then return nil end
    return ScannerDB.ContactFor(player:getScannerDB(), e)
  end

  row('Name', function ()
    local e = liveSubject()
    return e and shorten(TargetInfo.Name(e), 30) or ''
  end)
  row(function ()
    local e = liveSubject()
    if e and e.isWormhole then return 'Destination' end
    return e and e.isPlanet and 'Radius' or 'Health'
  end, function ()
    local e = liveSubject()
    if not e then return '' end
    if e.isWormhole then return TargetInfo.Destination(e) or '' end
    if e.isPlanet then return format('%.0f', e:getRadius()) end
    return e.health and format('%d / %d', e:getHealth(), e.healthMax) or ''
  end)
  row(function ()
    local e = liveSubject()
    return e and e.isAsteroid and 'Composition' or ''
  end, function ()
    local e = liveSubject()
    return e and TargetInfo.Composition(e, contactFor(e)) or ''
  end)
  row(function ()
    local e = liveSubject()
    local contact = e and contactFor(e)
    return e and e.isAsteroid and contact and contact.yieldIdentified and 'Remaining' or ''
  end, function ()
    local e = liveSubject()
    return e and TargetInfo.Deposit(e, contactFor(e)) or ''
  end)
  row(function ()
    local e = liveSubject()
    return e and TargetInfo.HasDisposition(e) and 'Disposition' or ''
  end, function ()
    local e = liveSubject()
    local player = self.ltheory and self.ltheory.player
    if not (e and player and TargetInfo.HasDisposition(e)) then return '' end
    return format('%+.1f', e:getOwnerDisposition(player))
  end)
  row('Distance', function ()
    local e = liveSubject()
    local player = self.ltheory and self.ltheory.player
    local ship = player and player:getControlling()
    if not (e and ship and ship.body) then return '' end
    return format('%.0f', (e:getPos() - ship:getPos()):length())
  end)
  row('Surface gap', function ()
    local e = liveSubject()
    local player = self.ltheory and self.ltheory.player
    local ship = player and player:getControlling()
    if not (e and ship and ship.body) then return '' end
    return format('%.0f', TargetInfo.SurfaceGap(e, ship))
  end)

  local body = Grid():setCols(2):setPadCellX(14):setPadCellY(0)
  body:add(preview):add(details)
  local layout = Grid():setCols(1):setPadCellY(8)
  layout:add(title):add(body)
  self:add(layout)
  return self
end

return NpcInfoPanel
