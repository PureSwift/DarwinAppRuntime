import DarwinHost
import DynamicDefaults
import DynamicRuntime
import Foundation
import RuntimeHost

/// The defaults contract (`HostRuntime.md` §5.5): `Defaults`.
///
/// The contract's rules are AppRuntime's `HostDefaults`. This module gives
/// it the store: a `UserDefaults` suite of the app's own
/// (`UserDefaultsStorage`).
public enum DarwinDefaults: DarwinHost.HostModule {

    public static var contracts: [ContractDescriptor] {
        [DefaultsProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        configure()
        DefaultsProxy.register(HostDefaults.self, in: registrar)
    }

    /// The suite the app's values are kept in. Read when the module is
    /// registered.
    nonisolated(unsafe) static var suite: () -> String = {
        UserDefaultsStorage.suite(for: DarwinBundle.bundle)
    }

    /// Opens the suite. If that fails, it's logged, and nothing is kept:
    /// reads find nothing and writes are refused.
    static func configure() {
        let suite = suite()
        guard let storage = UserDefaultsStorage(suite: suite) else {
            AppHost.logger.error("Couldn't open the defaults suite \(suite, privacy: .public)")
            HostDefaults.storage = nil
            return
        }
        HostDefaults.storage = storage
    }
}
