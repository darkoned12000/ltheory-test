#include fragment
#include deferred
#include math

/* GTAO pass 2 — naive horizon integral -> aoRaw (R8, half-res).
 * Phase A (uniform-horizon approximation): per azimuthal slice, track the
 * maximum horizon elevation sin(θ) above the tangent plane; visibility per
 * slice = 1 - sin(θmax), matching the cosine-window (grazing = no occlusion).
 * Phase B replaces this with the full cosine-windowed sky integral + blue-noise
 * slice rotation from a 64x64 LUT (today: hash rotation via timeSeed).
 */

#autovar mat4 mProj
#autovar mat4 mView
uniform mat4 mProj;
uniform mat4 mView;

uniform sampler2D texView;       /* aoView (unit view rays, half-res) */
uniform sampler2D texNormalMat;  /* buffer1                           */
uniform sampler2D texDepth;      /* zBufferL                          */

uniform float aoRadius;    /* world units (setting) */
uniform float aoIntensity; /* pow curve              */
uniform float aoMip;       /* log2(sx/aoSx)         */
uniform float aoSpacing;   /* slice step fraction of radius */
uniform float thickness;   /* silhouette bias 0..1  */
uniform float timeSeed;    /* frame slice rotation  */
uniform int   dirCount;    /* 2/4/6/8               */
uniform int   stepCount;   /* 2/3/4/6               */

float hash12 (vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

float sliceVisibility (vec3 P, vec3 N, float dist, vec2 frag, float mat) {
  /* Orthonormal tangent frame, robust to N == ±Y. */
  vec3 T1 = normalize(abs(N.y) < 0.999 ? cross(vec3(0.0, 1.0, 0.0), N) : vec3(1.0, 0.0, 0.0));
  vec3 T2 = cross(N, T1);

  /* Effective radius: constant-in-world feels dead at planet scale and blown at
   * ship scale; scale by camera distance (clamped) so the screen footprint of
   * the falloff stays similar. Metal hulls get a wider, subtler footprint. */
  float R = aoRadius * clamp(dist / 1000.0, 0.2, 4.0);
  if (mat == Material_Metal) R *= 2.0;

  float vis = 0.0;
  for (int i = 0; i < dirCount; ++i) {
    float ang = (float(i) + hash12(frag + float(i) + fract(timeSeed))) * (TAU / float(dirCount));
    vec3 D = T1 * cos(ang) + T2 * sin(ang);
    float hs = 0.0; /* max horizon sin(θ) along this slice */
    for (int s = 0; s < stepCount; ++s) {
      float t = R * (1.0 + float(s)) * aoSpacing;
      vec3 M = P + D * t;
      vec4 clip = mProj * vec4(M, 1.0);
      if (clip.w <= 1e-4) continue;                 /* behind the camera */
      vec2 uvs = (clip.xy / clip.w) * 0.5 + 0.5;
      if (any(lessThan(uvs, vec2(0.0))) || any(greaterThan(uvs, vec2(1.0)))) continue;
      float tapDist = textureLod(texDepth, uvs, aoMip).x;
      if (tapDist < 1e-4) continue;                 /* tap on sky: open horizon */
      vec3 Q = texture(texView, uvs).xyz * tapDist; /* tap's own view ray * depth */
      vec3 QP = Q - P;
      float lenQP = max(length(QP), 1e-6);
      float ncomp = dot(N, QP) / lenQP;                       /* height above tangent plane */
      float tcomp = max(length(QP - N * dot(N, QP)) / lenQP, 1e-6);
      float th = atan(ncomp, tcomp);                          /* + toward camera, - below plane */

      /* Thickness: occluders far behind along the view read full strength;
       * near-same-plane / in-front silhouettes dampen so thin rims read as lit,
       * not black rings. Phase B: Jimenez screen-space thickening. */
      float delta = tapDist - dist;
      float damp = 1.0 - thickness * exp(-abs(delta) / max(R, 1e-3));

      hs = max(hs, clamp(sin(max(th, 0.0)), 0.0, 1.0) * damp);
    }
    vis += 1.0 - hs; /* visible sky fraction for this slice */
  }
  return vis / float(dirCount);
}

void main () {
  float dist = textureLod(texDepth, uv, aoMip).x;
  if (dist < 1e-4) { fragData0 = vec4(1.0); return; } /* sky — never darkened */

  vec3 viewDir = texture(texView, uv).xyz;
  vec3 P = viewDir * dist;
  vec4 nrmat = texture(texNormalMat, uv);
  vec3 N = mat3(mView) * decodeNormal(nrmat.xy);

  float vis = sliceVisibility(P, N, dist, gl_FragCoord.xy, nrmat.w);
  float visn = clamp(!isnan(vis) ? vis : 1.0, 0.0, 1.0); /* sliceVisibility already averages over dirCount */
  float occl = pow(visn, aoIntensity);

  fragData0 = vec4(occl);
}