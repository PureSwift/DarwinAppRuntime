import DarwinBluetooth
import DarwinDevice
import DarwinFormatting
import DarwinHost
import DarwinLocation
import DarwinMotion
import DarwinNetworking
import DarwinNFC
import DarwinUI
import Foundation

/// The app's `main`. The packager generates it:
///
/// ```swift
/// import DarwinHostApp
///
/// HostApp.run(AppEntryPoints(main: rt_main, dispatch: rt_dispatch, finalize: rt_finalize))
/// ```
public enum HostApp {

    /// Every contract module this host implements. `AppHost` registers the
    /// ones the app uses.
    public static var modules: [any HostModule.Type] {
        [
            DarwinBluetooth.self,
            DarwinLocation.self,
            DarwinMotion.self,
            DarwinNFC.self,
            DarwinDeviceModule.self,
            DarwinNetworking.self,
            DarwinFormatting.self,
            DarwinUI.self,
        ]
    }

    /// Starts the SwiftUI app, which starts the guest once the app has
    /// launched. Never returns.
    public static func run(_ entry: AppEntryPoints) -> Never {
        HostSession.shared.entry = entry
        RuntimeHostApp.main()
        exit(0)
    }
}
