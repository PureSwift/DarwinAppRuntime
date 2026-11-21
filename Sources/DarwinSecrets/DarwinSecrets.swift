import DarwinFiles
import DarwinHost
import DynamicRuntime
import Foundation
import RuntimeSecrets

/// The secrets contract (`HostRuntime.md` §5.13): `Secrets`, with its
/// callback.
///
/// The contract is AppRuntime's `HostSecrets`, which checks keys and sizes,
/// runs the store off the main thread in order, and answers on the main
/// thread. This module gives it the Keychain (`KeychainStore`), scoped to
/// the app's identifier.
public enum DarwinSecrets: DarwinHost.HostModule {

    public static var contracts: [ContractDescriptor] {
        HostSecretsModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostSecrets.store = KeychainStore(service: service, marker: marker())
        HostSecretsModule.register(in: registrar)
    }

    /// No platform asks the user before an app keeps a secret.
    public static func permissionProviders() -> [Capability: any DarwinHost.PermissionProvider] {
        [.secrets: GrantedPermission()]
    }

    /// The app's identifier, under which its secrets are kept.
    static var service: String {
        DarwinBundle.bundle.bundleIdentifier ?? ProcessInfo.processInfo.processName
    }

    /// The marker of the first run since the app was installed, in the
    /// host's own folder, which goes with the app.
    static func marker() -> String? {
        let folder = FileLocations.current(bundle: DarwinBundle.bundle).host
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } catch {
            AppHost.logger.error("Couldn't make the host's folder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return folder + "/secrets-installed"
    }
}
