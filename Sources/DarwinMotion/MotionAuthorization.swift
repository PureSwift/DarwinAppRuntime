import CoreMotion
import DarwinHost
import DynamicMotion
import DynamicRuntime
import Foundation

/// Motion & Fitness authorization, shared by `Pedometer`, `Altimeter`,
/// `ActivityRecognizer` and the `motion` permission.
///
/// One permission covers all three services. CoreMotion has no call that
/// only prompts: the prompt appears the first time an app reads motion
/// data, so `request` runs a one-minute activity query (or, without
/// activity recognition, a pedometer query) and reads the status once it
/// answers. On macOS none of the services exist and the status is
/// `restricted`, which never changes.
enum MotionAuthorizationRequest {

    /// The current status. Never prompts.
    static func status() -> MotionAuthorization {
        #if os(iOS)
        MotionConversions.authorization(CMMotionActivityManager.authorizationStatus().rawValue)
        #else
        .restricted
        #endif
    }

    /// Whether a query can show the prompt on this device.
    static var canPrompt: Bool {
        #if os(iOS)
        CMMotionActivityManager.isActivityAvailable() || CMPedometer.isStepCountingAvailable()
        #else
        false
        #endif
    }

    #if os(iOS)
    /// The managers whose queries are showing the prompt.
    nonisolated(unsafe) private static var activityQuery: CMMotionActivityManager?

    nonisolated(unsafe) private static var pedometerQuery: CMPedometer?
    #endif

    nonisolated(unsafe) private static var completions: [(MotionAuthorization) -> Void] = []

    /// Prompts if the status isn't determined and the device has a service
    /// that can prompt, then calls `completion` once, on a later main-queue
    /// turn, with the status. Without anything to ask it reports the
    /// current status, logging when that is still `notDetermined`.
    static func request(_ completion: @escaping (MotionAuthorization) -> Void) {
        let current = status()
        guard current == .notDetermined, canPrompt else {
            if current == .notDetermined {
                AppHost.logger.error("Motion & Fitness: this device has no service that can show the prompt")
            }
            DispatchQueue.main.async { completion(current) }
            return
        }
        completions.append(completion)
        #if os(iOS)
        guard activityQuery == nil, pedometerQuery == nil else { return }
        let end = Date()
        let start = end.addingTimeInterval(-60)
        if CMMotionActivityManager.isActivityAvailable() {
            let manager = CMMotionActivityManager()
            activityQuery = manager
            manager.queryActivityStarting(from: start, to: end, to: .main) { _, _ in
                finish()
            }
        } else {
            let pedometer = CMPedometer()
            pedometerQuery = pedometer
            pedometer.queryPedometerData(from: start, to: end) { _, _ in
                DispatchQueue.main.async { finish() }
            }
        }
        #endif
    }

    private static func finish() {
        #if os(iOS)
        activityQuery = nil
        pedometerQuery = nil
        #endif
        let status = status()
        let waiting = completions
        completions = []
        for completion in waiting {
            completion(status)
        }
    }
}

/// `Permissions` for `motion`, from `CMMotionActivityManager`'s
/// authorization. `unavailable` on macOS.
final class MotionPermission: PermissionProvider {

    func status() -> PermissionStatus {
        #if os(iOS)
        MotionConversions.permission(MotionAuthorizationRequest.status())
        #else
        .unavailable
        #endif
    }

    func request(_ completion: @escaping (PermissionStatus) -> Void) {
        #if os(iOS)
        MotionAuthorizationRequest.request { status in
            completion(MotionConversions.permission(status))
        }
        #else
        completion(.unavailable)
        #endif
    }
}
