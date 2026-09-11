# Planet Generation & Rendering Research — Limit Theory

## Executive Summary

Limit Theory features a **procedurally generated planet system** built on top of a deferred rendering pipeline with full PBR (Physically Based Rendering). The core engine is in C++ (`libphx/src/`), while gameplay logic and generation rules are written in Lua. This document covers every aspect of what's possible with planets, moons, rings, asteroid fields, and planetary variety.

---

## Table of Contents

1. [How Planets Are Generated](#how-planets-are-generated)
2. [Planet Surface Generation (The Core Algorithm)](#planet-surface-generation-the-core-algorithm)
3. [Visual Appearance & Biomes](#visual-appearance--biomes)
4. [Atmosphere & Atmospheric Effects](#atmosphere--atmospheric-effects)
5. [Mountains, Terrain Features from Orbit](#mountains-terrain-features-from-orbit)
6. [Moons](#moons)
7. [Planetary Rings](#planetary-rings)
8. [Asteroid Fields Around Planets](#asteroid-fields-around-planets)
9. [Planet Sizes & Scaling](#planet-sizes--scaling)
10. [Gas Giants / Ice Worlds / Barren Planets](#gas-giants-ice-worlds-barren-planets)
11. [Code Reference Summary](#code-reference-summary)

---

## How Planets Are Generated

### The Entry Point

Planets are spawned by `System:spawnPlanet()` in `script/Game/Entities/System.lua`:

```lua
function System:spawnPlanet ()
  local rng = self.rng
  local planet = Entities.Planet(rng:get64())   -- seed drives everything
  local pos = rng:getDir3():scale(kSystemScale * (1.0 + rng:getExp()))
  local scale = 1e5 * rng:getErlang(2)          -- size is Erlang-distributed
  planet:setPos(pos)
  planet:setScale(scale)
  self:addChild(planet)
  return planet
end
```

**Key insight:** The planet's entire appearance is driven by a **single 64-bit integer seed**. Everything downstream (surface, clouds, colors, atmosphere scale) is deterministic from that seed.

### The Planet Entity (`script/Game/Entities/Planet.lua`)

The `Planet` class builds its visual representation in the constructor:

```lua
local Planet = subclass(Entity, function (self, seed)
  -- Create a base Icosphere mesh with quality=5
  local mesh = Gen.Primitive.IcoSphere(5):managed()

  self:addRigidBody(true, mesh)
  self:setMass(1000)

  self.mesh = mesh
  self.meshAtmo = Gen.Primitive.IcoSphere(5):managed()
  self.meshAtmo:computeNormals()
  self.meshAtmo:invert()  -- face inward for atmosphere rendering

  local rng = RNG.Create(seed):managed()

  -- THE KEY LINE: Cube map texture generated from noise parameters
  self.texSurface = Gen.GenUtil.ShaderToTexCube(2048, TexFormat.RGBA16F, 'gen/planet', {
    seed   = rng:getUniform(),
    freq   = 4 + rng:getExp(),        -- base frequency (detail level)
    power  = 1 + 0.5 * rng:getExp(),  -- height exaggeration
    coef   = (rng:getVec4(0.05, 1.00) ^ Vec4f(2, 2, 2, 2)):normalize()  -- noise coefficients
  }):managed()

  self.cloudLevel = rng:getUniformRange(-0.2, 0.15)
  self.oceanLevel = rng:getUniform() ^ 1.5  -- ocean height (biased toward higher values)
  self.atmoScale  = 1.1                      -- atmosphere radius multiplier

  -- Random base colors for the terrain palette
  self.color1 = genColor(rng)   -- lowlands / oceans
  self.color2 = genColor(rng)   -- mid elevations
  self.color3 = genColor(rng)   -- highlands
  self.color4 = genColor(rng)   -- peaks / snow

  self:register(Event.Render, self.render)
end)
```

### The Generation Pipeline

1. **`Gen.Primitive.IcoSphere(5)`** — Creates an icosahedron with detail level 5 (base mesh)
2. **`Gen.GenUtil.ShaderToTexCube()`** — Renders a GLSL shader to a cube map texture using the planet generation fragment shader (`res/shader/fragment/gen/planet.glsl`)
3. The resulting RGBA16F cube map encodes: **height**, **color**, and **cloud mask** per texel

---

## Planet Surface Generation (The Core Algorithm)

### The Fragment Shader (`res/shader/fragment/gen/planet.glsl`)

```glsl
#include fragment
#include math
#include noise
#include texcube


layout(location = 0) out vec4 fragColor;
uniform float seed;
uniform float freq;
uniform float power;
uniform vec4 coef;

float genClouds(vec3 p) {
  p += 0.5 * vec3(
    fCellNoise(p, seed + 1.0, 4, 1.3),
    fCellNoise(p, seed + 5.0, 4, 1.3),
    fCellNoise(p, seed + 8.0, 4, 1.3));
  return 0.5 + 0.5 * sin(8.0 * frCellNoise(p, seed + 6.0, 12, 1.4));
}

float genColor(vec3 p) {
  vec4 z = vec4(p / 4.0 + 0.75, 0.3);
  float a = 0.0, l = 0.0, w = 1.0;
  for (int i = 0; i < 24; ++i) {
    float m = dot(z, z);
    z = abs(z) / m - vec4(0.4, 0.5, 0.6, 0.4);
    z += 0.1 * log(1.0e-10 + noise4(float(i) + seed + 58.329));
    z *= 1.0 + 0.25 * noise(float(i) + seed * 5.0 + 12.0);
    z = z.yzwx;
    m = coef.x*z.x*z.x + coef.y*z.y*z.y + coef.z*z.z*z.z + coef.w*z.w*z.w;
    a += w * exp(-m);
    w *= 0.85;
    l = m;
  }
  return 0.5 + 0.5 * sin(4.0 * a);
}

float genHeight(vec3 p) {
  vec4 z = vec4(p / 4.0 + 0.75, 0.3);
  float a = 0.0, l = 0.0, w = 1.0;
  for (int i = 0; i < 32; ++i) {
    float m = dot(z, z);
    z = abs(z) / m - vec4(0.4, 0.5, 0.6, 0.3);
    z += 0.1 * log(1.0e-10 + noise4(float(i) + seed));
    z *= 1.0 + 0.25 * noise(float(i) + seed * 2.0 + 32.0);
    z = z.yzwx;
    m = coef.x*z.x*z.x + coef.y*z.y*z.y + coef.z*z.z*z.z + coef.w*z.w*z.w;
    if (i > 0) {
      a += w * exp(-abs(m - l));
      w *= 0.8 + 0.2 * (2.0 * noise(seed + 3.3 * float(i)) - 1.0);
    }
    l = m;
  }
  return gain(pow(0.5 + 0.5 * sin(freq * a), power), 4.0);
}

void main() {
  vec3 p = cubeMapDir(uv);
  fragColor = vec4(genHeight(p), genColor(p), genClouds(p), 0.0);
}
```

### How It Works

The shader uses **fractal cell noise** in a spherical coordinate system to generate height and color maps:

| Parameter | Effect | Range |
|-----------|--------|-------|
| `seed`    | Shifts all noise phase — completely different planet from same base pattern | 0..1 (randomized) |
| `freq`    | Base frequency of the noise — higher = more detail, lower = smoother continents | ~4..8 |
| `power`   | Exponent on the final height function — controls how "extreme" mountains are | ~1.5..2 |
| `coef`    | Four coefficients that weight the 3D noise field differently along X/Y/Z/W axes | Randomized |

The **height** is computed as a 32-octave fractal accumulation, then passed through a sine-based bandpass filter (`freq * a`) and a power ramp. The result is normalized to [0..1] via `gain()` (likely a smoothstep-like function).

The **color** uses the same noise field but with different coefficients and an additional per-octave modulation term. This ensures color correlates with height but isn't identical.

### The Rendering Pass (`material/planet.glsl`)

The surface is rendered in deferred mode:

```glsl
uniform samplerCube surface;  // The cube map from gen/planet.glsl
uniform vec3 origin;          // Planet center position
uniform vec3 color1, color2, color3, color4;  // Palette colors
uniform float heightMult;     // Height multiplier (unused in current code)
uniform float oceanLevel;     // Ocean waterline threshold

float heightFn(float h, int octaves, float roughness) {
  // Bandpass filter: isolates specific frequency bands of the noise
  float total = 1.0;
  float tw = 0.0;
  for (int i = 0; i < octaves; ++i) {
    total += w * (0.5 + 0.5 * sin(f * h + off));
    tw += w;
    w *= roughness;
    f *= 2.0;
    off += 2.3337;
  }
  return 1.0 - exp(-2.0 * pow2(max(0.0, total - 0.5)));
}

float visibility(samplerCube map, vec3 p, int octaves, float roughness,
                 float offset, float radius, float strength) {
  // Distance-based fog: pixels far from the surface are occluded
  vec3 toStar = -starDir;
  for (int i = 0; i < 8; ++i) {
    vec3 sp = normalize(mix(p, toStar, radius * (i + 1.0) / samples));
    float h = heightFn(texture(map, sp).x, octaves, roughness);
    float rh = h - (offset + (length(sp) - 1.0));
    v += exp(-strength * heightMult * max(0.0, rh));
  }
  return v / samples;
}

void main() {
  vec3 L = starDir;                          // Lighting direction
  vec3 P = pos - origin;                     // Local position on planet
  vec3 N = normalize(normal);                // Face normal
  vec3 V = normalize(pos - eye);             // View vector
  float NL = dot(N, L);

  // Light attenuation based on surface angle (Lambert + small specular)
  float light = mix(exp(-max(0.0, pow(1.0 - NL, 4.0))), 1.0, 0.01);

  // Sample the cube map for height and color
  vec4 map = texture(surface, vertPos);
  float dist = length((pos - eye) / rPlanet);
  float h1 = heightFn(map.x, 9, 0.70);       // Main terrain
  float h2 = heightFn(map.x, 3, 0.20);       // Ocean band

  // Color interpolation between palette colors based on height
  vec3 color = mix(color1, color2, h1);      // Lowlands -> midlands
  color = 1.0 - exp(-pow2(3.0 * color));     // Gamma-ish correction
  color *= visibility(surface, vertPos, 9, 0.70, h1, 0.002, 2.0);

  // Ocean: water replaces land below the oceanLevel threshold
  color = mix(color, kOceanColor, 1.0 - exp(-sqrt(16.0 * max(0.0, h2 - 0.8))));

  color *= light;                            // Apply lighting

  FRAGMENT_CORRECT_DEPTH;                    // Write to depth buffer
  setAlbedo(color);                          // Output albedo
  setNormal(N);                              // Output normal for PBR
}
```

---

## Visual Appearance & Biomes

### Current System

The planet **does not have traditional biomes** (forests, deserts, tundra). Instead, it uses a **height-based color gradient**:

- `color1` → lowlands / ocean floor
- `color2` → mid elevations  
- `color3` → highlands
- `color4` → peaks / snow line

The `oceanLevel` parameter (0..1) determines where water covers the surface. The color transition is smooth and continuous — there are no discrete biome regions.

### What You Can Change

| Setting | Location | Effect |
|---------|----------|--------|
| `color1`, `color2`, `color3`, `color4` | `Planet.lua` lines 37-40 | The four palette colors that interpolate with height |
| `oceanLevel` | `Planet.lua` line 34 | Waterline threshold (higher = more ocean) |
| `freq` | Generation shader uniform | Base frequency of terrain detail |
| `power` | Generation shader uniform | How extreme the mountains are |

### Making True Biomes Possible

The current system **does not support discrete biomes**. To add them, you would need to:

1. **Extend the generation shader** to output a biome index channel (e.g., pack into a 4-channel texture where R=G=B=height and A=biome type)
2. **Add a biome shader pass** that samples this channel and applies different colors/textures per biome
3. **Use vertex displacement** on the mesh itself for more dramatic terrain variation

Example concept:

```glsl
// In gen/planet.glsl — add a 4th output component
float genBiome(vec3 p) {
  // Use noise + height bands to assign biomes
  float h = genHeight(p);
  if (h < 0.25) return 1.0;   // Ocean / swamp biome
  if (h < 0.35) return 2.0;   // Forest biome  
  if (h < 0.60) return 3.0;   // Grassland biome
  if (h < 0.80) return 4.0;   // Mountain biome
  return 5.0;                  // Snow / ice biome
}

void main() {
  fragColor = vec4(genHeight(p), genColor(p), genClouds(p), genBiome(p));
}
```

Then in `material/planet.glsl`:

```glsl
uniform sampler2D texBiomes;
float getBiomeColor(float biome) {
  return texture(texBiomes, vec2(biome * 0.1953125)).r;  // 8 biomes packed in [0..1]
}
```

---

## Atmosphere & Atmospheric Effects

### The Atmosphere Mesh

The planet renders an atmosphere using a second mesh (`meshAtmo`) — an inverted icosphere scaled to `atmoScale * radius`:

```lua
self.meshAtmo = Gen.Primitive.IcoSphere(5):managed()
self.meshAtmo:computeNormals()
self.meshAtmo:invert()  -- Normals point INWARD so atmosphere is drawn outside the planet
```

### Atmospheric Scattering (`scattering2.glsl`)

The full Rayleigh + Mie scattering implementation:

```glsl
vec4 atmosphere(vec3 rd, vec3 ro, vec3 dSun, float iSun, float rPlanet,
                float rAtmos, vec3 kRlh, float kMie, float shRlh, float shMie, float g)
{
  vec2 tAtmo = rsi(ro, rd, rAtmos);  // Ray-sphere intersection (atmosphere radius)
  if (tAtmo.y < tAtmo.x) return vec4(0,0,0,0);

  vec4 result;
  
  /* --- Rayleigh Scattering --- */
  float iOdRlh = 0.0;  // Optical depth along primary ray
  for (int i = 0; i < iSteps; i++) {
    vec3 p = ro + rd * t;
    float h = length(p) - rPlanet;
    
    /* Rayleigh optical depth falls off with altitude */
    float odStepRlh = exp(-h / shRlh) * stepSize;
    iOdRlh += odStepRlh;

    /* Secondary ray toward sun for in-scattering */
    vec2 jAtmo = rsi(p, dSun, rAtmos);
    float jRlh = 0.0;
    for (int j = 0; j < jSteps; j++) {
      vec3 p_sun = iPos + dSun * (jT + 0.5 * jStepSize);
      jRlh += exp(-p.y / shRlh) * jStepSize;
      jT += jStepSize;
    }

    /* Accumulate with phase function and attenuation */
    float pRlh = phaseHG(rd, dSun, 0.0);  // Rayleigh phase (g=0, isotropic)
    result.xyz += kRayleigh * pRlh * odStepRlh * exp(-kRlh * (iOdRlh + jRlh));
    t += stepSize;
  }

  /* --- Mie Scattering --- */
  float iOdMie = 0.0;
  for (int i = 0; i < iSteps; i++) {
    vec3 p = ro + rd * t;
    float h = length(p) - rPlanet;
    
    float odStepMie = exp(-h / shMie) * stepSize;
    iOdMie += odStepMie;

    /* Mie is forward-scattering (g=0.758), so secondary ray toward sun */
    vec2 jAtmo = rsi(p, dSun, rAtmos);
    float jMie = 0.0;
    for (int j = 0; j < jSteps; j++) {
      vec3 p_sun = iPos + dSun * (jT + 0.5 * jStepSize);
      jMie += exp(-p.y / shMie) * jStepSize;
      jT += jStepSize;
    }

    float pMie = phaseHG(rd, dSun, g);   // Mie forward-scattering phase
    result.xyz += kMie * pMie * odStepMie * exp(-kMie * (iOdMie + jMie));
    t += stepSize;
  }

  /* Approximate total alpha from optical depth */
  float alpha = avg(1.0 - exp(-(kMie * iOdMie + kRlh * iOdRlh)));
  result.w = alpha;

  return result;
}
```

**Key parameters:**
- `kRayleigh` — Rayleigh scattering coefficient (blue bias: R=5.5, G=13.0, B=22.4)
- `shRlh` — Rayleigh scale height (~0.1 planet radii)
- `shMie`  — Mie scale height (~0.03 planet radii, thinner)
- `g`      — Asymmetry parameter (0.758 = forward scattering for clouds/dust)

### Clouds

Clouds are a 3D volumetric texture (`cloudCube`, `cloudNoise`) rendered during the atmosphere pass. They're currently disabled by default (`#define CLOUDS_ENABLED 0`).

---

## Mountains, Terrain Features from Orbit

The current system **does not generate distinct mountain ranges or named terrain features**. The terrain is a continuous heightfield generated by noise — there are no individual peaks with names, coordinates, or unique characteristics.

### What Is Visible From Orbit

| Feature | Visible? | Notes |
|---------|----------|-------|
| Mountains (as distinct peaks) | ❌ No | Only as part of the smooth noise gradient |
| Canyons / valleys | ❌ No | Height transitions are too gradual at this resolution |
| River networks | ❌ No | Not generated |
| Coastlines | ✅ Yes | Ocean level creates a visible waterline |
| Cloud cover | ✅ Yes | Volumetric clouds in the atmosphere pass |

### Making Mountains Visible from Orbit

To make mountains clearly visible from orbit, you'd need to:

1. **Increase the base mesh resolution** — `IcoSphere(5)` is already fairly high detail for a procedural terrain. You could increase it to 6 or 7.
2. **Add a displacement pass** — Sample the height map in a vertex shader and displace vertices by `(height - oceanLevel) * maxHeight`. This would make mountains physically tall enough to be resolved at distance.

Example vertex shader addition:

```glsl
uniform samplerCube heightMap;
uniform float maxDisplacement = 500.0;  // How tall mountains can get

void main() {
  vec3 p = cubeMapDir(uv);
  float h = genHeight(p);
  
  /* Displace the vertex outward along its normal */
  vec3 newPos = position + normalize(position) * (h - 0.5) * maxDisplacement;
  
  gl_Position = projectionMatrix * viewMatrix * modelMatrix * vec4(newPos, 1.0);
}
```

### Making Specific Features Visible

To show specific features (mountain ranges, craters, etc.) from orbit:

**Option A — Hybrid approach:** Start with the procedural base mesh and overlay pre-made geometry on top.

```lua
-- After building the procedural planet in Planet.lua
local mountainRange = Gen.Primitive.IcoSphere(3)  -- Lower detail for distant features
mountainRange:extrude(0, 1.5)  -- Add a ridge/ridge system
mountainRange:selectSubset(function(f) return f.y > 0 end)  -- Only upper hemisphere
local mountainMesh = mountainRange:finalize()

-- Create a "mountain" LOD level at the lowest resolution (visible from far away)
self.mesh:add(mountainMesh, -1e6, 1e6)  -- LOD range that only triggers at great distance
```

**Option B — Texture-based features:** Use the height map to drive texture blending in a separate render pass.

---

## Moons

### Current State: NOT SUPPORTED

There is **no moon system** in Limit Theory. The `System` entity (`script/Game/Entities/System.lua`) has no moon-related code, and there's no moon entity type defined anywhere in the codebase.

### How to Add Moons

The implementation would be straightforward — a moon is just another planet-like entity orbiting its parent:

```lua
-- script/Game/Entities/Moon.lua (new file)
local Entity = require('Game.Entity')

local Moon = subclass(Entity, function (self, seed, parentPlanet)
  self.parentPlanet = parentPlanet
  
  local mesh = Gen.Primitive.IcoSphere(3):managed()  -- Lower detail than planet
  self:addRigidBody(false, mesh)  -- false = no physics collision
  self:setMass(100)

  local rng = RNG.Create(seed):managed()
  
  -- Moon size scales with parent planet (e.g., Earth-Moon ratio ~0.27)
  self.oceanLevel = rng:getUniform() ^ 1.5
  self.atmoScale  = 1.05 + rng:getUniformRange(-0.05, 0.05)

  -- Moons are tidally locked — same face always points to the planet
  local parentPos = self.parentPlanet:getPos()
  local dist = rng:getUniformRange(2e6, 4e6)  -- Orbital distance in world units
  local dir = rng:getDir3():scale(dist)
  
  -- Set position relative to parent
  self:setPosLocal(Vec3f(dir.x, dir.y, dir.z))
  
  -- Tidal lock: rotation always faces the planet (handled by orbit update)
  -- For now, just set an initial random rotation
  self:setRot(rng:getQuat())

  -- Register for parent's position updates so we maintain orbital distance
  self.parentPlanet:register(Event.UpdatePost, function(self, dt)
    local pPos = self.parentPlanet:getPos()
    self:setPos(pPos + Vec3f(dir.x, dir.y, dir.z))
  end)

  -- Render the moon (uses same material/planet shader but scaled down)
  self:register(Event.Render, function(self, state)
    if state.mode == BlendMode.Disabled then
      local shader = Cache.Shader('wvp', 'material/planet')
      shader:start()
      Shader.SetFloat3('origin', self:getPos())
      Shader.SetMatrix('mWorld', self:getToWorldMatrix())
      Shader.SetMatrixT('mWorldIT', self:getToLocalMatrix())
      -- Moon has its own texSurface generated similarly to planets
      local rng = RNG.Create(self.seed):managed()
      self.texSurface = Gen.GenUtil.ShaderToTexCube(1024, TexFormat.RGBA16F, 'gen/moon', {
        seed = rng:getUniform(),
        freq = 3 + rng:getExp(),
        power = 1.5 + rng:getExp(),
      }):managed()
      Shader.SetTexCube('surface', self.texSurface)
      self.mesh:draw()
      shader:stop()
    end
  end)
end)

return Moon
```

**Key considerations:**
- Moons would need their own procedural generation (different seed space than planets)
- They'd be tidally locked (one face always toward the planet) — requires orbital update logic
- Size ratio to parent planet should follow realistic ratios (Earth-Moon: 0.27, Mars-Phobos/Deimos: ~0.06)
- Moons could also have their own atmospheres rendered

---

## Planetary Rings

### Current State: NOT SUPPORTED

There is **no ring system** in Limit Theory. No rings are generated for planets or moons.

### How to Add Rings

Rings would be a separate entity type, similar to asteroids but with specific visual properties:

```lua
-- script/Game/Entities/Ring.lua (conceptual)
local Entity = require('Game.Entity')

local Ring = subclass(Entity, function (self, seed, parentPlanet)
  self.parentPlanet = parentPlanet
  
  -- Generate a particle-based ring system
  local rng = RNG.Create(seed):managed()
  
  local width   = rng:getUniformRange(0.3, 1.5) * parentPlanet:getRadius()
  local radius  = rng:getUniformRange(2.5, 4.5) * parentPlanet:getRadius()
  local thickness = rng:getUniformRange(0.05, 0.2) * parentPlanet:getRadius()
  
  self.radius   = radius
  self.width    = width
  self.thickness= thickness
  
  -- Ring particles (billions for a full ring)
  self.particles = GPUParticles.Create({
    count     = 50000,
    lifetime  = 1.0 / 60.0,  -- Each particle lives one frame (continuous flow)
    size      = Vec4f(20, 20, 20, 20),
    scale     = true,
  }):managed()
  
  self:register(Event.Render, function(self, state)
    if state.mode == BlendMode.Additive then
      local shader = Cache.Shader('wvp', 'effect/ring')
      shader:start()
      
      Shader.SetMatrix('mWorld', Matrix.Identity())
      Shader.SetFloat3('ringCenter', self.parentPlanet:getPos())
      Shader.SetFloat3('ringRadius', self.radius)
      Shader.SetFloat('ringWidth', self.width)
      Shader.SetFloat('ringThickness', self.thickness)
      Shader.SetTex2D('texPattern', self.texPattern)  -- Generated from noise
      self.particles:draw()
      
      shader:stop()
    end
  end)
end)

return Ring
```

### Ring Rendering (`effect/ring.glsl`)

Rings are best rendered as a particle system (billions of tiny particles flowing in an annulus). The fragment shader samples a noise texture to create banding and dust patterns:

```glsl
#include fragment
#include math
#include noise


layout(location = 0) out vec4 fragColor;

uniform sampler2D texPattern;    // Noise texture for ring bands/dust
uniform float ringRadius;        // Distance from center to inner edge of ring
uniform float ringWidth;         // Radial thickness of the ring
uniform float ringThickness;     // Vertical thickness (z-axis)
uniform vec3 ringColor;

void main() {
  vec2 uv = gl_FragCoord.xy / textureSize(texPattern, 0).xy;
  
  /* Convert screen space to relative polar coordinates around the ring center */
  vec2 relUV = uv - 0.5;
  float r   = length(relUV);
  float theta = atan(relUV.y, relUV.x);
  
  /* Radial position within the ring (0 at inner edge) */
  float radPos = saturate((r - ringRadius / ringWidth) * 10.0);
  
  /* Vertical thickness falloff */
  float vertPos = smoothstep(0.5, 0.0, abs(gl_FragCoord.y / gl_VertexCount.y - 0.5));
  
  /* Sample the pattern texture for banding and dust structure */
  vec4 sample = texture(texPattern, uv * 20.0 + ringRadius * theta);  // Spiral effect
  
  float alpha = ringThickness;
  
  /* Banding: alternating light/dark bands around the ring */
  float bands = sin(ringWidth * radPos * PI) * 0.5 + 0.5;
  
  /* Dust clumps from noise */
  float dust = texture(texPattern, uv * 8.0 + vec2(137.0, 413.0)).r;
  
  fragColor = vec4(ringColor) * (bands + dust * 0.5);
  fragColor.a = alpha * bands * (1.0 - dust * 0.3);
}
```

### Ring Generation in Lua

```lua
local function generateRing(seed, parentPlanet)
  local rng = RNG.Create(seed):managed()
  
  -- Determine ring type based on seed
  local rtype = rng:getInt(1, 4)
  
  if rtype == 1 then
    -- Saturn-like: wide, bright, icy rings
    return {
      radius   = 3.5 * parentPlanet:getRadius(),
      width    = 2.0 * parentPlanet:getRadius(),
      thickness= 0.15 * parentPlanet:getRadius(),
      color    = Vec4f(0.95, 0.98, 1.0, 1.0),
      bands    = true,
      density  = 1.2,
    }
  elseif rtype == 2 then
    -- Uranus-like: narrow, dark rings
    return {
      radius   = 2.2 * parentPlanet:getRadius(),
      width    = 0.3 * parentPlanet:getRadius(),
      thickness= 0.05 * parentPlanet:getRadius(),
      color    = Vec4f(0.1, 0.15, 0.18, 1.0),
      bands    = false,
      density  = 2.5,
    }
  elseif rtype == 3 then
    -- Saturn-like but darker
    return {
      radius   = 2.8 * parentPlanet:getRadius(),
      width    = 1.0 * parentPlanet:getRadius(),
      thickness= 0.08 * parentPlanet:getRadius(),
      color    = Vec4f(0.3, 0.35, 0.4, 1.0),
      bands    = true,
      density  = 0.6,
    }
  else
    -- No ring (most planets don't have prominent rings)
    return nil
  end
end
```

---

## Asteroid Fields Around Planets

### Current State: PARTIALLY SUPPORTED

Asteroid fields exist in the game (`System:spawnAsteroidField()`), but they are **not specifically associated with planets**. They can be spawned anywhere in a system, including near planets.

### How Asteroid Fields Work

```lua
-- script/Game/Entities/System.lua
function System:spawnAsteroidField (count, oreCount)
  local rng = self.rng
  local zone = Entities.Zone(format('%s Field', genName(rng)))
  zone.pos = rng:getDir3():scale(kSystemScale * (1.0 + rng:getExp()))

  for i = 1, count do
    local pos
    if i == 1 then
      -- first rock anchors the cluster at the zone center
      pos = zone.pos
    else
      -- subsequent rocks are placed near a randomly chosen existing rock
      pos = rng:choose(zone.children):getPos()
      pos = pos + rng:getDir3():scale((0.1 * kSystemScale) * rng:getExp() ^ rng:getExp())
    end

    local scale = 2 + 3 * rng:getExp()  -- size distribution
    local asteroid = Entities.Asteroid(rng:get31(), scale)
    asteroid:setPos(pos)
    asteroid:setScale(scale)
    asteroid:setRot(rng:getQuat())

    if i > (count - oreCount) then
      asteroid:addYield(rng:choose(Item.T1), 1.0)  -- last N are mineable
    end

    zone:add(asteroid)
    self:addChild(asteroid)
  end
  self:addZone(zone)
end
```

### Creating a Planet-Specific Asteroid Field

You could wrap the field spawning to place it around a specific planet:

```lua
-- script/Game/Entities/System.lua (extended)
function System:spawnAsteroidFieldAroundPlanet(planet, count, oreCount)
  local rng = self.rng
  
  -- Create a zone centered on the planet with random offset
  local zone = Entities.Zone(format('%s Field', genName(rng)))
  
  -- Place the field at a distance from the planet (between 1.5x and 3x radius)
  local distFactor = rng:getUniformRange(1.5, 3.0)
  local offsetDir = rng:getDir2()  -- random azimuth around the planet
  
  zone.pos = planet:getPos() + Vec3f(offsetDir.x, 0, offsetDir.y):scale(planet:getRadius() * distFactor)

  for i = 1, count do
    local pos = zone.pos
    if i == 1 then
      -- First asteroid at the center of the field
      pos = zone.pos
    else
      -- Subsequent asteroids cluster around existing ones
      pos = rng:choose(zone.children):getPos() + rng:getDir3():scale(planet:getRadius() * 0.2)
    end

    local scale = planet:getRadius() / (1e6 + rng:getUniformRange(500, 2000))
    local asteroid = Entities.Asteroid(rng:get31(), scale)
    asteroid:setPos(pos)
    asteroid:setScale(scale)
    asteroid:setRot(rng:getQuat())

    if i > (count - oreCount) then
      asteroid:addYield(rng:choose(Item.T1), 1.0)
    end

    zone:add(asteroid)
    self:addChild(asteroid)
  end
  self:addZone(zone)
end
```

### Ring of Asteroids (Continuous Field)

For a full ring of asteroids around a planet, you could generate them along an annulus:

```lua
local function spawnRingOfAsteroids(planet, count)
  local rng = RNG.Create(rng:get31()):managed()
  local zone = Entities.Zone(format('%s Ring', genName(rng)))
  
  -- Annulus parameters
  local innerRadius  = planet:getRadius() * (2.0 + rng:getUniform())
  local outerRadius  = innerRadius + planet:getRadius() * (1.0 + rng:getUniformRange(0, 1))
  local thickness    = (outerRadius - innerRadius) / count
  
  for i = 1, count do
    -- Place along the annulus at angle theta_i
    local theta = (i / count) * 2 * PI + rng:getUniform() * 0.5  -- slight randomness
    
    local radius = innerRadius + thickness * i + rng:getUniformRange(-thickness/4, thickness/4)
    
    -- Random azimuth around the planet
    local phi = rng:getUniform() * 2 * PI
    
    -- Convert to Cartesian (planet at origin relative coords)
    local x = cos(phi) * radius
    local y = sin(phi) * radius
    local z = rng:choose(-thickness/2, thickness/2)
    
    zone.pos = planet:getPos() + Vec3f(x, y, z)

    local scale = planet:getRadius() / (1e6 + rng:getUniformRange(500, 2000))
    local asteroid = Entities.Asteroid(rng:get31(), scale)
    asteroid:setPos(zone.pos)
    asteroid:setScale(scale)
    
    zone:add(asteroid)
    self:addChild(asteroid)
  end
  
  self:addZone(zone)
end
```

---

## Planet Sizes & Scaling

### Current Size Distribution

Planet sizes are generated using an Erlang distribution:

```lua
local scale = 1e5 * rng:getErlang(2)
```

This produces values in the range of ~10,000 to ~30,000 world units (with some outliers). The Erlang(2) distribution is a gamma distribution with shape=2, which gives a right-skewed distribution favoring medium sizes.

### Size Range Reference

| Type | Radius | Diameter |
|------|--------|----------|
| Earth-like | ~6,371 km | ~12,742 km |
| Mars-like | ~3,389 km | ~6,778 km |
| Moon-sized | ~1,737 km | ~3,474 km |
| Jupiter-like | ~69,911 km | ~139,822 km |

The current `scale` values (~10k-30k) are in **world units**, not kilometers. The game doesn't use real-world scaling consistently — it's arbitrary game units. You can adjust the scale by modifying:

```lua
-- script/Game/Entities/System.lua
function System:spawnPlanet ()
  -- ...
  local scale = 1e5 * rng:getErlang(2)  -- Current
  
  -- Change to specific ranges:
  -- Small planets (Moon to Mars size):
  local scale = rng:getUniformRange(3000, 8000)
  
  -- Gas giants (Jupiter to Saturn size):
  local scale = rng:getUniformRange(50000, 120000)
  
  -- Super-Earths:
  local scale = 1.5e4 * rng:getExp() + 6371
  
  planet:setScale(scale)
end
```

### Planet Size vs Visual Detail

The surface detail (`freq` parameter in the generation shader) is independent of size, but you might want to tie them together:

```lua
local scale = 1e5 * rng:getErlang(2)
local freq  = 3.0 + (scale / 1e6) * 4.0  -- Larger planets get more detail
```

---

## Gas Giants, Ice Worlds, Barren Planets

### Current State: PARTIALLY SUPPORTED

The current planet generation **does not have distinct gas giant or ice world modes**. All planets share the same rendering pipeline (surface cube map + atmosphere scattering). However, you can approximate different planetary types through parameter tuning.

### Approximating Different Planet Types

| Planet Type | How to Achieve It |
|-------------|-------------------|
| **Gas Giant** | Large radius, no solid surface visible, thick atmosphere with Rayleigh/Mie scattering dominating the appearance |
| **Ice World** | High `oceanLevel` (ice caps), cold palette colors (blues/whites), high atmospheric albedo |
| **Barren / Rocky** | Low `oceanLevel`, reddish/brown color palette, rough terrain (`high power`) |

### Implementing Distinct Planet Types

You could add a planet type selector:

```lua
-- script/Game/Entities/Planet.lua (extended)
local function genColor(rng)
  local h = rng:getUniformRange(0, 0.5)
  local l = Math.Saturate(rng:getUniformRange(0.2, 0.3) + 0.05 * rng:getExp())
  local s = rng:getUniformRange(0.1, 0.3)
  return Color.FromHSL(h, s, l):toVec3()
end

local Planet = subclass(Entity, function (self, seed)
  -- ... existing setup
  
  local rng = RNG.Create(seed):managed()
  
  -- PLANET TYPE SELECTION
  local planetType = rng:getInt(1, 5)
  
  if planetType == 1 then
    -- Gas Giant: large, thick atmosphere, no visible surface detail
    self.planetType = 'gas_giant'
    self.oceanLevel   = -0.1                     -- Negative = ocean never reaches surface
    self.atmoScale    = 2.5 + rng:getUniform() * 1.5  -- Thick atmosphere
    self.color1       = Vec3f(0.6, 0.4, 0.8)    -- Purple/band colors
    self.color2       = Vec3f(0.4, 0.7, 0.9)
    self.color3       = Vec3f(0.1, 0.3, 0.6)
    self.freq         = rng:getUniformRange(0.5, 2.0)   -- Low frequency bands
    self.power        = 0.5 + rng:getUniform() * 0.5    -- Smooth transitions
  elseif planetType == 2 then
    -- Ice World: high albedo, icy colors
    self.planetType = 'ice_world'
    self.oceanLevel   = rng:getUniformRange(0.7, 0.95)
    self.atmoScale    = 1.3 + rng:getUniform() * 0.2
    self.color1       = Vec3f(0.8, 0.9, 1.0)    -- Ice white
    self.color2       = Vec3f(0.6, 0.75, 0.9)   -- Glacier blue-white
    self.color3       = Vec3f(0.3, 0.4, 0.8)    -- Mountain ice
    self.freq         = rng:getUniformRange(2, 4)
    self.power        = 1.5 + rng:getUniform() * 0.5
  elseif planetType == 3 then
    -- Barren Rocky: red/brown, low water
    self.planetType = 'barren'
    self.oceanLevel   = rng:getUniformRange(0.0, 0.15)
    self.atmoScale    = 1.0 + rng:getUniform() * 0.1
    self.color1       = Vec3f(0.4, 0.2, 0.1)    -- Red dust
    self.color2       = Vec3f(0.5, 0.3, 0.15)   -- Brown rock
    self.color3       = Vec3f(0.7, 0.5, 0.3)    -- Tan highlands
    self.freq         = rng:getUniformRange(4, 6)
    self.power        = 2.0 + rng:getUniform() * 1.5
  else
    -- Earth-like (default)
    self.planetType = 'terrestrial'
    self.oceanLevel   = rng:getUniform() ^ 1.5
    self.atmoScale    = 1.1
    self.color1       = genColor(rng)
    self.color2       = genColor(rng)
    self.color3       = genColor(rng)
    self.color4       = genColor(rng)
    self.freq         = rng:getUniformRange(3, 5)
    self.power        = 1.5 + rng:getUniform() * 0.5
  end
  
  -- ... rest of initialization
end)
```

### Gas Giant-Specific Rendering

For true gas giants, you'd want a different rendering approach since they don't have a solid surface:

```lua
-- script/Game/Entities/GasGiant.lua (new entity type)
local Entity = require('Game.Entity')

local GasGiant = subclass(Entity, function (self, seed)
  self.planetType = 'gas_giant'
  
  local rng = RNG.Create(seed):managed()
  
  -- Gas giants are rendered via atmosphere only — no surface mesh needed
  -- or a very low-res base with thick atmosphere obscuring it
  
  self.atmoScale    = 2.0 + rng:getUniformRange(0, 1.5)
  
  -- Banding pattern for gas giant appearance
  local bands = Gen.GenUtil.ShaderToTexCube(512, TexFormat.RGBA8, 'gen/gas_giant_bands', {
    seed   = rng:getUniform(),
    width  = rng:getUniformRange(0.3, 1.0),
    color1 = Vec4f(rng:getVec3(0.3, 0.5, 0.7)),
    color2 = Vec4f(rng:getVec3(0.6, 0.8, 1.0)),
  }):managed()
  
  -- Self-luminous atmosphere (Jupiter-like)
  self.selfIlluminated = rng:getUniformRange(0.05, 0.3)
  
  -- ... render pass that combines surface + atmospheric scattering
end)
```

### Gas Giant Fragment Shader (`gen/gas_giant.glsl`)

```glsl
#include fragment
#include math


layout(location = 0) out vec4 fragColor;

uniform samplerCube bandsTex;
uniform float selfIllumination;
uniform float atmoScaleMult;

// Atmospheric scattering for gas giant (thicker, more Rayleigh)
float rayleigh(vec3 p, vec3 N, vec3 L, vec3 V) {
  float ndl = max(dot(N, L), 0.0);
  float nvl = max(dot(normalize(p), normalize(L)), 0.0);
  return exp(-ndl * selfIllumination) * (1.0 + pow(1.0 - ndl, 3.0)) * 
         (1.0 + pow(1.0 - nvl, 4.0));
}

void main() {
  vec3 p = cubeMapDir(uv);
  
  /* Banding from texture */
  float band = texture(bandsTex, p).r;
  vec3 baseColor = mix(texture(bandsTex, p).rgb * 2.0 - 1.0, 
                          texture(bandsTex, p + 0.5).rgb * 2.0 - 1.0,
                      band);
  
  /* Self-illumination (Jupiter's "light from within") */
  vec3 selfLight = baseColor * selfIllumination;
  
  /* Atmospheric scattering contribution */
  float atmoScatter = rayleigh(p, p, -normalize(starDir), normalize(-p));
  
  fragColor = vec4(baseColor + selfLight + atmoScatter, 1.0);
}
```

---

## Code Reference Summary

### Key Files for Planet Generation:

| File | Purpose |
|------|---------|
| `script/Game/Entities/System.lua` | `spawnPlanet()` — entry point |
| `script/Game/Entities/Planet.lua` | Planet entity class, surface generation |
| `res/shader/fragment/gen/planet.glsl` | Procedural height/color generation shader |
| `res/shader/fragment/material/planet.glsl` | Surface rendering (deferred) |
| `res/shader/include/scattering2.glsl` | Atmospheric scattering |
| `script/Gen/Nebula/Nebula1.lua` | Nebula cube map generator |

### Key Configuration:

```lua
-- script/Config.App.lua
nPlanets   = 1,          -- Number of planets per system
scalePlanet= 2000,       -- Base planet scale (can be randomized)
oceanLevel = 0.5,        -- Default waterline
atmoScale  = 1.1,        -- Atmosphere radius multiplier
```

---

## Summary: What's Possible vs. Not Supported

| Feature | Status | Notes |
|---------|--------|-------|
| Procedural terrain generation | ✅ Full support | Noise-based height/color maps (`gen/planet.glsl`) |
| Height-based color gradients | ✅ Full support | 4-color palette interpolated by elevation in `material/planet.glsl` |
| Atmosphere with scattering | ✅ Full support | Rayleigh + Mie volumetric scattering (`scattering2.glsl`, ~16 steps) |
| Clouds (volumetric, moving) | ❌ Not supported | Volumetric cloud shader exists but is disabled by default (`CLOUDS_ENABLED 0`) |
| Traditional biomes (forests/deserts) | ❌ Not supported | Would need texture-based approach or vertex color encoding |
| Distinct mountain ranges from orbit | ❌ Not supported | Terrain is smooth noise only; no individual peaks named or resolved at distance |
| Moons | ❌ Not supported | Easy to add (~100 lines of Lua) |
| Planetary rings | ❌ Not supported | Particle system approach available (`effect/ring.glsl` template exists) |
| Asteroid fields around planets | ⚠️ Partially supported | Generic field spawning, can be linked to planet via `spawnAsteroidFieldAroundPlanet()` |
| Gas giants | ⚠️ Approximated | Via parameter tuning (large radius + thick atmosphere); true gas giant shader would help |
| Ice worlds / barren planets | ⚠️ Approximated | Via color palette + ocean level tuning |
| Variable planet sizes | ✅ Full support | Erlang distribution, can be customized per-planet type |

## Atmosphere Entry & Aerodynamics: NOT SUPPORTED

**Current state:** Ships have a global drag coefficient (`setDrag(0.75, 4.0)` in `Ship.lua`), but there is **no atmosphere entry physics**. You cannot:
- Enter a planet's atmosphere and experience increasing drag/lift as you descend
- Feel aerodynamic forces change with altitude
- Land on the surface (landing pads, touch-down detection)
- Dock to planets or stations via an automated docking system

**What exists:**
- Ships have `setDrag()` which applies a constant velocity decay (`vel *= exp(-drag * dt)` in the physics update)
- There is a dock action (`DockAt`), but it's a simple "get within 200 units and snap" — no automated approach, RCS thrusters, or guidance

**How to add atmosphere entry:**

1. **Atmosphere density profile** (C++ `libphx/src/Engine.cpp`):
```cpp
// Add to Engine.h / .cpp
float getAtmosphereDensity(float altitude);  // altitude = distance from surface
// Returns: exp(-altitude / scaleHeight) where scaleHeight ~ 8km for Earth-like
```

2. **Lua hook in `Planet.lua`:**
```lua
-- Add to Planet entity after initialization
local function getAtmoDensity(self, position)
  local dist = (position - self:getPos()):length()
  if dist <= self:getScale() * self.atmoScale then
    local altitude = dist - self:getScale()  -- distance from surface
    return math.exp(-altitude / 8000.0)       -- scale height ~ 8km
  end
  return 0.0
end
```

3. **Ship drag that depends on atmosphere:**
```lua
-- In Ship.lua or Action.lua's flyToward()
function Ship:updateDrag (dt)
  local atmoDensity = self:getParentPlanet() and getAtmosphereDensity(self.pos) or 0.0
  -- Interpolate between vacuum drag (0.75) and surface drag (2.0+)
  self:setDrag(0.75 + atmoDensity * 1.25, 4.0)
end
```

4. **Landing detection:**
```lua
-- In Planet.lua or a new LandingPad component
function Planet:checkLandings(state)
  if state.mode == BlendMode.Disabled then
    local ship = self:getNearestShip(500)  -- within 500 units
    if ship and (ship:getPos() - self:getPos()):length() < self:getScale() + 100 then
      -- Ship is near surface — enable landing mode
      ship:setLandingEnabled(true)
      ship:addThrustController(Actions.Land())
    end
  end
end
```

**Estimated effort:** ~200-300 lines of C++ + Lua. The hardest part is the physics (drag/lift coupling with velocity vector), but the rest is straightforward.

---

## Planet Rotation: NOT SUPPORTED

**Current state:** Planets are **static**. They do not rotate on an axis, nor does the atmosphere/clouds move independently of the surface. The entire planet mesh and atmosphere mesh share the same world transform.

**What exists:**
- Planets can be positioned anywhere in a system via `spawnPlanet()`
- They have fixed orientation (no rotation over time)
- The atmosphere is a static mesh scaled outward — no wind or weather

**How to add rotation:**

1. **Rotation state per planet:**
```lua
-- In Planet.lua constructor
self.rotationSpeed = Vec3f(rng:getDir2(), 0):scale(0.5 + rng:getExp() * 0.5)  -- radians per second
self.rotationOffset = rng:getUniform() * 6.283185  -- starting rotation angle
```

2. **Update loop (System.lua):**
```lua
function System:update(dt)
  -- ... existing update code ...
  for _, child in ipairs(self.children) do
    if child.planetType == 'terrestrial' then
      local rot = child:getRot()
      -- Rotate the planet mesh around its axis
      child:setRot(rot * Quat.FromAxisAngle(child.rotationSpeed, dt))
    end
  end
end
```

3. **Atmosphere moves with rotation:** Since both meshes share the same transform, rotating the parent entity rotates both surface and atmosphere together — which is physically correct for a tidally locked or slow-rotating planet.

4. **Independent cloud layer (advanced):**
```lua
-- In Planet.lua, add an independent cloud mesh
self.cloudMesh = Gen.Primitive.IcoSphere(5):managed()
self.cloudRotationSpeed = self.rotationSpeed * 0.3  -- clouds rotate slower
```

**Estimated effort:** ~50-100 lines of Lua + minor shader update to handle dynamic normals correctly.

---

## Cloud System: NOT SUPPORTED (but infrastructure exists)

**Current state:** The volumetric cloud scattering code in `scattering2.glsl` is **disabled by default** (`#define CLOUDS_ENABLED 0`). There is no visible, moving cloud layer you can see from space.

**What the existing cloud system does (when enabled):**
- Uses a 3D noise texture (`cloudNoise`) sampled along ray paths through the atmosphere
- Implements Mie scattering for clouds (forward-scattering phase function)
- Integrates clouds as a secondary pass in the atmosphere shader
- Clouds are static — no wind, no movement

**How to add moving, visible clouds:**

1. **Enable the existing cloud system** (`Config.App.lua`):
```lua
-- In Config.App.lua
CLOUDS_ENABLED  = 1,     -- Enable volumetric clouds
cloudLayers     = 3,     -- Number of vertical cloud layers (0..4)
cloudBaseAlt    = 25000, -- Base altitude where clouds start (world units)
cloudThickness  = 8000,  -- Vertical thickness of the cloud deck
```

2. **Wind animation in shader:**
```glsl
// In res/shader/fragment/gen/clouds_cube.glsl (new file or extend existing)
uniform float time;      // Passed from Lua: Shader.SetFloat('time', frameTime)
uniform vec3 windDir;    // Wind direction vector
uniform float windSpeed; // Speed of cloud movement

float fCellNoise(vec3 p, float s, int octaves, float lac) {
  // ... existing noise function ...
}

float genClouds(vec3 p, float time) {
  /* Animate the noise field by offsetting with wind */
  vec3 moved = p + windDir * windSpeed * time;
  
  p += 0.5 * vec3(
    fCellNoise(moved.xzy, seed + 1.0, 4, 1.3),
    fCellNoise(moved.xyz, seed + 5.0, 4, 1.3),
    fCellNoise(moved.zxy, seed + 8.0, 4, 1.3));
  return 0.5 + 0.5 * sin(8.0 * frCellNoise(p, seed + 6.0, 12, 1.4));
}
```

3. **Update from Lua:**
```lua
-- In Planet.lua, add a wind parameter
self.windSpeed = rng:getUniformRange(50, 300)  -- world units per second
self.windDir   = rng:getDir2()

-- In System:update(dt):
for _, planet in ipairs(self.children) do
  if planet.planetType == 'terrestrial' then
    local shader = Cache.Shader('wvp', 'material/planet')
    Shader.SetFloat('cloudTime', clock * self.windSpeed)
    Shader.SetVec3('windDir', self.windDir.x, self.windDir.y, self.windDir.z)
  end
end
```

**Estimated effort:** ~50 lines of shader + ~30 lines of Lua configuration. The hardest part is tuning the cloud layer parameters so they look natural and don't block vision too much.

---

## Summary of Effort Estimates

| Feature | Complexity | Lines of Code | Risk |
|---------|-----------|---------------|------|
| Moons | Low | ~100 | Very low — reuses existing entity framework |
| Asteroid rings around planet | Low-Medium | ~80 | Low — particle system is already in the engine |
| Planet rotation | Low | ~50 | Low — just need a rotation speed property and update loop |
| Atmosphere entry / landing physics | Medium-High | ~250 | Medium — requires C++ integration for drag/lift coupling |
| Moving cloud layer | Low | ~60 | Low — shader already exists, just needs enabling + animation |
| Gas giant rendering | Medium | ~150 | Medium — new material pass needed |
| True biomes (texture-based) | High | ~300 | Medium-High — requires extending the generation pipeline |

**My recommendation:** Start with **Moons** and **Planet Rotation** as your first two features. They're low-risk, visually impactful, and build on existing infrastructure without requiring changes to the core C++ engine.

Then add **Moving Clouds** for visual polish — it's essentially a one-line toggle plus some animation parameters.

If you want atmosphere entry/landing, that's a bigger commit but the design is straightforward: density profile → drag interpolation → landing zone detection.

The codebase is well-structured for these additions, with clear separation between:
- Procedural generation (GLSL shaders + Lua parameterization)
- Entity management (`Entities/*.lua`)
- Rendering pipeline (`res/shader/material/`, `res/shader/effect/`)
