#include fragment
#include math
#include color
#include noise
#include gamma
#include planetlocal

#autovar vec3 eye
#autovar vec3 starDir
#autovar vec3 sunColor
#autovar samplerCube irMap

// An autovar only REGISTERS the name for stack upload -- the line itself is
// stripped during preprocess -- so the shader must still declare a real uniform
// of the same name or the upload has nothing to bind to. Same as atmosphere.glsl.
uniform vec3 sunColor;
// irMap needs no declaration here: the fragment include already declares it,
// and the autovar above is what registers the name for the per-frame push from
// System:beginRender.
//
// NOTE: never write an include directive literally in a shader comment. The
// preprocessor scans the whole file for it and takes the REST OF THAT LINE as a
// path, comments included, so a comment explaining the include above will make
// it try to load a shader named after your sentence and abort the boot with
// "Resource_Resolve: Failed to find Shader <...>". configure.py's offline
// validator does not go through this path, so such a file still passes 137/137
// and then dies at runtime. Refer to it as "the include directive" instead.
//

layout(location = 0) out vec4 fragColor;

uniform vec3  origin;        // planet centre, world space
uniform float rPlanet;       // world radius, for the shadow solve only
// planetAxisX/Y/Z and worldToLocalDir come from include/planetlocal, shared with
// material/planet.glsl -- they were duplicated when rings were added.
uniform vec3  spinAxis;      // ring plane normal (world). The ring lies in the
                             // planet's equatorial plane, so this is the axis.
uniform float ringInner;     // inner edge, in planet radii
uniform float ringOuter;     // outer edge, in planet radii
uniform float ringOpacity;   // optical depth scale
uniform float ringBands;     // how much radial structure (gaps) to show
uniform float ringBright;    // overall brightness multiplier
uniform vec3  ringColor;     // particle colour (ice bright, dust dark red-brown)
uniform float ringIce;       // 0 = pure dust, 1 = pure ice. Drives COLOUR *and*
                             // scatter behaviour: dust is fine and nearly
                             // isotropic (matte ring), ice is coarse enough to
                             // blaze when backlit. Colour alone was the wrong
                             // tell -- a dust ring would still have flared.
uniform float ringEnv;       // how strongly the ring picks up the skybox /
                             // nebula irradiance around it
uniform float sunScale;

void main() {
  // vertPos is the LOCAL vertex position, i.e. already in planet radii.
  vec3 lp = vertPos;
  float r = length(lp.xz);          // radial distance in the ring plane

  // ---- radial extent ------------------------------------------------------
  // Soft both edges. A hard cut at the inner edge in particular reads as a
  // drawn circle rather than a cloud of particles.
  float aIn  = smoothstep(ringInner, ringInner + 0.06, r);
  float aOut = 1.0 - smoothstep(ringOuter - 0.10, ringOuter, r);
  float extent = aIn * aOut;
  if (extent <= 0.001) { discard; }

  // ---- radial structure ---------------------------------------------------
  // Real rings are banded: broad density variation plus sharp divisions (the
  // Cassini and Encke gaps are the famous ones). Build it from the normalised
  // radius so the pattern is a function of position on the ring, not of angle,
  // and therefore rotates rigidly with the planet.
  float t = (r - ringInner) / max(1e-4, (ringOuter - ringInner));
  // Broad variation across the whole band.
  float broad = fSmoothNoise(vec3(t * 6.0, 0.0, 0.0) + vec3(11.3, 0.0, 7.1), 4, 2.0);
  // Finer ringlets.
  float fine  = fSmoothNoise(vec3(t * 34.0, 0.0, 0.0) + vec3(3.7, 0.0, 19.4), 3, 2.0);
  float dens = broad * 0.72 + fine * 0.28;
  // Sharpen into bands: divide down where the field is low, which is what makes
  // a gap read as a gap instead of a thin smear.
  dens = pow(saturate((dens - 0.30) * 1.9), 1.4);
  // Two fixed divisions at plausible radii, so every ring gets at least the
  // suggestion of structure rather than relying on noise alone.
  float gaps = 1.0
    - 0.80 * exp(-pow2((t - 0.62) / 0.035))   // "Cassini"-like
    - 0.55 * exp(-pow2((t - 0.84) / 0.012));  // narrow "Encke"-like
  dens *= mix(1.0, gaps, saturate(ringBands));

  // Optical depth -> coverage. 1-exp(-tau) rather than a linear ramp so the
  // dense inner band does not saturate to a flat white sheet.
  float tau = dens * ringOpacity * 3.2;
  float cover = (1.0 - exp(-tau)) * extent;
  if (cover <= 0.002) { discard; }

  // ---- lighting -----------------------------------------------------------
  vec3 Lw = normalize(starDir);            // world, toward the star
  vec3 Vw = normalize(pos - eye);           // eye -> fragment
  vec3 Ll = worldToLocalDir(Lw);            // sun in the planet's frame
  vec3 Vl = worldToLocalDir(Vw);

  // A ring is a flat sheet: it is lit in proportion to how much of the sun's
  // hemisphere the sheet's face sees.
  vec3 nrm = normalize(spinAxis);
  float NL = dot(nrm, normalize(Lw));

  // FORWARD SCATTER, and why particle SIZE matters. A ring seen with the sun
  // behind it glows far brighter than the same ring lit from the front, and the
  // sharpness of that peak is set by how coarse the particles are: ice chunks
  // are big and scatter forward into a narrow, brilliant lobe, dust is fine and
  // scatters nearly isotropically so its ring stays matte. Driving only the
  // colour from the ice/dust mix was wrong -- a dust ring flared like ice.
  float backlit = saturate(dot(normalize(Lw), normalize(Vw)));
  float fwd = pow(backlit, mix(2.5, 9.0, ringIce)) * mix(0.30, 2.00, ringIce);

  // ---- the planet's shadow on the ring ------------------------------------
  // The ring is COPLANAR with the planet, so for a point p on the ring the ray
  // toward the sun passes through the planet exactly when p faces away from it
  // (p.L < 0). No quadratic needed -- the geometry reduces to a wedge, which
  // is the iconic dark band across a backlit ring. Softened, because the sun is
  // an extended source and the real edge has a penumbra.
  float s = -dot(lp, Ll);
  float shadow = smoothstep(0.0, 0.09, s);

  float lit = saturate(NL * 0.5 + 0.5) * (0.35 + 1.65 * fwd);

  // ENVIRONMENT PICKUP. Light scattered toward the observer arrives from the
  // SUN's direction, so sampling the skybox irradiance chain THERE is what makes
  // the ring take on the colour of whatever lies behind it -- and for a backlit
  // ring that is exactly the nebula bank you are looking through. Same irMap the
  // planet's night side uses; System:beginRender pushes it every frame, so no
  // per-pass binding is needed.
  vec3 envSun = linear(textureLod(irMap, normalize(Lw), 3.0).xyz);
  vec3 amb = envSun * ringEnv * mix(0.55, 1.0, ringIce) + vec3(0.025);
  vec3 ringLit = ringColor * (sunColor * (sunScale * lit * shadow) + amb);

  // Rings are bright ice or dark dust, and neither should be tinted by the
  // atmosphere shell, which is drawn in the same pass -- the ring sits above it.
  vec3 col = ringLit * ringBright;

  if (isnan(col.r) || isnan(col.g) || isnan(col.b)) {
    fragColor = vec4(0.0);
  } else {
    // Premultiplied alpha, matching the atmosphere shell's blend mode.
    fragColor = vec4(col * cover, cover);
  }
  FRAGMENT_CORRECT_DEPTH;
}