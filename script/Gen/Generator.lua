local generators = {}

local function Add (type, weight, fn)
  if not generators[type] then generators[type] = Distribution() end
  generators[type]:add(fn, weight)
end

local function Get (type, rng)
  local dist = generators[type]
  if not dist then
    Log.Error("No generators for asset type '%s' are loaded", type)
    return nil
  end
  return dist:sample(rng)
end

return {
  Add = Add,
  Get = Get,
}
