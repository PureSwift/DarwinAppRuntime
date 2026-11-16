import DarwinHost
import DarwinUI
import DynamicRuntime
import DynamicWebKit
import SwiftUI

/// The web contracts (`HostRuntime.md` §5.2): `WebContent` over `WKWebView`,
/// with its `WebContentDelegate`.
///
/// Registering the module also gives the SwiftUI renderer its `WebView`
/// views. An app that doesn't use `WebContent` gets neither, and its
/// `WebView` nodes show nothing.
public enum DarwinWebKit: HostModule {

    public static var contracts: [ContractDescriptor] {
        [WebContentProxy.descriptor, WebContentDelegateProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        WebContentProxy.register(DarwinWebContent.self, in: registrar)
        WebContentDelegateProxy.registerInterface(in: registrar)
        WebViews.provider = { identifier in
            AnyView(WebContentView(identifier: identifier))
        }
    }
}
