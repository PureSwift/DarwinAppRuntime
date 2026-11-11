import CoreMotion
import DarwinHost
import DynamicMotion
import DynamicRuntime
import Foundation

/// The `ActivityRecognizer` contract over `CMMotionActivityManager`.
///
/// Each `CMMotionActivity` becomes one `didUpdateActivity` call: its flags
/// as `MotionActivity`, its confidence, and its `startDate` in
/// milliseconds since 1970. Updates fail with `unauthorized` until Motion &
/// Fitness access is `authorized`, so that only `requestAuthorization()`
/// prompts. The handler runs on `OperationQueue.main`.
///
/// CoreMotion's activity handler has no error parameter: if access is
/// revoked while updates run, they stop arriving without a `didFail`.
///
/// macOS has no activity recognition: `isAvailable()` is `false`, the
/// status is `restricted` and updates fail with `unavailable`.
public final class DarwinActivityRecognizer: ActivityRecognizer {

    let delegate: any ActivityRecognizerDelegate

    /// The token of the running updates; activities queued before
    /// `stopUpdates()` carry an older one and are dropped.
    private(set) var updates: Int?

    private var nextToken = 0

    #if os(iOS)
    let manager = CMMotionActivityManager()
    #endif

    init(delegate: any ActivityRecognizerDelegate) {
        self.delegate = delegate
    }

    deinit {
        #if os(iOS)
        if updates != nil {
            manager.stopActivityUpdates()
        }
        #endif
    }

    public static func isAvailable() -> Bool {
        #if os(iOS)
        CMMotionActivityManager.isActivityAvailable()
        #else
        false
        #endif
    }

    public static func authorizationStatus() -> Int32 {
        MotionAuthorizationRequest.status().rawValue
    }

    public static func make(_ delegate: any ActivityRecognizerDelegate) -> DarwinActivityRecognizer {
        DarwinActivityRecognizer(delegate: delegate)
    }

    /// Reports the outcome through `didChangeAuthorization`, also when
    /// nothing was asked.
    public func requestAuthorization() {
        MotionAuthorizationRequest.request { [weak self] status in
            guard let self else { return }
            deliver {
                self.delegate.didChangeAuthorization(self, status: status.rawValue)
            }
        }
    }

    public func startUpdates() {
        if let error = Self.precondition() {
            stopUpdates()
            return DispatchQueue.main.async { [weak self] in
                self?.fail(error)
            }
        }
        #if os(iOS)
        if updates != nil {
            manager.stopActivityUpdates()
        }
        nextToken += 1
        let token = nextToken
        updates = token
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, self.updates == token, let activity else { return }
            let flags = MotionConversions.activity(
                stationary: activity.stationary, walking: activity.walking, running: activity.running,
                automotive: activity.automotive, cycling: activity.cycling, unknown: activity.unknown
            )
            let confidence = MotionConversions.confidence(activity.confidence.rawValue)
            let timestamp = MotionConversions.milliseconds(activity.startDate)
            deliver {
                self.delegate.didUpdateActivity(self, activity: flags, confidence: confidence.rawValue, timestamp: timestamp)
            }
        }
        #endif
    }

    public func stopUpdates() {
        guard updates != nil else { return }
        updates = nil
        #if os(iOS)
        manager.stopActivityUpdates()
        #endif
    }

    /// `unavailable` without activity recognition, `unauthorized` until the
    /// status is `authorized`.
    static func precondition() -> MotionError? {
        guard isAvailable() else { return .unavailable }
        guard MotionAuthorizationRequest.status() == .authorized else { return .unauthorized }
        return nil
    }

    /// Stops updates and reports `error`.
    func fail(_ error: MotionError) {
        stopUpdates()
        deliver {
            delegate.didFail(self, error: error.rawValue)
        }
    }
}
