import DynamicGraphics
import Testing
@testable import DarwinGraphics

/// Records a surface's delegate calls.
final class RecordingDelegate: SurfaceDelegate {

    var events: [String] = []

    /// Runs inside `frame`.
    var onFrame: (() -> Void)?

    func frame(_ surface: any Surface, timestamp: Int64, width: Int32, height: Int32) {
        events.append("frame \(width)x\(height)")
        onFrame?()
    }

    func resize(_ surface: any Surface, width: Int32, height: Int32, scale: Float) {
        events.append("resize \(width)x\(height)@\(scale)")
    }

    func contextLost(_ surface: any Surface) {
        events.append("contextLost")
    }

    func contextRestored(_ surface: any Surface) {
        events.append("contextRestored")
    }

    func pointer(_ surface: any Surface, id: Int32, kind: Int32, phase: Int32, x: Float, y: Float, buttons: Int32, timestamp: Int64) {
        let phases = ["down", "move", "up", "cancel"]
        events.append("pointer \(id) \(phases[Int(phase)]) \(Int(x)),\(Int(y)) kind \(kind) buttons \(buttons)")
    }

    func pointerDelta(_ surface: any Surface, x: Float, y: Float, timestamp: Int64) {
        events.append("delta \(x),\(y)")
    }

    func scroll(_ surface: any Surface, x: Float, y: Float) {
        events.append("scroll \(x),\(y)")
    }

    func key(_ surface: any Surface, code: Int32, pressed: Bool, modifiers: Int32, isRepeat: Bool, timestamp: Int64) {
        events.append("key \(code) \(pressed ? "down" : "up") \(modifiers)\(isRepeat ? " repeat" : "")")
    }

    func focus(_ surface: any Surface, focused: Bool) {
        events.append("focus \(focused)")
    }

    func pointerCapture(_ surface: any Surface, captured: Bool) {
        events.append("capture \(captured)")
    }
}

/// A context that records what the frame loop does with it.
final class RecordingContext: SurfaceContext {

    var events: [String] = []

    var canBegin = true

    func begin() -> Bool {
        events.append("begin")
        return canBegin
    }

    func present() {
        events.append("present")
    }

    func end() {
        events.append("end")
    }
}

final class FakeHost: SurfaceHost {

    var canCapture = true

    func capturePointer(_ captured: Bool) -> Bool {
        captured && canCapture
    }
}

/// The surface's rules, without a view or GL (`DynamicRuntime.md` §8.2,
/// §8.6).
@Suite("Surface", .serialized)
struct SurfaceTests {

    @Test func identifiersFindLiveSurfaces() throws {
        let delegate = RecordingDelegate()
        var first: DarwinSurface? = DarwinSurface.make(delegate)
        let second = DarwinSurface.make(delegate)
        let id = try #require(first).identifier()
        #expect(id > 0)
        #expect(id != second.identifier())
        #expect(DarwinSurface.surface(id) === first)
        #expect(DarwinSurface.surface(second.identifier()) === second)
        first = nil
        #expect(DarwinSurface.surface(id) == nil, "released")
        #expect(DarwinSurface.surface(0) == nil)
    }

    @Test func resizeComesOnceBeforeTheFrame() {
        let delegate = RecordingDelegate()
        let context = RecordingContext()
        let surface = DarwinSurface.make(delegate)
        surface.context = context
        surface.drawFrame(timestamp: 1)
        #expect(delegate.events.isEmpty, "no size yet")

        surface.resize(width: 0, height: 10, scale: 2)
        surface.resize(width: 200, height: 100, scale: 2)
        surface.resize(width: 200, height: 100, scale: 2)
        surface.drawFrame(timestamp: 2)
        #expect(delegate.events == ["resize 200x100@2.0", "frame 200x100"])
        #expect(context.events == ["begin", "present", "end"])
    }

    @Test func noFrameWithoutADrawable() {
        let delegate = RecordingDelegate()
        let context = RecordingContext()
        context.canBegin = false
        let surface = DarwinSurface.make(delegate)
        surface.resize(width: 10, height: 10, scale: 1)
        surface.drawFrame(timestamp: 1)
        surface.context = context
        surface.drawFrame(timestamp: 2)
        #expect(delegate.events == ["resize 10x10@1.0"])
        #expect(context.events == ["begin", "end"])
    }

    @Test func movesWaitForTheFrame() {
        let delegate = RecordingDelegate()
        let surface = DarwinSurface.make(delegate)
        surface.context = RecordingContext()
        surface.resize(width: 10, height: 10, scale: 1)
        delegate.events = []

        surface.pointer(id: 1, kind: .touch, phase: .down, x: 1, y: 1, buttons: .primary, timestamp: 1)
        surface.pointer(id: 2, kind: .touch, phase: .down, x: 5, y: 5, buttons: .primary, timestamp: 1)
        surface.pointer(id: 2, kind: .touch, phase: .move, x: 6, y: 6, buttons: .primary, timestamp: 2)
        surface.pointer(id: 1, kind: .touch, phase: .move, x: 2, y: 2, buttons: .primary, timestamp: 2)
        surface.pointer(id: 1, kind: .touch, phase: .move, x: 3, y: 3, buttons: .primary, timestamp: 3)
        #expect(delegate.events == [
            "pointer 1 down 1,1 kind 0 buttons 1",
            "pointer 2 down 5,5 kind 0 buttons 1",
        ], "moves wait")

        surface.drawFrame(timestamp: 4)
        #expect(delegate.events.suffix(3) == [
            "pointer 2 move 6,6 kind 0 buttons 1",
            "pointer 1 move 3,3 kind 0 buttons 1",
            "frame 10x10",
        ], "one per pointer, in the order they first moved, before the frame")

        // An up goes at once, after its pointer's waiting move.
        delegate.events = []
        surface.pointer(id: 1, kind: .touch, phase: .move, x: 4, y: 4, buttons: .primary, timestamp: 5)
        surface.pointer(id: 1, kind: .touch, phase: .up, x: 4, y: 4, buttons: [], timestamp: 5)
        #expect(delegate.events == [
            "pointer 1 move 4,4 kind 0 buttons 1",
            "pointer 1 up 4,4 kind 0 buttons 0",
        ])
        #expect(surface.contacts == [2])
    }

    @Test func nothingFollowsTheEndOfAContact() {
        let delegate = RecordingDelegate()
        let surface = DarwinSurface.make(delegate)
        surface.pointer(id: 3, kind: .touch, phase: .up, x: 0, y: 0, buttons: [], timestamp: 1)
        surface.pointer(id: 3, kind: .touch, phase: .move, x: 0, y: 0, buttons: .primary, timestamp: 1)
        surface.pointer(id: 3, kind: .touch, phase: .cancel, x: 0, y: 0, buttons: [], timestamp: 1)
        surface.flushMoves()
        #expect(delegate.events.isEmpty)

        // A hovering mouse has no contact, and moves anyway.
        surface.pointer(id: 0, kind: .mouse, phase: .move, x: 7, y: 8, buttons: [], timestamp: 1)
        surface.flushMoves()
        #expect(delegate.events == ["pointer 0 move 7,8 kind 1 buttons 0"])
    }

    @Test func aSecondButtonIsAMoveAtOnce() {
        let delegate = RecordingDelegate()
        let surface = DarwinSurface.make(delegate)
        surface.pointer(id: 0, kind: .mouse, phase: .down, x: 1, y: 1, buttons: .primary, timestamp: 1)
        surface.buttonsChanged(id: 0, kind: .mouse, x: 1, y: 1, buttons: [.primary, .secondary], timestamp: 2)
        #expect(delegate.events == [
            "pointer 0 down 1,1 kind 1 buttons 1",
            "pointer 0 move 1,1 kind 1 buttons 3",
        ])
    }

    @Test func losingFocusCancelsContactsFirst() {
        let delegate = RecordingDelegate()
        let surface = DarwinSurface.make(delegate)
        surface.focus(true, timestamp: 0)
        surface.focus(true, timestamp: 0)
        surface.pointer(id: 2, kind: .touch, phase: .down, x: 1, y: 1, buttons: .primary, timestamp: 1)
        surface.pointer(id: 1, kind: .pen, phase: .down, x: 3, y: 3, buttons: .primary, timestamp: 1)
        surface.pointer(id: 1, kind: .pen, phase: .move, x: 4, y: 4, buttons: .primary, timestamp: 2)
        delegate.events = []

        surface.focus(false, timestamp: 3)
        #expect(delegate.events == [
            "pointer 1 cancel 4,4 kind 2 buttons 0",
            "pointer 2 cancel 0,0 kind 0 buttons 0",
            "focus false",
        ])
        #expect(surface.contacts.isEmpty)

        // The touch lifting later is dropped.
        surface.pointer(id: 2, kind: .touch, phase: .up, x: 1, y: 1, buttons: [], timestamp: 4)
        #expect(delegate.events.count == 3)
    }

    @Test func endingInputWithoutFocusCancelsContacts() {
        let delegate = RecordingDelegate()
        let surface = DarwinSurface.make(delegate)
        surface.pointer(id: 1, kind: .touch, phase: .down, x: 1, y: 1, buttons: .primary, timestamp: 1)
        surface.endInput(timestamp: 2)
        surface.endInput(timestamp: 3)
        #expect(delegate.events == [
            "pointer 1 down 1,1 kind 0 buttons 1",
            "pointer 1 cancel 0,0 kind 0 buttons 0",
        ])
    }

    @Test func keysNeedFocus() {
        let delegate = RecordingDelegate()
        let surface = DarwinSurface.make(delegate)
        surface.key(code: KeyCode.space.rawValue, pressed: true, modifiers: [], isRepeat: false, timestamp: 1)
        surface.focus(true, timestamp: 1)
        surface.key(code: KeyCode.space.rawValue, pressed: true, modifiers: [.shift], isRepeat: false, timestamp: 2)
        surface.key(code: KeyCode.space.rawValue, pressed: true, modifiers: [.shift], isRepeat: true, timestamp: 3)
        surface.key(code: 0, pressed: true, modifiers: [], isRepeat: false, timestamp: 3)
        #expect(delegate.events == ["focus true", "key 44 down 1", "key 44 down 1 repeat"])
    }

    @Test func scrollsGoAtOnce() {
        let delegate = RecordingDelegate()
        let surface = DarwinSurface.make(delegate)
        surface.scroll(x: 0, y: 0)
        surface.scroll(x: 0, y: -12)
        #expect(delegate.events == ["scroll 0.0,-12.0"])
    }

    @Test func pointerCapture() {
        let delegate = RecordingDelegate()
        let surface = DarwinSurface.make(delegate)
        #expect(!surface.setPointerCaptured(true), "not on screen")
        let host = FakeHost()
        surface.host = host
        surface.pointerDelta(x: 1, y: 1, timestamp: 1)
        surface.flushMoves()
        #expect(delegate.events.isEmpty, "no deltas without capture")

        #expect(surface.setPointerCaptured(true))
        surface.pointerDelta(x: 1, y: 2, timestamp: 1)
        surface.pointerDelta(x: 3, y: -1, timestamp: 2)
        surface.flushMoves()
        #expect(delegate.events == ["capture true", "delta 4.0,1.0"], "summed, once per frame")

        // The host ends it when focus goes.
        delegate.events = []
        surface.focus(true, timestamp: 3)
        surface.focus(false, timestamp: 4)
        #expect(delegate.events == ["focus true", "capture false", "focus false"])
        #expect(!surface.isPointerCaptured)

        host.canCapture = false
        #expect(!surface.setPointerCaptured(true))
        #expect(!surface.setPointerCaptured(false))
        #expect(delegate.events.count == 3, "nothing changed")
    }
}
