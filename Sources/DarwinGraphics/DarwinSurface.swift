import DarwinHost
import DynamicGraphics
import DynamicRuntime
import Foundation

/// A GL context that draws a surface's frames: EAGL on iOS, an
/// `NSOpenGLContext` on macOS.
protocol SurfaceContext: AnyObject {

    /// Makes the context current and binds the drawable. `false` when there's
    /// nothing to draw into yet.
    func begin() -> Bool

    /// Shows what the frame drew.
    func present()

    /// Clears the current context.
    func end()
}

/// The view that shows a surface: what `setPointerCaptured` asks.
protocol SurfaceHost: AnyObject {

    /// Captures or releases the mouse; returns whether it's captured
    /// afterwards.
    func capturePointer(_ captured: Bool) -> Bool
}

/// The `Surface` contract (`HostRuntime.md` §5.2, `DynamicRuntime.md` §8.2):
/// a GL context, the frames and the input of one `GLSurface` view.
///
/// The surface creates nothing until a `GLSurface` node with its
/// identifier appears: then the platform view (`SurfaceView`) makes the GL
/// context, drives frames from the display and turns touches, the mouse
/// and keys into delegate calls through the methods here, which keep the
/// contract's rules:
///
/// - `resize` comes before the first frame of a new size;
/// - pending moves, at most one per pointer, and one `pointerDelta`, go out
///   before each frame;
/// - before focus goes, every pointer in contact gets `cancel`.
///
/// Every call is on the main thread.
public final class DarwinSurface: Surface {

    let delegate: any SurfaceDelegate

    let id: Int32

    /// The GL context. It lives as long as the surface, so the guest's GL
    /// objects survive the view leaving and coming back.
    var context: SurfaceContext?

    /// The view showing the surface now. A second view showing it takes
    /// over.
    weak var host: SurfaceHost?

    /// The drawable's size last reported with `resize`.
    private(set) var size: (width: Int32, height: Int32, scale: Float)?

    /// Pointers in contact, by ID: from `down` to `up` or `cancel`.
    private(set) var contacts: Set<Int32> = []

    private(set) var isFocused = false

    private(set) var isPointerCaptured = false

    /// Moves waiting for the next frame, in the order their pointers first
    /// moved.
    private var pendingMoves: [Int32: PendingMove] = [:]

    private var moveOrder: [Int32] = []

    private var pendingDelta: (x: Float, y: Float, timestamp: Int64)?

    struct PendingMove {
        var kind: Int32
        var x: Float
        var y: Float
        var buttons: Int32
        var timestamp: Int64
    }

    init(delegate: any SurfaceDelegate, id: Int32) {
        self.delegate = delegate
        self.id = id
    }

    deinit {
        Self.live[id] = nil
    }

    // MARK: Surface

    public static func make(_ delegate: any SurfaceDelegate) -> DarwinSurface {
        nextID &+= 1
        if nextID <= 0 {
            nextID = 1
        }
        let surface = DarwinSurface(delegate: delegate, id: nextID)
        live[surface.id] = Weak(surface)
        return surface
    }

    public func identifier() -> Int32 {
        id
    }

    public func setPointerCaptured(_ captured: Bool) -> Bool {
        guard let host else {
            return false
        }
        let now = host.capturePointer(captured)
        if now != isPointerCaptured {
            isPointerCaptured = now
            if !now {
                pendingDelta = nil
            }
            delegate.pointerCapture(self, captured: now)
        }
        return now
    }

    // MARK: Surfaces

    private final class Weak {
        weak var surface: DarwinSurface?
        init(_ surface: DarwinSurface) {
            self.surface = surface
        }
    }

    private static var live: [Int32: Weak] = [:]

    private static var nextID: Int32 = 0

    /// The live surface with this identifier: what a `GLSurface` node shows.
    static func surface(_ identifier: Int32) -> DarwinSurface? {
        live[identifier]?.surface
    }

    // MARK: Frames

    /// Reports the drawable's size, if it changed. Zero sizes aren't
    /// reported.
    func resize(width: Int32, height: Int32, scale: Float) {
        guard width > 0, height > 0 else { return }
        if let size, size.width == width, size.height == height, size.scale == scale {
            return
        }
        size = (width, height, scale)
        delegate.resize(self, width: width, height: height, scale: scale)
    }

    /// One frame: the moves since the last, then `frame` with the context
    /// current, then presents. Nothing without a context, a drawable or a
    /// size.
    func drawFrame(timestamp: Int64) {
        flushMoves()
        guard let context, let size else { return }
        guard context.begin() else {
            context.end()
            return
        }
        delegate.frame(self, timestamp: timestamp, width: size.width, height: size.height)
        context.present()
        context.end()
    }

    // MARK: Input

    /// A pointer event. `move`s wait for the next frame, one per pointer;
    /// other phases go at once, after that pointer's waiting move. Events of
    /// a pointer that isn't in contact are dropped, except moves without
    /// buttons (a hovering mouse), so nothing follows a `cancel`.
    func pointer(id: Int32, kind: PointerKind, phase: PointerPhase, x: Float, y: Float, buttons: PointerButtons, timestamp: Int64) {
        switch phase {
        case .down:
            flushMove(id)
            contacts.insert(id)
        case .move:
            guard contacts.contains(id) || buttons.isEmpty else { return }
            if pendingMoves[id] == nil {
                moveOrder.append(id)
            }
            pendingMoves[id] = PendingMove(kind: kind.rawValue, x: x, y: y, buttons: buttons.rawValue, timestamp: timestamp)
            return
        case .up, .cancel:
            guard contacts.contains(id) else { return }
            flushMove(id)
            contacts.remove(id)
        }
        delegate.pointer(self, id: id, kind: kind.rawValue, phase: phase.rawValue, x: x, y: y, buttons: buttons.rawValue, timestamp: timestamp)
    }

    /// A pointer's buttons changed while it stays in contact (a second
    /// mouse button): a `move` that goes at once.
    func buttonsChanged(id: Int32, kind: PointerKind, x: Float, y: Float, buttons: PointerButtons, timestamp: Int64) {
        guard contacts.contains(id) else { return }
        flushMove(id)
        delegate.pointer(self, id: id, kind: kind.rawValue, phase: PointerPhase.move.rawValue, x: x, y: y, buttons: buttons.rawValue, timestamp: timestamp)
    }

    /// Captured mouse movement, summed until the next frame.
    func pointerDelta(x: Float, y: Float, timestamp: Int64) {
        guard isPointerCaptured else { return }
        if let pending = pendingDelta {
            pendingDelta = (pending.x + x, pending.y + y, timestamp)
        } else {
            pendingDelta = (x, y, timestamp)
        }
    }

    func scroll(x: Float, y: Float) {
        guard x != 0 || y != 0 else { return }
        delegate.scroll(self, x: x, y: y)
    }

    /// A key, while the surface has focus.
    func key(code: Int32, pressed: Bool, modifiers: KeyModifiers, isRepeat: Bool, timestamp: Int64) {
        guard isFocused, code > 0 else { return }
        delegate.key(self, code: code, pressed: pressed, modifiers: modifiers.rawValue, isRepeat: isRepeat, timestamp: timestamp)
    }

    /// Focus came or went. Before it goes: `cancel` for every pointer in
    /// contact, and the end of capture.
    func focus(_ focused: Bool, timestamp: Int64) {
        guard focused != isFocused else { return }
        if !focused {
            cancelContacts(timestamp: timestamp)
            endCapture()
        }
        isFocused = focused
        delegate.focus(self, focused: focused)
    }

    /// The view left the screen or the app stopped being active: no input
    /// may stay stuck. Pointers in contact are cancelled even without
    /// focus.
    func endInput(timestamp: Int64) {
        if isFocused {
            focus(false, timestamp: timestamp)
        } else {
            cancelContacts(timestamp: timestamp)
            endCapture()
        }
        pendingMoves = [:]
        moveOrder = []
    }

    /// The host ended capture itself.
    func endCapture() {
        guard isPointerCaptured else { return }
        isPointerCaptured = false
        pendingDelta = nil
        _ = host?.capturePointer(false)
        delegate.pointerCapture(self, captured: false)
    }

    private func cancelContacts(timestamp: Int64) {
        for id in contacts.sorted() {
            let move = pendingMoves.removeValue(forKey: id)
            moveOrder.removeAll { $0 == id }
            delegate.pointer(
                self, id: id, kind: move?.kind ?? (id == 0 ? PointerKind.mouse.rawValue : PointerKind.touch.rawValue),
                phase: PointerPhase.cancel.rawValue, x: move?.x ?? 0, y: move?.y ?? 0, buttons: 0, timestamp: timestamp
            )
        }
        contacts = []
    }

    private func flushMove(_ id: Int32) {
        guard let move = pendingMoves.removeValue(forKey: id) else { return }
        moveOrder.removeAll { $0 == id }
        delegate.pointer(self, id: id, kind: move.kind, phase: PointerPhase.move.rawValue, x: move.x, y: move.y, buttons: move.buttons, timestamp: move.timestamp)
    }

    /// Every waiting move and delta, before a frame.
    func flushMoves() {
        let order = moveOrder
        moveOrder = []
        for id in order {
            guard let move = pendingMoves.removeValue(forKey: id) else { continue }
            delegate.pointer(self, id: id, kind: move.kind, phase: PointerPhase.move.rawValue, x: move.x, y: move.y, buttons: move.buttons, timestamp: move.timestamp)
        }
        if let delta = pendingDelta {
            pendingDelta = nil
            delegate.pointerDelta(self, x: delta.x, y: delta.y, timestamp: delta.timestamp)
        }
    }
}

/// Timestamps on the `Clock.now()` timeline: `mach_continuous_time`.
enum SurfaceClock {

    static let clock = DispatchClock()

    static func now() -> Int64 {
        clock.now()
    }

    /// An event's timestamp, which UIKit and AppKit give as seconds of
    /// system uptime, on the `Clock.now()` timeline.
    static func timestamp(uptime: TimeInterval) -> Int64 {
        let age = ProcessInfo.processInfo.systemUptime - uptime
        return now() - Int64(max(0, age) * 1_000_000_000)
    }
}
