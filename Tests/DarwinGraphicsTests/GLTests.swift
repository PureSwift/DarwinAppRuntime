import CDarwinGL
import DynamicGraphics
import Testing
@testable import DarwinGraphics

/// GLSL ES on desktop GL, and a real frame on macOS's OpenGL.
@Suite("GL", .serialized)
struct GLTests {

    func desktop(_ source: String) -> String {
        let bytes = Array(source.utf8)
        var length = 0
        let result = bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                darwin_gl_desktop_shader($0, bytes.count, &length)
            }
        }
        defer { free(result) }
        #expect(length == bytes.count, "same length, same lines")
        return String(cString: result!)
    }

    @Test func precisionGoesAndLinesStay() {
        let source = """
            #version 100
            precision mediump float;
            /* precision highp float; stays */
            varying lowp vec3 v_color; // highp too
            uniform highp float highpass;
              precision
                lowp int;
            void main() { gl_FragColor = vec4(v_color * highpass, 1.0); }
            """
        let result = desktop(source)
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 8)
        #expect(lines[0].allSatisfy { $0 == " " }, "#version goes")
        #expect(lines[1].allSatisfy { $0 == " " })
        #expect(lines[2] == "/* precision highp float; stays */", "comments stay")
        #expect(lines[3] == "varying      vec3 v_color; // highp too")
        #expect(lines[4] == "uniform       float highpass;", "a word that starts with a qualifier stays")
        #expect(lines[5].allSatisfy { $0 == " " } && lines[6].allSatisfy { $0 == " " }, "across lines")
        #expect(lines[7] == "void main() { gl_FragColor = vec4(v_color * highpass, 1.0); }")
    }

    @Test func otherDirectivesStay() {
        let source = "#ifdef GL_ES\nprecision mediump float;\n#endif\n  #extension GL_OES_standard_derivatives : enable\nvoid main() { }\n"
        let result = desktop(source)
        #expect(result.hasPrefix("#ifdef GL_ES\n"))
        #expect(result.contains("\n#endif\n  #extension GL_OES_standard_derivatives : enable\n"))
        #expect(!result.contains("precision"))
    }

    #if os(macOS)

    static let vertexShader = """
        attribute vec2 a_position;
        attribute vec3 a_color;
        varying vec3 v_color;
        void main() {
            gl_Position = vec4(a_position, 0.0, 1.0);
            v_color = a_color;
        }
        """

    static let fragmentShader = """
        precision mediump float;
        varying vec3 v_color;
        void main() {
            gl_FragColor = vec4(v_color, 1.0);
        }
        """

    func compile(_ type: GLenum, _ source: String) -> GLuint {
        let shader = glCreateShader(type)
        source.withCString { text in
            var pointer: UnsafePointer<GLchar>? = text
            var length = GLint(source.utf8.count)
            glShaderSource(shader, 1, &pointer, &length)
        }
        glCompileShader(shader)
        var compiled: GLint = 0
        glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled)
        return compiled != 0 ? shader : 0
    }

    /// ExampleGL's kind of frame through a surface: GLSL ES shaders, a
    /// buffer, and framebuffer 0, which is the one bound when the frame
    /// began, as AppKit binds a layer-backed view's.
    @Test func drawsAFrame() throws {
        let context = try #require(DesktopSurfaceContext())
        context.context.makeCurrentContext()
        defer { NSOpenGLContextClear.clear() }
        var framebuffer: GLuint = 0
        var renderbuffer: GLuint = 0
        glGenFramebuffers(1, &framebuffer)
        glGenRenderbuffers(1, &renderbuffer)
        glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer)
        glRenderbufferStorage(GL_RENDERBUFFER, GLenum(0x8058) /* GL_RGBA8 */, 64, 64)
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, renderbuffer)
        try #require(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE)

        let delegate = RecordingDelegate()
        var compiled = false
        var generation: UInt32 = 0
        delegate.onFrame = {
            generation = rt_gl_context_generation()
            let vertex = compile(GL_VERTEX_SHADER, Self.vertexShader)
            let fragment = compile(GL_FRAGMENT_SHADER, Self.fragmentShader)
            compiled = vertex != 0 && fragment != 0
            guard compiled else { return }
            let program = glCreateProgram()
            glAttachShader(program, vertex)
            glAttachShader(program, fragment)
            glBindAttribLocation(program, 0, "a_position")
            glBindAttribLocation(program, 1, "a_color")
            glLinkProgram(program)
            var buffer: GLuint = 0
            glGenBuffers(1, &buffer)
            glBindBuffer(GL_ARRAY_BUFFER, buffer)
            let vertices: [GLfloat] = [0, 0.8, 1, 0, 0, -0.8, -0.8, 1, 0, 0, 0.8, -0.8, 1, 0, 0]
            glBufferData(GL_ARRAY_BUFFER, vertices.count * 4, vertices, GL_STATIC_DRAW)

            glBindFramebuffer(GL_FRAMEBUFFER, 0)
            glViewport(0, 0, 64, 64)
            glClearColor(0, 0, 1, 1)
            glClear(GL_COLOR_BUFFER_BIT)
            glUseProgram(program)
            glEnableVertexAttribArray(0)
            glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 20, nil)
            glEnableVertexAttribArray(1)
            glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 20, UnsafeRawPointer(bitPattern: 8))
            glDrawArrays(GL_TRIANGLES, 0, 3)
            glFinish()
        }
        let surface = DarwinSurface.make(delegate)
        surface.context = context
        surface.resize(width: 64, height: 64, scale: 1)
        surface.drawFrame(timestamp: 1)

        #expect(compiled, "GLSL ES compiles on desktop GL")
        #expect(generation == context.generation)
        #expect(delegate.events == ["resize 64x64@1.0", "frame 64x64"])

        context.context.makeCurrentContext()
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
        var center = [UInt8](repeating: 0, count: 4)
        var corner = [UInt8](repeating: 0, count: 4)
        glReadPixels(32, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &center)
        glReadPixels(1, 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, &corner)
        #expect(center == [255, 0, 0, 255], "the triangle, in framebuffer 0")
        #expect(corner == [0, 0, 255, 255], "the clear color")
        #expect(darwin_gl_default_framebuffer() == 0, "0 means 0 again after the frame")
    }

    #endif
}

#if os(macOS)
import AppKit

enum NSOpenGLContextClear {
    static func clear() {
        NSOpenGLContext.clearCurrentContext()
    }
}
#endif
