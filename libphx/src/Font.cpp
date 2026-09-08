#include "BlendMode.h"
#include "DataFormat.h"
#include "Draw.h"
#include "DrawInternal.h"
#include "Font.h"
#include "HashMap.h"
#include "PhxMemory.h"
#include "OpenGL.h"
#include "Profiler.h"
#include "RenderState.h"
#include "RefCounted.h"
#include "Resource.h"
#include "PhxMath.h"
#include "Shader.h"
#include "Tex2D.h"
#include "PixelFormat.h"
#include "TexFormat.h"
#include "Vec2.h"
#include "Vec4.h"

#include "ft2build.h"
#include FT_FREETYPE_H
#include FT_GLYPH_H
#include FT_BITMAP_H

/* TODO : Re-implement UTF-8 support */
/* Glyphs are packed into a per-font atlas (shelf-packed, 1px padding each
 * side) instead of one texture per glyph, so a whole string renders in a
 * single bind + draw — see debug-panel-update.md §S4.4. */

/* NOTE : Gamma of 1.8 recommended by FreeType */
const float kGamma = 1.8f;
const float kRcpGamma = 1.0f / kGamma;

#define FONT_ATLAS_INIT (256)
#define FONT_ATLAS_MAX  (1024)

struct Glyph {
  int index;
  int x0, y0, x1, y1;
  int sx, sy;
  int advance;
  int ax, ay;       /* Atlas pixel origin of the glyph top-left */
  Vec4f* bits;      /* CPU copy of the glyph RGBA (kept for atlas repack) */
};

struct Font {
  RefCounted;
  FT_Face handle;
  HashMap* glyphs;
  Glyph* glyphsAscii[256];
  Tex2D* atlas;
  Vec4f* atlasBits;
  int atlasSize;
  int shelfY;       /* Top of the current packing shelf */
  int shelfH;       /* Height of the current packing shelf */
  int curX;         /* X cursor within the current shelf */
  Glyph** ordered;  /* All glyphs in insertion order (for repack) */
  int orderedCount;
  int orderedCap;
};

static FT_Library ft = 0;

/* --- Glyph atlas ----------------------------------------------------------
 * Shelf packer over a square PoT atlas. Glyphs keep a CPU RGBA copy (Gamma
 * 1.8 alpha, as the old per-glyph textures) so a double-and-repack keeps the
 * exact same pixels. Placements leave a 1px clear border per side to prevent
 * linear-filter bleed between glyphs. */

static void Font_AtlasGrow (Font* self);

static void Font_AtlasCopy (Font* self, Glyph* g) {
  for (int dy = 0; dy < g->sy; ++dy)
    for (int dx = 0; dx < g->sx; ++dx)
      self->atlasBits[(size_t)(g->ay + dy) * self->atlasSize + (size_t)(g->ax + dx)]
        = g->bits[(size_t)dy * g->sx + (size_t)dx];
}

static void Font_AtlasUpload (Font* self) {
  if (!self->atlas)
    self->atlas = Tex2D_Create(self->atlasSize, self->atlasSize, TexFormat_RGBA8);
  Tex2D_SetData(self->atlas, self->atlasBits, PixelFormat_RGBA, DataFormat_Float);
}

static void Font_AtlasPlace (Font* self, int w, int h, int* outX, int* outY) {
  int cellW = Min(w + 2, self->atlasSize);
  int cellH = Min(h + 2, self->atlasSize);

  if (self->curX + cellW > self->atlasSize || self->shelfY + cellH > self->atlasSize) {
    self->curX = 0;
    self->shelfY += self->shelfH + 2;
    self->shelfH = 0;
    while (self->shelfY + cellH > self->atlasSize && self->atlasSize < FONT_ATLAS_MAX)
      Font_AtlasGrow(self);
    if (self->shelfY + cellH > self->atlasSize) {
      /* Pathological: a clamped glyph still taller than the max atlas. Overlap. */
      self->curX = 0;
      self->shelfY = 0;
    }
  }
  *outX = self->curX + 1;
  *outY = self->shelfY + 1;
  self->curX += cellW + 1;
  self->shelfH = Max(self->shelfH, cellH);
}

static void Font_AtlasGrow (Font* self) {
  self->atlasSize *= 2;
  if (self->atlasSize > FONT_ATLAS_MAX)
    self->atlasSize = FONT_ATLAS_MAX;
  MemFree(self->atlasBits);
  self->atlasBits = MemNewArray(Vec4f, (size_t)self->atlasSize * self->atlasSize);
  MemZero(self->atlasBits, (size_t)self->atlasSize * self->atlasSize * sizeof(Vec4f));
  self->shelfY = 0;
  self->shelfH = 0;
  self->curX = 0;
  for (int i = 0; i < self->orderedCount; ++i) {
    Glyph* g = self->ordered[i];
    Font_AtlasPlace(self, g->sx, g->sy, &g->ax, &g->ay);
    Font_AtlasCopy(self, g);
  }
  Font_AtlasUpload(self);
}

static Glyph* Font_GetGlyph (Font* self, uint32 codepoint) {
  if (codepoint < 256 && self->glyphsAscii[codepoint])
    return self->glyphsAscii[codepoint];

  Glyph* g = (Glyph*)HashMap_Get(self->glyphs, &codepoint);
  if (g)
    return g;

  FT_Face face = self->handle;
  int glyph = FT_Get_Char_Index(face, codepoint);
  if (glyph == 0)
    return 0;
  if (FT_Load_Glyph(face, glyph, FT_LOAD_FORCE_AUTOHINT | FT_LOAD_RENDER))
    return 0;

  FT_Bitmap const* bitmap = &face->glyph->bitmap;
  uchar const* pBitmap = bitmap->buffer;

  /* Create a new glyph and fill out metrics. */ {
    g = MemNew(Glyph);
    g->index = glyph;
    g->x0 = face->glyph->bitmap_left;
    g->y0 = -face->glyph->bitmap_top;
    g->sx = bitmap->width;
    g->sy = bitmap->rows;
    g->x1 = g->x0 + g->sx;
    g->y1 = g->y0 + g->sy;
    g->advance = face->glyph->advance.x >> 6;
  }

  Vec4f* buffer = MemNewArray(Vec4f, (size_t)g->sx * g->sy);

  /* Copy rendered bitmap into buffer. */ {
    Vec4f* pBuffer = buffer;
    for (uint dy = 0; dy < bitmap->rows; ++dy) {
      for (uint dx = 0; dx < bitmap->width; ++dx) {
        float a = Pow((float)(pBitmap[dx]) / 255.0f, kRcpGamma);
        *pBuffer++ = Vec4f_Create(1.0f, 1.0f, 1.0f, a);
      }
      pBitmap += bitmap->pitch;
    }
  }

  /* Pack into the glyph atlas (keeps the CPU copy for later repack). */ {
    g->bits = buffer;
    Font_AtlasPlace(self, g->sx, g->sy, &g->ax, &g->ay);
    Font_AtlasCopy(self, g);
    Font_AtlasUpload(self);
  }

  /* Record insertion order so a grow can repack everything. */ {
    if (self->orderedCount == self->orderedCap) {
      self->orderedCap = self->orderedCap ? self->orderedCap * 2 : 64;
      self->ordered = (Glyph**)MemRealloc(self->ordered, (size_t)self->orderedCap * sizeof(Glyph*));
    }
    self->ordered[self->orderedCount++] = g;
  }

  /* Add to glyph cache. */
  if (codepoint < 256)
    self->glyphsAscii[codepoint] = g;
  else
    HashMap_Set(self->glyphs, &codepoint, g);
  return g;
}

inline static int Font_GetKerning (Font* self, int a, int b) {
  FT_Vector kern;
  FT_Get_Kerning(self->handle, a, b, FT_KERNING_DEFAULT, &kern);
  return kern.x >> 6;
}

Font* Font_Load (cstr name, int size) {
  if (!ft)
    FT_Init_FreeType(&ft);

  cstr path = Resource_GetPath(ResourceType_Font, name);
  Font* self = MemNew(Font);
  RefCounted_Init(self);

  if (FT_New_Face(ft, path, 0, &self->handle))
    Fatal("Font_Load: Failed to load font <%s> at <%s>", name, path);
  FT_Set_Pixel_Sizes(self->handle, 0, size);

  MemZero(self->glyphsAscii, sizeof(self->glyphsAscii));
  self->glyphs = HashMap_Create(sizeof(uint32), 16);
  self->atlasSize = FONT_ATLAS_INIT;
  self->atlasBits = MemNewArrayZero(Vec4f, (size_t)FONT_ATLAS_INIT * FONT_ATLAS_INIT);
  self->atlas = 0;
  self->shelfY = 0;
  self->shelfH = 0;
  self->curX = 0;
  self->ordered = 0;
  self->orderedCount = 0;
  self->orderedCap = 0;
  return self;
}

void Font_Acquire (Font* self) {
  RefCounted_Acquire(self);
}

void Font_Free (Font* self) {
  RefCounted_Free(self) {
    for (int i = 0; i < self->orderedCount; ++i)
      MemFree(self->ordered[i]->bits);
    MemFree(self->ordered);
    MemFree(self->atlasBits);
    if (self->atlas)
      Tex2D_Free(self->atlas);
    /* TODO : Free glyphs! (the Glyph nodes themselves still leak) */
    FT_Done_Face(self->handle);
    MemFree(self);
  }
}

/* First pass: rasterize + cache every glyph in the string (new glyphs get
 * packed into the atlas here) and count how many drawable quads there are. */
static int Font_CountGlyphs (Font* self, cstr text) {
  uint32 codepoint = *text++;
  int n = 0;
  while (codepoint) {
    if (Font_GetGlyph(self, codepoint))
      ++n;
    codepoint = *text++;
  }
  return n;
}

/* Second pass: emit one quad per glyph (advance + kerning identical to the
 * old per-glyph path) with UVs pointing into the glyph atlas. */
static int Font_CollectQuads (Font* self, cstr text, float x, float y, ImmVert* verts) {
  int glyphLast = 0;
  int n = 0;
  float atlasSize = (float)self->atlasSize;
  uint32 codepoint = *text++;
  while (codepoint) {
    Glyph* glyph = Font_GetGlyph(self, codepoint);
    if (glyph) {
      if (glyphLast)
        x += Font_GetKerning(self, glyphLast, glyph->index);
      float x0 = (float)(x + glyph->x0);
      float y0 = (float)(y + glyph->y0);
      float x1 = (float)(x + glyph->x1);
      float y1 = (float)(y + glyph->y1);
      float u0 = (float)glyph->ax / atlasSize;
      float v0 = (float)glyph->ay / atlasSize;
      float u1 = (float)(glyph->ax + glyph->sx) / atlasSize;
      float v1 = (float)(glyph->ay + glyph->sy) / atlasSize;
      verts[n * 4 + 0] = { x0, y0, 0.0f, u0, v0 };
      verts[n * 4 + 1] = { x0, y1, 0.0f, u0, v1 };
      verts[n * 4 + 2] = { x1, y1, 0.0f, u1, v1 };
      verts[n * 4 + 3] = { x1, y0, 0.0f, u1, v0 };
      ++n;
      x += glyph->advance;
      glyphLast = glyph->index;
    } else {
      glyphLast = 0;
    }
    codepoint = *text++;
  }
  return n;
}

/* Draw an entire string as ONE quads draw against the glyph atlas (identical
 * metrics/coloring to the old per-glyph Tex2D_DrawEx path, but ~1 bind + 1
 * draw instead of one per glyph — debug-panel-update.md §S4.4). */
void Font_Draw (
  Font* self, cstr text,
  float x, float y,
  float r, float g, float b, float a)
{
  FRAME_BEGIN;
  int glyphs = Font_CountGlyphs(self, text);
  x = Floor(x);
  y = Floor(y);
  RenderState_PushBlendMode(BlendMode_Alpha);
  Draw_Color(r, g, b, a);

  if (glyphs) {
    enum { kStackQuads = 64 };
    ImmVert stackVerts[kStackQuads * 4];
    ImmVert* verts = stackVerts;
    if (glyphs > kStackQuads)
      verts = MemNewArray(ImmVert, (size_t)glyphs * 4);
    int n = Font_CollectQuads(self, text, x, y, verts);
    if (n) {
      GLCALL(glActiveTexture(GL_TEXTURE0))
      GLCALL(glBindTexture(GL_TEXTURE_2D, Tex2D_GetHandle(self->atlas)))
      Draw_SetTexturedImm(true);
      Imm_Draw(verts, n * 4, GL_QUADS);
    }
    if (verts != stackVerts)
      MemFree(verts);
  }

  Draw_Color(1, 1, 1, 1);
  RenderState_PopBlendMode();
  FRAME_END;
}

void Font_DrawShaded (Font* self, cstr text, float x, float y) {
  FRAME_BEGIN;
  int glyphs = Font_CountGlyphs(self, text);
  x = Floor(x);
  y = Floor(y);

  if (glyphs) {
    enum { kStackQuads = 64 };
    ImmVert stackVerts[kStackQuads * 4];
    ImmVert* verts = stackVerts;
    if (glyphs > kStackQuads)
      verts = MemNewArray(ImmVert, (size_t)glyphs * 4);
    int n = Font_CollectQuads(self, text, x, y, verts);
    if (n) {
      Shader_SetTex2D("glyph", self->atlas);
      Draw_SetTexturedImm(true);
      Imm_Draw(verts, n * 4, GL_QUADS);
    }
    if (verts != stackVerts)
      MemFree(verts);
  }

  FRAME_END;
}

int Font_GetLineHeight (Font* self) {
  return self->handle->size->metrics.height >> 6;
}

void Font_GetSize (Font* self, Vec4i* out, cstr text) {
  FRAME_BEGIN;
  int x = 0, y = 0;
  Vec2i lower = { INT_MAX, INT_MAX };
  Vec2i upper = { INT_MIN, INT_MIN };

  int glyphLast = 0;
  uint32 codepoint = *text++;
  if (!codepoint) {
    *out = Vec4i_Create(0, 0, 0, 0);
    return;
  }

  while (codepoint) {
    Glyph* glyph = Font_GetGlyph(self, codepoint);
    if (glyph) {
      if (glyphLast)
        x += Font_GetKerning(self, glyphLast, glyph->index);
      lower.x = Min(lower.x, x + glyph->x0);
      lower.y = Min(lower.y, y + glyph->y0);
      upper.x = Max(upper.x, x + glyph->x1);
      upper.y = Max(upper.y, y + glyph->y1);
      x += glyph->advance;
      glyphLast = glyph->index;
    } else {
      glyphLast = 0;
    }
    codepoint = *text++;
  }

  *out = Vec4i_Create(lower.x, lower.y, upper.x - lower.x, upper.y - lower.y);
  FRAME_END;
}

/* NOTE : The height returned here is the maximal *ascender* height for the
 *        string. This allows easy centering of text while still allowing
 *        descending characters to look correct.
 *
 *        To correctly center text, first compute bounds via this function,
 *        then draw it at:
 *
 *           pos.x - (size.x - bound.x) / 2
 *           pos.y - (size.y + bound.y) / 2
 */

void Font_GetSize2 (Font* self, Vec2i* out, cstr text) {
  FRAME_BEGIN;
  out->x = 0;
  out->y = 0;

  int glyphLast = 0;
  uint32 codepoint = *text++;
  while (codepoint) {
    Glyph* glyph = Font_GetGlyph(self, codepoint);
    if (glyph) {
      if (glyphLast)
        out->x += Font_GetKerning(self, glyphLast, glyph->index);
      out->x += glyph->advance;
      out->y = Max(out->y, -glyph->y0 + 1);
      glyphLast = glyph->index;
    } else {
      glyphLast = 0;
    }
    codepoint = *text++;
  }

  FRAME_END;
}
