import DarwinHost
import DynamicMotion
import DynamicRuntime

/// The Motion contracts over CoreMotion (`HostRuntime.md` §5.1).
///
/// On macOS, CoreMotion has none of these services: every contract is
/// registered, its availability checks are `false`, and the Motion &
/// Fitness services report `restricted`.
public enum DarwinMotion: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            MotionManagerProxy.descriptor,
            MotionManagerDelegateProxy.descriptor,
            PedometerProxy.descriptor,
            PedometerDelegateProxy.descriptor,
            AltimeterProxy.descriptor,
            AltimeterDelegateProxy.descriptor,
            ActivityRecognizerProxy.descriptor,
            ActivityRecognizerDelegateProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        MotionManagerProxy.register(DarwinMotionManager.self, in: registrar)
        MotionManagerDelegateProxy.registerInterface(in: registrar)
        PedometerProxy.register(DarwinPedometer.self, in: registrar)
        PedometerDelegateProxy.registerInterface(in: registrar)
        AltimeterProxy.register(DarwinAltimeter.self, in: registrar)
        AltimeterDelegateProxy.registerInterface(in: registrar)
        ActivityRecognizerProxy.register(DarwinActivityRecognizer.self, in: registrar)
        ActivityRecognizerDelegateProxy.registerInterface(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [Capability("motion"): MotionPermission()]
    }
}
