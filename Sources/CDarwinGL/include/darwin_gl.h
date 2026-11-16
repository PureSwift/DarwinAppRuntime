#ifndef DARWIN_GL_H
#define DARWIN_GL_H

/* The GL side of a Surface on Apple platforms (HostRuntime.md §5.2).
 *
 * A guest calls OpenGL ES 2.0 directly: a native slice and wasm2c output
 * both reference the gl* symbols, and the app's executable links them to
 * OpenGLES.framework on iOS and OpenGL.framework on macOS. Two differences
 * from GLES 2.0 are covered here, by defining the gl* function in the
 * executable itself, which wins over the framework's:
 *
 * - Framebuffer 0 isn't the surface's: iOS has no default framebuffer, and
 *   AppKit may draw a layer-backed view into a framebuffer object.
 *   glBindFramebuffer(target, 0) binds the surface's drawable instead.
 * - macOS has desktop OpenGL 2.1, whose GLSL 1.20 rejects GLSL ES's
 *   precision statements and `#version 100`. glShaderSource rewrites the
 *   source first (darwin_gl_desktop_shader).
 *
 * Everything here runs on the main thread, as the guest's GL calls do. */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* MARK: - Frames */

/* Called before a surface's frame, with its context current: records the
 * context's generation (rt_gl_context_generation) and binds `framebuffer`,
 * which glBindFramebuffer(_, 0) means until darwin_gl_end_frame. */
void darwin_gl_begin_frame(uint32_t generation, uint32_t framebuffer);

/* After the frame: framebuffer 0 means 0 again. */
void darwin_gl_end_frame(void);

/* Binds the frame's framebuffer again, which the guest may have changed:
 * before presenting. */
void darwin_gl_restore_framebuffer(void);

/* The framebuffer bound now (GL_FRAMEBUFFER_BINDING). */
uint32_t darwin_gl_current_framebuffer(void);

/* What glBindFramebuffer(_, 0) binds now. */
uint32_t darwin_gl_default_framebuffer(void);

/* A number that changes whenever the context the guest draws in is another
 * one, for the wasm2c GL shim, which forgets buffer bindings then. Each
 * context has its own, so a switch between two surfaces counts as a new
 * context. */
uint32_t rt_gl_context_generation(void);

/* MARK: - Drawables (iOS) */

/* With the context current: a framebuffer with a color renderbuffer, whose
 * storage the caller then takes from a CAEAGLLayer, and a depth and
 * stencil renderbuffer. Returns the framebuffer. */
uint32_t darwin_gl_make_framebuffer(uint32_t *color, uint32_t *depth);

/* After the color renderbuffer has its storage: sizes the depth and stencil
 * buffer to match and attaches both. Returns whether the framebuffer is
 * complete, and its size in pixels. */
int darwin_gl_finish_framebuffer(uint32_t framebuffer, uint32_t color, uint32_t depth,
                                 int32_t *width, int32_t *height);

/* Binds `renderbuffer`, for presenting it. */
void darwin_gl_bind_renderbuffer(uint32_t renderbuffer);

void darwin_gl_delete_framebuffer(uint32_t framebuffer, uint32_t color, uint32_t depth);

/* MARK: - Desktop GL (macOS) */

/* With a new context current: what GLES 2.0 has on without asking, such as
 * gl_PointSize in vertex shaders. Nothing on iOS. */
void darwin_gl_prepare_context(void);

/* GLSL ES 1.00 source as desktop GLSL 1.20 takes it: without `#version 100`
 * and precision statements, and with lowp, mediump and highp defined away.
 * Comments are left alone, and line numbers stay the same, so errors point
 * at the guest's lines. Returns a buffer to free(), `*result_length` bytes
 * long and NUL-terminated, or NULL without memory. */
char *darwin_gl_desktop_shader(const char *source, size_t length, size_t *result_length);

#ifdef __cplusplus
}
#endif

#endif
