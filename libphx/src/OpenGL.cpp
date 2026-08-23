#include "BlendMode.h"
#include "CullFace.h"
#include "OpenGL.h"
#include "RenderState.h"
#include <SDL2/SDL.h>
#include <cstdio>

void OpenGL_Init () {
  static bool init = false;
  if (!init) {
    init = true;
    glewInit();

    /* Core-profile contexts have no default vertex array (compat profile's
     * VAO 0 does not exist). Create one global VAO and leave it bound for
     * the lifetime of the process: all existing buffer/attrib code then
     * records into it exactly like it recorded into implicit VAO 0. */
    GLuint vao = 0;
    GLCALL(glGenVertexArrays(1, &vao))
    GLCALL(glBindVertexArray(vao))

    /* One-time context report — makes version/profile skew visible. */
    GLint profile = 0;
    SDL_GL_GetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, &profile);
    /* Final ladder gate (GL 4.6): also report that the extension loader
     * actually exposes the 4.6 entry points — a granted context does not by
     * itself prove GLEW resolved every function we may call. */
    printf(
      "[GL] %s | %s | GL %s | GLSL %s | profile %s | glew-4.6 %s\n",
      glGetString(GL_VENDOR),
      glGetString(GL_RENDERER),
      glGetString(GL_VERSION),
      glGetString(GL_SHADING_LANGUAGE_VERSION),
      profile == SDL_GL_CONTEXT_PROFILE_CORE ? "CORE"
        : profile == SDL_GL_CONTEXT_PROFILE_COMPATIBILITY ? "COMPATIBILITY"
        : "ES",
      glewIsSupported("GL_VERSION_4_6") ? "yes" : "NO");
  }

  GLCALL(glDisable(GL_MULTISAMPLE))
  GLCALL(glDisable(GL_CULL_FACE));
  GLCALL(glCullFace(GL_BACK))

  GLCALL(glPixelStorei(GL_PACK_ALIGNMENT, 1))
  GLCALL(glPixelStorei(GL_UNPACK_ALIGNMENT, 1))
  GLCALL(glDepthFunc(GL_LEQUAL))

  GLCALL(glEnable(GL_BLEND))
  GLCALL(glBlendFunc(GL_ONE, GL_ZERO))

  GLCALL(glEnable(GL_TEXTURE_CUBE_MAP_SEAMLESS))
  // NOTE : GL_LINE_SMOOTH / GL_POINT_SMOOTH are compatibility-only; removed
  // in the core-profile migration (stage 5). glLineWidth >1 is also illegal
  // in core, so the old glLineWidth(2) default is dropped (GL default is 1).

  RenderState_PushAllDefaults();
}

void OpenGL_CheckError (cstr file, int line) {
  GLenum errorID = glGetError();
  cstr error = 0;
  switch (errorID) {
    case GL_NO_ERROR: return;
    case GL_INVALID_ENUM:
      error = "GL_INVALID_ENUM"; break;
    case GL_INVALID_VALUE:
      error = "GL_INVALID_VALUE"; break;
    case GL_INVALID_OPERATION:
      error = "GL_INVALID_OPERATION"; break;
    case GL_INVALID_FRAMEBUFFER_OPERATION:
      error = "GL_INVALID_FRAMEBUFFER_OPERATION"; break;
    case GL_OUT_OF_MEMORY:
      error = "GL_OUT_OF_MEMORY"; break;
    default:
      Fatal("OpenGL_CheckError: glGetError returned illegal error code %u at %s:%d", errorID, file, line);
      break;
  }
  Fatal("OpenGL_CheckError: %s at %s:%d", error, file, line);
}
