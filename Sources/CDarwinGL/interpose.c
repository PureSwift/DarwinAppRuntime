/* The gl* functions the executable defines itself, over the framework's
 * (darwin_gl.h). This file includes no GL header, so its definitions don't
 * meet the SDK's declarations; the GL types are spelled out. */

#include "darwin_gl.h"

#include <TargetConditionals.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned int gl_enum;
typedef unsigned int gl_uint;
typedef int gl_int;
typedef int gl_sizei;
typedef char gl_char;

static uint32_t current_generation = 1;
static uint32_t default_framebuffer = 0;

static void bind_framebuffer(gl_uint framebuffer);

/* The framework's own function, not the one defined here. */
static void *framework_function(const char *name) {
    static void *library;
    if (library == NULL) {
#if TARGET_OS_OSX
        library = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_LOCAL);
#else
        library = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_LAZY | RTLD_LOCAL);
#endif
    }
    return library != NULL ? dlsym(library, name) : NULL;
}

void darwin_gl_begin_frame(uint32_t generation, uint32_t framebuffer) {
    current_generation = generation;
    default_framebuffer = framebuffer;
    bind_framebuffer(framebuffer);
}

void darwin_gl_end_frame(void) {
    default_framebuffer = 0;
}

uint32_t darwin_gl_default_framebuffer(void) {
    return default_framebuffer;
}

uint32_t rt_gl_context_generation(void) {
    return current_generation;
}

static void bind_framebuffer(gl_uint framebuffer) {
    static void (*bind)(gl_enum, gl_uint);
    if (bind == NULL) {
        bind = (void (*)(gl_enum, gl_uint))framework_function("glBindFramebuffer");
    }
    if (bind != NULL) {
        bind(0x8D40 /* GL_FRAMEBUFFER */, framebuffer);
    }
}

void darwin_gl_restore_framebuffer(void) {
    bind_framebuffer(default_framebuffer);
}

uint32_t darwin_gl_current_framebuffer(void) {
    static void (*get)(gl_enum, gl_int *);
    if (get == NULL) {
        get = (void (*)(gl_enum, gl_int *))framework_function("glGetIntegerv");
    }
    gl_int framebuffer = 0;
    if (get != NULL) {
        get(0x8CA6 /* GL_FRAMEBUFFER_BINDING */, &framebuffer);
    }
    return framebuffer > 0 ? (uint32_t)framebuffer : 0;
}

/* Framebuffer 0 is the surface's: on iOS a framebuffer object, on macOS
 * the one AppKit draws the view with. */
void glBindFramebuffer(gl_enum target, gl_uint framebuffer) {
    static void (*bind)(gl_enum, gl_uint);
    if (bind == NULL) {
        bind = (void (*)(gl_enum, gl_uint))framework_function("glBindFramebuffer");
    }
    if (bind != NULL) {
        bind(target, framebuffer == 0 ? default_framebuffer : framebuffer);
    }
}

/* MARK: - Shader source */

static int is_identifier(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

/* Spaces over [start, end), keeping line breaks. */
static void blank(char *text, size_t start, size_t end) {
    for (size_t i = start; i < end; i++) {
        if (text[i] != '\n' && text[i] != '\r') {
            text[i] = ' ';
        }
    }
}

static int is_word(const char *text, size_t length, const char *word) {
    return strlen(word) == length && memcmp(text, word, length) == 0;
}

char *darwin_gl_desktop_shader(const char *source, size_t length, size_t *result_length) {
    char *text = malloc(length + 1);
    if (text == NULL) {
        return NULL;
    }
    if (length > 0) {
        memcpy(text, source, length);
    }
    text[length] = 0;

    int line_start = 1;
    size_t i = 0;
    while (i < length) {
        char c = text[i];
        if (c == '/' && i + 1 < length && text[i + 1] == '/') {
            while (i < length && text[i] != '\n') {
                i++;
            }
        } else if (c == '/' && i + 1 < length && text[i + 1] == '*') {
            i += 2;
            while (i < length && !(text[i] == '*' && i + 1 < length && text[i + 1] == '/')) {
                i++;
            }
            i = i + 2 <= length ? i + 2 : length;
            line_start = 0;
        } else if (c == '\n') {
            line_start = 1;
            i++;
        } else if (c == ' ' || c == '\t' || c == '\r' || c == '\f' || c == '\v') {
            i++;
        } else if (c == '#' && line_start) {
            /* A directive: `#version` goes, the rest stays. */
            size_t start = i;
            size_t name = i + 1;
            while (name < length && (text[name] == ' ' || text[name] == '\t')) {
                name++;
            }
            size_t end = start;
            while (end < length && text[end] != '\n') {
                end++;
            }
            size_t word = name;
            while (word < length && is_identifier(text[word])) {
                word++;
            }
            if (is_word(text + name, word - name, "version")) {
                blank(text, start, end);
            }
            i = end;
        } else if (is_identifier(c) && !(c >= '0' && c <= '9')) {
            size_t start = i;
            while (i < length && is_identifier(text[i])) {
                i++;
            }
            const char *word = text + start;
            size_t size = i - start;
            if (is_word(word, size, "lowp") || is_word(word, size, "mediump") || is_word(word, size, "highp")) {
                blank(text, start, i);
            } else if (is_word(word, size, "precision")) {
                while (i < length && text[i] != ';') {
                    i++;
                }
                i = i < length ? i + 1 : length;
                blank(text, start, i);
            }
            line_start = 0;
        } else {
            line_start = 0;
            i++;
        }
    }
    if (result_length != NULL) {
        *result_length = length;
    }
    return text;
}

#if TARGET_OS_OSX

/* GLSL ES 1.00 in, GLSL 1.20 to the framework. */
void glShaderSource(gl_uint shader, gl_sizei count, const gl_char *const *string, const gl_int *length) {
    static void (*source)(gl_uint, gl_sizei, const gl_char *const *, const gl_int *);
    if (source == NULL) {
        source = (void (*)(gl_uint, gl_sizei, const gl_char *const *, const gl_int *))framework_function("glShaderSource");
        if (source == NULL) {
            return;
        }
    }
    if (count <= 0 || string == NULL) {
        /* GL reports the error. */
        source(shader, count, string, length);
        return;
    }
    size_t total = 0;
    for (gl_sizei index = 0; index < count; index++) {
        if (string[index] == NULL) {
            source(shader, count, string, length);
            return;
        }
        total += length != NULL && length[index] >= 0 ? (size_t)length[index] : strlen(string[index]);
    }
    char *joined = malloc(total + 1);
    if (joined == NULL) {
        source(shader, count, string, length);
        return;
    }
    size_t offset = 0;
    for (gl_sizei index = 0; index < count; index++) {
        size_t size = length != NULL && length[index] >= 0 ? (size_t)length[index] : strlen(string[index]);
        memcpy(joined + offset, string[index], size);
        offset += size;
    }
    size_t rewritten_length = 0;
    char *rewritten = darwin_gl_desktop_shader(joined, total, &rewritten_length);
    free(joined);
    if (rewritten == NULL) {
        source(shader, count, string, length);
        return;
    }
    const gl_char *text = rewritten;
    gl_int size = (gl_int)rewritten_length;
    source(shader, 1, &text, &size);
    free(rewritten);
}

#endif
