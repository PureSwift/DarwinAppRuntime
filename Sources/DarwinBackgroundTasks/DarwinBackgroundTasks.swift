import DarwinFiles
import DarwinHost
import DynamicRuntime
import Foundation
import RuntimeBackgroundTasks

/// The background contract (`HostRuntime.md` §5.10): `BackgroundTasks`,
/// with its delegate and callback.
///
/// The contract is AppRuntime's `HostBackgroundTasks`, which checks each
/// request against the manifest's tasks, numbers runs and activities, and
/// remembers repeating requests. This module gives it the system's
/// scheduler (`DarwinBackgroundScheduler`).
///
/// iOS runs a task only through a handler registered before the app
/// finishes launching, so the app delegate calls `registerLaunchHandlers()`
/// then:
///
/// ```swift
/// func application(_ application: UIApplication, willFinishLaunchingWithOptions …) -> Bool {
///     DarwinBackgroundTasks.registerLaunchHandlers()
///     return true
/// }
/// ```
public enum DarwinBackgroundTasks: DarwinHost.HostModule {

    public static var contracts: [ContractDescriptor] {
        HostBackgroundTasksModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        let info = Bundle.main.infoDictionary ?? [:]
        HostBackgroundTasks.scheduler = scheduler
        HostBackgroundTasks.declared = BackgroundValues.declared(info)
        HostBackgroundTasks.requestsFile = requestsFile()
        HostBackgroundTasksModule.register(in: registrar)
        #if os(macOS)
        scheduler.restore(HostBackgroundTasks.repeatingRequests)
        #endif
    }

    /// Nothing prompts: `status` is the system's switch.
    public static func permissionProviders() -> [Capability: any DarwinHost.PermissionProvider] {
        [.backgroundTasks: SchedulerPermission()]
    }

    nonisolated(unsafe) static let scheduler = DarwinBackgroundScheduler()

    /// Registers a launch handler for each of the manifest's tasks that the
    /// app's `BGTaskSchedulerPermittedIdentifiers` names. Call it before the
    /// app finishes launching; nothing on macOS needs it.
    public static func registerLaunchHandlers() {
        #if os(iOS)
        let info = Bundle.main.infoDictionary ?? [:]
        let permitted = BackgroundValues.permitted(info)
        let identifiers = BackgroundValues.declared(info).keys.filter(permitted.contains).sorted()
        scheduler.registerLaunchHandlers(identifiers)
        #endif
    }

    /// The repeating requests, kept in the host's own folder, which it makes.
    static func requestsFile() -> String? {
        let folder = FileLocations.current(bundle: DarwinBundle.bundle).host
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } catch {
            AppHost.logger.error("Couldn't make the host's folder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return folder + "/background-requests"
    }
}

/// `Permissions` for background work: the system's switch.
final class SchedulerPermission: DarwinHost.PermissionProvider {

    func status() -> PermissionStatus {
        DarwinBackgroundTasks.scheduler.status
    }

    func request(_ completion: @escaping (PermissionStatus) -> Void) {
        completion(status())
    }
}
