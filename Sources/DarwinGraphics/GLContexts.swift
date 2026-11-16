import CDarwinGL
import Foundation
#if os(iOS)
import OpenGLES
import QuartzCore
#elseif os(macOS)
import AppKit
#endif

// This file makes no gl* calls: those are CDarwinGL's, so the SDK's GL
// headers and AppRuntime's `gles2.h` never meet in one Swift file.

/// A number for each GL context made, for `rt_gl_context_generation`.
enum ContextGenerations {

    private static var last: UInt32 = 1

    static func next() -> UInt32 {
        last &+= 1
        if last == 0 {
            last = 2
        }
        return last
    }
}

#if os(iOS)

/// An OpenGL ES 2.0 context drawing into a `CAEAGLLayer` through a
/// framebuffer object, with a depth and stencil buffer. iOS has no default
/// framebuffer, so the guest's framebuffer 0 is this one (`darwin_gl.h`).
final class EAGLSurfaceContext: SurfaceContext {

    let context: EAGLContext

    let generation = ContextGenerations.next()

    private var framebuffer: UInt32 = 0

    private var color: UInt32 = 0

    private var depth: UInt32 = 0

    /// Whether the framebuffer has storage and is complete.
    private(set) var isComplete = false

    init?() {
        guard let context = EAGLContext(api: .openGLES2) else { return nil }
        self.context = context
        withCurrent {
            framebuffer = darwin_gl_make_framebuffer(&color, &depth)
        }
    }

    deinit {
        let (framebuffer, color, depth) = (self.framebuffer, self.color, self.depth)
        withCurrent {
            darwin_gl_delete_framebuffer(framebuffer, color, depth)
        }
    }

    /// Gives the color buffer `layer`'s size and returns the drawable's size
    /// in pixels, or `nil` when the layer has none.
    func attach(_ layer: CAEAGLLayer) -> (width: Int32, height: Int32)? {
        var size: (Int32, Int32)?
        withCurrent {
            darwin_gl_bind_renderbuffer(color)
            guard context.renderbufferStorage(Int(GL_RENDERBUFFER), from: layer) else {
                isComplete = false
                return
            }
            var width: Int32 = 0
            var height: Int32 = 0
            isComplete = darwin_gl_finish_framebuffer(framebuffer, color, depth, &width, &height) != 0
            if isComplete {
                size = (width, height)
            }
        }
        return size
    }

    func begin() -> Bool {
        guard isComplete, EAGLContext.setCurrent(context) else { return false }
        darwin_gl_begin_frame(generation, framebuffer)
        return true
    }

    func present() {
        darwin_gl_bind_renderbuffer(color)
        context.presentRenderbuffer(Int(GL_RENDERBUFFER))
    }

    func end() {
        darwin_gl_end_frame()
        EAGLContext.setCurrent(nil)
    }

    private func withCurrent(_ body: () -> Void) {
        let previous = EAGLContext.current()
        EAGLContext.setCurrent(context)
        body()
        EAGLContext.setCurrent(previous)
    }
}

#elseif os(macOS)

/// A desktop OpenGL 2.1 context (the legacy profile), which runs GLES 2.0
/// calls; its shaders are rewritten from GLSL ES (`darwin_gl.h`). An
/// `NSOpenGLView` draws with it.
final class DesktopSurfaceContext: SurfaceContext {

    let context: NSOpenGLContext

    let generation = ContextGenerations.next()

    init?() {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAColorSize), 24,
            UInt32(NSOpenGLPFAAlphaSize), 8,
            UInt32(NSOpenGLPFADepthSize), 24,
            UInt32(NSOpenGLPFAStencilSize), 8,
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersionLegacy),
            0,
        ]
        guard let format = NSOpenGLPixelFormat(attributes: attributes),
              let context = NSOpenGLContext(format: format, share: nil) else {
            return nil
        }
        self.context = context
        // Frames follow the display link; a swap mustn't block the main
        // thread too.
        context.setValues([0], for: .swapInterval)
        let previous = NSOpenGLContext.current
        context.makeCurrentContext()
        darwin_gl_prepare_context()
        if let previous {
            previous.makeCurrentContext()
        } else {
            NSOpenGLContext.clearCurrentContext()
        }
    }

    /// The view's size changed.
    func update() {
        context.update()
    }

    /// The context current before `begin`: AppKit's, while it draws the
    /// view, which it keeps using after the frame.
    private var previous: NSOpenGLContext?

    /// Draws into the framebuffer bound now: the view's, which AppKit binds
    /// before `NSView.draw`, or one a test binds.
    func begin() -> Bool {
        previous = NSOpenGLContext.current
        context.makeCurrentContext()
        darwin_gl_begin_frame(generation, darwin_gl_current_framebuffer())
        return true
    }

    func present() {
        darwin_gl_restore_framebuffer()
        context.flushBuffer()
    }

    func end() {
        darwin_gl_end_frame()
        if let previous {
            previous.makeCurrentContext()
        } else {
            NSOpenGLContext.clearCurrentContext()
        }
        previous = nil
    }
}

#endif
