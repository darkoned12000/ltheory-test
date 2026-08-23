#include "Common.h"
#include "GPUBuffer.h"
#include "OpenGL.h"
#include "PhxMemory.h"
#include "RefCounted.h"

struct GPUBuffer {
  RefCounted;
  uint handle;
  uint size;
};

GPUBuffer* GPUBuffer_Create (uint size) {
  /* Storage is zero-initialized so early frames/dispatches read deterministic
   * data instead of driver-dependent garbage. */
  GPUBuffer* self = MemNew(GPUBuffer);
  RefCounted_Init(self);
  self->size = size;
  void* zeroed = MemAllocZero(size);
  GLCALL(glGenBuffers(1, &self->handle))
  GLCALL(glBindBuffer(GL_SHADER_STORAGE_BUFFER, self->handle))
  GLCALL(glBufferData(GL_SHADER_STORAGE_BUFFER, size, zeroed, GL_DYNAMIC_DRAW))
  GLCALL(glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0))
  MemFree(zeroed);
  return self;
}

void GPUBuffer_Acquire (GPUBuffer* self) {
  RefCounted_Acquire(self);
}

void GPUBuffer_Free (GPUBuffer* self) {
  RefCounted_Free(self) {
    GLCALL(glDeleteBuffers(1, &self->handle))
    MemFree(self);
  }
}

void GPUBuffer_Upload (GPUBuffer* self, void const* data, uint size) {
  if (size > self->size)
    Fatal("GPUBuffer_Upload: %u bytes exceeds buffer size %u", size, self->size);
  GLCALL(glBindBuffer(GL_SHADER_STORAGE_BUFFER, self->handle))
  GLCALL(glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, size, data))
  GLCALL(glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0))
}

void GPUBuffer_Download (GPUBuffer* self, void* outData, uint size) {
  if (size > self->size)
    Fatal("GPUBuffer_Download: %u bytes exceeds buffer size %u", size, self->size);
  GLCALL(glBindBuffer(GL_SHADER_STORAGE_BUFFER, self->handle))
  GLCALL(glGetBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, size, outData))
  GLCALL(glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0))
}

void GPUBuffer_BindSSBO (GPUBuffer* self, uint binding) {
  GLCALL(glBindBufferBase(GL_SHADER_STORAGE_BUFFER, binding, self->handle))
}

uint GPUBuffer_GetHandle (GPUBuffer* self) {
  return self->handle;
}

uint GPUBuffer_GetSize (GPUBuffer* self) {
  return self->size;
}
