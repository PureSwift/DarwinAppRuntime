import DarwinFiles
import DarwinHost
import DynamicRuntime
import RuntimeClipboard

/// The clipboard contract (`HostRuntime.md` §5.11): `Clipboard`, with its
/// callback.
///
/// The contract is AppRuntime's `HostClipboard`, which tells a PNG from a
/// JPEG, reads and writes image files through `HostFiles`, and answers each
/// callback once. This module gives it the system's pasteboard
/// (`SystemPasteboard`). No capability: the platforms guard a read when it
/// happens.
public enum DarwinClipboard: DarwinHost.HostModule {

    public static var contracts: [ContractDescriptor] {
        HostClipboardModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        // An image is copied from a file and pasted into one, found through
        // `HostFiles`, whether or not the app uses `Files` itself.
        DarwinFiles.configureIfNeeded()
        HostClipboard.platform = SystemPasteboard()
        HostClipboardModule.register(in: registrar)
    }
}
