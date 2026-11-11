import DarwinHost
import DynamicNetworking
import Foundation
import Network

extension NetworkError {

    /// The contract's code for a URLSession failure (`HTTPClient.md`).
    /// Failures with no matching code are `unknown`; `report(_:)` logs them.
    init(urlSessionError error: Error) {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else {
            self = .unknown
            return
        }
        switch error.code {
        case NSURLErrorCancelled:
            self = .cancelled
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL:
            self = .invalidURL
        case NSURLErrorTimedOut:
            self = .timedOut
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            self = .cannotFindHost
        case NSURLErrorCannotConnectToHost:
            self = .cannotConnectToHost
        case NSURLErrorNetworkConnectionLost:
            self = .connectionLost
        case NSURLErrorNotConnectedToInternet:
            self = Self.unavailableNetwork(error)
        case NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed:
            self = .networkAccessNotAllowed
        case NSURLErrorCallIsActive:
            self = .notConnectedToInternet
        case NSURLErrorSecureConnectionFailed, NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired:
            self = .secureConnectionFailed
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
            self = .serverCertificateUntrusted
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            self = .insecureConnectionNotAllowed
        case NSURLErrorHTTPTooManyRedirects:
            self = .tooManyRedirects
        case NSURLErrorBadServerResponse, NSURLErrorRedirectToNonExistentLocation,
            NSURLErrorZeroByteResource, NSURLErrorCannotDecodeRawData,
            NSURLErrorCannotDecodeContentData, NSURLErrorCannotParseResponse:
            self = .badServerResponse
        case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication:
            self = .userAuthenticationRequired
        // A cache-only load with nothing cached.
        case NSURLErrorResourceUnavailable, NSURLErrorCannotLoadFromNetwork:
            self = .resourceUnavailable
        default:
            self = .unknown
        }
    }

    /// `NSURLErrorNotConnectedToInternet` covers a network that's there but
    /// that the configuration or the user disallowed.
    private static func unavailableNetwork(_ error: NSError) -> NetworkError {
        if let reason = (error as Error as? URLError)?.networkUnavailableReason {
            switch reason {
            case .cellular, .expensive, .constrained:
                return .networkAccessNotAllowed
            default:
                break
            }
        }
        // The path URLSession gave up on says if local network access was
        // denied (iOS 14+). The key isn't public API, so its absence is
        // normal.
        if let path = error.userInfo["_NSURLErrorNWPathKey"] as? nw_path_t,
           nw_path_get_unsatisfied_reason(path) == nw_path_unsatisfied_reason_local_network_denied {
            return .localNetworkDenied
        }
        return .notConnectedToInternet
    }

    /// Logs a failure the contract has no code for, so it isn't lost.
    static func report(_ error: Error, code: NetworkError, url: URL?) {
        guard code == .unknown else { return }
        let error = error as NSError
        AppHost.logger.error("""
            HTTP task for \(url?.absoluteString ?? "?", privacy: .private) failed with an error the contract has no code for: \
            \(error.domain, privacy: .public) \(error.code, privacy: .public): \(error.localizedDescription, privacy: .public)
            """)
    }
}
