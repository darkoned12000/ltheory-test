#include fragment
#include deferred
#include math

/* GTAO pass 2 — full cosine-windowed sky integral -> aoRaw (R8, half-res). */

#autovar mat4 mProj
#autovar mat4 mView
uniform mat4 mProj;
uniform mat4 mView;

uniform sampler2D texView;       /* aoView (unit view rays, half-res) */
uniform sampler2D texNormalMat;  /* buffer1                           */
uniform sampler2D texDepth;      /* zBufferL                          */
uniform sampler2D texNoise;      /* 64x64 blue-noise LUT (R8)         */

uniform float aoRadius;    /* world units (setting) */
uniform float aoIntensity; /* pow curve              */
uniform float aoMip;       /* log2(sx/aoSx)         */
uniform float aoSpacing;   /* slice step fraction of radius */
uniform float aoNoiseSize; /* LUT texels per axis    */
uniform float thickness;   /* silhouette bias 0..1  */
uniform int   dirCount;    /* 2/4/6/8               */
uniform int   stepCount;   /* 2/3/4/6               */

float integrateSlice (float h0, float h1) {
  float c0 = sqrt(max(1.0 - h0 * h0, 0.0));
  float c1 = sqrt(max(1.0 - h1 * h1, 0.0));
  return (c0 + c1) * 0.5;
}

float marchHorizon (vec3 P, vec3 N, vec3 D, float t, float dist, float R) {
  vec3 M = P + D * t;
  vec4 clip = mProj * vec4(M, 1.0);
  if (clip.w <= 1e-4) return 0.0;                     /* behind the camera */
  vec2 uvs = (clip.xy / clip.w) * 0.5 + 0.5;
  if (any(lessThan(uvs, vec2(0.0))) || any(greaterThan(uvs, vec2(1.0)))) return 0.0;

  // Read exact depth at LOD 0.0
  float tapDist = textureLod(texDepth, uvs, 0.0).x;
  if (tapDist < 1e-4 || tapDist >= 900000.0) return 0.0; /* tap on sky: open horizon */

  vec3 Q = texture(texView, uvs).xyz * tapDist;       /* tap's own view ray * depth */
  vec3 QP = Q - P;
  float lenQP = max(length(QP), 1e-6);
  float ncomp = dot(N, QP) / lenQP;                   /* height above tangent plane */
  float tcomp = max(length(QP - N * dot(N, QP)) / lenQP, 1e-6);
  float th = atan(ncomp, tcomp);                      /* + toward camera, - below plane */

  float delta = tapDist - dist;
  float damp = 1.0 - thickness * exp(-abs(delta) / max(R, 1e-3));

  return clamp(sin(max(th, 0.0)), 0.0, 1.0) * damp;
}

float sliceVisibility (vec3 P, vec3 N, float dist, vec2 uv, float mat) {
  vec3 T1 = normalize(abs(N.y) < 0.999 ? cross(vec3(0.0, 1.0, 0.0), N) : vec3(1.0, 0.0, 0.0));
  vec3 T2 = cross(N, T1);

  float R = aoRadius * clamp(dist / 1000.0, 0.05, 2.5);
  if (mat == Material_Metal) R *= 2.0;

  float nz = texture(texNoise, uv * aoNoiseSize).x;

  float vis = 0.0;
  for (int i = 0; i < dirCount; ++i) {
    float ang = (float(i) + nz) * (TAU / float(dirCount));
    vec3 D = T1 * cos(ang) + T2 * sin(ang);

    float h0 = 0.0, h1 = 0.0;
    for (int s = 0; s < stepCount; ++s) {
      float t = R * (1.0 + float(s)) * aoSpacing;
      h0 = max(h0, marchHorizon(P, N,  D, t, dist, R));
      h1 = max(h1, marchHorizon(P, N, -D, t, dist, R));
    }
    vis += integrateSlice(h0, h1);
  }
  return vis / float(dirCount);
}

void main () {
  float dist = textureLod(texDepth, uv, 0.0).x;
  if (dist < 1e-4 || dist >= 900000.0) { fragData0 = vec4(1.0); return; } /* sky gate */

  vec3 viewDir = texture(texView, uv).xyz;
  vec3 P = viewDir * dist;
  vec4 nrmat = texture(texNormalMat, uv);
  vec3 N = mat3(mView) * decodeNormal(nrmat.xy);

  float vis = sliceVisibility(P, N, dist, uv, nrmat.w);
  float visn = clamp(!isnan(vis) ? vis : 1.0, 0.0, 1.0);
  float occl = pow(visn, aoIntensity);

  fragData0 = vec4(occl);
}
