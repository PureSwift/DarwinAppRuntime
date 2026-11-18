import DarwinHost
import os
import RuntimeFormatting

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
}
