import DarwinHost
import DynamicNetworking
import Foundation

/// `HTTPSessionConfiguration` over a `URLSessionConfiguration`. A session
/// copies it when it's made, so later changes don't reach that session.
public final class DarwinHTTPSessionConfiguration: HTTPSessionConfiguration {

    /// The settings. Tests set `protocolClasses` here to answer requests
    /// without a network.
    public let urlSessionConfiguration: URLSessionConfiguration

    public init(_ configuration: URLSessionConfiguration) {
        self.urlSessionConfiguration = configuration
    }

    public static func makeDefault() -> DarwinHTTPSessionConfiguration {
        DarwinHTTPSessionConfiguration(.default)
    }

    public static func makeEphemeral() -> DarwinHTTPSessionConfiguration {
        DarwinHTTPSessionConfiguration(.ephemeral)
    }

    public func setTimeoutForRequest(_ seconds: Double) {
        urlSessionConfiguration.timeoutIntervalForRequest = seconds
    }

    public func timeoutForRequest() -> Double {
        urlSessionConfiguration.timeoutIntervalForRequest
    }

    public func setTimeoutForResource(_ seconds: Double) {
        urlSessionConfiguration.timeoutIntervalForResource = seconds
    }

    public func timeoutForResource() -> Double {
        urlSessionConfiguration.timeoutIntervalForResource
    }

    public func setAllowsCellularAccess(_ allowed: Bool) {
        urlSessionConfiguration.allowsCellularAccess = allowed
    }

    public func setAllowsExpensiveNetworkAccess(_ allowed: Bool) {
        urlSessionConfiguration.allowsExpensiveNetworkAccess = allowed
    }

    public func setAllowsConstrainedNetworkAccess(_ allowed: Bool) {
        urlSessionConfiguration.allowsConstrainedNetworkAccess = allowed
    }

    public func setWaitsForConnectivity(_ waits: Bool) {
        urlSessionConfiguration.waitsForConnectivity = waits
    }

    public func setShouldSetCookies(_ enabled: Bool) {
        urlSessionConfiguration.httpShouldSetCookies = enabled
    }

    public func setCachePolicy(_ policy: Int32) {
        urlSessionConfiguration.requestCachePolicy = URLRequest.CachePolicy(contract: policy)
    }

    public func setMaximumConnectionsPerHost(_ count: Int32) {
        urlSessionConfiguration.httpMaximumConnectionsPerHost = Int(count)
    }

    public func setAdditionalHeader(_ name: String, value: String?) {
        var headers = urlSessionConfiguration.httpAdditionalHeaders ?? [:]
        // Header names are case-insensitive: replace any spelling of `name`.
        for key in headers.keys {
            if let key = key as? String, key.caseInsensitiveCompare(name) == .orderedSame {
                headers.removeValue(forKey: key)
            }
        }
        if let value {
            headers[name] = value
        }
        urlSessionConfiguration.httpAdditionalHeaders = headers.isEmpty ? nil : headers
    }

    /// A copy of `configuration`'s settings for a new session. One this
    /// module didn't make can only be read back partly, through its
    /// protocol: the defaults with its timeouts.
    static func urlSessionConfiguration(for configuration: any HTTPSessionConfiguration) -> URLSessionConfiguration {
        if let own = DarwinNetworking.host(configuration, as: DarwinHTTPSessionConfiguration.self) {
            return own.urlSessionConfiguration.copy() as! URLSessionConfiguration
        }
        AppHost.logger.warning("HTTPSession.make: the configuration wasn't made by this host; only its timeouts apply")
        let copy = URLSessionConfiguration.default
        copy.timeoutIntervalForRequest = configuration.timeoutForRequest()
        copy.timeoutIntervalForResource = configuration.timeoutForResource()
        return copy
    }
}

extension URLRequest.CachePolicy {

    /// The policy for an `HTTPCachePolicy` raw value; unknown values follow
    /// the protocol's cache rules.
    init(contract policy: Int32) {
        switch HTTPCachePolicy(rawValue: policy) {
        case .reloadIgnoringLocalCacheData: self = .reloadIgnoringLocalCacheData
        case .returnCacheDataElseLoad: self = .returnCacheDataElseLoad
        case .returnCacheDataDontLoad: self = .returnCacheDataDontLoad
        case .useProtocolCachePolicy, nil: self = .useProtocolCachePolicy
        }
    }

    /// The `HTTPCachePolicy` raw value; policies the contract lacks are
    /// `useProtocolCachePolicy`.
    var contractValue: Int32 {
        switch self {
        case .reloadIgnoringLocalCacheData, .reloadIgnoringLocalAndRemoteCacheData, .reloadRevalidatingCacheData:
            HTTPCachePolicy.reloadIgnoringLocalCacheData.rawValue
        case .returnCacheDataElseLoad:
            HTTPCachePolicy.returnCacheDataElseLoad.rawValue
        case .returnCacheDataDontLoad:
            HTTPCachePolicy.returnCacheDataDontLoad.rawValue
        default:
            HTTPCachePolicy.useProtocolCachePolicy.rawValue
        }
    }
}
