import DarwinHost
import DynamicRuntime
import Foundation
import RuntimeABI
import RuntimeDocuments

/// The documents contracts (`HostRuntime.md` §5.7): `Documents`, its
/// grants, and their callbacks.
///
/// The contracts are AppRuntime's `HostDocuments`, which makes each
/// document a grant in `HostFiles`, so the guest's `FileManager` reaches
/// it. This module gives it the platform's pickers and bookmarks
/// (`DarwinPickers`), and hands it the files the app is opened with.
public enum DarwinDocuments: DarwinHost.HostModule {

    public static var contracts: [ContractDescriptor] {
        HostDocumentsModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostDocuments.presenter = pickers
        HostDocuments.deliver = { answer in
            DispatchQueue.main.async {
                autoreleasepool(invoking: answer)
            }
        }
        HostDocumentsModule.register(in: registrar)
    }

    /// The pickers ask the user themselves: `.userFiles` prompts for
    /// nothing.
    public static func permissionProviders() -> [Capability: any DarwinHost.PermissionProvider] {
        [.userFiles: GrantedPermission()]
    }

    nonisolated(unsafe) static var pickers = DarwinPickers()

    /// Hands the guest files the app was opened with, from the file manager
    /// or another app. `HostDocuments` keeps them until the guest listens.
    public static func open(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        HostDocuments.open(files.map { DarwinPickers.document($0, access: nil) })
    }
}
