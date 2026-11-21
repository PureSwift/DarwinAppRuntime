import DarwinFiles
import DarwinHost
import DarwinUI
import DynamicRuntime
import RuntimeText
import SwiftUI

/// The text contract (`HostRuntime.md` §5.12): `TextStorage`, with its
/// delegate and callback.
///
/// The contract is AppRuntime's `HostTextStorage`, which reads and writes
/// files off the main thread, keeps `\n` as the only line break, moves
/// positions out of surrogate pairs, keeps whether the text is modified,
/// and searches. This module gives it a text view per text
/// (`TextViewEngine`), and the encodings Foundation has.
///
/// Registering it also gives the SwiftUI renderer its `TextEditor` views.
public enum DarwinText: DarwinHost.HostModule {

    public static var contracts: [ContractDescriptor] {
        HostTextModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        // A text is loaded from the bundle or the app's files through
        // `HostFiles`, whether or not the app uses `Files` itself.
        DarwinFiles.configureIfNeeded()
        HostTextStorage.platform = platform
        HostTextModule.register(in: registrar)
        TextEditorViews.provider = { node in
            AnyView(TextEditorView(node: node))
        }
    }

    nonisolated(unsafe) static let platform = DarwinTextPlatform()
}
