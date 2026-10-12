#include "CubeFace.h"
#include "DataFormat.h"
#include "Draw.h"
#include "PhxMemory.h"
#include "PixelFormat.h"
#include "RenderTarget.h"
#include "RNG.h"
#include "Shader.h"
#include "Tex2D.h"
#include "TexCube.h"
#include "TexFilter.h"
#include "TexFormat.h"
#include "Vec2.h"

/* TODO : Make this cleaner and faster. */
/* TODO : This is very specific functionality (GGX mips). Where does this kind
 *        of functionality really belong? Not PHX core but not Lua.. */

/* van der Corput radical inverse in base 2. Combined with a stratified first
 * coordinate this gives the Hammersley set: reproducible for a given index, and
 * far better distributed than iid random taps, so a fixed sample count buys a
 * lot less variance (the coarse levels used to be visibly noisy). */
static double RadicalInverse2 (uint32 bits) {
  bits = (bits << 16) | (bits >> 16);
  bits = ((bits & 0x55555555u) << 1) | ((bits & 0xAAAAAAAAu) >> 1);
  bits = ((bits & 0x33333333u) << 2) | ((bits & 0xCCCCCCCCu) >> 2);
  bits = ((bits & 0x0F0F0F0Fu) << 4) | ((bits & 0xF0F0F0F0u) >> 4);
  bits = ((bits & 0x00FF00FFu) << 8) | ((bits & 0xFF00FF00u) >> 8);
  return (double)bits * (1.0 / 4294967296.0);
}

TexCube* TexCube_GenIRMap (TexCube* self, int sampleCount, uint64 seed) {
  if (sampleCount < 1)
    sampleCount = 1;
  int size = TexCube_GetSize(self);
  int const baseSize = size;
  TexFormat format = TexCube_GetFormat(self);
  TexCube* result = TexCube_Create(size, format);

  /* Copy 0th-level data directly, as it should be identical. Doing so in
   * shader may result in subtle differences. */ {
    int components = TexFormat_Components(format);
    PixelFormat pf =
      components == 4 ? PixelFormat_RGBA :
      components == 3 ? PixelFormat_RGB  :
      components == 2 ? PixelFormat_RG   :
                        PixelFormat_Red;
    DataFormat df = DataFormat_Float;

    void* buffer = MemAlloc(size * size * sizeof(float) * components);
    for (int i = 0; i < 6; ++i) {
      TexCube_GetData(self, buffer, CubeFace_Get(i), 0, pf, df);
      TexCube_SetData(result, buffer, CubeFace_Get(i), 0, pf, df);
    }
    TexCube_GenMipmap(result);
    MemFree(buffer);
  }

  static Shader* shader = 0;
  if (!shader)
    shader = Shader_Load("vertex/identity", "fragment/compute/irmap");

  CubeFace const face[6] = {
    CubeFace_PX, CubeFace_NX, CubeFace_PY,
    CubeFace_NY, CubeFace_PZ, CubeFace_NZ,
  };

  Vec3f const look[6] = {
    {  1,  0,  0 }, { -1,  0,  0 }, {  0,  1,  0 },
    {  0, -1,  0 }, {  0,  0,  1 }, {  0,  0, -1 },
  };

  Vec3f const up[6] = {
    {  0,  1,  0 }, {  0,  1,  0 }, {  0,  0, -1 },
    {  0,  0,  1 }, {  0,  1,  0 }, {  0,  1,  0 },
  };

  /* The shader reads the source at a cone-matched LOD (see srcLod below), which
   * is only well-defined if the source carries a mip chain. Both nebula
   * generators build one; this keeps the function correct for any cube. */
  TexCube_GenMipmap(self);

  RNG* rng = RNG_Create(seed);

  int levels = 0;
  for (int i = size; i > 0; i /= 2)
    levels++;

  /* Angular radius of one level-0 source texel, in radians (a cube face spans
   * Pi/2). Used to pick the LOD whose footprint matches the sampling cap. */
  double const texelAngle = Pi2 / (double)baseSize;

  Shader_Start(shader);
  int level = 0;
  while (size > 1) {
    size /= 2;
    level += 1;

    double ggxWidth = (double)level / (double)levels;
    ggxWidth *= ggxWidth;

    /* Every level convolves from the ORIGINAL source, so no noise accumulates
     * down the chain; the cap widens with the level. Prefilter the source to
     * that cap (LOD-matched) instead of taking N sharp point taps of it --
     * without this the wide caps are the noisiest levels in the cube, and they
     * are exactly the ones the planet ambient (LOD 5) and the nebula inscatter
     * (LOD 6) sample. */
    double srcLod = Clamp(Log(Atan(ggxWidth) / texelAngle, 2.0), 0.0, (double)(levels - 1));

    /* Cranley-Patterson rotation of the azimuthal sequence, drawn from the seed
     * so each level is decorrelated from its neighbours but still reproducible. */
    double const rotYaw = RNG_GetUniform(rng);

    Vec2f* sampleBuffer = MemNewArray(Vec2f, sampleCount);
    Tex2D* sampleTex = Tex2D_Create(sampleCount, 1, TexFormat_RG16F);
    /* Populate the sample buffer with a fresh set of weighted directions */ {
      for (int i = 0; i < sampleCount; ++i) {
        double e1 = ((double)i + 0.5) / (double)sampleCount;
        double e2 = RadicalInverse2((uint32)i) + rotYaw;
        e2 -= Floor(e2);
        double pitch = Atan(ggxWidth * Sqrt(e1), Sqrt(1.0 - e1));
        double yaw = Tau * e2;
        sampleBuffer[i] = Vec2f_Create((float)pitch, (float)yaw);
      }
      Tex2D_SetData(sampleTex, sampleBuffer, PixelFormat_RG, DataFormat_Float);
    }

    float angle = (float)level / (float)(levels - 1);
    angle = angle * angle;

    Shader_SetFloat("angle", angle);
    Shader_SetFloat("srcLod", (float)srcLod);
    Shader_SetTexCube("src", self);
    Shader_SetTex2D("sampleBuffer", sampleTex);
    Shader_SetInt("samples", sampleCount);

    for (int i = 0; i < 6; ++i) {
      CubeFace thisFace = face[i];
      Vec3f thisLook = look[i];
      Vec3f thisUp = up[i];
      RenderTarget_Push(size, size);
      RenderTarget_BindTexCubeLevel(result, thisFace, level);
      Shader_SetFloat3("cubeLook", thisLook.x, thisLook.y, thisLook.z);
      Shader_SetFloat3("cubeUp", thisUp.x, thisUp.y, thisUp.z);
      Draw_Rect(-1, -1, 2, 2);
      RenderTarget_Pop();
    }

    MemFree(sampleBuffer);
    Tex2D_Free(sampleTex);
  }

  RNG_Free(rng);
  Shader_Stop(shader);
  TexCube_SetMagFilter(result, TexFilter_Linear);
  TexCube_SetMinFilter(result, TexFilter_LinearMipLinear);
  return result;
}
