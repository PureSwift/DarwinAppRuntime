import DarwinHost
import DynamicFormatting
import DynamicRuntime

/// The `DynamicFormatting` contracts over Foundation's formatters
/// (`HostRuntime.md` §5.1).
///
/// The contracts need no capability, so this module has no permission
/// providers.
public enum DarwinFormatting: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            LocaleInfoProxy.descriptor,
            NumberFormatProxy.descriptor,
            DateFormatProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        LocaleInfoProxy.register(DarwinLocale.self, in: registrar)
        NumberFormatProxy.register(DarwinNumberFormat.self, in: registrar)
        DateFormatProxy.register(DarwinDateFormat.self, in: registrar)
    }
}
