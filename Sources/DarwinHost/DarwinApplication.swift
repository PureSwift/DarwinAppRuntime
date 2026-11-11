import DynamicRuntime
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The built-in `Application` contract: lifecycle, memory warnings and
/// opened URLs, from UIKit's or AppKit's notifications.
///
/// The guest makes one, normally in `rt_main`. The host app forwards the
/// URLs it's opened with through `DarwinApplication.open(_:)`; a URL that
/// arrives before the guest made an application waits for it.
public final class DarwinApplication: Application {

    /// Live applications, in the order the guest made them.
    nonisolated(unsafe) private static var live: [Weak] = []

    /// URLs opened before any application existed.
    nonisolated(unsafe) private static var pendingURLs: [String] = []

    /// Notifications the lifecycle comes from. Replaceable in tests.
    nonisolated(unsafe) public static var notificationCenter = NotificationCenter.default

    /// The state before the first notification. Replaceable in tests.
    nonisolated(unsafe) public static var initialState: () -> ApplicationState = DarwinApplication.systemState

    private let delegate: any ApplicationDelegate

    private var current: ApplicationState

    private var observers: [NSObjectProtocol] = []

    init(delegate: any ApplicationDelegate) {
        self.delegate = delegate
        self.current = Self.initialState()
    }

    deinit {
        for observer in observers {
            Self.notificationCenter.removeObserver(observer)
        }
    }

    public static func make(_ delegate: any ApplicationDelegate) -> DarwinApplication {
        let application = DarwinApplication(delegate: delegate)
        application.observe()
        live.removeAll { $0.value == nil }
        live.append(Weak(application))
        let urls = pendingURLs
        pendingURLs = []
        for url in urls {
            _ = application.delegate.open(application, url: url)
        }
        return application
    }

    public func state() -> Int32 {
        current.rawValue
    }

    /// Passes a URL the app was opened with to the guest. Returns whether a
    /// guest handled it. Before the guest has an application, the URL waits
    /// for one, and this returns `true`.
    @discardableResult
    public static func open(_ url: URL) -> Bool {
        let applications = live.compactMap(\.value)
        guard !applications.isEmpty else {
            pendingURLs.append(url.absoluteString)
            return true
        }
        var handled = false
        for application in applications {
            handled = application.delegate.open(application, url: url.absoluteString) || handled
        }
        return handled
    }

    // MARK: Lifecycle

    private func observe() {
        for (name, state) in Self.stateNotifications {
            observers.append(Self.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.change(to: state)
            })
        }
        if let memoryWarning = Self.memoryWarningNotification {
            observers.append(Self.notificationCenter.addObserver(forName: memoryWarning, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.delegate.didReceiveMemoryWarning(self)
            })
        }
    }

    private func change(to state: ApplicationState) {
        guard state != current else { return }
        current = state
        delegate.didChangeState(self, state: state.rawValue)
    }

    #if canImport(UIKit)
    static let stateNotifications: [(Notification.Name, ApplicationState)] = [
        (UIApplication.didBecomeActiveNotification, .active),
        (UIApplication.willResignActiveNotification, .inactive),
        (UIApplication.didEnterBackgroundNotification, .background),
        (UIApplication.willEnterForegroundNotification, .inactive),
    ]

    static let memoryWarningNotification: Notification.Name? = UIApplication.didReceiveMemoryWarningNotification

    static func systemState() -> ApplicationState {
        switch UIApplication.shared.applicationState {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .inactive
        }
    }
    #elseif canImport(AppKit)
    /// macOS has no background state for a running app: hidden is the
    /// closest.
    static let stateNotifications: [(Notification.Name, ApplicationState)] = [
        (NSApplication.didBecomeActiveNotification, .active),
        (NSApplication.didResignActiveNotification, .inactive),
        (NSApplication.didHideNotification, .background),
        (NSApplication.didUnhideNotification, .inactive),
    ]

    /// macOS has no memory warnings; the system compresses and swaps.
    static let memoryWarningNotification: Notification.Name? = nil

    static func systemState() -> ApplicationState {
        guard let application = NSApp else { return .inactive }
        if application.isHidden { return .background }
        return application.isActive ? .active : .inactive
    }
    #endif

    private final class Weak {
        weak var value: DarwinApplication?
        init(_ value: DarwinApplication) { self.value = value }
    }
}
