#include fragment
#include deferred
#include gamma
#include color
#include fog

#autovar samplerCube envMap

/* The scene's light comes from `starDir` but nothing was ever drawn there, so
 * the planet read as lit by a source that doesn't exist. Draw the star here, at
 * skybox time, rather than baking it into the envMap cube: it stays live-tintable
 * from render.sun.* and it keeps the star out of irMap (a bright point in the
 * irradiance convolution would add exactly the kind of noise we just spent a
 * week removing). */
uniform vec3  sunStarDir;    /* normalised star direction */
uniform vec3  sunStarColor;  /* engine sun hue x intensity (render.sun.*)     */
uniform float sunStarGain;   /* 0 when Sun Light is off                       */

void main() {
  vec3 V = normalize(vertPos);
  vec3 c = texture(envMap, V).xyz;

  if (sunStarGain > 0.0) {
    float ca   = clamp(dot(V, sunStarDir), 0.0, 1.0);
    float core = pow(ca, 6000.0);   /* tight disc, ~1 deg across  */
    float halo = pow(ca, 120.0);    /* soft bloom-around glow     */
    c += sunStarColor * (core * 60.0 + halo * 0.8) * sunStarGain;
  }

  gl_FragDepth = 1.0;

  setAlbedo(linear(c.xyz));
  setAlpha(1.0);
  setDepth();
  setNormal(-normalize(vertPos));
  setRoughness(0);
  setMaterial(Material_NoShade);
}
