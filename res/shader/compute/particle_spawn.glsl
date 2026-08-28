/* GPU particle spawn kernel: consumes this frame's spawn records (uploaded by
 * Lua) and claims pool slots for them via an atomic ring-buffer cursor, so
 * emitters never need to know which slots are free. Overflowing the pool just
 * overwrites the oldest particles -- harmless for short-lived effect sprites.
 *
 * Each record is one ready-to-integrate Particle; CPU-side jittering keeps
 * the kernel branch-free. */
layout(local_size_x = 64) in;

struct Particle {
  vec4 posSize;
  vec4 velLife;
  vec4 colMaxLife;
  vec4 aux;        /* xyz = exhaust dir*speed (streak shaping), w = spare */
};

layout(std430, binding = 0) buffer Pool {
  Particle pool[];
};

layout(std430, binding = 1) readonly buffer Spawns {
  Particle spawns[];
};

/* x = spawnCount (CPU-written each frame), y = tail cursor (GPU-owned). */
layout(std430, binding = 2) buffer Meta {
  uvec4 meta;
};

uniform int capacity;

void main () {
  uint id = gl_GlobalInvocationID.x;
  if (id >= meta.x) return;
  uint slot = atomicAdd(meta.y, 1u) % uint(capacity);
  pool[slot] = spawns[id];
}
