local LTheory_Socket = class(function (self, type, pos, external)
  self.type = type
  self.pos = pos
  self.external = external
  self.child = nil
end)

return LTheory_Socket
