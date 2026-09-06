#ifndef PHX_Shader
#define PHX_Shader

#include "Common.h"

/* --- API NOTES ---------------------------------------------------------------
 *
 *   This type is REFERENCE-COUNTED. See ../doc/RefCounted.txt for details.
 *
 * -------------------------------------------------------------------------- */

PHX_API Shader*       Shader_Create         (cstr vertCode, cstr fragCode);
PHX_API Shader*       Shader_Load           (cstr vertName, cstr fragName);
/* Compute programs: single GL_COMPUTE_SHADER stage loaded from
 * res/shader/<compName>.glsl through the same preprocessor as graphics
 * shaders (#include / #autovar both work). */
PHX_API Shader*       Shader_LoadCompute    (cstr compName);
PHX_API void          Shader_Acquire        (Shader*);
PHX_API void          Shader_Free           (Shader*);
PHX_API ShaderState*  Shader_ToShaderState  (Shader*);

PHX_API void          Shader_Start          (Shader*);
PHX_API void          Shader_Stop           (Shader*);
/* The currently-bound program (Shader_Start/Stop track it), or null if none.
 * Lets low-level draw paths detect the core-profile "no program bound" state. */
PHX_API Shader*       Shader_GetActive      ();

/* Dispatches the currently-bound COMPUTE shader. Fatals if no shader is
 * bound or the bound program is a graphics pipeline. */
PHX_API void          Shader_Dispatch       (uint x, uint y, uint z);

/* glMemoryBarrier passthrough. Values mirror the GL_*_BARRIER_BIT constants. */
PHX_API void          Shader_MemoryBarrier  (uint barriers);

enum {
  ShaderBarrier_VertexAttrib     = 0x00000001,
  ShaderBarrier_ElementArray     = 0x00000002,
  ShaderBarrier_Uniform          = 0x00000004,
  ShaderBarrier_TextureFetch     = 0x00000008,
  ShaderBarrier_ShaderImageAccess= 0x00000020,
  ShaderBarrier_Command          = 0x00000040,
  ShaderBarrier_PixelBuffer      = 0x00000080,
  ShaderBarrier_TextureUpdate    = 0x00000100,
  ShaderBarrier_BufferUpdate     = 0x00000200,
  ShaderBarrier_Framebuffer      = 0x00000400,
  ShaderBarrier_TransformFeedback= 0x00000800,
  ShaderBarrier_AtomicCounter    = 0x00001000,
  ShaderBarrier_ShaderStorage    = 0x00002000,
  ShaderBarrier_QueryBuffer      = 0x00008000,
  ShaderBarrier_All              = 0xFFFFFFFFu,
};

PHX_API uint          Shader_GetHandle      (Shader*);
PHX_API int           Shader_GetVariable    (Shader*, cstr);
PHX_API bool          Shader_HasVariable    (Shader*, cstr);

PHX_API void          Shader_ClearCache     ();
PHX_API void          Shader_SetFloat       (cstr, float);
PHX_API void          Shader_SetFloat2      (cstr, float, float);
PHX_API void          Shader_SetFloat3      (cstr, float, float, float);
PHX_API void          Shader_SetFloat4      (cstr, float, float, float, float);
PHX_API void          Shader_SetInt         (cstr, int);
PHX_API void          Shader_SetMatrix      (cstr, Matrix*);
PHX_API void          Shader_SetMatrixT     (cstr, Matrix*);
PHX_API void          Shader_SetTex1D       (cstr, Tex1D*);
PHX_API void          Shader_SetTex2D       (cstr, Tex2D*);
PHX_API void          Shader_SetTex3D       (cstr, Tex3D*);
PHX_API void          Shader_SetTexCube     (cstr, TexCube*);

PHX_API void          Shader_ISetFloat      (int, float);
PHX_API void          Shader_ISetFloat2     (int, float, float);
PHX_API void          Shader_ISetFloat3     (int, float, float, float);
PHX_API void          Shader_ISetFloat4     (int, float, float, float, float);
PHX_API void          Shader_ISetInt        (int, int);
PHX_API void          Shader_ISetMatrix     (int, Matrix*);
PHX_API void          Shader_ISetMatrixT    (int, Matrix*);
PHX_API void          Shader_ISetTex1D      (int, Tex1D*);
PHX_API void          Shader_ISetTex2D      (int, Tex2D*);
PHX_API void          Shader_ISetTex3D      (int, Tex3D*);
PHX_API void          Shader_ISetTexCube    (int, TexCube*);
#endif
