import DynamicDefaults
import Foundation
import RuntimeHost
import Testing
@testable import DarwinDefaults

/// The module: `HostDefaults` over the app's suite. `HostDefaults` is
/// AppRuntime's, tested there; this checks what the Darwin host gives it.
@Suite("Defaults", .serialized)
final class DarwinDefaultsTests {

    let suite = "org.pureswift.DarwinDefaultsTests.\(UUID().uuidString)"

    init() {
        let suite = suite
        DarwinDefaults.suite = { suite }
        DarwinDefaults.configure()
    }

    deinit {
        HostDefaults.storage = nil
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    @Test func moduleListsItsContract() {
        #expect(DarwinDefaults.contracts.map(\.name) == ["org.pureswift.data.Defaults"])
    }

    @Test func theContractKeepsValuesInTheSuite() {
        let defaults = HostDefaults.standard()
        #expect(defaults.setString("true", key: "soundOn"))
        #expect(defaults.setString("0.5", key: "volume"))
        #expect(defaults.setData([1, 2], key: "Zebra"))
        #expect(!defaults.setString("x", key: ""), "an empty key is refused")
        #expect(defaults.keys() == ["Zebra", "soundOn", "volume"], "by UTF-8 bytes")
        #expect(defaults.string("soundOn") == "true")
        #expect(defaults.data("Zebra") == [1, 2])

        let stored = UserDefaults.standard.persistentDomain(forName: suite)
        #expect(stored?["volume"] as? String == "0.5")
        #expect(stored?["Zebra"] as? Data == Data([1, 2]))
        #expect(UserDefaults.standard.object(forKey: "soundOn") == nil, "not in the host's own settings")
    }

    @Test func aValueOverTheLimitIsRefused() {
        let defaults = HostDefaults.standard()
        #expect(defaults.setString(String(repeating: "x", count: 64 << 10), key: "k"))
        #expect(!defaults.setString(String(repeating: "x", count: (64 << 10) + 1), key: "k"))
        #expect(defaults.string("k")?.utf8.count == 64 << 10)
    }
}
