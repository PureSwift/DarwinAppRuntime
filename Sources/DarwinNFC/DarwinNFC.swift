import DarwinHost
import DynamicNFC
import DynamicRuntime
import RuntimeNative
#if canImport(CoreNFC) && os(iOS) && !targetEnvironment(macCatalyst)
import CoreNFC
#endif

/// The `DynamicNFC` contracts over CoreNFC (`HostRuntime.md` §5.1).
///
/// CoreNFC reads tags only on iOS. Elsewhere (macOS, Mac Catalyst):
/// - `register(in:)` registers nothing, so `rt_class` returns `0` for every
///   NFC contract and the guest sees NFC as unsupported
///   (`AsyncNFCReader.availability`);
/// - `contracts` still lists them all, so an app that uses NFC passes the
///   host's startup check and runs without it;
/// - the `nfc` capability is `unavailable`.
public enum DarwinNFC: HostModule {

    /// Every NFC contract and the delegate interface, on every platform.
    public static var contracts: [ContractDescriptor] {
        [
            NFCReaderProxy.descriptor,
            NFCReaderDelegateProxy.descriptor,
            NFCTagProxy.descriptor,
            NDEFMessageProxy.descriptor,
            NDEFRecordProxy.descriptor,
        ]
    }

    /// Whether this platform has CoreNFC reader sessions.
    public static var isSupported: Bool {
        #if canImport(CoreNFC) && os(iOS) && !targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    public static func register(in registrar: some ContractRegistrar) {
        #if canImport(CoreNFC) && os(iOS) && !targetEnvironment(macCatalyst)
        if let native = registrar as? NativeRuntime {
            self.native = native
        }
        NFCReaderProxy.register(DarwinNFCReader.self, in: registrar)
        NFCTagProxy.register(DarwinNFCTag.self, in: registrar)
        NDEFMessageProxy.register(DarwinNDEFMessage.self, in: registrar)
        NDEFRecordProxy.register(DarwinNDEFRecord.self, in: registrar)
        NFCReaderDelegateProxy.registerInterface(in: registrar)
        #endif
    }

    /// `granted` where the device can read tags: NFC has no prompt, the
    /// session's sheet is the consent. `unavailable` otherwise.
    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        #if canImport(CoreNFC) && os(iOS) && !targetEnvironment(macCatalyst)
        return [Capability("nfc"): NFCPermission()]
        #else
        return [Capability("nfc"): UnavailablePermission()]
        #endif
    }

    // MARK: Own objects

    /// The runtime the guest's proxies come from, for recovering this
    /// module's own objects from them (`host(_:as:)`). The last
    /// `NativeRuntime` registered with, else `NativeRuntime.shared`.
    nonisolated(unsafe) static var native: NativeRuntime?

    /// The object of this module behind `value`.
    ///
    /// A tag or message the guest passes back arrives as a proxy even when
    /// this module made it. Returns `nil` for an object implemented
    /// elsewhere, such as by the guest.
    static func host<T: AnyObject>(_ value: AnyObject, as type: T.Type) -> T? {
        if let object = value as? T {
            return object
        }
        guard let proxy = value as? DynamicObject else {
            return nil
        }
        return (native ?? .shared).swiftObject(for: proxy) as? T
    }
}

#if canImport(CoreNFC) && os(iOS) && !targetEnvironment(macCatalyst)
/// The `nfc` capability: there's no prompt, so it's granted wherever the
/// device can read tags.
final class NFCPermission: PermissionProvider {

    func status() -> PermissionStatus {
        NFCReaderSession.readingAvailable ? .granted : .unavailable
    }

    func request(_ completion: @escaping (PermissionStatus) -> Void) {
        completion(status())
    }
}
#endif
