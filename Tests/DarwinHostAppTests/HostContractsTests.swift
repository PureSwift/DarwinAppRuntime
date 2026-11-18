import DarwinHost
import DarwinHostApp
import DarwinPackager
import DynamicRuntime
import Testing

/// The packager doesn't link the host modules, so it keeps its own table of
/// what they implement. This checks the table against the modules.
@Suite struct HostContractsTests {

    @Test func packagerTableMatchesTheHostModules() {
        var host = [String: ContractDescriptor]()
        for descriptor in BuiltinContracts.all + HostApp.modules.flatMap({ $0.contracts }) {
            host[descriptor.name] = descriptor
        }
        var packager = [String: ContractDescriptor]()
        for module in HostContracts.modules {
            for descriptor in module.descriptors {
                packager[descriptor.name] = descriptor
            }
        }
        #expect(Set(packager.keys) == Set(host.keys))
        for (name, descriptor) in host {
            #expect(packager[name] == descriptor, "\(name)")
        }
    }

    @Test func everyModuleIsInTheTable() {
        let names = Set(HostContracts.modules.map(\.name))
        for module in HostApp.modules {
            // The Swift module the type is in: `DarwinDevice` for
            // `DarwinDevice.DarwinDeviceModule`.
            let name = String(reflecting: module)
            let moduleName = String(name.prefix { $0 != "." })
            #expect(names.contains(moduleName), "\(name)")
        }
    }
}
