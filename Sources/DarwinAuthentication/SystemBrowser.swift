import AuthenticationServices
import DynamicAuthentication
import Foundation
import RuntimeAuthentication
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// `HostWebAuthentication`'s presenter: the system's browser, through
/// `ASWebAuthenticationSession`, over the app's window. The redirect is
/// the platform's default, `scheme:/path`, and the session is told the
/// scheme.
///
/// Main thread only.
final class SystemBrowser: NSObject, WebAuthenticationPresenter {

    private var session: ASWebAuthenticationSession?

    func present(_ url: String, redirect: String, ephemeral: Bool,
                 completion: @escaping (Result<String, WebAuthenticationError>) -> Void) {
        guard let address = URL(string: url), let scheme = Self.scheme(of: redirect) else {
            completion(.failure(.invalidURL))
            return
        }
        let session = ASWebAuthenticationSession(url: address, callbackURLScheme: scheme) { [weak self] callback, error in
            DispatchQueue.main.async {
                self?.session = nil
                completion(Self.result(callback, error))
            }
        }
        session.prefersEphemeralWebBrowserSession = ephemeral
        session.presentationContextProvider = self
        self.session = session
        guard session.start() else {
            // Not from a user action, or the app isn't in front.
            self.session = nil
            completion(.failure(.notAllowed))
            return
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
    }

    /// The scheme a redirect is called back on: what's before its `:`.
    static func scheme(of redirect: String) -> String? {
        guard let colon = redirect.firstIndex(of: ":"), colon > redirect.startIndex else { return nil }
        return String(redirect[..<colon])
    }

    static func result(_ callback: URL?, _ error: Error?) -> Result<String, WebAuthenticationError> {
        if let callback {
            return .success(callback.absoluteString)
        }
        guard let error = error as? ASWebAuthenticationSessionError else {
            return .failure(.unknown)
        }
        switch error.code {
        case .canceledLogin:
            return .failure(.canceledLogin)
        case .presentationContextNotProvided, .presentationContextInvalid:
            return .failure(.notAllowed)
        @unknown default:
            return .failure(.unknown)
        }
    }
}

extension SystemBrowser: ASWebAuthenticationPresentationContextProviding {

    /// The app's window, which the page is shown over.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
        #else
        return NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #endif
    }
}
