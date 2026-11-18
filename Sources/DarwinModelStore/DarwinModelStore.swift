import DarwinFiles
import DarwinHost
import DynamicRuntime
import Foundation
import RuntimeCoreModel

/// The model store contracts (`HostRuntime.md` §5.6): `ModelStore` and the
/// objects it's described and queried with.
///
/// The contracts are AppRuntime's `HostModelStore`, over any CoreModel
/// backend. This module gives it the backend, `CoreDataStores`: a SQLite
/// file for each store, through Core Data, in the app's `Library/Stores`.
/// It answers on the main queue inside an autorelease pool.
public enum DarwinModelStore: DarwinHost.HostModule {

    public static var contracts: [ContractDescriptor] {
        HostModelStoreModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        configure()
        HostModelStoreModule.register(in: registrar)
    }

    /// Where the stores are kept. Read when the module is registered.
    nonisolated(unsafe) static var directory: () -> String = {
        FileLocations.current(bundle: DarwinBundle.bundle).stores
    }

    static func configure() {
        HostModelStore.configure(.init(provider: CoreDataStores(directory: directory()), deliver: { answer in
            DispatchQueue.main.async {
                autoreleasepool(invoking: answer)
            }
        }))
    }
}
