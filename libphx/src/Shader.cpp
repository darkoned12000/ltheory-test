#include "ArrayList.h"
#include "Matrix.h"
#include "PhxMemory.h"
#include "OpenGL.h"
#include "Profiler.h"
#include "RefCounted.h"
#include "Resource.h"
#include "Shader.h"
#include "ShaderState.h"
#include "ShaderVar.h"
#include "ShaderVarType.h"
#include "StrMap.h"
#include "PhxString.h"
#include "Tex1D.h"
#include "Tex2D.h"
#include "Tex3D.h"
#include "TexCube.h"
#include "Vec2.h"
#include "Vec3.h"
#include "Vec4.h"

/* TODO : Implement custom directives to mimic layout functionality from GL3+. */
/* TODO : Use glShaderSource's array functionality to implement include files
 *        elegantly. */

static cstr includePath = "include/";
static cstr versionString = "#version 460 core\n";

struct ShaderVar {
  ShaderVarType type;
  cstr name;
  int index;
};

struct Shader {
  RefCounted;
  cstr name;
  uint vs;
  uint fs;
  uint cs;      /* Compute stage handle; 0 for graphics shaders. */
  bool compute; /* True if this program is a single compute stage. */
  uint program;
  uint texIndex;
  ArrayList(ShaderVar, vars);
};

static Shader* current = 0;
static StrMap* cache = 0;

static cstr GLSL_Load(cstr path, Shader*);
static cstr GLSL_Preprocess(cstr code, Shader*);

static int GetUniformIndex (Shader* self, cstr name, bool mustSucceed = false) {
  if (!self)
    Fatal("GetUniformIndex: No shader is bound");
  int index = glGetUniformLocation(self->program, name);
  if (index == -1 && mustSucceed)
    Fatal("GetUniformIndex: Shader <%s> has no variable <%s>", self->name, name);
  return index;
}

static uint CreateGLShader (cstr name, cstr src, GLenum type) {
  uint self = glCreateShader(type);

  cstr srcs[] = {
    versionString,
    src,
  };

  GLCALL(glShaderSource(self, 2, srcs, 0))
  GLCALL(glCompileShader(self))

  /* Return NULL on compile failure. The caller logs stage + source; returning here
   * (instead of aborting) lets Lua degrade gracefully — a broken shader no longer kills
   * the whole process at first draw. */ {
    int status;
    GLCALL(glGetShaderiv(self, GL_COMPILE_STATUS, &status))
    if (status == GL_FALSE) {
      int length;
      GLCALL(glGetShaderiv(self, GL_INFO_LOG_LENGTH, &length))
      char* infoLog = (char*)MemAllocZero(length + 1);
      GLCALL(glGetShaderInfoLog(self, length, 0, infoLog))
      fprintf(stderr, "phx: shader compile failed <%s>:\n%s\n", name, infoLog);
      return 0;
    }
  }
  return self;
}

static uint CreateGLProgram (uint vs, uint fs) {
  uint self = glCreateProgram();
  GLCALL(glAttachShader(self, vs))
  GLCALL(glAttachShader(self, fs))

  /* TODO : Replace with custom directives. */ {
    GLCALL(glBindAttribLocation(self, 0, "vertex_position"))
    GLCALL(glBindAttribLocation(self, 1, "vertex_normal"))
    GLCALL(glBindAttribLocation(self, 2, "vertex_uv"))
  }

  GLCALL(glLinkProgram(self))

  /* Check for link errors. Return NULL on failure (caller logs stage + source). */ {
    int status;
    GLCALL(glGetProgramiv(self, GL_LINK_STATUS, &status))
    if (status == GL_FALSE) {
      int length;
      GLCALL(glGetProgramiv(self, GL_INFO_LOG_LENGTH, &length))
      char* infoLog = (char*)MemAllocZero(length + 1);
      GLCALL(glGetProgramInfoLog(self, length, 0, infoLog))
      fprintf(stderr, "phx: shader link failed [vs:%u fs:%u]:\n%s\n", vs, fs, infoLog);
      return 0;
    }
  }
  return self;
}

/* Compute programs have no vertex attributes to bind and exactly one stage. */
static uint CreateGLComputeProgram (uint cs) {
  uint self = glCreateProgram();
  GLCALL(glAttachShader(self, cs))
  GLCALL(glLinkProgram(self))

  /* Check for link errors. Return NULL on failure (caller logs stage + source). */ {
    int status;
    GLCALL(glGetProgramiv(self, GL_LINK_STATUS, &status))
    if (status == GL_FALSE) {
      int length;
      GLCALL(glGetProgramiv(self, GL_INFO_LOG_LENGTH, &length))
      char* infoLog = (char*)MemAllocZero(length + 1);
      GLCALL(glGetProgramInfoLog(self, length, 0, infoLog))
      fprintf(stderr, "phx: compute shader link failed <%u>:\n%s\n", cs, infoLog);
      return 0;
    }
  }
  return self;
}

/* BUG : Cache does not contain information about custom preprocessor
 *       directives, hence cached shaders with custom directives do not work */
static cstr GLSL_Load (cstr name, Shader* self) {
  if (!cache)
    cache = StrMap_Create(16);
  void* cached = StrMap_Get(cache, name);
  if (cached)
    return (cstr)cached;
  cstr rawCode = Resource_LoadCstr(ResourceType_Shader, name);
  cstr code = StrReplace(rawCode, "\r\n", "\n");
  StrFree(rawCode);
  code = GLSL_Preprocess(code, self);
  /* BUG : Disable GLSL caching until preprocessor cache works. */
  // StrMap_Set(cache, name, (void*)code);
  return code;
}

static cstr GLSL_Preprocess (cstr code, Shader* self) {
  const int lenInclude = StrLen("#include");
  cstr begin;

  /* Parse Includes. */
  while ((begin = StrFind(code, "#include")) != 0) {
    cstr end = StrFind(begin, "\n");
    cstr name = StrSubStr(begin + lenInclude + 1, end);
    cstr path = StrAdd(includePath, name);
    cstr prev = code;
    code = StrSub(code, begin, end, GLSL_Load(path, self));
    StrFree(prev);
    StrFree(path);
    StrFree(name);
  }

  /* Parse automatic ShaderVar stack bindings. */
  while ((begin = StrFind(code, "#autovar")) != 0) {
    cstr end = StrFind(begin, "\n");
    cstr line = StrSubStr(begin, end);
    char varType[32] = { 0 };
    char varName[32] = { 0 };

    if (sscanf(line, "#autovar %31s %31s", varType, varName) == 2) {
      ShaderVar var = { 0 };
      var.type = ShaderVarType_FromStr(varType);
      if (var.type == ShaderVarType_None)
        Fatal("GLSL_Preprocess: Unknown shader variable type <%s> "
              "in directive:\n  %s", varType, line);
      var.name = StrDup(varName);
      var.index = -1;
      ArrayList_Append(self->vars, var);
    } else {
      Fatal("GLSL_Preprocess: Failed to parse directive:\n  %s", line);
    }

    cstr prev = code;
    code = StrSub(code, begin, end, "");
    StrFree(prev);
    StrFree(line);
  }
  return code;
}

static void Shader_BindVariables (Shader* self) {
  for (int i = 0; i < ArrayList_GetSize(self->vars); ++i) {
    ShaderVar* var = ArrayList_GetPtr(self->vars, i);
    var->index = glGetUniformLocation(self->program, var->name);
    if (var->index < 0)
      Warn("Shader_BindVariables: Automatic shader variable <%s> does not exist"
           " in shader <%s>", var->name, self->name);
  }
}

/* --- Creation ------------------------------------------------------------- */

Shader* Shader_Create (cstr vs, cstr fs) {
  Shader* self = MemNewZero(Shader);
  RefCounted_Init(self);
  ArrayList_Init(self->vars);
  vs = GLSL_Preprocess(StrDup(vs), self);
  fs = GLSL_Preprocess(StrDup(fs), self);
  self->vs = CreateGLShader(vs, vs, GL_VERTEX_SHADER);
  if (!self->vs) { MemFree(self); return NULL; }
  self->fs = CreateGLShader(fs, fs, GL_FRAGMENT_SHADER);
  if (!self->fs) { Shader_Free(self); return NULL; }
  self->program = CreateGLProgram(self->vs, self->fs);
  if (!self->program) { Shader_Free(self); fprintf(stderr, "phx: anonymous shader link failed\n"); return NULL; }
  self->texIndex = 1;
  self->name = StrFormat("[anonymous shader @ %p]", self);
  StrFree(vs);
  StrFree(fs);
  Shader_BindVariables(self);
  return self;
}

Shader* Shader_Load (cstr vName, cstr fName) {
  Shader* self = MemNewZero(Shader);
  RefCounted_Init(self);
  ArrayList_Init(self->vars);
  self->vs = 0;
  self->fs = 0;
  self->cs = 0;
  self->compute = false;
  cstr vs = GLSL_Load(vName, self);
  cstr fs = GLSL_Load(fName, self);
  uint vsh = CreateGLShader(vName, vs, GL_VERTEX_SHADER);
  if (!vsh) { MemFree(self); return NULL; }
  uint fsh = CreateGLShader(fName, fs, GL_FRAGMENT_SHADER);
  if (!fsh) { Shader_Free(self); return NULL; }
  uint program = CreateGLProgram(vsh, fsh);
  if (!program) { Shader_Free(self); return NULL; }
  self->vs = vsh;
  self->fs = fsh;
  self->program = program;
  self->texIndex = 1;
  self->name = StrFormat("[vs: %s , fs: %s]", vName, fName);
  Shader_BindVariables(self);
  return self;
}

Shader* Shader_LoadCompute (cstr cName) {
  Shader* self = MemNewZero(Shader);
  RefCounted_Init(self);
  ArrayList_Init(self->vars);
  self->vs = 0;
  self->fs = 0;
  self->cs = 0;
  self->compute = true;
  cstr cs = GLSL_Load(cName, self);
  uint csh = CreateGLShader(cName, cs, GL_COMPUTE_SHADER);
  if (!csh) { MemFree(self); return NULL; }
  StrFree(cs);
  uint program = CreateGLComputeProgram(csh);
  if (!program) { Shader_Free(self); return NULL; }
  self->cs = csh;
  self->texIndex = 1;
  self->name = StrFormat("[cs: %s]", cName);
  Shader_BindVariables(self);
  return self;
}

void Shader_Acquire (Shader* self) {
  RefCounted_Acquire(self);
}

void Shader_Free (Shader* self) {
  RefCounted_Free(self) {
    /* Handles of unused stages stay 0; glDeleteShader(0) is a silent no-op. */
    GLCALL(glDeleteShader(self->vs))
    GLCALL(glDeleteShader(self->fs))
    GLCALL(glDeleteShader(self->cs))
    GLCALL(glDeleteProgram(self->program))
    ArrayList_Free(self->vars);
    StrFree(self->name);
    MemFree(self);
  }
}

ShaderState* Shader_ToShaderState (Shader* self) {
  return ShaderState_Create(self);
}

/* --- Usage ---------------------------------------------------------------- */

void Shader_Start (Shader* self) {
  if (!self) return; /* Item 4: broken shader load returned NULL; skip the pass instead of dereferencing program/vars, preventing SIGSEGV in Lua caller */
  FRAME_BEGIN;
  GLCALL(glUseProgram(self->program))
  current = self;
  self->texIndex = 1;

  /* Fetch & bind automatic variables from the shader var stack. */
  for (int i = 0; i < ArrayList_GetSize(self->vars); ++i) {
    ShaderVar* var = ArrayList_GetPtr(self->vars, i);
    if (var->index < 0) continue;
    void* pValue = ShaderVar_Get(var->name, var->type);
    if (!pValue)
      Fatal("Shader_Start: Shader variable stack does not contain variable <%s>", var->name);

    switch (var->type) {
      case ShaderVarType_Float: {
        float value = *(float*)pValue;
        GLCALL(glUniform1f(var->index, value));
        break; }
      case ShaderVarType_Float2: {
        Vec2f value = *(Vec2f*)pValue;
        GLCALL(glUniform2f(var->index, value.x, value.y));
        break; }
      case ShaderVarType_Float3: {
        Vec3f value = *(Vec3f*)pValue;
        GLCALL(glUniform3f(var->index, value.x, value.y, value.z));
        break; }
      case ShaderVarType_Float4: {
        Vec4f value = *(Vec4f*)pValue;
        GLCALL(glUniform4f(var->index, value.x, value.y, value.z, value.w));
        break; }
      case ShaderVarType_Int: {
        int value = *(int*)pValue;
        GLCALL(glUniform1i(var->index, value));
        break; }
      case ShaderVarType_Int2: {
        Vec2i value = *(Vec2i*)pValue;
        GLCALL(glUniform2i(var->index, value.x, value.y));
        break; }
      case ShaderVarType_Int3: {
        Vec3i value = *(Vec3i*)pValue;
        GLCALL(glUniform3i(var->index, value.x, value.y, value.z));
        break; }
      case ShaderVarType_Int4: {
        Vec4i value = *(Vec4i*)pValue;
        GLCALL(glUniform4i(var->index, value.x, value.y, value.z, value.w));
        break; }
      case ShaderVarType_Matrix: {
        Shader_ISetMatrix(var->index, *(Matrix**)pValue);
        break; }
      case ShaderVarType_Tex1D: {
        Shader_ISetTex1D(var->index, *(Tex1D**)pValue);
        break; }
      case ShaderVarType_Tex2D: {
        Shader_ISetTex2D(var->index, *(Tex2D**)pValue);
        break; }
      case ShaderVarType_Tex3D: {
        Shader_ISetTex3D(var->index, *(Tex3D**)pValue);
        break; }
      case ShaderVarType_TexCube: {
        Shader_ISetTexCube(var->index, *(TexCube**)pValue);
        break; }
    }
  }
  FRAME_END;
}

void Shader_Stop (Shader*) {
  GLCALL(glUseProgram(0))
  current = 0;
}

Shader* Shader_GetActive () {
  return current;
}

void Shader_Dispatch (uint x, uint y, uint z) {
  if (!current)
    Fatal("Shader_Dispatch: No shader is bound");
  if (!current->compute)
    Fatal("Shader_Dispatch: Bound shader <%s> is not a compute shader", current->name);
  GLCALL(glDispatchCompute(x, y, z))
}

void Shader_MemoryBarrier (uint barriers) {
  GLCALL(glMemoryBarrier(barriers))
}

static void ShaderCache_FreeElem (cstr, void* data) {
  free(data);
}

void Shader_ClearCache () {
  if (cache) {
    StrMap_FreeEx(cache, ShaderCache_FreeElem);
    cache = 0;
  }
}

uint Shader_GetHandle (Shader* self) {
  return self->program;
}

int Shader_GetVariable (Shader* self, cstr name) {
  int index = glGetUniformLocation(self->program, name);
  if (index == -1)
    Fatal("Shader_GetVariable: Shader <%s> has no variable <%s>", self->name, name);
  return index;
}

bool Shader_HasVariable (Shader* self, cstr name) {
  return glGetUniformLocation(self->program, name) > -1;
}

/* --- Variable Binding ----------------------------------------------------- */

void Shader_SetFloat (cstr name, float value) {
  GLCALL(glUniform1f(GetUniformIndex(current, name), value))
}

void Shader_ISetFloat (int index, float value) {
  GLCALL(glUniform1f(index, value))
}

void Shader_SetFloat2 (cstr name, float x, float y) {
  GLCALL(glUniform2f(GetUniformIndex(current, name), x, y))
}

void Shader_ISetFloat2 (int index, float x, float y) {
  GLCALL(glUniform2f(index, x, y))
}

void Shader_SetFloat3 (cstr name, float x, float y, float z) {
  GLCALL(glUniform3f(GetUniformIndex(current, name), x, y, z))
}

void Shader_ISetFloat3 (int index, float x, float y, float z) {
  GLCALL(glUniform3f(index, x, y, z))
}

void Shader_SetFloat4 (cstr name, float x, float y, float z, float w) {
  GLCALL(glUniform4f(GetUniformIndex(current, name), x, y, z, w))
}

void Shader_ISetFloat4 (int index, float x, float y, float z, float w) {
  GLCALL(glUniform4f(index, x, y, z, w))
}

void Shader_SetInt (cstr name, int value) {
  GLCALL(glUniform1i(GetUniformIndex(current, name), value))
}

void Shader_ISetInt (int index, int value) {
  GLCALL(glUniform1i(index, value))
}

void Shader_SetMatrix (cstr name, Matrix* value) {
  GLCALL(glUniformMatrix4fv(GetUniformIndex(current, name), 1, true, (float*)value))
}

void Shader_SetMatrixT (cstr name, Matrix* value) {
  GLCALL(glUniformMatrix4fv(GetUniformIndex(current, name), 1, false, (float*)value))
}

void Shader_ISetMatrix (int index, Matrix* value) {
  GLCALL(glUniformMatrix4fv(index, 1, true, (float*)value))
}

void Shader_ISetMatrixT (int index, Matrix* value) {
  GLCALL(glUniformMatrix4fv(index, 1, false, (float*)value))
}

void Shader_SetTex1D (cstr name, Tex1D* value) {
  GLCALL(glUniform1i(GetUniformIndex(current, name), current->texIndex))
  GLCALL(glActiveTexture(GL_TEXTURE0 + current->texIndex++))
  GLCALL(glBindTexture(GL_TEXTURE_1D, Tex1D_GetHandle(value)))
  GLCALL(glActiveTexture(GL_TEXTURE0))
}

void Shader_ISetTex1D (int index, Tex1D* value) {
  GLCALL(glUniform1i(index, current->texIndex))
  GLCALL(glActiveTexture(GL_TEXTURE0 + current->texIndex++))
  GLCALL(glBindTexture(GL_TEXTURE_1D, Tex1D_GetHandle(value)))
  GLCALL(glActiveTexture(GL_TEXTURE0))
}

void Shader_SetTex2D (cstr name, Tex2D* value) {
  GLCALL(glUniform1i(GetUniformIndex(current, name), current->texIndex))
  GLCALL(glActiveTexture(GL_TEXTURE0 + current->texIndex++))
  GLCALL(glBindTexture(GL_TEXTURE_2D, Tex2D_GetHandle(value)))
  GLCALL(glActiveTexture(GL_TEXTURE0))
}

void Shader_ISetTex2D (int index, Tex2D* value) {
  GLCALL(glUniform1i(index, current->texIndex))
  GLCALL(glActiveTexture(GL_TEXTURE0 + current->texIndex++))
  GLCALL(glBindTexture(GL_TEXTURE_2D, Tex2D_GetHandle(value)))
  GLCALL(glActiveTexture(GL_TEXTURE0))
}

void Shader_SetTex3D (cstr name, Tex3D* value) {
  GLCALL(glUniform1i(GetUniformIndex(current, name), current->texIndex))
  GLCALL(glActiveTexture(GL_TEXTURE0 + current->texIndex++))
  GLCALL(glBindTexture(GL_TEXTURE_3D, Tex3D_GetHandle(value)))
  GLCALL(glActiveTexture(GL_TEXTURE0))
}

void Shader_ISetTex3D (int index, Tex3D* value) {
  GLCALL(glUniform1i(index, current->texIndex))
  GLCALL(glActiveTexture(GL_TEXTURE0 + current->texIndex++))
  GLCALL(glBindTexture(GL_TEXTURE_3D, Tex3D_GetHandle(value)))
  GLCALL(glActiveTexture(GL_TEXTURE0))
}

void Shader_SetTexCube (cstr name, TexCube* value) {
  GLCALL(glUniform1i(GetUniformIndex(current, name), current->texIndex))
  GLCALL(glActiveTexture(GL_TEXTURE0 + current->texIndex++))
  GLCALL(glBindTexture(GL_TEXTURE_CUBE_MAP, TexCube_GetHandle(value)))
  GLCALL(glActiveTexture(GL_TEXTURE0))
}

void Shader_ISetTexCube (int index, TexCube* value) {
  GLCALL(glUniform1i(index, current->texIndex))
  GLCALL(glActiveTexture(GL_TEXTURE0 + current->texIndex++))
  GLCALL(glBindTexture(GL_TEXTURE_CUBE_MAP, TexCube_GetHandle(value)))
  GLCALL(glActiveTexture(GL_TEXTURE0))
}
