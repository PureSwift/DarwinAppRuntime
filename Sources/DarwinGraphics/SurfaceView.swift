import DynamicGraphics
import SwiftUI

/// What a `GLSurface` node shows: the GL view of the surface whose
/// `identifier()` it carries, or nothing once the guest released it.
struct SurfaceView: View {

    let identifier: Int32

    var body: some View {
        if let surface = DarwinSurface.surface(identifier) {
            PlatformSurfaceView(surface: surface)
        }
    }
}

#if os(iOS)
import UIKit

private struct PlatformSurfaceView: UIViewRepresentable {

    let surface: DarwinSurface

    func makeUIView(context: Context) -> SurfaceUIView {
        let view = SurfaceUIView()
        view.show(surface)
        return view
    }

    func updateUIView(_ view: SurfaceUIView, context: Context) {
        view.show(surface)
    }

    static func dismantleUIView(_ view: SurfaceUIView, coordinator: ()) {
        view.show(nil)
    }
}

/// A surface on iOS: a `CAEAGLLayer` drawn each display refresh, with
/// touches, the pencil, an iPad's pointer, scrolling and a hardware
/// keyboard as input. It takes keyboard focus when it appears and when
/// touched.
final class SurfaceUIView: UIView, SurfaceHost {

    override class var layerClass: AnyClass {
        CAEAGLLayer.self
    }

    private(set) weak var surface: DarwinSurface?

    private var displayLink: CADisplayLink?

    /// Whether the layer's size or scale changed since the drawable was
    /// made.
    private var needsStorage = true

    /// Touch IDs: 1 and up. The mouse (an indirect pointer) is 0.
    private var touchIDs: [ObjectIdentifier: Int32] = [:]

    private var nextTouchID: Int32 = 0

    private var isAppActive: Bool

    private var observers: [NSObjectProtocol] = []

    init() {
        isAppActive = UIApplication.shared.applicationState == .active
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        isOpaque = true
        if let layer = layer as? CAEAGLLayer {
            layer.isOpaque = true
            layer.drawableProperties = [
                kEAGLDrawablePropertyRetainedBacking: false,
                kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8,
            ]
        }
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hover(_:)))
        addGestureRecognizer(hover)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        scroll.allowedScrollTypesMask = .all
        // Only scroll wheels and trackpads, never touches.
        scroll.allowedTouchTypes = []
        addGestureRecognizer(scroll)

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.isAppActive = true
                self?.updateRunning()
            },
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.isAppActive = false
                self?.updateRunning()
            },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        displayLink?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Shows `surface`, taking it from any view that showed it.
    func show(_ surface: DarwinSurface?) {
        guard surface !== self.surface || surface?.host !== self else { return }
        if let old = self.surface, old !== surface, old.host === self {
            old.endInput(timestamp: SurfaceClock.now())
            old.host = nil
        }
        self.surface = surface
        surface?.host = self
        needsStorage = true
        updateRunning()
    }

    /// Frames run while the view is in a window and the app is active.
    private var isRunning: Bool {
        guard let surface, surface.host === self else { return false }
        return window != nil && !isHidden && isAppActive
    }

    private func updateRunning() {
        if isRunning {
            if displayLink == nil {
                let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } else {
            displayLink?.invalidate()
            displayLink = nil
            if let surface, surface.host === self {
                surface.endInput(timestamp: SurfaceClock.now())
            }
        }
        syncFocus()
    }

    private func syncFocus() {
        guard let surface, surface.host === self else { return }
        surface.focus(isRunning && isFirstResponder, timestamp: SurfaceClock.now())
    }

    fileprivate func tick() {
        guard isRunning, let surface else {
            updateRunning()
            return
        }
        if surface.context == nil {
            surface.context = EAGLSurfaceContext()
        }
        guard let context = surface.context as? EAGLSurfaceContext, let layer = layer as? CAEAGLLayer else { return }
        if needsStorage {
            needsStorage = false
            if let size = context.attach(layer) {
                surface.resize(width: size.width, height: size.height, scale: Float(contentScaleFactor))
            }
        }
        surface.drawFrame(timestamp: SurfaceClock.now())
    }

    // MARK: Layout

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            contentScaleFactor = window.screen.scale
        }
        needsStorage = true
        updateRunning()
        if window != nil, surface?.host === self {
            _ = becomeFirstResponder()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        needsStorage = true
    }

    override var isHidden: Bool {
        didSet { updateRunning() }
    }

    // MARK: Focus and keys

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        syncFocus()
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        syncFocus()
        return resigned
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = keys(presses, pressed: true)
        if !rest.isEmpty {
            super.pressesBegan(rest, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = keys(presses, pressed: false)
        if !rest.isEmpty {
            super.pressesEnded(rest, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = keys(presses, pressed: false)
        if !rest.isEmpty {
            super.pressesCancelled(rest, with: event)
        }
    }

    /// Sends the keyboard's presses; returns the rest. `UIKey.keyCode` is a
    /// HID usage already. UIKit has no auto-repeat for presses.
    private func keys(_ presses: Set<UIPress>, pressed: Bool) -> Set<UIPress> {
        guard let surface, surface.host === self, surface.isFocused else { return presses }
        var rest = Set<UIPress>()
        for press in presses {
            guard let key = press.key else {
                rest.insert(press)
                continue
            }
            surface.key(
                code: Int32(truncatingIfNeeded: key.keyCode.rawValue),
                pressed: pressed,
                modifiers: KeyCodes.modifiers(flags: UInt(key.modifierFlags.rawValue)),
                isRepeat: false,
                timestamp: SurfaceClock.timestamp(uptime: press.timestamp)
            )
        }
        return rest
    }

    // MARK: Pointers

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }
        send(touches, .down, event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, .move, event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, .up, event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, .cancel, event)
    }

    private func send(_ touches: Set<UITouch>, _ phase: PointerPhase, _ event: UIEvent?) {
        guard let surface, surface.host === self, isRunning else { return }
        let scale = Float(contentScaleFactor)
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let key = ObjectIdentifier(touch)
            let kind: PointerKind
            let id: Int32
            switch touch.type {
            case .indirectPointer:
                kind = .mouse
                id = 0
            case .pencil:
                kind = .pen
                id = touchID(key)
            default:
                kind = .touch
                id = touchID(key)
            }
            let ending = phase == .up || phase == .cancel
            let buttons: PointerButtons
            if ending {
                buttons = []
            } else if kind == .mouse {
                buttons = Self.buttons(event?.buttonMask ?? .primary)
            } else {
                buttons = .primary
            }
            let point = touch.location(in: self)
            surface.pointer(
                id: id, kind: kind, phase: phase,
                x: Float(point.x) * scale, y: Float(point.y) * scale,
                buttons: buttons, timestamp: SurfaceClock.timestamp(uptime: touch.timestamp)
            )
            if ending {
                touchIDs[key] = nil
            }
        }
    }

    private func touchID(_ key: ObjectIdentifier) -> Int32 {
        if let id = touchIDs[key] {
            return id
        }
        nextTouchID = nextTouchID == Int32.max ? 1 : nextTouchID + 1
        touchIDs[key] = nextTouchID
        return nextTouchID
    }

    static func buttons(_ mask: UIEvent.ButtonMask) -> PointerButtons {
        var buttons: PointerButtons = []
        if mask.contains(.primary) { buttons.insert(.primary) }
        if mask.contains(.secondary) { buttons.insert(.secondary) }
        if mask.contains(.button(3)) { buttons.insert(.middle) }
        return buttons
    }

    /// An iPad's pointer moving with no button held.
    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        guard let surface, surface.host === self, isRunning else { return }
        switch recognizer.state {
        case .began, .changed:
            let point = recognizer.location(in: self)
            let scale = Float(contentScaleFactor)
            surface.pointer(id: 0, kind: .mouse, phase: .move, x: Float(point.x) * scale, y: Float(point.y) * scale, buttons: [], timestamp: SurfaceClock.now())
        default:
            break
        }
    }

    /// A scroll wheel or trackpad: how far content moves, in pixels.
    @objc private func scroll(_ recognizer: UIPanGestureRecognizer) {
        guard let surface, surface.host === self, isRunning else { return }
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        let scale = Float(contentScaleFactor)
        surface.scroll(x: Float(translation.x) * scale, y: Float(translation.y) * scale)
    }

    // MARK: SurfaceHost

    /// iOS keeps the pointer: there's no capture.
    func capturePointer(_ captured: Bool) -> Bool {
        false
    }
}

/// The display link's target, which doesn't keep the view.
private final class DisplayLinkTarget: NSObject {

    weak var view: SurfaceUIView?

    init(_ view: SurfaceUIView) {
        self.view = view
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        view.tick()
    }
}

#elseif os(macOS)
import AppKit

private struct PlatformSurfaceView: NSViewRepresentable {

    let surface: DarwinSurface

    func makeNSView(context: Context) -> SurfaceNSView {
        let view = SurfaceNSView()
        view.show(surface)
        return view
    }

    func updateNSView(_ view: SurfaceNSView, context: Context) {
        view.show(surface)
    }

    static func dismantleNSView(_ view: SurfaceNSView, coordinator: ()) {
        view.show(nil)
    }
}

/// A surface on macOS: an `NSOpenGLView` on the surface's context, drawn
/// each display refresh, with the mouse, the scroll wheel and the keyboard
/// as input, and pointer capture. It takes keyboard focus when it appears
/// and when clicked.
final class SurfaceNSView: NSOpenGLView, SurfaceHost {

    private(set) weak var surface: DarwinSurface?

    private var timer: Timer?

    private var displayLink: AnyObject?

    /// Whether the drawable's size or scale changed.
    private var needsResize = true

    /// The mouse buttons held.
    private var mouseButtons: PointerButtons = []

    private var isCapturing = false

    private var observers: [NSObjectProtocol] = []

    init() {
        super.init(frame: .zero, pixelFormat: nil)!
        wantsBestResolutionOpenGLSurface = true
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateRunning()
            })
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self, notification.object as? NSWindow === self.window else { return }
                self.updateRunning()
            })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Shows `surface`, taking it from any view that showed it.
    func show(_ surface: DarwinSurface?) {
        guard surface !== self.surface || surface?.host !== self else { return }
        if let old = self.surface, old !== surface, old.host === self {
            old.endInput(timestamp: SurfaceClock.now())
            endCapture()
            old.host = nil
        }
        self.surface = surface
        surface?.host = self
        if let surface {
            if surface.context == nil {
                surface.context = DesktopSurfaceContext()
            }
            if let context = surface.context as? DesktopSurfaceContext {
                pixelFormat = context.context.pixelFormat
                openGLContext = context.context
            }
        }
        needsResize = true
        updateRunning()
    }

    override var isFlipped: Bool {
        true
    }

    private var isRunning: Bool {
        guard let surface, surface.host === self, let window else { return false }
        return !isHiddenOrHasHiddenAncestor && window.isVisible && NSApp.isActive && !NSApp.isHidden
    }

    private func updateRunning() {
        if isRunning {
            startFrames()
        } else {
            stopFrames()
            if let surface, surface.host === self {
                endCapture()
                surface.endInput(timestamp: SurfaceClock.now())
            }
        }
        syncFocus()
    }

    private func syncFocus() {
        guard let surface, surface.host === self else { return }
        let focused = isRunning && window?.isKeyWindow == true && window?.firstResponder === self
        surface.focus(focused, timestamp: SurfaceClock.now())
    }

    private func startFrames() {
        guard timer == nil, displayLink == nil else { return }
        if #available(macOS 14, *) {
            let link = displayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                self?.needsDisplay = true
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func stopFrames() {
        timer?.invalidate()
        timer = nil
        if #available(macOS 14, *) {
            (displayLink as? CADisplayLink)?.invalidate()
        }
        displayLink = nil
    }

    fileprivate func tick() {
        guard isRunning else {
            updateRunning()
            return
        }
        needsDisplay = true
    }

    /// AppKit calls this with the context current and the view's
    /// framebuffer bound.
    override func draw(_ dirtyRect: NSRect) {
        guard isRunning, let surface, let context = surface.context as? DesktopSurfaceContext,
              context.context === openGLContext else {
            return
        }
        if needsResize {
            needsResize = false
            context.update()
            let pixels = convertToBacking(bounds).size
            let scale = Float(window?.backingScaleFactor ?? 1)
            surface.resize(width: Int32(pixels.width.rounded()), height: Int32(pixels.height.rounded()), scale: scale)
        }
        surface.drawFrame(timestamp: SurfaceClock.now())
    }

    override func reshape() {
        super.reshape()
        needsResize = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsResize = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsResize = true
        updateRunning()
        if let window, surface?.host === self {
            window.makeFirstResponder(self)
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateRunning()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateRunning()
    }

    // MARK: Focus and keys

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.syncFocus() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.syncFocus() }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        guard key(event, pressed: true) else {
            super.keyDown(with: event)
            return
        }
    }

    override func keyUp(with event: NSEvent) {
        guard key(event, pressed: false) else {
            super.keyUp(with: event)
            return
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let code = event.keyCode
        let pressed: Bool
        if let mask = KeyCodes.macModifierMasks[code] {
            pressed = event.modifierFlags.rawValue & mask != 0
        } else if code == 0x39 {
            // Caps Lock reports its state: a press and a release.
            guard key(event, pressed: true) else {
                super.flagsChanged(with: event)
                return
            }
            _ = key(event, pressed: false)
            return
        } else {
            super.flagsChanged(with: event)
            return
        }
        if !key(event, pressed: pressed) {
            super.flagsChanged(with: event)
        }
    }

    /// Sends a key while focused; `false` for one to pass on.
    private func key(_ event: NSEvent, pressed: Bool) -> Bool {
        guard let surface, surface.host === self, surface.isFocused,
              let code = KeyCodes.hidUsage(macKeyCode: event.keyCode) else {
            return false
        }
        let isRepeat = event.type == .keyDown && event.isARepeat
        surface.key(
            code: code, pressed: pressed,
            modifiers: KeyCodes.modifiers(flags: event.modifierFlags.rawValue),
            isRepeat: isRepeat, timestamp: SurfaceClock.timestamp(uptime: event.timestamp)
        )
        return true
    }

    // MARK: Pointers

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        press(.primary, true, event)
    }

    override func mouseUp(with event: NSEvent) {
        press(.primary, false, event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        press(.secondary, true, event)
    }

    override func rightMouseUp(with event: NSEvent) {
        press(.secondary, false, event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        window?.makeFirstResponder(self)
        press(.middle, true, event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        press(.middle, false, event)
    }

    override func mouseMoved(with event: NSEvent) {
        move(event)
    }

    override func mouseDragged(with event: NSEvent) {
        move(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        move(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        move(event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface, surface.host === self, isRunning else { return }
        // Lines become 16 points, as a browser's are about.
        let points: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
        let scale = window?.backingScaleFactor ?? 1
        surface.scroll(x: Float(event.scrollingDeltaX * points * scale), y: Float(event.scrollingDeltaY * points * scale))
    }

    private func location(_ event: NSEvent) -> (x: Float, y: Float) {
        let point = convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 1
        return (Float(point.x * scale), Float(point.y * scale))
    }

    private func press(_ button: PointerButtons, _ down: Bool, _ event: NSEvent) {
        guard let surface, surface.host === self, isRunning else { return }
        let old = mouseButtons
        if down {
            mouseButtons.insert(button)
        } else {
            mouseButtons.remove(button)
        }
        guard old != mouseButtons, !surface.isPointerCaptured else { return }
        let (x, y) = location(event)
        let timestamp = SurfaceClock.timestamp(uptime: event.timestamp)
        if old.isEmpty {
            surface.pointer(id: 0, kind: .mouse, phase: .down, x: x, y: y, buttons: mouseButtons, timestamp: timestamp)
        } else if mouseButtons.isEmpty {
            surface.pointer(id: 0, kind: .mouse, phase: .up, x: x, y: y, buttons: [], timestamp: timestamp)
        } else {
            surface.buttonsChanged(id: 0, kind: .mouse, x: x, y: y, buttons: mouseButtons, timestamp: timestamp)
        }
    }

    private func move(_ event: NSEvent) {
        guard let surface, surface.host === self, isRunning else { return }
        let timestamp = SurfaceClock.timestamp(uptime: event.timestamp)
        if surface.isPointerCaptured {
            let scale = Float(window?.backingScaleFactor ?? 1)
            surface.pointerDelta(x: Float(event.deltaX) * scale, y: Float(event.deltaY) * scale, timestamp: timestamp)
            return
        }
        let (x, y) = location(event)
        surface.pointer(id: 0, kind: .mouse, phase: .move, x: x, y: y, buttons: mouseButtons, timestamp: timestamp)
    }

    // MARK: SurfaceHost

    /// Hides the cursor and keeps it still: mouse movement becomes
    /// `pointerDelta`. Only while the surface runs in the key window.
    func capturePointer(_ captured: Bool) -> Bool {
        if captured {
            guard isRunning, window?.isKeyWindow == true else { return false }
            if !isCapturing {
                CGAssociateMouseAndMouseCursorPosition(0)
                NSCursor.hide()
                isCapturing = true
            }
            return true
        }
        endCapture()
        return false
    }

    private func endCapture() {
        guard isCapturing else { return }
        isCapturing = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        surface?.endCapture()
    }
}

/// The display link's target, which doesn't keep the view.
private final class DisplayLinkTarget: NSObject {

    weak var view: SurfaceNSView?

    init(_ view: SurfaceNSView) {
        self.view = view
    }

    @objc func tick(_ link: AnyObject) {
        guard let view else {
            (link as? NSObject)?.perform(Selector(("invalidate")))
            return
        }
        view.tick()
    }
}

#endif
