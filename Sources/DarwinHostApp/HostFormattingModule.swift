import DarwinHost
import Foundation
import os
import RuntimeFormatting
#if canImport(UIKit)
import UIKit
#endif

/// The formatting contracts (`HostRuntime.md` §5.1): AppRuntime's
/// `RuntimeFormatting`, which the Linux host shares, as one of this host's
/// modules.
extension HostFormattingModule: DarwinHost.HostModule {

    /// Sends what a guest asks for that the contracts don't know, such as an
    /// unknown style or time zone, to the host's log.
    static func logToHost() {
        HostFormattingModule.log = { message in
            AppHost.logger.error("\(message, privacy: .public)")
        }
    }

    /// Tells the system's clock when the app returns from the background,
    /// so a guest hears of a zone, locale or day that changed while it was
    /// suspended. Foundation's own notifications cover the rest. A macOS app
    /// isn't suspended, so it's told as things change.
    static func followForeground() {
        #if canImport(UIKit)
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            HostSystemClock.applicationWillEnterForeground()
        }
        #endif
    }
}
