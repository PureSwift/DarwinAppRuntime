/* The host's own GL calls: drawables on iOS, context setup on macOS. */

#include "darwin_gl.h"

#include <TargetConditionals.h>

#if TARGET_OS_OSX
#include <OpenGL/gl.h>
#else
#include <OpenGLES/ES2/gl.h>
#include <OpenGLES/ES2/glext.h>
#endif

#if TARGET_OS_OSX

uint32_t darwin_gl_make_framebuffer(uint32_t *color, uint32_t *depth) {
    *color = 0;
    *depth = 0;
    return 0;
}

int darwin_gl_finish_framebuffer(uint32_t framebuffer, uint32_t color, uint32_t depth,
                                 int32_t *width, int32_t *height) {
    *width = 0;
    *height = 0;
    return 0;
}

void darwin_gl_bind_renderbuffer(uint32_t renderbuffer) { }

void darwin_gl_delete_framebuffer(uint32_t framebuffer, uint32_t color, uint32_t depth) { }

void darwin_gl_prepare_context(void) {
    /* GLES 2.0 always honors gl_PointSize and gl_PointCoord. */
    glEnable(GL_VERTEX_PROGRAM_POINT_SIZE);
    glEnable(GL_POINT_SPRITE);
}

#else

uint32_t darwin_gl_make_framebuffer(uint32_t *color, uint32_t *depth) {
    GLuint framebuffer = 0;
    GLuint renderbuffers[2] = {0, 0};
    glGenFramebuffers(1, &framebuffer);
    glGenRenderbuffers(2, renderbuffers);
    *color = renderbuffers[0];
    *depth = renderbuffers[1];
    glBindRenderbuffer(GL_RENDERBUFFER, *color);
    return framebuffer;
}

int darwin_gl_finish_framebuffer(uint32_t framebuffer, uint32_t color, uint32_t depth,
                                 int32_t *width, int32_t *height) {
    GLint w = 0;
    GLint h = 0;
    glBindRenderbuffer(GL_RENDERBUFFER, color);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &w);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &h);
    *width = w;
    *height = h;
    if (w <= 0 || h <= 0) {
        return 0;
    }
    glBindRenderbuffer(GL_RENDERBUFFER, depth);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8_OES, w, h);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, color);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depth);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, depth);
    glBindRenderbuffer(GL_RENDERBUFFER, color);
    return glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
}

void darwin_gl_bind_renderbuffer(uint32_t renderbuffer) {
    glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
}

void darwin_gl_delete_framebuffer(uint32_t framebuffer, uint32_t color, uint32_t depth) {
    GLuint renderbuffers[2] = {color, depth};
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteRenderbuffers(2, renderbuffers);
}

void darwin_gl_prepare_context(void) { }

#endif
