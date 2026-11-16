/// OpenGL ES 2.0 under WebGL 1 rules: the functions a slice may call when
/// the app draws (AppRuntime's `Scripts/gles2.py`, `DynamicRuntime.md` §8.1).
/// The app's executable links them to OpenGLES.framework, or OpenGL.framework
/// on macOS (`DarwinGraphics`).
enum GLFunctions {

    static let names: Set<String> = [
        "glActiveTexture", "glAttachShader", "glBindAttribLocation", "glBindBuffer", "glBindFramebuffer",
        "glBindRenderbuffer", "glBindTexture", "glBlendColor", "glBlendEquation", "glBlendEquationSeparate",
        "glBlendFunc", "glBlendFuncSeparate", "glBufferData", "glBufferSubData", "glCheckFramebufferStatus",
        "glClear", "glClearColor", "glClearDepthf", "glClearStencil", "glColorMask", "glCompileShader",
        "glCompressedTexImage2D", "glCompressedTexSubImage2D", "glCopyTexImage2D", "glCopyTexSubImage2D",
        "glCreateProgram", "glCreateShader", "glCullFace", "glDeleteBuffers", "glDeleteFramebuffers",
        "glDeleteProgram", "glDeleteRenderbuffers", "glDeleteShader", "glDeleteTextures", "glDepthFunc",
        "glDepthMask", "glDepthRangef", "glDetachShader", "glDisable", "glDisableVertexAttribArray",
        "glDrawArrays", "glDrawElements", "glEnable", "glEnableVertexAttribArray", "glFinish", "glFlush",
        "glFramebufferRenderbuffer", "glFramebufferTexture2D", "glFrontFace", "glGenBuffers",
        "glGenFramebuffers", "glGenRenderbuffers", "glGenTextures", "glGenerateMipmap", "glGetActiveAttrib",
        "glGetActiveUniform", "glGetAttachedShaders", "glGetAttribLocation", "glGetBooleanv",
        "glGetBufferParameteriv", "glGetError", "glGetFloatv", "glGetFramebufferAttachmentParameteriv",
        "glGetIntegerv", "glGetProgramInfoLog", "glGetProgramiv", "glGetRenderbufferParameteriv",
        "glGetShaderInfoLog", "glGetShaderPrecisionFormat", "glGetShaderSource", "glGetShaderiv",
        "glGetString", "glGetTexParameterfv", "glGetTexParameteriv", "glGetUniformLocation",
        "glGetUniformfv", "glGetUniformiv", "glGetVertexAttribPointerv", "glGetVertexAttribfv",
        "glGetVertexAttribiv", "glHint", "glIsBuffer", "glIsEnabled", "glIsFramebuffer", "glIsProgram",
        "glIsRenderbuffer", "glIsShader", "glIsTexture", "glLineWidth", "glLinkProgram", "glPixelStorei",
        "glPolygonOffset", "glReadPixels", "glRenderbufferStorage", "glSampleCoverage", "glScissor",
        "glShaderSource", "glStencilFunc", "glStencilFuncSeparate", "glStencilMask", "glStencilMaskSeparate",
        "glStencilOp", "glStencilOpSeparate", "glTexImage2D", "glTexParameterf", "glTexParameterfv",
        "glTexParameteri", "glTexParameteriv", "glTexSubImage2D", "glUniform1f", "glUniform1fv",
        "glUniform1i", "glUniform1iv", "glUniform2f", "glUniform2fv", "glUniform2i", "glUniform2iv",
        "glUniform3f", "glUniform3fv", "glUniform3i", "glUniform3iv", "glUniform4f", "glUniform4fv",
        "glUniform4i", "glUniform4iv", "glUniformMatrix2fv", "glUniformMatrix3fv", "glUniformMatrix4fv",
        "glUseProgram", "glValidateProgram", "glVertexAttrib1f", "glVertexAttrib1fv", "glVertexAttrib2f",
        "glVertexAttrib2fv", "glVertexAttrib3f", "glVertexAttrib3fv", "glVertexAttrib4f",
        "glVertexAttrib4fv", "glVertexAttribPointer", "glViewport",
    ]
}
