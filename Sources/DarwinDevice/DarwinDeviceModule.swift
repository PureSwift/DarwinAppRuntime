import DarwinHost
import DynamicDevice
import DynamicRuntime

/// The `DynamicDevice` contracts over UIDevice and ProcessInfo on iOS, and
/// ProcessInfo and IOKit power sources on macOS (`HostRuntime.md` §5.1).
///
/// `Device` needs no capability, so this module has no permission
/// providers.
public enum DarwinDeviceModule: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            DeviceProxy.descriptor,
            DeviceDelegateProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        DeviceProxy.register(DarwinDevice.self, in: registrar)
        DeviceDelegateProxy.registerInterface(in: registrar)
    }
}
