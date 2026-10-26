/* Fragment shader common (autovars, inputs). */
#include common

/* Logarithmic depth: gl_FragDepth only ever increases relative to the
 * interpolated (standard) depth, so declare depth_greater to re-enable
 * early-Z / hierarchical-Z for fragments that don't change depth. */
layout(depth_greater) out float gl_FragDepth;

in vec2 uv;
in vec3 pos;
in vec3 normal;
in vec3 vertNormal;
in vec3 vertPos;
in float flogz;

uniform vec3 eye;
uniform mat4 mWorldIT;

uniform samplerCube envMap;
uniform samplerCube irMap;
uniform vec3 starColor;
uniform vec3 starDir;

#define FRAGMENT_CORRECT_DEPTH                                                 \
  gl_FragDepth = log2(flogz) * (0.5 * Fcoef);
