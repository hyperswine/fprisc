/* vecgpu.c — the GPU tier's machine layer: headless (EGL surfaceless)
 * desktop-GL 4.5 compute shaders over DOUBLE SSBOs.
 *
 * Why desktop GL and not ES: GLSL 4.30's fp64 means the GPU tier does
 * the SAME IEEE double arithmetic the JIT does — the dispatch contract
 * stays "bit-identical or bail", not "approximately right".  llvmpipe
 * satisfies it on machines with no GPU at all (it IS the CPU, but the
 * dispatch layer neither knows nor cares — same contract, different
 * discharge).
 *
 * API (Sol/Gpu.hs FFI):
 *   solgpu_init()                       -> 1 ok / 0 unavailable (probe once)
 *   solgpu_map_f64(src, us, nu, xs, out, n) -> 0 ok / -1 (src = full GLSL
 *                       text, programs cached by source; us = nu captured
 *                       scalars bound to double uniforms u0..u{nu-1})
 */
#if defined(__APPLE__) && !defined(SOL_GPU_APPLE)
/* macOS: no system EGL; mesa-from-brew is opt-in (-DSOL_GPU_APPLE with
 * mesa include/lib dirs).  Default build: the tier declines cleanly at
 * init instead of crashing at startup. */
#include <stdint.h>
int solgpu_init(void) { return 0; }
int solgpu_map_f64(const char *src, const double *us, long nu,
                   const double *xs, double *out, long n) {
  (void)src; (void)us; (void)nu; (void)xs; (void)out; (void)n; return -1;
}
#else
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>
#include <GL/glext.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_ready = 0;

/* tiny program cache: source pointer identity is not stable from Haskell,
 * so hash the source text */
#define CACHE 32
static struct { unsigned long h; GLuint prog; } g_cache[CACHE];
static int g_cachen = 0;

static unsigned long strhash(const char *s) {
  unsigned long h = 1469598103934665603UL;
  for (; *s; s++) { h ^= (unsigned char)*s; h *= 1099511628211UL; }
  return h;
}

/* resolve GL entry points through EGL (no GLEW dependency) */
#define GP(t, n) static t n##_ = 0; if (!n##_) n##_ = (t)eglGetProcAddress(#n);
typedef GLuint (*PFNCREATESHADER)(GLenum);
typedef void (*PFNSHADERSOURCE)(GLuint, GLsizei, const char *const *, const GLint *);
typedef void (*PFNCOMPILESHADER)(GLuint);
typedef void (*PFNGETSHADERIV)(GLuint, GLenum, GLint *);
typedef void (*PFNGETSHADERLOG)(GLuint, GLsizei, GLsizei *, char *);
typedef GLuint (*PFNCREATEPROGRAM)(void);
typedef void (*PFNATTACH)(GLuint, GLuint);
typedef void (*PFNLINK)(GLuint);
typedef void (*PFNGETPROGIV)(GLuint, GLenum, GLint *);
typedef void (*PFNUSEPROG)(GLuint);
typedef void (*PFNGENBUF)(GLsizei, GLuint *);
typedef void (*PFNBINDBUF)(GLenum, GLuint);
typedef void (*PFNBUFDATA)(GLenum, GLsizeiptr, const void *, GLenum);
typedef void (*PFNBINDBASE)(GLenum, GLuint, GLuint);
typedef void (*PFNDISPATCH)(GLuint, GLuint, GLuint);
typedef void (*PFNMEMBAR)(GLbitfield);
typedef void (*PFNGETBUFSUB)(GLenum, GLintptr, GLsizeiptr, void *);
typedef void (*PFNDELBUF)(GLsizei, const GLuint *);
typedef void (*PFNDELSH)(GLuint);
typedef GLint (*PFNGETUNILOC)(GLuint, const char *);
typedef void (*PFNUNIFORM1D)(GLint, double);

int solgpu_init(void) {
  if (g_ready) return 1;
  EGLDisplay d = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, (const EGLAttrib *)0);
  if (d == EGL_NO_DISPLAY || !eglInitialize(d, 0, 0)) return 0;
  eglBindAPI(EGL_OPENGL_API);
  EGLConfig c; EGLint n = 0;
  EGLint attr[] = {EGL_NONE};
  eglChooseConfig(d, attr, &c, 1, &n);
  EGLContext ctx = eglCreateContext(d, n ? c : NULL, EGL_NO_CONTEXT, NULL);
  if (ctx == EGL_NO_CONTEXT) return 0;
  if (!eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) return 0;
  const char *ver = (const char *)glGetString(GL_VERSION);
  if (!ver || ver[0] < '4' || (ver[0] == '4' && ver[2] < '3')) return 0; /* need 4.3 compute */
  fprintf(stderr, "[gpu] init: %s\n", ver);
  g_ready = 1;
  return 1;
}

static GLuint compileProg(const char *src) {
  GP(PFNCREATESHADER, glCreateShader)
  GP(PFNSHADERSOURCE, glShaderSource)
  GP(PFNCOMPILESHADER, glCompileShader)
  GP(PFNGETSHADERIV, glGetShaderiv)
  GP(PFNGETSHADERLOG, glGetShaderInfoLog)
  GP(PFNCREATEPROGRAM, glCreateProgram)
  GP(PFNATTACH, glAttachShader)
  GP(PFNLINK, glLinkProgram)
  GP(PFNGETPROGIV, glGetProgramiv)
  GP(PFNDELSH, glDeleteShader)
  unsigned long h = strhash(src);
  for (int i = 0; i < g_cachen; i++)
    if (g_cache[i].h == h) return g_cache[i].prog;
  GLuint sh = glCreateShader_(0x91B9 /* GL_COMPUTE_SHADER */);
  glShaderSource_(sh, 1, &src, NULL);
  glCompileShader_(sh);
  GLint ok = 0;
  glGetShaderiv_(sh, 0x8B81 /* COMPILE_STATUS */, &ok);
  if (!ok) {
    char log[512]; GLsizei ln = 0;
    glGetShaderInfoLog_(sh, sizeof log, &ln, log);
    fprintf(stderr, "[gpu] shader compile failed:\n%.*s\n", (int)ln, log);
    return 0;
  }
  GLuint p = glCreateProgram_();
  glAttachShader_(p, sh);
  glLinkProgram_(p);
  glGetProgramiv_(p, 0x8B82 /* LINK_STATUS */, &ok);
  glDeleteShader_(sh);
  if (!ok) return 0;
  if (g_cachen < CACHE) { g_cache[g_cachen].h = h; g_cache[g_cachen].prog = p; g_cachen++; }
  return p;
}

/* captured scalars ride uniform slots u0..u{nu-1}: the program cache is
 * keyed by SOURCE, so a training loop whose parameters change every
 * epoch reuses one compiled shader and only the uniform values move */
int solgpu_map_f64(const char *src, const double *us, long nu,
                   const double *xs, double *out, long n) {
  if (!g_ready || n <= 0) return -1;
  GP(PFNUSEPROG, glUseProgram)
  GP(PFNGETUNILOC, glGetUniformLocation)
  GP(PFNUNIFORM1D, glUniform1d)
  GP(PFNGENBUF, glGenBuffers)
  GP(PFNBINDBUF, glBindBuffer)
  GP(PFNBUFDATA, glBufferData)
  GP(PFNBINDBASE, glBindBufferBase)
  GP(PFNDISPATCH, glDispatchCompute)
  GP(PFNMEMBAR, glMemoryBarrier)
  GP(PFNGETBUFSUB, glGetBufferSubData)
  GP(PFNDELBUF, glDeleteBuffers)
  GLuint prog = compileProg(src);
  if (!prog) return -1;
  GLuint buf[2];
  glGenBuffers_(2, buf);
  const GLenum SSBO = 0x90D2, SDRAW = 0x88E4, SREAD = 0x88E9;
  glBindBuffer_(SSBO, buf[0]);
  glBufferData_(SSBO, n * 8, xs, SDRAW);
  glBindBufferBase_(SSBO, 0, buf[0]);
  glBindBuffer_(SSBO, buf[1]);
  glBufferData_(SSBO, n * 8, NULL, SREAD);
  glBindBufferBase_(SSBO, 1, buf[1]);
  glUseProgram_(prog);
  for (long i = 0; i < nu; i++) {
    char nm[8];
    nm[0] = 'u';
    if (i < 10) { nm[1] = (char)('0' + i); nm[2] = 0; }
    else { nm[1] = (char)('0' + i / 10); nm[2] = (char)('0' + i % 10); nm[3] = 0; }
    GLint loc = glGetUniformLocation_(prog, nm);
    if (loc < 0) { glDeleteBuffers_(2, buf); return -1; } /* mismatch: decline */
    glUniform1d_(loc, us[i]);
  }
  glDispatchCompute_((GLuint)((n + 63) / 64), 1, 1);
  glMemoryBarrier_(0x00000200 /* SHADER_STORAGE_BARRIER_BIT */);
  glBindBuffer_(SSBO, buf[1]);
  glGetBufferSubData_(SSBO, 0, n * 8, out);
  glDeleteBuffers_(2, buf);
  return 0;
}
#endif /* __APPLE__ stub */
