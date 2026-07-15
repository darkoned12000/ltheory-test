local MyTest = Application()

function MyTest:onInit()
  printf("Hello from my new environment!")
end

function MyTest:onUpdate(dt)
  -- Game logic here
end

function MyTest:onDraw()
  -- Rendering calls here
end

return MyTest
