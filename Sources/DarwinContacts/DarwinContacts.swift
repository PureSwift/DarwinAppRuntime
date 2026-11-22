import Contacts
import DarwinHost
import DynamicContacts
import DynamicRuntime
import Foundation
import RuntimeContacts
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The contacts contract (`HostRuntime.md` §5.14): `Contacts`, its record,
/// callback and delegate.
///
/// The contract is AppRuntime's `HostContacts`, which checks access before
/// every call, refuses a write by an app that declared reading alone, runs
/// the directory off the main thread in order, and gathers a burst of
/// changes into one. This module gives it the user's address book
/// (`SystemAddressBook`), the system's question, and the store's changes.
public enum DarwinContacts: DarwinHost.HostModule {

    public static var contracts: [ContractDescriptor] {
        HostContactsModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostContacts.directory = SystemAddressBook(store: store)
        HostContacts.allowsWriting = ContactValues.allowsWriting(Bundle.main.infoDictionary ?? [:])
        HostContacts.access = currentAccess
        HostContacts.requester = { completion in
            store.requestAccess(for: .contacts) { _, _ in
                // What was granted, which may be some contacts and not all.
                DispatchQueue.main.async {
                    completion(currentAccess)
                }
            }
        }
        observe()
        HostContactsModule.register(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any DarwinHost.PermissionProvider] {
        [.contacts: ContactsAccessPermission()]
    }

    static let store = CNContactStore()

    /// What the user has granted now. Never asks.
    static var currentAccess: ContactStoreAccess {
        ContactValues.access(CNContactStore.authorizationStatus(for: .contacts))
    }

    nonisolated(unsafe) private static var observing = false

    /// The store's changes, from any app or a sync, and what the user
    /// granted, which they can change in Settings while the app is away.
    private static func observe() {
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        center.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { _ in
            HostContacts.storeChanged()
        }
        #if canImport(UIKit)
        let active = UIApplication.didBecomeActiveNotification
        #else
        let active = NSApplication.didBecomeActiveNotification
        #endif
        center.addObserver(forName: active, object: nil, queue: .main) { _ in
            // Who the app sees has changed with it: the guest looks again.
            let access = currentAccess
            if access != HostContacts.access {
                HostContacts.access = access
                HostContacts.storeChanged()
            }
        }
    }
}

/// Contacts access as the built-in `Permissions` contract reports it: the
/// same as the store's.
final class ContactsAccessPermission: DarwinHost.PermissionProvider {

    func status() -> PermissionStatus {
        ContactValues.permission(HostContacts.effectiveAccess)
    }

    func request(_ completion: @escaping (PermissionStatus) -> Void) {
        HostContacts.requestAccess { completion(ContactValues.permission($0)) }
    }
}
