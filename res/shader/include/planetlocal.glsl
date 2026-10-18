// Shared by material/planet.glsl and material/ring.glsl.
//
// The surface cube is authored in the planet's LOCAL frame so the terrain spins
// with the body, which means any world-space ray (the view ray for the cloud
// shell, the star direction for shadows, the view ray for the ring) has to be
// brought back into that frame before it can be used as a lookup direction.
//
// This lived in material/planet.glsl and was copied verbatim into
// material/ring.glsl when rings were added. Two copies of a frame conversion is
// exactly how the next planet shader ends up with a third, and how one of them
// ends up disagreeing with the planet's actual orientation. Both shaders use the
// SAME uniform names, so moving the declarations here changes nothing about what
// Lua uploads -- see Planet:render, which sets planetAxisX/Y/Z in both draw
// paths.
//
// The uniforms live here rather than per-shader because both shaders genuinely
// use all three. Do NOT add a uniform here "for symmetry": per 12, setting a
// uniform a program lacks ABORTS the process, and declaring one nobody uploads
// leaves it silently at 0.

uniform vec3 planetAxisX;  // world-space directions of the planet's local axes
uniform vec3 planetAxisY;
uniform vec3 planetAxisZ;

// World-space direction -> the planet's local direction, and back. Valid for any
// rigid transform; uniform scale cancels under normalize().
vec3 worldToLocalDir (vec3 w) {
  return vec3(dot(w, planetAxisX), dot(w, planetAxisY), dot(w, planetAxisZ));
}

vec3 localToWorldDir (vec3 l) {
  return planetAxisX * l.x + planetAxisY * l.y + planetAxisZ * l.z;
}