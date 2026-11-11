import DynamicRuntime
import Testing
@testable import DarwinHost
import RuntimeABI
import RuntimeCore
import RuntimeNative

/// A module with one contract, recording its registrations.
enum UsedModule: HostModule {

    nonisolated(unsafe) static var registrations = 0

    static let contracts = [
        ContractDescriptor(name: "org.example.Used", kind: .contract, version: 2, methods: [MethodDescriptor("ping", "()V")]),
    ]

    static func register(in registrar: some ContractRegistrar) {
        registrations += 1
        for descriptor in contracts {
            registrar.register(descriptor, statics: nil)
        }
    }

    static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.bluetooth: FakePermission(.granted, answer: .granted)]
    }
}

/// A module the app doesn't use.
enum UnusedModule: HostModule {

    nonisolated(unsafe) static var registrations = 0

    static let contracts = [
        ContractDescriptor(name: "org.example.Unused", kind: .contract, version: 1, methods: []),
    ]

    static func register(in registrar: some ContractRegistrar) {
        registrations += 1
    }
}

/// `prepare()` binds `DynamicRuntime` and sets the built-ins' static state,
/// so the suite is serialized and restores both.
@Suite(.serialized) struct AppHostTests {

    func info(contracts: [AppInfo.Contract], abiVersion: UInt32 = runtimeABIVersion) -> AppInfo {
        AppInfo(identifier: "org.example.App", abiVersion: abiVersion, capabilities: [.bluetooth], contracts: contracts)
    }

    func prepare(_ info: AppInfo) throws(AppHostError) -> AppHost {
        let host = AppHost(info: info, modules: [UsedModule.self, UnusedModule.self], native: NativeRuntime(), clock: ManualClock())
        try host.prepare()
        return host
    }

    @Test func refusesANewerABI() {
        #expect(throws: AppHostError.self) {
            _ = try prepare(info(contracts: [], abiVersion: runtimeABIVersion + 1))
        }
    }

    @Test func refusesContractsThisHostLacks() {
        #expect(throws: AppHostError.incompatible("org.example.Missing isn't implemented by this host")) {
            _ = try prepare(info(contracts: [.init(name: "org.example.Missing", version: 1, kind: .contract)]))
        }
        #expect(throws: AppHostError.incompatible("org.example.Used is a different kind of interface on this host")) {
            _ = try prepare(info(contracts: [.init(name: "org.example.Used", version: 1, kind: .callback)]))
        }
    }

    @Test func registersBuiltinsAndTheModulesTheAppUses() throws {
        let binding = Runtime.binding
        defer {
            Runtime.binding = binding
            DarwinPermissions.declared = []
            DarwinPermissions.providers = [:]
        }
        UsedModule.registrations = 0
        UnusedModule.registrations = 0

        let host = try prepare(info(contracts: [
            .init(name: "org.example.Used", version: 3, kind: .contract),
            .init(name: BuiltinContracts.applicationName, version: 1, kind: .contract),
        ]))
        #expect(UsedModule.registrations == 1)
        #expect(UnusedModule.registrations == 0)
        #expect(host.warnings == ["org.example.Used is version 2 on this host; the app was built against 3"])
        #expect(host.native.capabilities == [.bluetooth])
        #expect(host.native.runtime.clock is ManualClock)
        #expect(host.native.runtime.descriptor(named: "org.example.Used")?.version == 2)
        #expect(host.native.runtime.descriptor(named: "org.example.Unused") == nil)
        #expect(DarwinPermissions.declared == [.bluetooth])
        #expect(DarwinPermissions.providers[.bluetooth] is FakePermission, "a module's provider")
        #expect(DarwinPermissions.providers[.network] is GrantedPermission, "the system's")
        // The built-ins are implemented, and the host's own proxies reach them
        // through the direct binding.
        #expect(try AppBundleProxy.identifier() == DarwinBundle.identifier())
        #expect(try PermissionsProxy.status(.bluetooth) == PermissionStatus.granted.rawValue)
        #expect(try PermissionsProxy.status(.camera) == PermissionStatus.denied.rawValue, "not declared")
        #expect(Set(host.providedContracts.keys).isSuperset(of: BuiltinContracts.all.map(\.name)))
    }
}
