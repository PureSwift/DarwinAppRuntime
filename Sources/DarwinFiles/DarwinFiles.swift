import DarwinHost
import DynamicFiles
import DynamicRuntime
import Foundation
import RuntimeHost

/// The files contracts (`HostRuntime.md` §5.4): `Files`, with its
/// `FileCallback`.
///
/// The work is AppRuntime's `HostFiles`, over POSIX calls on a serial
/// queue. This module says where the directories are (`FileLocations`),
/// and answers on the main queue inside an autorelease pool.
public enum DarwinFiles: DarwinHost.HostModule {

    public static var contracts: [ContractDescriptor] {
        [FilesProxy.descriptor, FileCallbackProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        configure()
        FilesProxy.register(HostFiles.self, in: registrar)
        FileCallbackProxy.registerInterface(in: registrar)
    }

    /// Where the app's files are. Read when the module is registered.
    nonisolated(unsafe) static var directories: () -> [FileDirectory: String] = {
        FileLocations.current(bundle: DarwinBundle.bundle).directories
    }

    /// Makes the writable directories and empties `temporary`. If that
    /// fails, it's logged, and every operation fails with `notFound`.
    static func configure() {
        let configuration = HostFiles.Configuration(directories: directories(), deliver: { answer in
            DispatchQueue.main.async {
                autoreleasepool(invoking: answer)
            }
        })
        do throws(FileError) {
            try HostFiles.configure(configuration)
        } catch {
            AppHost.logger.error("Couldn't prepare the app's directories: \(String(describing: error), privacy: .public)")
        }
    }
}
