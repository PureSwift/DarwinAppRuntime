import DynamicAuthentication
import DynamicBackgroundTasks
import DynamicBluetooth
import DynamicClipboard
import DynamicCoreModel
import DynamicDefaults
import DynamicDocuments
import DynamicDevice
import DynamicFiles
import DynamicFormatting
import DynamicGraphics
import DynamicLocation
import DynamicMedia
import DynamicMotion
import DynamicNFC
import DynamicNotifications
import DynamicNetworking
import DynamicRuntime
import DynamicSecrets
import DynamicText
import DynamicUI
import DynamicWebKit

/// What this host implements: its contract modules and their descriptors
/// (`HostRuntime.md` §3), which compatibility checks a bundle against
/// (`ManifestPackager.md` §3, step 2).
///
/// The table mirrors the host modules (`DarwinBluetooth`, …) and their
/// `HostModule.contracts`. The packager doesn't link them, so it doesn't
/// depend on the frameworks they use.
public enum HostContracts {

    /// A host module and the contracts and callback interfaces it registers.
    public struct Module: Sendable {

        /// The host module, such as `DarwinBluetooth` or AppRuntime's
        /// `RuntimeFormatting`.
        public var name: String

        public var descriptors: [ContractDescriptor]

        /// Where the module is registered.
        public var platforms: Set<ApplePlatform>

        public init(name: String, descriptors: [ContractDescriptor], platforms: Set<ApplePlatform> = Set(ApplePlatform.allCases)) {
            self.name = name
            self.descriptors = descriptors
            self.platforms = platforms
        }
    }

    /// The rt ABI version the host provides.
    public static var abiVersion: UInt32 {
        runtimeABIVersion
    }

    /// Every host module.
    public static var modules: [Module] {
        [
            Module(name: "DarwinHost", descriptors: BuiltinContracts.all),
            Module(name: "DarwinBluetooth", descriptors: [
                BluetoothCentralProxy.descriptor, BluetoothCentralDelegateProxy.descriptor,
                BluetoothPeripheralProxy.descriptor, BluetoothPeripheralDelegateProxy.descriptor,
                BluetoothServiceProxy.descriptor, BluetoothCharacteristicProxy.descriptor,
                BluetoothDescriptorProxy.descriptor, BluetoothAdvertisementProxy.descriptor,
            ]),
            Module(name: "DarwinLocation", descriptors: [
                LocationManagerProxy.descriptor, LocationManagerDelegateProxy.descriptor,
                LocationProxy.descriptor, HeadingProxy.descriptor,
            ]),
            Module(name: "DarwinMotion", descriptors: [
                MotionManagerProxy.descriptor, MotionManagerDelegateProxy.descriptor,
                PedometerProxy.descriptor, PedometerDelegateProxy.descriptor,
                AltimeterProxy.descriptor, AltimeterDelegateProxy.descriptor,
                ActivityRecognizerProxy.descriptor, ActivityRecognizerDelegateProxy.descriptor,
            ]),
            // CoreNFC is iOS-only: on macOS the contracts aren't registered.
            Module(name: "DarwinNFC", descriptors: [
                NFCReaderProxy.descriptor, NFCReaderDelegateProxy.descriptor,
                NFCTagProxy.descriptor, NDEFMessageProxy.descriptor, NDEFRecordProxy.descriptor,
            ], platforms: [.ios, .iosSimulator]),
            Module(name: "DarwinDevice", descriptors: [
                DeviceProxy.descriptor, DeviceDelegateProxy.descriptor,
            ]),
            Module(name: "DarwinNetworking", descriptors: [
                HTTPSessionProxy.descriptor, HTTPSessionConfigurationProxy.descriptor,
                HTTPRequestProxy.descriptor, HTTPResponseProxy.descriptor,
                HTTPTaskProxy.descriptor, HTTPTaskDelegateProxy.descriptor,
                HTTPCredentialProxy.descriptor, ParsedURLProxy.descriptor,
            ]),
            // AppRuntime's, shared with the Linux host.
            Module(name: "RuntimeFormatting", descriptors: [
                NumberFormatProxy.descriptor, DateFormatProxy.descriptor, LocaleInfoProxy.descriptor,
            ]),
            Module(name: "DarwinUI", descriptors: [
                RendererProxy.descriptor, RendererDelegateProxy.descriptor,
            ]),
            Module(name: "DarwinWebKit", descriptors: [
                WebContentProxy.descriptor, WebContentDelegateProxy.descriptor,
            ]),
            Module(name: "DarwinGraphics", descriptors: [
                SurfaceProxy.descriptor, SurfaceDelegateProxy.descriptor,
            ]),
            Module(name: "DarwinFiles", descriptors: [
                FilesProxy.descriptor, FileCallbackProxy.descriptor,
            ]),
            Module(name: "DarwinDefaults", descriptors: [DefaultsProxy.descriptor]),
            Module(name: "DarwinDocuments", descriptors: [
                DocumentsProxy.descriptor, DocumentGrantProxy.descriptor,
                DocumentCallbackProxy.descriptor, DocumentsDelegateProxy.descriptor,
            ]),
            Module(name: "DarwinNotifications", descriptors: [
                NotificationsProxy.descriptor, NotificationRecordProxy.descriptor,
                NotificationCallbackProxy.descriptor, NotificationsDelegateProxy.descriptor,
                PushNotificationsProxy.descriptor, PushCallbackProxy.descriptor, PushDelegateProxy.descriptor,
            ]),
            Module(name: "DarwinBackgroundTasks", descriptors: [
                BackgroundTasksProxy.descriptor, BackgroundTasksDelegateProxy.descriptor, BackgroundCallbackProxy.descriptor,
            ]),
            Module(name: "DarwinClipboard", descriptors: [ClipboardProxy.descriptor, ClipboardCallbackProxy.descriptor]),
            Module(name: "DarwinText", descriptors: [
                TextStorageProxy.descriptor, TextStorageDelegateProxy.descriptor, TextCallbackProxy.descriptor,
            ]),
            Module(name: "DarwinSecrets", descriptors: [SecretsProxy.descriptor, SecretCallbackProxy.descriptor]),
            Module(name: "DarwinAuthentication", descriptors: [
                WebAuthenticationProxy.descriptor, WebAuthenticationCallbackProxy.descriptor,
            ]),
            Module(name: "DarwinMedia", descriptors: [MediaPlaybackProxy.descriptor, MediaPlaybackDelegateProxy.descriptor]),
            Module(name: "DarwinModelStore", descriptors: [
                ModelStoreProxy.descriptor, ModelSchemaProxy.descriptor, ModelEntityProxy.descriptor,
                ModelPropertyProxy.descriptor, ModelFetchProxy.descriptor, ModelPredicateProxy.descriptor,
                ModelExpressionProxy.descriptor, ModelRecordProxy.descriptor, ModelResultsProxy.descriptor,
                ModelBatchProxy.descriptor, ModelStoreCallbackProxy.descriptor, ModelStoreDelegateProxy.descriptor,
            ]),
        ]
    }

    /// The descriptors registered on `platform`, by name.
    public static func descriptors(for platform: ApplePlatform) -> [String: ContractDescriptor] {
        var descriptors = [String: ContractDescriptor]()
        for module in modules where module.platforms.contains(platform) {
            for descriptor in module.descriptors {
                descriptors[descriptor.name] = descriptor
            }
        }
        return descriptors
    }

    /// The module that registers a contract on some platform.
    public static func module(registering name: String) -> Module? {
        modules.first { $0.descriptors.contains { $0.name == name } }
    }
}
