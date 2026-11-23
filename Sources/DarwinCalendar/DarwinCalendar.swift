import DarwinHost
import DynamicCalendar
import DynamicRuntime
import EventKit
import Foundation
import RuntimeCalendar
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The calendar contract (`HostRuntime.md` §5.17): `Calendars`, its
/// records, its callback and its delegate.
///
/// The contract is AppRuntime's `HostCalendars`, which checks access
/// before every call and caps it at what the manifest declares, checks
/// dates, ranges and spans, sorts, and gathers a burst of changes into
/// one. This module gives it the user's calendars through EventKit
/// (`SystemCalendarStore`), the system's question, and the store's
/// changes.
public enum DarwinCalendar: DarwinHost.HostModule {

    public static var contracts: [ContractDescriptor] {
        HostCalendarsModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostCalendars.store = store
        HostCalendars.declaredAccess = CalendarValues.declaredAccess(Bundle.main.infoDictionary ?? [:])
        HostCalendars.access = currentAccess
        HostCalendars.requester = { completion in
            request(HostCalendars.declaredAccess) {
                DispatchQueue.main.async {
                    store.accessChanged()
                    completion(currentAccess)
                }
            }
        }
        observe()
        HostCalendarsModule.register(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any DarwinHost.PermissionProvider] {
        [.calendars: CalendarAccessPermission()]
    }

    static let store = SystemCalendarStore()

    /// What the user has granted now. Never asks.
    static var currentAccess: EventStoreAccess {
        CalendarValues.access(EKEventStore.authorizationStatus(for: .event).rawValue)
    }

    /// Asks the system at the level the manifest declares. Before iOS 17
    /// and macOS 14 there's one level, and the host keeps a write-only
    /// app from reading.
    private static func request(_ level: EventStoreAccess, _ completion: @escaping () -> Void) {
        if #available(iOS 17, macOS 14, *) {
            if level == .writeOnly {
                store.store.requestWriteOnlyAccessToEvents { _, _ in completion() }
            } else {
                store.store.requestFullAccessToEvents { _, _ in completion() }
            }
        } else {
            store.store.requestAccess(to: .event) { _, _ in completion() }
        }
    }

    nonisolated(unsafe) private static var observing = false

    /// The store's changes, from any app, a sync or this one; and what the
    /// user granted, which they can change in Settings while the app is
    /// away.
    private static func observe() {
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        center.addObserver(forName: .EKEventStoreChanged, object: store.store, queue: .main) { _ in
            HostCalendars.storeChanged()
        }
        #if canImport(UIKit)
        let active = UIApplication.didBecomeActiveNotification
        #else
        let active = NSApplication.didBecomeActiveNotification
        #endif
        center.addObserver(forName: active, object: nil, queue: .main) { _ in
            let access = currentAccess
            if access != HostCalendars.access {
                // What the app sees has changed with it: the guest looks
                // again.
                HostCalendars.access = access
                store.accessChanged()
                HostCalendars.storeChanged()
            }
        }
    }
}

/// Calendar access as the built-in `Permissions` contract reports it:
/// AppRuntime's `CalendarPermission`, for this host's protocol.
final class CalendarAccessPermission: DarwinHost.PermissionProvider {

    private let permission = CalendarPermission()

    func status() -> PermissionStatus {
        permission.status()
    }

    func request(_ completion: @escaping (PermissionStatus) -> Void) {
        permission.request(completion)
    }
}
