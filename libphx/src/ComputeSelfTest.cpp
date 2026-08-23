#include "Common.h"
#include "ComputeSelfTest.h"
#include "GPUBuffer.h"
#include "Shader.h"
#include <cstdio>
#include <cstdlib>

/* Exercises every piece of compute plumbing in one pass:
 *   1. Shader_LoadCompute   — .comp file through preprocessor + program link
 *   2. GPUBuffer upload     — CPU -> SSBO
 *   3. GPUBuffer_BindSSBO   — layout(std430, binding = N) association
 *   4. uniform + dispatch   — glDispatchCompute with local_size_x = 64
 *   5. Shader_MemoryBarrier — SSBO writes visible to subsequent reads
 *   6. GPUBuffer_Download   — GPU -> CPU verification
 * The kernel computes dst[i] = src[i] * 2 + 1, so any stage failing produces
 * an obvious mismatch pattern rather than a silent pass. */
void ComputeSelfTest_Run () {
  uint const count = 256;
  float src[count];
  float dst[count];

  for (uint i = 0; i < count; ++i)
    src[i] = (float)i;

  Shader* cs = Shader_LoadCompute("compute/selftest");
  GPUBuffer* in = GPUBuffer_Create(count * sizeof(float));
  GPUBuffer* out = GPUBuffer_Create(count * sizeof(float));

  GPUBuffer_Upload(in, src, count * sizeof(float));
  GPUBuffer_BindSSBO(in, 0);
  GPUBuffer_BindSSBO(out, 1);

  Shader_Start(cs);
  Shader_SetInt("count", (int)count);
  Shader_Dispatch(count / 64, 1, 1);
  Shader_Stop(cs);

  /* Barrier AFTER Stop is fine: the dispatch is already submitted; this only
   * orders subsequent buffer reads against its SSBO writes. */
  Shader_MemoryBarrier(ShaderBarrier_ShaderStorage);
  GPUBuffer_Download(out, dst, count * sizeof(float));

  int fails = 0;
  for (uint i = 0; i < count; ++i) {
    float expect = src[i] * 2.0f + 1.0f;
    if (dst[i] != expect) {
      if (++fails <= 5)
        printf("[COMPUTE-TEST] FAIL at %u: expected %f, got %f\n", i, expect, dst[i]);
    }
  }

  if (fails == 0)
    printf("[COMPUTE-TEST] PASS (%u/%u elements correct)\n", count, count);
  else
    printf("[COMPUTE-TEST] FAILED (%d of %u elements wrong)\n", fails, count);

  Shader_Free(cs);
  GPUBuffer_Free(in);
  GPUBuffer_Free(out);
}
