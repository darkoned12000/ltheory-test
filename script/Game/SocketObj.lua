local LTheory_Socket = class(function (self, type, pos, external, typeIndex, moduleId)
  self.type = type
  self.pos = pos
  self.external = external
  self.typeIndex = typeIndex
  self.moduleId = moduleId
  self.child = nil
end)

return LTheory_Socket
