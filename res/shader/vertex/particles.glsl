/* GPU particle billboard vertex shader: attribute-less quad expansion straight
 * from the SSBO pool. One instance per particle, 6 vertices per instance
 * (two triangles), corner selected from gl_VertexID -- no VBO involved.
 *
 * Camera-facing basis comes from the view matrix columns (rotation part is
 * orthonormal, so its transpose rows are the camera axes in world space). */
#include vertex

/* Plain uniforms declared by vertex.glsl; these directives bind them from the
 * ShaderVar stack at start time (eager autovar upload -- must Start while the
 * world camera is pushed, which the additive render pass guarantees). */
#autovar mat4 mView
#autovar mat4 mProj

/* MUST mirror the AoS Particle struct used by the compute kernels -- std430
 * packs it as stride-48 array of {vec4,vec4,vec4}. Declaring SoA arrays here
 * would silently address the wrong bytes. */
struct Particle {
  vec4 posSize;    /* xyz = world position, w = sprite size */
  vec4 velLife;    /* w = seconds of life remaining */
  vec4 colMaxLife; /* rgb = color, a = max life (for fade) */
};

layout(std430, binding = 0) readonly buffer Pool {
  Particle pool[];
};

out vec4 pCol;
out float pFade;

uniform float sizeBoost;

void main () {
  uint i = uint(gl_InstanceID);
  vec3 cpos = pool[i].posSize.xyz;
  float psize = pool[i].posSize.w * sizeBoost;
  float life = pool[i].velLife.w;
  pCol = vec4(pool[i].colMaxLife.rgb, 1.0);
  pFade = pool[i].colMaxLife.a <= 0.0
    ? 0.0
    : clamp(life / pool[i].colMaxLife.a, 0.0, 1.0);

  /* Dead particles are pushed outside the clip volume: zero-area work for
   * the rasterizer, no discard needed in the fragment stage. */
  if (life <= 0.0) {
    gl_Position = vec4(0.0, 0.0, 3.0, 1.0); /* z/w = 3 > 1 -> clipped */
    return;
  }

  const vec2 corners[6] = vec2[6](
    vec2(-1.0, -1.0), vec2( 1.0, -1.0), vec2( 1.0,  1.0),
    vec2(-1.0, -1.0), vec2( 1.0,  1.0), vec2(-1.0,  1.0)
  );
  vec2 c = corners[gl_VertexID % 6];
  uv = c * 0.5 + 0.5;

  vec3 right = mView[0].xyz; /* camera X axis in world space */
  vec3 up    = mView[1].xyz; /* camera Y axis in world space */

  vec4 wp = vec4(cpos + (right * c.x + up * c.y) * psize, 1.0);
  gl_Position = mProj * (mView * wp);
  gl_Position = logDepth(gl_Position);
}
