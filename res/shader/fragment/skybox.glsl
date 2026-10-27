#include fragment
#include deferred
#include gamma
#include color

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
uniform float sunStarTight;  /* disc exponent: higher = smaller disc          */
uniform float sunStarDisc;   /* disc brightness (HDR; the tonemap rolls it)   */
uniform float sunStarHalo;   /* halo exponent: higher = tighter halo          */
uniform float sunStarGlow;   /* halo brightness                                */

void main() {
  vec3 V = normalize(vertPos);
  vec3 c = texture(envMap, V).xyz;

  if (sunStarGain > 0.0) {
    float ca = clamp(dot(V, sunStarDir), 0.0, 1.0);
    /* A star is a POINT. These were pow(ca, 6000) * 60 + pow(ca, 120) * 0.8,
     * and the halo exponent of 120 spreads the glow over ~20 degrees of sky --
     * i.e. "light from all degrees", which is exactly how it read: a huge blown
     * white blob hugging the planet's limb, indistinguishable from a light
     * source sitting ON the planet. (It survived every planet-shading toggle --
     * sunScale/atmoGlow/clouds/envAmbient all at 0 -- because it is sky, not
     * surface; only render.sun.intensity moved it, since that is the gain.)
     * Now: a tight disc with a modest halo, both tunable. The disc stays HDR so
     * the tonemap still rolls it off instead of clipping to a flat white dot. */
    float core = pow(ca, sunStarTight);
    float halo = pow(ca, sunStarHalo);
    c += sunStarColor * (core * sunStarDisc + halo * sunStarGlow) * sunStarGain;
  }

  gl_FragDepth = 1.0;

  setAlbedo(linear(c.xyz));
  setAlpha(1.0);
  setDepth();
  setNormal(-normalize(vertPos));
  setRoughness(0);
  setMaterial(Material_NoShade);
}
