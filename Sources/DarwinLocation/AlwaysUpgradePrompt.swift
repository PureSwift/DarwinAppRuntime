import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Answers a request to upgrade when-in-use location access to always.
///
/// iOS shows that upgrade prompt once per install. When it doesn't show it,
/// or the user keeps when-in-use, CoreLocation reports nothing, and a guest
/// waiting for an answer would wait forever. So:
///
/// - **The request is remembered** in `UserDefaults`, like iOS's own limit:
///   later requests answer at once with the current status instead of
///   asking again (`alreadyRequested`).
/// - **The first request always gets an answer** (`watch`). A system prompt
///   makes the app resign active. If that happens within `promptDelay`, the
///   answer comes once the app is active again; if it doesn't, no prompt
///   appeared and the answer comes then.
final class AlwaysUpgradePrompt {

    /// The `UserDefaults` key recording that this install asked.
    static let requestedKey = "org.pureswift.DarwinLocation.alwaysUpgradeRequested"

    /// Where the request is remembered. Replaceable in tests.
    nonisolated(unsafe) static var defaults = UserDefaults.standard

    /// The notifications a prompt causes. Replaceable in tests.
    nonisolated(unsafe) static var notificationCenter = NotificationCenter.default

    #if canImport(UIKit)
    nonisolated(unsafe) static var resignActive = UIApplication.willResignActiveNotification
    nonisolated(unsafe) static var becomeActive = UIApplication.didBecomeActiveNotification
    #else
    nonisolated(unsafe) static var resignActive = Notification.Name("AlwaysUpgradePrompt.resignActive")
    nonisolated(unsafe) static var becomeActive = Notification.Name("AlwaysUpgradePrompt.becomeActive")
    #endif

    /// How long to wait for the prompt to appear. Replaceable in tests.
    nonisolated(unsafe) static var promptDelay: TimeInterval = 1

    /// Whether this install already asked to upgrade.
    static var alreadyRequested: Bool {
        get { defaults.bool(forKey: requestedKey) }
        set { defaults.set(newValue, forKey: requestedKey) }
    }

    private var observers: [NSObjectProtocol] = []

    private var resigned = false

    private var finished = false

    private let completion: () -> Void

    private init(completion: @escaping () -> Void) {
        self.completion = completion
    }

    /// Calls `completion` once, on the main thread, when the prompt the
    /// upgrade request may show is over. The watch keeps itself alive until
    /// then.
    @discardableResult
    static func watch(_ completion: @escaping () -> Void) -> AlwaysUpgradePrompt {
        let watch = AlwaysUpgradePrompt(completion: completion)
        let center = notificationCenter
        watch.observers.append(center.addObserver(forName: resignActive, object: nil, queue: .main) { _ in
            watch.resigned = true
        })
        watch.observers.append(center.addObserver(forName: becomeActive, object: nil, queue: .main) { _ in
            guard watch.resigned else { return }
            // CoreLocation's own report, if the status changed, arrives on
            // the main queue around now; answer after it.
            DispatchQueue.main.async { watch.finish() }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + promptDelay) {
            // No prompt appeared.
            if !watch.resigned {
                watch.finish()
            }
        }
        return watch
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        for observer in observers {
            Self.notificationCenter.removeObserver(observer)
        }
        observers = []
        completion()
    }
}
