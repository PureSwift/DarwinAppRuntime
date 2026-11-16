import DarwinHost
import DarwinUI
import DynamicGraphics
import DynamicRuntime
import SwiftUI

/// The Graphics contracts (`HostRuntime.md` §5.2): `Surface` over EAGL on
/// iOS and desktop OpenGL on macOS, with its `SurfaceDelegate`.
///
/// Registering the module also gives the SwiftUI renderer its `GLSurface`
/// views. An app that doesn't use `Surface` gets neither, and its
/// `GLSurface` nodes show nothing.
public enum DarwinGraphics: HostModule {

    public static var contracts: [ContractDescriptor] {
        [SurfaceProxy.descriptor, SurfaceDelegateProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        SurfaceProxy.register(DarwinSurface.self, in: registrar)
        SurfaceDelegateProxy.registerInterface(in: registrar)
        GLSurfaceViews.provider = { identifier in
            AnyView(SurfaceView(identifier: identifier))
        }
    }
}
