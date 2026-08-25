/* GPU particle simulation kernel: integrates the whole fixed-size pool every
 * frame. Dead particles (life <= 0) are skipped in-place -- rendering culls
 * them by life, so no compaction pass is needed at this pool size.
 *
 * Drag is applied as exp(-drag*dt), which stays stable for any dt and makes
 * velocity fade exponentially rather than linearly. */
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

uniform float dt;
uniform float drag;

void main () {
  uint i = gl_GlobalInvocationID.x;
  Particle p = pool[i]; /* No bounds check needed: dispatch covers exactly capacity. */

  if (p.velLife.w > 0.0) {
    p.posSize.xyz += p.velLife.xyz * dt;
    p.velLife.xyz *= exp(-drag * dt);
    p.velLife.w -= dt;
    pool[i] = p;
  }
}
