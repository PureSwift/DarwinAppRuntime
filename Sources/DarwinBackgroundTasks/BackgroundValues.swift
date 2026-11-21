import DynamicBackgroundTasks
import DynamicRuntime
import Foundation
import RuntimeBackgroundTasks
#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
import UIKit
#endif

/// The contract's values as the platform's, and the bundle's keys.
///
/// None of it needs a scheduler, so the tests check it on its own.
enum BackgroundValues {

    // MARK: The bundle

    /// The tasks the manifest names, with their kinds: `RTBackgroundTasks`,
    /// each an `Identifier` and a `Kind` (`refresh` or `processing`).
    static func declared(_ info: [String: Any]) -> [String: BackgroundTaskKind] {
        var tasks: [String: BackgroundTaskKind] = [:]
        for entry in info["RTBackgroundTasks"] as? [[String: Any]] ?? [] {
            guard let identifier = entry["Identifier"] as? String, !identifier.isEmpty,
                  let kind = (entry["Kind"] as? String).flatMap(kind) else { continue }
            tasks[identifier] = kind
        }
        return tasks
    }

    static func kind(_ name: String) -> BackgroundTaskKind? {
        switch name {
        case "refresh": .refresh
        case "processing": .processing
        default: nil
        }
    }

    /// The identifiers iOS lets the app schedule: its
    /// `BGTaskSchedulerPermittedIdentifiers`, which the packager writes from
    /// the same tasks. Registering any other one is a crash.
    static func permitted(_ info: [String: Any]) -> Set<String> {
        Set(info["BGTaskSchedulerPermittedIdentifiers"] as? [String] ?? [])
    }

    // MARK: Requests

    /// When a request may run first. `earliest` is seconds from `now`.
    static func earliestDate(_ earliest: Double, now: Date) -> Date? {
        earliest > 0 ? now.addingTimeInterval(earliest) : nil
    }

    #if canImport(BackgroundTasks) && os(iOS)
    /// The system's request. A refresh can't ask for the network or power:
    /// the system runs it when it thinks best.
    static func request(_ request: HostBackgroundRequest, now: Date) -> BGTaskRequest {
        let made: BGTaskRequest
        switch request.kind {
        case .refresh:
            made = BGAppRefreshTaskRequest(identifier: request.identifier)
        case .processing:
            let processing = BGProcessingTaskRequest(identifier: request.identifier)
            processing.requiresNetworkConnectivity = request.requirements.contains(.network)
            processing.requiresExternalPower = request.requirements.contains(.charging)
            made = processing
        }
        made.earliestBeginDate = earliestDate(request.earliest, now: now)
        return made
    }

    /// Why the system refused a request. In the Simulator it's
    /// `unavailable`: there's no background scheduling there.
    static func error(_ error: Error) -> BackgroundError {
        guard let error = error as? BGTaskScheduler.Error else { return .unknown }
        switch error.code {
        case .tooManyPendingTaskRequests: return .limitReached
        case .notPermitted: return .notDeclared
        case .unavailable: return .unsupported
        default: return .unknown
        }
    }

    static func status(_ status: UIBackgroundRefreshStatus) -> PermissionStatus {
        switch status {
        case .available: .granted
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unavailable
        }
    }
    #endif

    /// Seconds left, as the contract has it: `nil` while the app is in front,
    /// where the system says "unlimited".
    static func timeRemaining(_ seconds: Double) -> Double? {
        seconds.isFinite && seconds < 1e9 ? max(seconds, 0) : nil
    }
}
