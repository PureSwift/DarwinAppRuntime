import DynamicBackgroundTasks
import DynamicRuntime
import Foundation
import RuntimeBackgroundTasks
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// `HostBackgroundTasks`' scheduler.
///
/// On iOS, `BGTaskScheduler` runs the manifest's tasks, with the app closed
/// too, and an activity is `beginBackgroundTask`. A request runs once, so
/// `HostBackgroundTasks` asks again for a repeating one as each run starts.
///
/// On macOS, an `NSBackgroundActivityScheduler` per request runs it while
/// the app is open, and repeats it itself. A Mac app isn't suspended, so
/// an activity only keeps the system from terminating it, and never runs
/// out.
///
/// Main thread only.
final class DarwinBackgroundScheduler: BackgroundScheduler {

    #if os(iOS)

    /// The open activities' background tasks, by the activity's number.
    private var tasks: [Int32: UIBackgroundTaskIdentifier] = [:]

    /// The identifiers with a launch handler: registering one twice is a
    /// crash.
    private var handled: Set<String> = []

    var status: PermissionStatus {
        BackgroundValues.status(UIApplication.shared.backgroundRefreshStatus)
    }

    var repeatsRequests: Bool { false }

    func submit(_ request: HostBackgroundRequest, completion: @escaping (BackgroundError?) -> Void) {
        do {
            // Replaces a pending request with the same identifier.
            try BGTaskScheduler.shared.submit(BackgroundValues.request(request, now: Date()))
            completion(nil)
        } catch {
            completion(BackgroundValues.error(error))
        }
    }

    func cancel(_ identifier: String?) {
        if let identifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        } else {
            BGTaskScheduler.shared.cancelAllTaskRequests()
        }
    }

    func pending(_ completion: @escaping ([String]) -> Void) {
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let identifiers = requests.map(\.identifier)
            DispatchQueue.main.async { completion(identifiers) }
        }
    }

    func beginActivity(_ name: String, number: Int32) -> Bool {
        let task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // On the main thread. The guest hears first; then the system's
            // task ends, as it must before the handler returns.
            HostBackgroundTasks.expireActivity(number)
            self?.endTask(number)
        }
        guard task != .invalid else { return false }
        tasks[number] = task
        return true
    }

    func endActivity(_ number: Int32) {
        endTask(number)
    }

    private func endTask(_ number: Int32) {
        guard let task = tasks.removeValue(forKey: number) else { return }
        UIApplication.shared.endBackgroundTask(task)
    }

    var timeRemaining: Double? {
        BackgroundValues.timeRemaining(UIApplication.shared.backgroundTimeRemaining)
    }

    /// Tells the system what runs each task, before the app finishes
    /// launching, as it requires. A run waits for the guest: the guest
    /// starts as launch finishes, before the system runs anything.
    func registerLaunchHandlers(_ identifiers: [String]) {
        for identifier in identifiers where !handled.contains(identifier) {
            handled.insert(identifier)
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                let run = HostBackgroundTasks.start(identifier) { success in
                    task.setTaskCompleted(success: success)
                }
                task.expirationHandler = {
                    DispatchQueue.main.async { HostBackgroundTasks.expire(run) }
                }
            }
        }
    }

    #else

    /// The requests the system holds, by identifier.
    private var schedulers: [String: NSBackgroundActivityScheduler] = [:]

    /// What keeps the system from terminating the app, by activity.
    private var activities: [Int32: NSObjectProtocol] = [:]

    var status: PermissionStatus { .granted }

    var repeatsRequests: Bool { true }

    func submit(_ request: HostBackgroundRequest, completion: @escaping (BackgroundError?) -> Void) {
        schedulers.removeValue(forKey: request.identifier)?.invalidate()
        let scheduler = NSBackgroundActivityScheduler(identifier: request.identifier)
        scheduler.repeats = request.repeats
        // A repeating request runs about every `interval`. One that runs once
        // runs within a window; it's put off until its earliest time.
        scheduler.interval = request.repeats ? request.interval : max(request.earliest, 60)
        scheduler.qualityOfService = request.kind == .processing ? .background : .utility
        let notBefore = BackgroundValues.earliestDate(request.earliest, now: Date())
        let identifier = request.identifier
        scheduler.schedule { [weak self] done in
            DispatchQueue.main.async {
                if let notBefore, Date() < notBefore {
                    done(.deferred)
                    return
                }
                HostBackgroundTasks.start(identifier) { _ in
                    done(.finished)
                }
                if !request.repeats {
                    self?.schedulers[identifier] = nil
                }
            }
        }
        schedulers[request.identifier] = scheduler
        completion(nil)
    }

    func cancel(_ identifier: String?) {
        let cancelled = identifier.map { [$0] } ?? Array(schedulers.keys)
        for identifier in cancelled {
            schedulers.removeValue(forKey: identifier)?.invalidate()
        }
    }

    func pending(_ completion: @escaping ([String]) -> Void) {
        completion(schedulers.keys.sorted())
    }

    func beginActivity(_ name: String, number: Int32) -> Bool {
        activities[number] = ProcessInfo.processInfo.beginActivity(
            options: [.suddenTerminationDisabled, .automaticTerminationDisabled], reason: name)
        return true
    }

    func endActivity(_ number: Int32) {
        guard let activity = activities.removeValue(forKey: number) else { return }
        ProcessInfo.processInfo.endActivity(activity)
    }

    /// Unlimited: a Mac app isn't suspended.
    var timeRemaining: Double? { nil }

    /// Nothing keeps a Mac app's requests when it quits: the repeating ones
    /// `HostBackgroundTasks` remembers are asked for again at launch.
    func restore(_ requests: [HostBackgroundRequest]) {
        for request in requests where schedulers[request.identifier] == nil {
            var again = request
            again.earliest = request.interval
            submit(again) { _ in }
        }
    }

    #endif
}
