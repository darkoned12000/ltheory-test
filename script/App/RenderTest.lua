local RenderTest = Application()

function RenderTest:onInit()
  printf("Rendering test started...")
end

function RenderTest:onUpdate(dt)
  -- Define the UI here
  ImGui.Begin(self.resX, self.resY)
    ImGui.BeginWindow("Render Test", 300, 200)
      ImGui.Text("If you see this, graphics are working!")
      if ImGui.Button("Click Me") then
        printf("Button clicked!")
      end
    ImGui.EndWindow()
  ImGui.End()
end

function RenderTest:onDraw()
  -- Render the defined UI
  ImGui.Draw()
end

return RenderTest
