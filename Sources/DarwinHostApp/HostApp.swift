import DarwinAuthentication
import DarwinBackgroundTasks
import DarwinBluetooth
import DarwinClipboard
import DarwinDefaults
import DarwinDevice
import DarwinDocuments
import DarwinFiles
import DarwinGraphics
import DarwinHost
import DarwinLocation
import DarwinMedia
import DarwinModelStore
import DarwinMotion
import DarwinNetworking
import DarwinNFC
import DarwinNotifications
import DarwinSecrets
import DarwinText
import DarwinUI
import DarwinWebKit
import Foundation
import RuntimeFormatting

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
            HostFormattingModule.self,
            DarwinUI.self,
            DarwinGraphics.self,
            DarwinWebKit.self,
            DarwinFiles.self,
            DarwinDefaults.self,
            DarwinModelStore.self,
            DarwinDocuments.self,
            DarwinNotifications.self,
            DarwinMedia.self,
            DarwinBackgroundTasks.self,
            DarwinClipboard.self,
            DarwinText.self,
            DarwinSecrets.self,
            DarwinAuthentication.self,
        ]
    }

    /// Starts the SwiftUI app, which starts the guest once the app has
    /// launched. Never returns.
    public static func run(_ entry: AppEntryPoints) -> Never {
        HostSession.shared.entry = entry
        HostFormattingModule.logToHost()
        RuntimeHostApp.main()
        exit(0)
    }
}
