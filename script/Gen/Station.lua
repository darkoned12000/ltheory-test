-- objects
local Joint        = require('Gen.ShapeLib.Joint')
local JointField   = require('Gen.ShapeLib.JointField')
local Shape        = require('Gen.ShapeLib.Shape')
local Style        = require('Gen.ShapeLib.Style')

-- shapes
local BasicShapes  = require('Gen.ShapeLib.BasicShapes')
local Cluster      = require('Gen.ShapeLib.Cluster')
local Scaffolding  = require('Gen.ShapeLib.Scaffolding')
local Module       = require('Gen.ShapeLib.Module')
local RandomShapes = require('Gen.ShapeLib.RandomShapes')

-- warps
require('Gen.ShapeLib.Warp')

-- util
local MathUtil     = require('Gen.MathUtil')
local Parametric   = require('Gen.ShapeLib.Parametric')

local sin, cos = math.sin, math.cos

local Station = {}

function Station.GenerateStation (seed)
  local rng = RNG.Create(seed)

  -- Force higher side counts (min 8) so station hull is circular/octagonal instead of a 4-sided box
  local res = rng:choose({8, 10, 12, 16, 20})
  local shape = BasicShapes.Prism(2, res)
  shape:rotate(0, math.pi / 2, 0)

  -- Extrude forward superstructure
  local pi = shape:getPolyWithNormal(Vec3d(0, 0, 1))
  local t = math.pi * 1.05
  local l = rng:getUniformRange(1.0, 3.0)
  shape:extrudePoly(pi, l,
            Vec3d(rng:getUniformRange(0.2, 0.6), rng:getUniformRange(0.2, 0.6), rng:getUniformRange(0.2, 0.6)),
            Vec3d(0, sin(t), -cos(t)))

  -- Extrude aft section
  local back = shape:getPolyWithNormal(Vec3d(0, 0, -1))
  shape:extrudePoly(back, 0.5, Vec3d(0.5, 0.5, 0.5), Vec3d(0, sin(t), cos(t)))

  -- Add side pod attachments
  local bodyAABB = shape:getAABB()
  for i = 1, rng:getInt(2, 4) do
    local pod = BasicShapes.Prism(2, res)
    pod:scale(0.2, 0.2, 0.8)
    pod:rotate(0, (i / 4.0) * math.pi * 2.0, 0)
    shape:add(pod)
  end

  -- Bevel edges and apply surface details
  shape = shape:bevel(rng:getUniformRange(0.1, 0.3))
  shape:greeble(rng, 1, 0.01, 0.03)

  -- Scale station bounds (~30m radius)
  local rcpRadius = 30.0 / math.max(0.001, shape:getRadius())
  shape:scale(rcpRadius, rcpRadius, rcpRadius)

  rng:free()
  return shape:finalize()
end

return Station
