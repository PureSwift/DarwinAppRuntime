import DynamicWebKit
import Foundation
import WebKit

/// What `WKWebView` reports, as the `WebContent` contract carries it
/// (`Contracts/WebKit.md`).
enum WebConversions {

    // MARK: URLs

    /// Whether loading `url` reaches the network: `http`, `https`, `ws` and
    /// `wss`.
    static func isRemote(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "ws", "wss"].contains(scheme)
    }

    /// A URL the guest may `load`: absolute, and not a file (files come
    /// from `loadResource`, which limits what the page reads).
    static func loadableURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme != "file" else {
            return nil
        }
        return url
    }

    /// The file at `path` among the app's resources, or `nil` when it's
    /// missing, a directory, or outside them.
    static func resource(_ path: String, in resources: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        let root = resources.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return url
    }

    // MARK: Navigations

    static func kind(_ type: WKNavigationType) -> WebNavigationKind {
        switch type {
        case .linkActivated: .linkActivated
        case .formSubmitted, .formResubmitted: .formSubmitted
        case .backForward: .backForward
        case .reload: .reload
        default: .other
        }
    }

    /// The `WebError.Code` of a failed navigation, or `nil` when it isn't a
    /// failure: one another navigation replaced, or one a policy refused.
    static func failure(_ error: Error) -> WebError.Code? {
        let error = error as NSError
        switch error.domain {
        case NSURLErrorDomain:
            switch error.code {
            case NSURLErrorCancelled:
                return nil
            case NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorInternationalRoamingOff,
                 NSURLErrorDataNotAllowed, NSURLErrorCallIsActive, NSURLErrorCannotLoadFromNetwork:
                return .network
            case NSURLErrorTimedOut:
                return .timedOut
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired, NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return .security
            case NSURLErrorBadURL, NSURLErrorUnsupportedURL, NSURLErrorFileDoesNotExist,
                 NSURLErrorFileIsDirectory, NSURLErrorNoPermissionsToReadFile:
                return .badURL
            default:
                return .unknown
            }
        case "WebKitErrorDomain":
            switch error.code {
            // Frame load interrupted: a policy refused the navigation.
            case 102: return nil
            // Can't show the URL: a scheme WebKit doesn't handle.
            case 101: return .badURL
            default: return .unknown
            }
        default:
            return .unknown
        }
    }

    // MARK: Scripts

    /// A script's value as JSON text, as `JSON.stringify` would write it:
    /// dates become ISO 8601 strings, and `nil` stands for what JSON can't
    /// hold.
    static func json(_ value: Any?) -> String? {
        guard let value else { return nil }
        let object = jsonObject(value)
        guard JSONSerialization.isValidJSONObject([object]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func jsonObject(_ value: Any) -> Any {
        switch value {
        case let date as Date:
            return isoDate.string(from: date)
        case let array as [Any]:
            return array.map(jsonObject)
        case let dictionary as [String: Any]:
            return dictionary.mapValues(jsonObject)
        default:
            return value
        }
    }

    private static let isoDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// What `evaluateJavaScript`'s completion gives, as the contract's
    /// result and error.
    static func scriptOutcome(_ value: Any?, _ error: Error?) -> (result: String?, error: String?) {
        guard let error = error as NSError? else {
            return (json(value), nil)
        }
        if error.domain == WKError.errorDomain {
            switch error.code {
            case WKError.javaScriptResultTypeIsUnsupported.rawValue:
                // `undefined`, a function, …: no value, and no exception.
                return (nil, nil)
            case WKError.javaScriptExceptionOccurred.rawValue:
                let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String
                return (nil, message ?? error.localizedDescription)
            default:
                break
            }
        }
        return (nil, error.localizedDescription)
    }
}
