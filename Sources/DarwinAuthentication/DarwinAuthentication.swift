import DarwinHost
import DynamicRuntime
import Foundation
import RuntimeAuthentication

/// The sign-in contract (`HostRuntime.md` §5.13): `WebAuthentication`,
/// with its callback.
///
/// The contract is AppRuntime's `HostWebAuthentication`, which refuses a
/// URL that isn't `https` and a redirect whose scheme the manifest doesn't
/// declare, shows one page at a time, and answers once. This module gives
/// it the system's browser (`SystemBrowser`).
public enum DarwinAuthentication: DarwinHost.HostModule {

    public static var contracts: [ContractDescriptor] {
        HostWebAuthenticationModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostWebAuthentication.presenter = SystemBrowser()
        HostWebAuthentication.declaredSchemes = declaredSchemes(Bundle.main.infoDictionary ?? [:])
        HostWebAuthenticationModule.register(in: registrar)
    }

    /// The manifest's `authenticationSchemes`: `RTAuthenticationSchemes`.
    static func declaredSchemes(_ info: [String: Any]) -> Set<String> {
        Set(info["RTAuthenticationSchemes"] as? [String] ?? [])
    }
}
