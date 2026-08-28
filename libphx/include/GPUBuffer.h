#ifndef PHX_GPUBuffer
#define PHX_GPUBuffer

#include "Common.h"

/* --- API NOTES ---------------------------------------------------------------
 *
 *   This type is REFERENCE-COUNTED. See ../doc/RefCounted.txt for details.
 *
 *   A GPUBuffer is a raw block of device-local memory addressable as a shader
 *   storage buffer (SSBO). It backs the compute pipeline: upload state, bind it
 *   to a binding index (matching `layout(std430, binding = N)` in the shader),
 *   dispatch, memory-barrier, then download results or leave it resident for
 *   rendering to consume.
 *
 * -------------------------------------------------------------------------- */

PHX_API GPUBuffer* GPUBuffer_Create     (uint size);
PHX_API void       GPUBuffer_Acquire    (GPUBuffer*);
PHX_API void       GPUBuffer_Free       (GPUBuffer*);

/* Uploads/downloads are bounds-checked against the buffer's fixed size.
 * Both operate through GL_SHADER_STORAGE_BUFFER so no second target is kept. */
PHX_API void       GPUBuffer_Upload     (GPUBuffer*, void const* data, uint size);
PHX_API void       GPUBuffer_Download   (GPUBuffer*, void* outData, uint size);

/* Binds the whole buffer to an SSBO binding point (glBindBufferBase). */
PHX_API void       GPUBuffer_BindSSBO   (GPUBuffer*, uint binding);

PHX_API uint       GPUBuffer_GetHandle  (GPUBuffer*);
PHX_API uint       GPUBuffer_GetSize    (GPUBuffer*);
#endif
