import DarwinHost
import DynamicNetworking
import DynamicRuntime
import RuntimeNative

/// The `DynamicNetworking` contracts over URLSession (`HostRuntime.md` §5.1).
///
/// `.network` is granted by `DarwinHost` itself, so this module has no
/// permission providers.
public enum DarwinNetworking: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            HTTPSessionProxy.descriptor,
            HTTPSessionConfigurationProxy.descriptor,
            HTTPRequestProxy.descriptor,
            HTTPResponseProxy.descriptor,
            HTTPTaskProxy.descriptor,
            HTTPTaskDelegateProxy.descriptor,
            HTTPCredentialProxy.descriptor,
            ParsedURLProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        if let native = registrar as? NativeRuntime {
            self.native = native
        }
        HTTPSessionProxy.register(DarwinHTTPSession.self, in: registrar)
        HTTPSessionConfigurationProxy.register(DarwinHTTPSessionConfiguration.self, in: registrar)
        HTTPRequestProxy.register(DarwinHTTPRequest.self, in: registrar)
        HTTPResponseProxy.register(DarwinHTTPResponse.self, in: registrar)
        HTTPTaskProxy.register(DarwinHTTPTask.self, in: registrar)
        HTTPCredentialProxy.register(DarwinHTTPCredential.self, in: registrar)
        ParsedURLProxy.register(DarwinURL.self, in: registrar)
        HTTPTaskDelegateProxy.registerInterface(in: registrar)
    }

    /// The runtime the guest's proxies come from, for recovering this
    /// module's own objects from them (`host(_:as:)`). The last
    /// `NativeRuntime` registered with, else `NativeRuntime.shared`.
    nonisolated(unsafe) static var native: NativeRuntime?

    /// The object of this module behind `value`.
    ///
    /// Objects the guest passes back, such as a configuration, a request or a
    /// credential, arrive as proxies even when this module made them. Some
    /// contracts can't be read back through their protocol (a credential's
    /// password is write-only), so the implementation recovers its own
    /// object. Returns `nil` for an object implemented elsewhere, such as by
    /// the guest.
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
