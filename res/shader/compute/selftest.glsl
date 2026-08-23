/* Compute-pipeline self-test kernel: dst[i] = src[i] * 2 + 1.
 * Loaded by ComputeSelfTest_Run (PHX_SELFTEST_COMPUTE=1) and validated
 * offline by tools/validate_glsl.py as a standalone compute stage. */
layout(local_size_x = 64) in;

layout(std430, binding = 0) readonly buffer SrcBuf {
  float srcData[];
};

layout(std430, binding = 1) writeonly buffer DstBuf {
  float dstData[];
};

/* NOTE : Engine's Shader_SetInt issues glUniform1i, which requires an int
 * uniform -- declaring this uint makes glUniform1i raise INVALID_OPERATION. */
uniform int count;

void main () {
  uint i = gl_GlobalInvocationID.x;
  if (i >= uint(count)) return;
  dstData[i] = srcData[i] * 2.0f + 1.0f;
}
